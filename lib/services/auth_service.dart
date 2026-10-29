import 'dart:async';
import 'dart:convert';
import 'dart:io' show ContentType, HttpServer, HttpStatus, InternetAddress, SocketException;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/app/app_config.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/services/mfa_recovery_failure.dart';
import 'package:checkpoint/services/session_storage.dart';

/// Google OAuth client IDs.
///
/// The WEB client ID (the same one configured under Supabase Authentication >
/// Google) is required on every platform: it makes Google issue an ID token that
/// Supabase can verify. The iOS client ID is optional and only read on iOS:
///   flutter run --dart-define=GOOGLE_IOS_CLIENT_ID=yyy.apps.googleusercontent.com
const _googleWebClientId = '920307411259-urq6579e0gukditu4839u7djhs3j3p5e.apps.googleusercontent.com';
const _googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

/// Desktop (Linux / Windows / macOS) sign-in returns to this localhost address.
/// It must be allowed in Supabase > Authentication > URL Configuration: that is
/// automatic while it equals the project's Site URL (the default is
/// http://localhost:3000). If you change the Site URL, change the port here too,
/// or add this address to the Redirect URLs list.
const _desktopRedirectPort = 3000;
const _desktopRedirectUrl = 'http://localhost:$_desktopRedirectPort';

/// What an authenticator app needs to add the account, while two-factor
/// authentication is being turned on ([AuthService.enrollTwoFactor]).
class TotpSetup {
  const TotpSetup({required this.factorId, required this.secret, required this.uri});

  /// The factor the first code confirms.
  final String factorId;

  /// The shared key (base32), typed in when the QR code can't be scanned.
  final String secret;

  /// The `otpauth://totp/...` link the QR code holds.
  final String uri;
}

/// All network/auth calls live here so screens and the store stay SDK-light.
///
/// Auth only: the `profiles` row is created and read by CheckpointRepository.
///
/// Requires `google_sign_in: ^6.x` in pubspec.yaml.
class AuthService {
  AuthService(this._client);
  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  /// Google's native account picker only exists on Android and iOS.
  bool get _usesNativeGoogle =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// Desktop has no native picker and no URL scheme registered to catch the
  /// OAuth redirect, so it listens on localhost instead (see [_signInWithGoogleDesktop]).
  bool get _usesLoopbackRedirect =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Sign in with Apple is offered on iOS, through Apple's own sheet: the App
  /// Store requires it of an app that offers Google sign-in. Elsewhere Apple
  /// would need a browser round trip the app has no way to come back from yet.
  bool get offersAppleSignIn =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// The temporary localhost listener of an unfinished desktop sign-in, if any.
  HttpServer? _loopback;

