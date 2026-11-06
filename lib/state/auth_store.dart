import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/services/auth_service.dart';
import 'package:checkpoint/services/connection_failure.dart';

/// Who is signed in. Owns the Supabase session and the sign-in / sign-out calls,
/// and nothing else: the stores that hold a user's data ([ProfileStore],
/// [LibraryStore], [SearchStore]) follow [userChanges] and load or drop their
/// data when the account changes.
class AuthStore extends ChangeNotifier {
  AuthStore(this._service);

  final AuthService _service;

  User? _user;
  User? _waitingUser;
  bool _twoFactorOn = false;
  bool _sessionPending = false;
  bool _recoveringPassword = false;
  StreamSubscription<AuthState>? _subscription;
  final StreamController<User?> _changes = StreamController<User?>.broadcast();

  /// The signed-in user, or `null` when signed out. While [isSessionPending] it
  /// is a stand-in that has only the account's id.
  User? get user => _user;
  bool get isLoggedIn => _user != null;

  /// The signed-in account's email address, if the provider shared one.
  String? get email {
    final text = _user?.email?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// How the account signs in, as Supabase names it: `google`, `email`, ... Null
  /// while the session is only a stand-in (see [isSessionPending]).
  String? get provider {
    final value = _user?.appMetadata['provider'];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// The device has a saved session for this account, but it could not be
  /// refreshed (the app started offline with an expired access token), so there
  /// is no live session yet. The data stores show what is saved on the device and
  /// queue edits instead of calling the server; [restoreSession] ends the state.
  bool get isSessionPending => _sessionPending;

  /// The user opened a password reset link, which signed them in, and has not
  /// chosen a new password yet: the app shell asks for one until
  /// [updatePassword] saves it or [dismissPasswordRecovery] puts it off. Only
  /// the browser tab that opened the link asks, not the other open tabs. An
  /// account with two-factor authentication is asked after its code.
  bool get isRecoveringPassword => _recoveringPassword && _user != null;

  /// Signed in (password, Google, Apple, a reset link...), but the account has
  /// two-factor authentication on and this session has not entered a code
  /// from the authenticator app yet. Until [verifySecondFactor] takes one the
  /// app treats it as signed out: [user] is null and [userChanges] says null,
  /// as the server refuses such a session the account's data anyway.
  /// SecondFactorGate asks for the code over the whole app.
  bool get needsSecondFactor => _waitingUser != null;

  /// The email address of the account waiting for its code, if it has one.
  String? get waitingEmail {
    final text = _waitingUser?.email?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// Whether the signed-in account has two-factor authentication on.
  bool get hasTwoFactor => _twoFactorOn;

  /// Emits the current user (`null` = signed out) on every auth event: sign-in,
  /// sign-out, token refresh, profile update. Unlike [addListener], this includes
  /// events for the same account, which the data stores treat as "refresh your
  /// data" rather than "a different person is here" (they compare ids).
  Stream<User?> get userChanges => _changes.stream;

  /// Reads the session Supabase restored from disk and starts following changes.
  /// Call once, before the stores that listen to [userChanges] call theirs.
  Future<void> initialize() async {
    final restored = _service.currentUser;
    if (restored != null) {
      if (_service.needsSecondFactor) {
        _waitingUser = restored;
      } else {
        _user = restored;
        _twoFactorOn = _service.hasTwoFactor;
      }
      notifyListeners();
    }
    _subscription = _service.changes.listen((state) {
      final signedIn = state.session?.user;
      // A session that still owes its two-factor code is no one yet.
      final waiting =
          signedIn != null && _service.needsSecondFactor ? signedIn : null;
      final next = waiting == null ? signedIn : null;
      final accountChanged = next?.id != _user?.id;
      final waitingChanged = waiting?.id != _waitingUser?.id;
      final opensReset =
          state.event == AuthChangeEvent.passwordRecovery &&
          !state.fromBroadcast;
      final sameAccount =
          signedIn != null && signedIn.id == (_user ?? _waitingUser)?.id;
      final recovering =
          signedIn != null &&
          (opensReset || (_recoveringPassword && sameAccount));
      final recoveryChanged = recovering != _recoveringPassword;
      final twoFactor = next != null && _service.hasTwoFactor;
      final twoFactorChanged = twoFactor != _twoFactorOn;
      _sessionPending = false;
      _user = next;
      _waitingUser = waiting;
      _recoveringPassword = recovering;
      _twoFactorOn = twoFactor;
      // Widgets watching this store care who is signed in, not about the hourly
      // token refresh, so they are told only when the account changes (or a
      // reset link wants a new password, or two-factor is turned on or off).
      if (accountChanged || waitingChanged || recoveryChanged || twoFactorChanged) {
        notifyListeners();
      }
      _changes.add(next);
    }, onError: (Object e) => debugPrint('Auth stream error: $e'));

    if (_user == null && _waitingUser == null) {
      final savedId = await _service.persistedUserId();
      if (savedId != null && _user == null) {
        _user = User(
          id: savedId,
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: '',
        );
        _sessionPending = true;
        notifyListeners();
      }
    }
  }

  /// Tries to turn a [isSessionPending] session into a live one. Returns whether
  /// there is a live session now; on success [userChanges] announces it.
  Future<bool> restoreSession() async {
    if (!_sessionPending) return true;
    return _service.restoreSession();
  }

  /// Throws [SessionPending] while there is no live session, for the stores to
  /// call before a request: the server would refuse it, so the edit is queued
  /// like any other made while the server can't be reached.
  void requireSession() {
    if (_sessionPending) throw const SessionPending();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_changes.close());
    super.dispose();
  }

  Future<void> signInWithEmail(String email, String password) =>
      _service.signInWithEmail(email, password);

  Future<bool> signUpWithEmail(
    String email,
    String password, {
    String? displayName,
  }) => _service.signUpWithEmail(email, password, displayName: displayName);

  /// Emails a link for choosing a new password.
  Future<void> sendPasswordReset(String email) =>
      _service.sendPasswordReset(email);

  /// Replaces the signed-in account's password, which also ends
  /// [isRecoveringPassword]. Throws when there is no live session to ask with
  /// ([SessionPending]) or the server refused it (too weak, the same as before).
  Future<void> updatePassword(String password) async {
    if (_user == null) throw StateError('Not signed in.');
    requireSession();
    await _service.updatePassword(password);
    dismissPasswordRecovery();
  }

  /// Stops asking for a new password after a reset link. The user stays signed
  /// in and keeps the old password.
  void dismissPasswordRecovery() {
    if (!_recoveringPassword) return;
    _recoveringPassword = false;
    notifyListeners();
  }

  Future<void> signInWithGoogle() => _service.signInWithGoogle();

  /// Whether this device can sign in with Apple (iOS: see AuthService).
  bool get offersAppleSignIn => _service.offersAppleSignIn;

  Future<void> signInWithApple() => _service.signInWithApple();

  /// Told the id of the account a [logOut] is about to sign out, so what the phone
  /// keeps for it alone (a saved PlayStation sign-in) goes with it.
  void Function(String userId)? onLogOut;

  Future<void> logOut() async {
    final leaving = _user?.id;
    if (leaving != null) onLogOut?.call(leaving);
    if (_sessionPending) {
      // No live session to end: just forget the saved one.
      await _service.discardPersistedSession();
      _sessionPending = false;
      _user = null;
      notifyListeners();
      _changes.add(null);
      return;
    }
    await _service.signOut();
  }

  /// Signs the account out on every other device and keeps this one signed in.
  /// Throws when there is no live session to ask with ([SessionPending]) or the
  /// server could not do it.
  Future<void> signOutOtherDevices() async {
    if (_user == null) throw StateError('Not signed in.');
    requireSession();
    await _service.signOutOtherDevices();
  }

  /// Checks [code] from the authenticator app of the account that
  /// [needsSecondFactor]. A right one signs it in ([userChanges] announces
  /// it); a wrong or expired one throws its [AuthException].
  Future<void> verifySecondFactor(String code) async {
    if (_waitingUser == null) throw StateError('No code is needed.');
    await _service.verifySecondFactor(code);
  }

  /// Starts turning two-factor authentication on: what to show for adding the
  /// account to an authenticator app. Nothing changes until
  /// [confirmTwoFactor] gets the first code. Throws when there is no live
  /// session to ask with ([SessionPending]) or the server refused.
  Future<TotpSetup> enrollTwoFactor() async {
    if (_user == null) throw StateError('Not signed in.');
    requireSession();
    return _service.enrollTwoFactor();
  }

  /// Turns two-factor authentication on with the first [code] the app shows
  /// for the [enrollTwoFactor] setup [factorId]; [hasTwoFactor] follows.
  Future<void> confirmTwoFactor(String factorId, String code) async {
    if (_user == null) throw StateError('Not signed in.');
    requireSession();
    await _service.confirmTwoFactor(factorId, code);
  }

  /// Drops an [enrollTwoFactor] setup that was left unfinished. Best effort:
  /// Supabase drops unverified ones by itself after a few minutes.
  Future<void> cancelTwoFactor(String factorId) async {
    try {
      await _service.cancelTwoFactor(factorId);
    } catch (e) {
      debugPrint('Dropping the unfinished two-factor setup failed: $e');
    }
  }

  /// Turns two-factor authentication off; [hasTwoFactor] follows. Throws when
  /// there is no live session to ask with ([SessionPending]) or the server
  /// refused.
  Future<void> disableTwoFactor() async {
    if (_user == null) throw StateError('Not signed in.');
    requireSession();
    await _service.disableTwoFactor();
  }

  /// Makes new backup codes for the signed-in account (two-factor
  /// authentication is on, and this session entered its code) and returns
  /// them, to show once. The codes it had stop working. Throws when there is no
  /// live session to ask with ([SessionPending]) or the server refused; see
  /// `backupCodesMessage` for text to show.
  Future<List<String>> generateBackupCodes() async {
    if (_user == null) throw StateError('Not signed in.');
    requireSession();
    return _service.generateBackupCodes();
  }

  /// Gets the account that [needsSecondFactor] in with a backup [code] in place
  /// of the authenticator app's. That uses the code up and turns two-factor
  /// authentication off: [userChanges] announces the account, and
  /// [hasTwoFactor] is false. A wrong or used code throws (`INVALID_CODE`); see
  /// `backupCodeMessage` for text to show.
  Future<void> redeemBackupCode(String code) async {
    if (_waitingUser == null) throw StateError('No code is needed.');
    await _service.redeemBackupCode(code);
  }

  /// Permanently deletes the signed-in account and everything stored for it on
  /// the server, then signs out ([userChanges] announces it like any sign-out).
  /// Throws when there is no live session to ask with ([SessionPending]) or the
  /// server could not do it; the account is untouched then. See
  /// `deleteAccountMessage` for text to show.
  Future<void> deleteAccount() async {
    if (_user == null) throw StateError('Not signed in.');
    requireSession();
    await _service.deleteAccount();
  }

  String messageFor(Object e) => AuthService.messageFor(e);
}