  /// Built on first use and reused, so sign-in and sign-out talk to the same native client.
  late final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: _googleIosClientId.isEmpty ? null : _googleIosClientId,
    serverClientId: _googleWebClientId,
    scopes: ['email', 'profile'],
  );

  /// The user from the session Supabase restored from disk (null = signed out).
  User? get currentUser => _auth.currentUser;

  /// Emits on sign-in, sign-out, token refresh and profile updates.
  Stream<AuthState> get changes => _auth.onAuthStateChange;

  /// Where the links in Supabase's emails (confirm address, reset password)
  /// send the browser. Web returns to whichever host served the app, as Google
  /// sign-in does; elsewhere null leaves it to the project's Site URL.
  String? get _emailRedirectUrl => kIsWeb ? Uri.base.origin : null;

  Future<void> signInWithEmail(String email, String password) =>
      _auth.signInWithPassword(email: email.trim(), password: password);

  /// Returns true when a session exists immediately, false when the project
  /// requires the user to confirm their email address first. [displayName]
  /// becomes the new profile's name (see CheckpointRepository.ensureProfile).
  Future<bool> signUpWithEmail(String email, String password, {String? displayName}) async {
    final name = displayName?.trim() ?? '';
    final res = await _auth.signUp(
      email: email.trim(),
      password: password,
      data: {if (name.isNotEmpty) 'full_name': name},
      emailRedirectTo: _emailRedirectUrl,
    );
    // While email confirmation is required, Supabase answers a sign-up for an
    // address that already has an account as if it were new, so the request
    // sends nothing; only the user it returns has no identities.
    final identities = res.user?.identities;
    if (res.session == null && identities != null && identities.isEmpty) {
      throw const AuthException('User already registered', code: 'user_already_exists');
    }
    return res.session != null;
  }

  /// Emails a password reset link. Supabase answers the same whether or not an
  /// account uses [email], so this can't tell who has one.
  Future<void> sendPasswordReset(String email) =>
      _auth.resetPasswordForEmail(email.trim(), redirectTo: _emailRedirectUrl);

  /// Replaces the signed-in account's password: after a reset link signed the
  /// user in, or from Settings. Supabase doesn't ask for the current one unless
  /// the project turns that on; [changes] announces the update.
  Future<void> updatePassword(String password) =>
      _auth.updateUser(UserAttributes(password: password));

  Future<void> signInWithGoogle() async {
    if (_usesLoopbackRedirect) {
      await _signInWithGoogleDesktop();
      return;
    }
    if (!_usesNativeGoogle) {
      // Web has no native account picker: use Supabase's browser flow.
      // Return to whichever host served the app (localhost, Netlify, ...).
      await _auth.signInWithOAuth(OAuthProvider.google, redirectTo: Uri.base.origin);
      return;
    }
    if (_googleWebClientId.isEmpty) {
      throw AuthException("Google sign-in isn't configured. Set _googleWebClientId in services/auth_service.dart.");
    }

    // Native flow: Google account picker → ID token → Supabase session.
    final account = await _googleSignIn.signIn();
    if (account == null) throw AuthException(L10n.current.authGoogleCancelled);

    final googleAuth = await account.authentication;
    final idToken = googleAuth.idToken;
    if (idToken == null) throw AuthException(L10n.current.authGoogleNoToken);

    await _auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: googleAuth.accessToken,
    );
  }

  /// Apple's sheet → ID token → Supabase session. Supabase checks the token
  /// against the SHA-256 of a one-time nonce that only this call knows, so a
  /// token taken from somewhere else can't be replayed. Throws
  /// [SignInWithAppleAuthorizationException] when the sheet is cancelled.
  ///
  /// Apple tells an app the person's name only the first time they sign in to
  /// it, and the ID token never carries it, so it is saved on the account as
  /// `full_name` for CheckpointRepository.ensureProfile to use.
  Future<void> signInWithApple() async {
    final rawNonce = generateNonce();
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
      nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
    );
    final idToken = credential.identityToken;
    if (idToken == null) throw AuthException(L10n.current.authAppleNoToken);

    await _auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );

    final name = appleFullName(credential.givenName, credential.familyName);
    if (name == null) return;
    try {
      await _auth.updateUser(UserAttributes(data: {'full_name': name}));
    } catch (e) {
      // Signed in all the same; the name can be typed in Edit Profile.
      debugPrint('Saving the name Apple shared failed: $e');
    }
  }

  /// "Given Family" from the parts of a name Apple shared, or null when it
  /// shared none (every sign-in after the first, or the person hid it).
  @visibleForTesting
  static String? appleFullName(String? given, String? family) {
    final parts = [given, family]
        .map((part) => part?.trim() ?? '')
        .where((part) => part.isNotEmpty);
    return parts.isEmpty ? null : parts.join(' ');
  }

  /// Opens Google sign-in in the system browser and catches the redirect on
  /// localhost: Supabase sends the browser back to [_desktopRedirectUrl] with a
  /// PKCE `code`, which is exchanged for a session here. The code is useless
  /// without the verifier the app kept, so another local program can't use it.
  Future<void> _signInWithGoogleDesktop() async {
    // An earlier attempt that was never finished still holds the port.
    await _loopback?.close(force: true);
    _loopback = null;

    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, _desktopRedirectPort);
    } on SocketException {
      throw AuthException(L10n.current.authPortInUse(_desktopRedirectPort));
    }
    _loopback = server;

    final callback = Completer<Uri>();
    final subscription = server.listen((request) {
      final params = request.uri.queryParameters;
      final isCallback = params.containsKey('code') || params.containsKey('error');
      final response = request.response;
      if (isCallback) {
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_callbackPage(ok: !params.containsKey('error')));
      } else {
        response.statusCode = HttpStatus.notFound; // favicon.ico and friends
      }
      unawaited(response.close());
      if (isCallback && !callback.isCompleted) callback.complete(request.uri);
    });

    try {
      final opened = await _auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: _desktopRedirectUrl,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
      if (!opened) throw AuthException("Couldn't open your browser for Google sign-in.");

      final uri = await callback.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () => throw AuthException('Google sign-in timed out. Please try again.'),
      );

      final error = uri.queryParameters['error_description'] ?? uri.queryParameters['error'];
      if (error != null) throw AuthException(error);
      final code = uri.queryParameters['code'];
      if (code == null) throw AuthException('Google did not return a sign-in code.');

      await _auth.exchangeCodeForSession(code);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      if (identical(_loopback, server)) _loopback = null;
    }
  }

  /// The page the browser shows after Google sends the user back.
  static String _callbackPage({required bool ok}) {
    final l10n = L10n.current;
    final title = ok ? l10n.authCallbackSignedIn : l10n.authCallbackFailed;
    final body = ok ? l10n.authCallbackSignedInBody : l10n.authCallbackFailedBody;
    return '<!doctype html><html lang="${L10n.languageCode}"><head><meta charset="utf-8"><title>Gamebit</title>'
        '<style>body{font-family:sans-serif;background:#0b0d12;color:#eee;display:grid;'
        'place-items:center;height:100vh;margin:0;text-align:center}</style></head>'
        '<body><div><h2>$title</h2><p>$body</p></div></body></html>';
  }

  /// Where supabase_flutter keeps the session on disk (see `Supabase.initialize`
  /// in main.dart): encrypted on Android and iOS, SharedPreferences elsewhere.
  String get _persistedSessionKey => sessionKeyFor(_client.rest.url);

  Future<String?> _persistedSession() async {
    if (EncryptedSessionStorage.supported) {
      return EncryptedSessionStorage(_persistedSessionKey).accessToken();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_persistedSessionKey);
    } catch (e) {
      debugPrint('Reading the saved session failed: $e');
      return null;
    }
  }

  /// The id of the user whose session is saved on this device, or null. While
  /// [currentUser] is null this is the "signed in, but the session could not be
  /// refreshed yet" state: an expired access token is only dropped from memory
  /// when the refresh fails because the network is down, and the saved session
  /// stays on disk. A real sign-out, or a refresh token the server rejected,
  /// removes it.
  ///
  /// A saved session that never got its two-factor code ([owesSecondFactor])
  /// counts as none: the code can only be checked online.
  Future<String?> persistedUserId() async {
    final raw = await _persistedSession();
    if (raw == null) return null;
    try {
      final session = jsonDecode(raw) as Map;
      if (owesSecondFactor(session)) return null;
      final user = session['user'];
      final id = user is Map ? user['id'] : null;
      return id is String && id.isNotEmpty ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether a saved [session] (as JSON) is [needsSecondFactor]'s case: its
  /// account has a verified authenticator app and its token is not aal2.
  @visibleForTesting
  static bool owesSecondFactor(Map session) {
    final user = session['user'];
    final factors = user is Map ? user['factors'] : null;
    final enrolled = factors is List &&
        factors.any((f) => f is Map && f['status'] == FactorStatus.verified.name);
    if (!enrolled) return false;
    final token = session['access_token'];
    try {
      return token is! String || decodeJwt(token).payload.claims['aal'] != 'aal2';
    } catch (_) {
      return true;
    }
  }

  /// Tries to turn the saved session back into a live one (refreshing its
  /// token). Returns whether it worked; on success [changes] announces it.
  Future<bool> restoreSession() async {
    final raw = await _persistedSession();
    if (raw == null) return false;
    try {
      await _auth.recoverSession(raw);
      return _auth.currentUser != null;
    } catch (e) {
      debugPrint('Restoring the session failed: $e');
      return false;
    }
  }

  /// Forgets a saved session that never became live (signing out in that state).
  Future<void> discardPersistedSession() async {
    if (EncryptedSessionStorage.supported) {
      await EncryptedSessionStorage(_persistedSessionKey).removePersistedSession();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_persistedSessionKey);
    } catch (e) {
      debugPrint('Discarding the saved session failed: $e');
    }
  }

  // Two-factor authentication: a code from an authenticator app (TOTP) after
  // the password, Google or Apple. Supabase Auth MFA keeps the factor; the
  // database and the Edge Functions refuse an account that has one until its
  // session is aal2 (20261019135155_require_mfa.sql).

  /// The signed-in account's verified authenticator apps. Supabase keeps the
  /// list on the session's user and updates it on sign-in, on a verified code
  /// and on every refresh.
  Iterable<Factor> get _verifiedTotp =>
      (_auth.currentUser?.factors ?? const <Factor>[]).where(
        (f) => f.factorType == FactorType.totp && f.status == FactorStatus.verified,
      );

  /// Whether the signed-in account has two-factor authentication on.
  bool get hasTwoFactor => _verifiedTotp.isNotEmpty;

  /// Whether this session signed in with one factor (aal1) while the account
  /// has two-factor authentication on (aal2 is next): the authenticator app's
  /// code is still owed. Read from the session, without a request.
  bool get needsSecondFactor {
    final aal = _auth.mfa.getAuthenticatorAssuranceLevel();
    return aal.currentLevel == AuthenticatorAssuranceLevels.aal1 &&
        aal.nextLevel == AuthenticatorAssuranceLevels.aal2;
  }

  /// Checks [code] from the authenticator app, which makes this session aal2;
  /// [changes] announces it (mfaChallengeVerified).
  Future<void> verifySecondFactor(String code) async {
    final factor = _verifiedTotp.firstOrNull;
    if (factor == null) {
      throw const AuthException('Two-factor authentication is not on for this account.');
    }
    await _auth.mfa.challengeAndVerify(factorId: factor.id, code: code.trim());
  }

  /// Starts turning two-factor authentication on: adds an authenticator app
  /// that is not verified yet, and returns what to show to set it up. Nothing
  /// changes for the account until [confirmTwoFactor] checks its first code.
  Future<TotpSetup> enrollTwoFactor() async {
    final res = await _auth.mfa.enroll(factorType: FactorType.totp, issuer: 'Gamebit');
    final totp = res.totp;
    if (totp == null) throw const AuthException('Two-factor setup did not return a key.');
    return TotpSetup(factorId: res.id, secret: totp.secret, uri: totp.uri);
  }

  /// Finishes turning two-factor authentication on with the first [code] the
  /// authenticator app shows for [factorId]. The session becomes aal2 and
  /// Supabase ends the account's aal1 sessions on other devices.
  Future<void> confirmTwoFactor(String factorId, String code) =>
      _auth.mfa.challengeAndVerify(factorId: factorId, code: code.trim());

  /// Drops the authenticator app of a setup that was not finished. (Supabase
  /// also drops unverified ones by itself after a few minutes.)
  Future<void> cancelTwoFactor(String factorId) => _auth.mfa.unenroll(factorId);

  /// Turns two-factor authentication off. Supabase only allows it from an aal2
  /// session (`insufficient_aal`). The session is refreshed afterwards, so it
  /// stops listing the factor and [changes] announces that.
  Future<void> disableTwoFactor() async {
    for (final factor in _verifiedTotp.toList()) {
      try {
        await _auth.mfa.unenroll(factor.id);
      } on AuthException catch (e) {
        // Removed by an earlier attempt whose refresh failed.
        if (e.code != ErrorCode.mfaFactorNotFound.code) rethrow;
      }
    }
    await _auth.refreshSession();
  }

  /// Makes new backup codes for the signed-in account through the
  /// `mfa-recovery` Edge Function and returns them as they are shown
  /// (`7K3QD-M9XHT`). This is the only time they are sent: the server keeps
  /// their hashes, and the account's earlier codes stop working. Needs
  /// two-factor authentication on and an aal2 session. Throws the
  /// [FunctionException] of a failed call (see `backupCodesMessage`).
  Future<List<String>> generateBackupCodes() async {
    final res = await _client.functions.invoke(
      'mfa-recovery',
      body: const {'mode': 'generate'},
    );
    final data = res.data;
    final codes = data is Map ? data['codes'] : null;
    if (codes is! List || codes.isEmpty || codes.any((c) => c is! String)) {
      throw const FormatException('mfa-recovery answered no codes');
    }
    return List<String>.unmodifiable(codes);
  }

  /// Gets the session that owes its two-factor code ([needsSecondFactor]) past
  /// it with a backup [code] instead (`mfa-recovery`, mode `redeem`): the server
  /// uses the code up and removes the account's authenticator apps, which turns
  /// two-factor authentication off. The session is refreshed afterwards, so its
  /// user lists no factor, no code is owed, and [changes] announces it. Throws
  /// the [FunctionException] of a failed call (`INVALID_CODE`: no unused code
  /// of the account matches; see `backupCodeMessage`).
  Future<void> redeemBackupCode(String code) async {
    try {
      await _client.functions.invoke(
        'mfa-recovery',
        body: {'mode': 'redeem', 'code': code.trim()},
      );
    } on FunctionException catch (e) {
      // Already off: an earlier attempt whose refresh failed.
      if (mfaRecoveryErrorCode(e) != 'TWO_FACTOR_OFF') rethrow;
    }
    await _auth.refreshSession();
  }

  /// Permanently deletes the signed-in user's account through the `delete-account`
  /// Edge Function (their data, uploaded photo and sign-in), then ends the local
  /// session. Nothing is signed out when the function fails, so the user can try
  /// again. The function ignores any body: it deletes the caller and no one else.
  /// Throws the [FunctionException] of a failed call.
  Future<void> deleteAccount() async {
    await _client.functions.invoke('delete-account');
    // The account is gone, so the server may answer the sign-out with a 401/403/404;
    // gotrue ignores those and still ends the local session.
    await signOut();
  }

  /// Ends the sessions of this account on every other device, and keeps this one
  /// signed in. Throws the [AuthException] of a failed call.
  Future<void> signOutOtherDevices() => _auth.signOut(scope: SignOutScope.others);

  Future<void> signOut() async {
    await _auth.signOut();
    if (_usesNativeGoogle) {
      try {
        await _googleSignIn.signOut();
      } catch (e) {
        debugPrint('Google sign-out failed: $e');
      }
    }
  }

  /// Text for the UI. Raw exceptions never reach the screen.
  static String messageFor(Object e) {
    final l10n = L10n.current;
    if (e is AuthRetryableFetchException) return l10n.authOffline;
    if (e is AuthException) {
      // The codes Supabase sends for email sign-in, sign-up and password
      // changes; anything else (the Google flow's own messages included) is
      // shown as it comes.
      return switch (e.code) {
        'invalid_credentials' => l10n.authInvalidCredentials,
        'user_already_exists' || 'email_exists' => l10n.authEmailExists,
        'weak_password' => l10n.authWeakPassword(_weakPasswordReason(e)).trim(),
        'same_password' => l10n.authSamePassword,
        // "Secure password change" is on and this session is over a day old.
        'reauthentication_needed' => l10n.authReauthenticationNeeded,
        'email_not_confirmed' => l10n.authEmailNotConfirmed,
        // A moderator suspended the account (moderation.suspend_member).
        'user_banned' => l10n.accountSuspended(AppConfig.contactEmail),
        'email_address_invalid' => l10n.authEmailInvalid,
        'over_email_send_rate_limit' => l10n.authTooManyEmails,
        'over_request_rate_limit' => l10n.authTooManyAttempts,
        'email_provider_disabled' => l10n.authEmailSignInUnavailable,
        'signup_disabled' => l10n.authSignupDisabled,
        // Two-factor authentication.
        'mfa_verification_failed' => l10n.authCodeDidNotWork,
        'mfa_challenge_expired' || 'mfa_verification_rejected' => l10n.authCodeExpired,
        'mfa_totp_enroll_not_enabled' || 'mfa_totp_verify_not_enabled' => l10n.authTwoFactorUnavailable,
        'insufficient_aal' => l10n.authInsufficientAal,
        'too_many_enrolled_mfa_factors' => l10n.authTooManyFactors,
        _ => e.message,
      };
    }
    if (e is SignInWithAppleAuthorizationException) {
      return switch (e.code) {
        AuthorizationErrorCode.canceled => l10n.authAppleCancelled,
        _ => l10n.authAppleFailed,
      };
    }
    if (e is SignInWithAppleException) return l10n.authAppleFailed;
    if (e is PlatformException) {
      return switch (e.code) {
        GoogleSignIn.kSignInCanceledError => l10n.authGoogleCancelled,
        _ => l10n.authGoogleFailed(e.code),
      };
    }
    return l10n.somethingWentWrong;
  }

  /// Why Supabase found a password too weak. Supabase says it in English, so
  /// English shows its words; another language says the reasons it knows.
  static String _weakPasswordReason(AuthException e) {
    final l10n = L10n.current;
    if (L10n.languageCode == 'en') return e.message;
    final minLength = RegExp(r'at least (\d+) characters').firstMatch(e.message);
    if (minLength != null) return l10n.authWeakPasswordMinLength(int.parse(minLength.group(1)!));
    final reasons = e is AuthWeakPasswordException ? e.reasons : const <String>[];
    if (reasons.contains('pwned')) return l10n.authWeakPasswordPwned;
    if (reasons.contains('characters')) return l10n.authWeakPasswordCharacters;
    return e.message;
  }
}
