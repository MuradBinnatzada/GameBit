import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        AuthChangeEvent,
        AuthException,
        AuthRetryableFetchException,
        FunctionException,
        User;

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/auth_gate.dart';
import 'package:checkpoint/app/new_password_screen.dart';
import 'package:checkpoint/app/second_factor_gate.dart';
import 'package:checkpoint/app/sign_in_panel.dart';
import 'package:checkpoint/screens/settings/backup_codes_screen.dart';
import 'package:checkpoint/screens/settings/settings_screen.dart';
import 'package:checkpoint/screens/settings/two_factor_setup_screen.dart';
import 'package:checkpoint/services/auth_service.dart';
import 'package:checkpoint/services/connection_failure.dart';
import 'package:checkpoint/services/mfa_recovery_failure.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/widgets/qr_code_view.dart';

import 'support/fakes.dart';

/// Two-factor authentication (an authenticator app): the code a sign-in still
/// owes, the prompt over the whole app, turning it on and off in Settings, and
/// the backup codes that get in without the app.
void main() {
  User emailUser([String id = 'u1']) => User(
    id: id,
    appMetadata: const {'provider': 'email'},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
    email: 'ada@example.com',
  );

  /// Lets the store take in an auth event.
  Future<void> events() => Future<void>.delayed(Duration.zero);

  group('AuthStore', () {
    late FakeAuthService service;
    late AuthStore auth;
    late List<String?> announced;

    setUp(() async {
      service = FakeAuthService()..twoFactorOn = true;
      auth = AuthStore(service);
      announced = [];
      auth.userChanges.listen((user) => announced.add(user?.id));
      await auth.initialize();
    });

    tearDown(() => auth.dispose());

    test(
      'a sign-in that owes its code counts as no one until the code is right',
      () async {
        await auth.signInWithEmail('ada@example.com', 'pw');
        await events();

        expect(auth.needsSecondFactor, isTrue);
        expect(auth.waitingEmail, isNull); // testUser has no address
        expect(auth.isLoggedIn, isFalse);
        expect(auth.user, isNull);
        expect(announced, [null]);

        await expectLater(
          auth.verifySecondFactor('000000'),
          throwsA(
            isA<AuthException>().having(
              (e) => e.code,
              'code',
              'mfa_verification_failed',
            ),
          ),
        );
        await events();
        expect(auth.isLoggedIn, isFalse);

        await auth.verifySecondFactor('123456');
        await events();

        expect(auth.needsSecondFactor, isFalse);
        expect(auth.isLoggedIn, isTrue);
        expect(auth.user?.id, 'u1');
        expect(auth.hasTwoFactor, isTrue);
        expect(announced, [null, 'u1']);
        expect(service.twoFactorCalls, ['verify:000000', 'verify:123456']);
      },
    );

    test('signing out while the code is owed ends the wait', () async {
      await auth.signInWithGoogle();
      await events();
      expect(auth.needsSecondFactor, isTrue);

      await auth.logOut();
      await events();

      expect(auth.needsSecondFactor, isFalse);
      expect(auth.isLoggedIn, isFalse);
      expect(service.user, isNull);
    });

    test('an account without two-factor is signed in straight away', () async {
      service.twoFactorOn = false;
      await auth.signInWithApple();
      await events();

      expect(auth.needsSecondFactor, isFalse);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.hasTwoFactor, isFalse);
      expect(announced, ['u1']);
    });

    test('a verified code is not asked for again on a token refresh', () async {
      await auth.signInWithEmail('ada@example.com', 'pw');
      await auth.verifySecondFactor('123456');
      await events();

      service.emit(service.user, event: AuthChangeEvent.tokenRefreshed);
      await events();

      expect(auth.needsSecondFactor, isFalse);
      expect(auth.isLoggedIn, isTrue);
    });

    test('a reset link asks for the new password after the code', () async {
      service.openResetLink(emailUser());
      await events();

      expect(auth.needsSecondFactor, isTrue);
      expect(auth.waitingEmail, 'ada@example.com');
      expect(auth.isRecoveringPassword, isFalse);

      await auth.verifySecondFactor('123456');
      await events();

      expect(auth.isLoggedIn, isTrue);
      expect(auth.isRecoveringPassword, isTrue);
    });

    test('turning it on and off follows the account', () async {
      service.twoFactorOn = false;
      await auth.signInWithEmail('ada@example.com', 'pw');
      await events();
      expect(auth.hasTwoFactor, isFalse);

      final setup = await auth.enrollTwoFactor();
      expect(setup.factorId, 'factor-1');
      expect(auth.hasTwoFactor, isFalse);

      await auth.confirmTwoFactor(setup.factorId, '123456');
      await events();
      expect(auth.hasTwoFactor, isTrue);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.needsSecondFactor, isFalse);

      await auth.disableTwoFactor();
      await events();
      expect(auth.hasTwoFactor, isFalse);
      expect(service.twoFactorCalls, [
        'enroll',
        'confirm:factor-1:123456',
        'disable',
      ]);
    });

    test(
      'a backup code gets the waiting account in and turns two-factor off',
      () async {
        await auth.signInWithEmail('ada@example.com', 'pw');
        await events();
        expect(auth.needsSecondFactor, isTrue);

        await expectLater(
          auth.redeemBackupCode('ZZZZZ-ZZZZZ'),
          throwsA(
            isA<FunctionException>().having(
              mfaRecoveryErrorCode,
              'code',
              'INVALID_CODE',
            ),
          ),
        );
        await events();
        expect(auth.isLoggedIn, isFalse);

        // Typed any way.
        await auth.redeemBackupCode('aaaaa bbbbb');
        await events();

        expect(auth.needsSecondFactor, isFalse);
        expect(auth.isLoggedIn, isTrue);
        expect(auth.user?.id, 'u1');
        expect(auth.hasTwoFactor, isFalse);
        expect(announced, [null, 'u1']);
        expect(service.twoFactorCalls, [
          'redeem:ZZZZZ-ZZZZZ',
          'redeem:aaaaa bbbbb',
        ]);
      },
    );

    test('a backup code is only taken while a code is owed', () async {
      await expectLater(auth.redeemBackupCode('AAAAA-BBBBB'), throwsStateError);

      await auth.signInWithEmail('ada@example.com', 'pw');
      await auth.verifySecondFactor('123456');
      await events();
      await expectLater(auth.redeemBackupCode('AAAAA-BBBBB'), throwsStateError);
      expect(service.twoFactorCalls, ['verify:123456']);
    });

    test('new backup codes are made for a signed-in account', () async {
      await expectLater(auth.generateBackupCodes(), throwsStateError);

      await auth.signInWithEmail('ada@example.com', 'pw');
      await auth.verifySecondFactor('123456');
      await events();

      expect(await auth.generateBackupCodes(), FakeAuthService.newBackupCodes);
      expect(service.twoFactorCalls, ['verify:123456', 'generate']);
    });

    test('a session restored at aal1 waits for its code', () async {
      final restored = FakeAuthService(emailUser())..twoFactorOn = true;
      final store = AuthStore(restored);
      addTearDown(store.dispose);
      await store.initialize();

      expect(store.needsSecondFactor, isTrue);
      expect(store.waitingEmail, 'ada@example.com');
      expect(store.isLoggedIn, isFalse);
      expect(store.isSessionPending, isFalse);
    });
  });

  group('Backup code messages', () {
    FunctionException failure(int status, [Map<String, Object?>? body]) =>
        FunctionException(status: status, details: body);

    test('using one says what went wrong', () {
      expect(
        backupCodeMessage(failure(400, {'code': 'INVALID_CODE'})),
        startsWith("That backup code didn't work."),
      );
      expect(
        backupCodeMessage(
          failure(429, {'code': 'RATE_LIMITED', 'retry_after': 1500}),
        ),
        'Too many tries. Try again in 25 minutes.',
      );
      expect(
        backupCodeMessage(
          failure(429, {'code': 'RATE_LIMITED', 'retry_after': 40}),
        ),
        'Too many tries. Try again in a minute.',
      );
      expect(
        backupCodeMessage(failure(429)),
        'Too many tries. Try again later.',
      );
      expect(
        backupCodeMessage(failure(401, {'code': 'UNAUTHENTICATED'})),
        'Your sign-in expired. Sign out and sign in again.',
      );
      expect(
        backupCodeMessage(failure(503)),
        'The server is busy right now. Try again in a moment.',
      );
      expect(
        backupCodeMessage(failure(0)),
        startsWith('Could not reach the server.'),
      );
      // The code was used, but the session could not be refreshed.
      expect(
        backupCodeMessage(AuthRetryableFetchException()),
        startsWith('Could not reach the server.'),
      );
      expect(
        backupCodeMessage(const AuthException('Invalid Refresh Token')),
        'Your sign-in expired. Sign out and sign in again.',
      );
      expect(
        backupCodeMessage(const FormatException('odd answer')),
        'Could not check that backup code. Please try again.',
      );
    });

    test('making them says what went wrong', () {
      expect(
        backupCodesMessage(failure(403, {'code': 'MFA_REQUIRED'})),
        startsWith('Sign in again with the code from your authenticator app'),
      );
      expect(
        backupCodesMessage(failure(409, {'code': 'TWO_FACTOR_OFF'})),
        'Turn on two-factor authentication first.',
      );
      expect(
        backupCodesMessage(
          failure(429, {'code': 'RATE_LIMITED', 'retry_after': 3600}),
        ),
        'You made new backup codes too many times. Try again in 60 minutes.',
      );
      expect(
        backupCodesMessage(failure(401)),
        startsWith('Your session expired.'),
      );
      expect(
        backupCodesMessage(const SessionPending()),
        startsWith('Could not reach the server.'),
      );
      expect(
        backupCodesMessage(StateError('Not signed in.')),
        'Sign in to make backup codes.',
      );
      expect(
        backupCodesMessage(const FormatException('no codes')),
        'Could not make backup codes. Please try again.',
      );
    });

    test('the code is read from the function only', () {
      expect(
        mfaRecoveryErrorCode(failure(400, {'code': 'INVALID_CODE'})),
        'INVALID_CODE',
      );
      expect(mfaRecoveryErrorCode(failure(500, {'error': 'boom'})), isNull);
      expect(mfaRecoveryErrorCode(failure(500)), isNull);
      expect(
        mfaRecoveryErrorCode(const AuthException('x', code: 'INVALID_CODE')),
        isNull,
      );
    });
  });

  group('A saved session', () {
    String jwt(Map<String, Object?> claims) {
      String part(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.c2ln';
    }

    Map<String, Object?> session({
      required String aal,
      List<String> factors = const [],
    }) => {
      'access_token': jwt({'sub': 'u1', 'aal': aal}),
      'user': {
        'id': 'u1',
        'factors': [
          for (final status in factors)
            {'id': 'f-$status', 'factor_type': 'totp', 'status': status},
        ],
      },
    };

    test('owes its code only when two-factor is on and it is not aal2', () {
      expect(
        AuthService.owesSecondFactor(
          session(aal: 'aal1', factors: ['verified']),
        ),
        isTrue,
      );
      expect(
        AuthService.owesSecondFactor(
          session(aal: 'aal2', factors: ['verified']),
        ),
        isFalse,
      );
      expect(AuthService.owesSecondFactor(session(aal: 'aal1')), isFalse);
      // An unfinished setup doesn't turn it on.
      expect(
        AuthService.owesSecondFactor(
          session(aal: 'aal1', factors: ['unverified']),
        ),
        isFalse,
      );
    });

    test('with two-factor on, a token that cannot be read owes it', () {
      final broken = session(aal: 'aal2', factors: ['verified'])
        ..['access_token'] = 'not-a-jwt';
      expect(AuthService.owesSecondFactor(broken), isTrue);
      final missing = session(aal: 'aal2', factors: ['verified'])
        ..remove('access_token');
      expect(AuthService.owesSecondFactor(missing), isTrue);
    });
  });

  group('The app', () {
    late FakeAuthService authService;
    late AppStores stores;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      authService = FakeAuthService()..twoFactorOn = true;
      stores = AppStores(
        repository: FakeRepository(),
        authService: authService,
        connectivity: FakeConnectivity(),
        // Home asks IGDB for what is popular.
        apiService: FakeBrowseApi(),
      );
    });

    /// The shell with the gate where CheckpointApp puts it: over the Navigator.
    Future<void> start(WidgetTester tester) async {
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => SecondFactorGate(child: child!),
            home: const AppShell(),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
    }

    /// Lets the stores take in an auth event, and a screen slide in or out.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> enterCode(WidgetTester tester, String code) async {
      await tester.enterText(
        find.widgetWithText(TextField, '6-digit code'),
        code,
      );
      await settle(tester);
    }

    testWidgets(
      'asks for the code over everything after a sign-in, and lets the app in',
      (tester) async {
        await start(tester);
        authService.emit(emailUser());
        await settle(tester);

        expect(find.byType(SecondFactorScreen), findsOneWidget);
        expect(
          find.textContaining('for Gamebit (ada@example.com)'),
          findsOneWidget,
        );
        // The shell is still there underneath, hidden.
        expect(find.byType(AppShell, skipOffstage: false), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        expect(stores.auth.isLoggedIn, isFalse);

        // Six digits are sent as soon as they are in.
        await enterCode(tester, '654321');
        expect(find.textContaining("That code didn't work"), findsOneWidget);
        expect(find.byType(SecondFactorScreen), findsOneWidget);

        await enterCode(tester, '123456');

        expect(authService.twoFactorCalls, ['verify:654321', 'verify:123456']);
        expect(find.byType(SecondFactorScreen), findsNothing);
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(stores.auth.isLoggedIn, isTrue);
      },
    );

    testWidgets('only takes digits, and checks the length before sending', (
      tester,
    ) async {
      await start(tester);
      authService.emit(emailUser());
      await settle(tester);

      await tester.enterText(
        find.widgetWithText(TextField, '6-digit code'),
        '12a3',
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '123',
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
      await settle(tester);

      expect(
        find.text('Enter the 6-digit code from your authenticator app.'),
        findsOneWidget,
      );
      expect(authService.twoFactorCalls, isEmpty);
    });

    testWidgets('signing out from the prompt works', (tester) async {
      await start(tester);
      authService.emit(emailUser());
      await settle(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
      await settle(tester);

      expect(find.byType(SecondFactorScreen), findsNothing);
      expect(authService.user, isNull);
      expect(stores.auth.isLoggedIn, isFalse);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets(
      'covers the sign-in screen, which closes once the code is right',
      (tester) async {
        await start(tester);
        unawaited(logIn(tester.element(find.byType(AppShell))));
        await settle(tester);
        expect(find.byType(SignInScreen), findsOneWidget);

        await tester.runAsync(() => stores.auth.signInWithGoogle());
        await settle(tester);

        expect(find.byType(SecondFactorScreen), findsOneWidget);
        expect(find.byType(SignInScreen), findsNothing);
        expect(find.byType(SignInScreen, skipOffstage: false), findsOneWidget);

        await enterCode(tester, '123456');

        expect(find.byType(SecondFactorScreen), findsNothing);
        expect(find.byType(SignInScreen, skipOffstage: false), findsNothing);
        expect(stores.auth.isLoggedIn, isTrue);
      },
    );

    testWidgets('a reset link asks for the code, then the new password', (
      tester,
    ) async {
      await start(tester);
      authService.openResetLink(emailUser());
      await settle(tester);

      expect(find.byType(SecondFactorScreen), findsOneWidget);

      await enterCode(tester, '123456');

      expect(find.byType(SecondFactorScreen), findsNothing);
      expect(find.byType(NewPasswordScreen), findsOneWidget);
    });

    Finder backupField() => find.widgetWithText(TextField, 'Backup code');

    Future<void> useBackupCode(WidgetTester tester, String code) async {
      await tester.enterText(backupField(), code);
      await tester.tap(find.widgetWithText(FilledButton, 'Verify'));
      await settle(tester);
    }

    testWidgets(
      'a backup code gets in without the app, and two-factor is off then',
      (tester) async {
        await start(tester);
        authService.emit(emailUser());
        await settle(tester);

        await tester.tap(find.widgetWithText(TextButton, 'Use a backup code'));
        await settle(tester);
        expect(backupField(), findsOneWidget);
        expect(find.widgetWithText(TextField, '6-digit code'), findsNothing);
        expect(
          find.textContaining('turns two-factor authentication off'),
          findsOneWidget,
        );

        await useBackupCode(tester, 'ZZZZZ-ZZZZZ');
        expect(
          find.textContaining("That backup code didn't work"),
          findsOneWidget,
        );
        expect(find.byType(SecondFactorScreen), findsOneWidget);
        expect(stores.auth.isLoggedIn, isFalse);

        await useBackupCode(tester, 'aaaaa bbbbb');

        expect(authService.twoFactorCalls, [
          'redeem:ZZZZZ-ZZZZZ',
          'redeem:aaaaa bbbbb',
        ]);
        expect(find.byType(SecondFactorScreen), findsNothing);
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(stores.auth.isLoggedIn, isTrue);
        expect(stores.auth.hasTwoFactor, isFalse);
        expect(
          find.textContaining('Signed in with a backup code.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('turn it on again in Settings > Security'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a backup code is checked for length before sending, and the app code '
      'comes back',
      (tester) async {
        await start(tester);
        authService.emit(emailUser());
        await settle(tester);

        await tester.tap(find.widgetWithText(TextButton, 'Use a backup code'));
        await settle(tester);
        await useBackupCode(tester, 'ABC-DE');

        expect(
          find.text('Enter one of your backup codes: 10 letters and digits.'),
          findsOneWidget,
        );
        expect(authService.twoFactorCalls, isEmpty);

        await tester.tap(
          find.widgetWithText(TextButton, 'Use your authenticator app'),
        );
        await settle(tester);
        expect(backupField(), findsNothing);
        expect(
          find.text('Enter one of your backup codes: 10 letters and digits.'),
          findsNothing,
        );

        await enterCode(tester, '123456');
        expect(stores.auth.isLoggedIn, isTrue);
        expect(stores.auth.hasTwoFactor, isTrue);
      },
    );

    testWidgets('too many backup codes say when to try again', (tester) async {
      authService.backupCodeError = const FunctionException(
        status: 429,
        details: {'code': 'RATE_LIMITED', 'retry_after': 1500},
      );
      await start(tester);
      authService.emit(emailUser());
      await settle(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Use a backup code'));
      await settle(tester);
      await useBackupCode(tester, 'AAAAA-BBBBB');

      expect(
        find.text('Too many tries. Try again in 25 minutes.'),
        findsOneWidget,
      );
      expect(find.byType(SecondFactorScreen), findsOneWidget);
    });
  });

  group('Settings > Security', () {
    late FakeAuthService authService;
    late AppStores stores;
    late List<MethodCall> clipboard;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      authService = FakeAuthService(emailUser());
      stores = AppStores(
        repository: FakeRepository(),
        authService: authService,
        connectivity: FakeConnectivity(),
      );
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      clipboard = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboard.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: const SettingsScreen(
              initialSection: SettingsSection.security,
            ),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await tester.pumpAndSettle();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    Finder twoFactorSwitch() =>
        find.widgetWithText(SwitchListTile, 'Authenticator app');

    bool switchedOn(WidgetTester tester) =>
        tester.widget<SwitchListTile>(twoFactorSwitch()).value;

    testWidgets(
      'turning it on shows a QR code and the key, and checks the first code',
      (tester) async {
        await open(tester);
        expect(switchedOn(tester), isFalse);

        await tester.tap(twoFactorSwitch());
        await settle(tester);

        expect(find.byType(TwoFactorSetupScreen), findsOneWidget);
        final qr = tester.widget<QrCodeView>(find.byType(QrCodeView));
        expect(qr.data, FakeAuthService.setup.uri);
        // The key in groups of four.
        expect(
          find.text('JBSW Y3DP EHPK 3PXP JBSW Y3DP EHPK 3PXP'),
          findsOneWidget,
        );

        await tester.tap(find.byTooltip('Copy setup key'));
        await settle(tester);
        expect(clipboard.single.arguments, {
          'text': FakeAuthService.setup.secret,
        });
        expect(find.text('Setup key copied'), findsOneWidget);

        await tester.enterText(
          find.widgetWithText(TextField, '6-digit code'),
          '111111',
        );
        await settle(tester);
        expect(find.textContaining("That code didn't work"), findsOneWidget);
        expect(stores.auth.hasTwoFactor, isFalse);

        await tester.enterText(
          find.widgetWithText(TextField, '6-digit code'),
          '123456',
        );
        await settle(tester);

        // On, and then the backup codes, shown once.
        expect(stores.auth.hasTwoFactor, isTrue);
        expect(find.byType(TwoFactorSetupScreen), findsOneWidget);
        expect(find.text('Two-factor authentication is on'), findsOneWidget);
        expect(find.textContaining('Each code works once'), findsOneWidget);
        for (final code in FakeAuthService.newBackupCodes) {
          expect(find.text(code), findsOneWidget);
        }

        await tester.tap(find.widgetWithText(OutlinedButton, 'Copy'));
        await settle(tester);
        expect(clipboard.last.arguments, {
          'text': FakeAuthService.newBackupCodes.join('\n'),
        });
        expect(find.text('Backup codes copied'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'I saved them'));
        await settle(tester);

        expect(find.byType(TwoFactorSetupScreen), findsNothing);
        expect(find.text('Two-factor authentication is on'), findsOneWidget);
        expect(switchedOn(tester), isTrue);
        expect(authService.twoFactorCalls, [
          'enroll',
          'confirm:factor-1:111111',
          'confirm:factor-1:123456',
          'generate',
        ]);
      },
    );

    Future<void> turnOn(WidgetTester tester) async {
      await tester.tap(twoFactorSwitch());
      await settle(tester);
      await tester.enterText(
        find.widgetWithText(TextField, '6-digit code'),
        '123456',
      );
      await settle(tester);
    }

    testWidgets('backup codes that cannot be made can be tried again', (
      tester,
    ) async {
      authService.backupCodeError = const FunctionException(
        status: 503,
        details: {'code': 'INTERNAL'},
      );
      await open(tester);
      await turnOn(tester);

      expect(stores.auth.hasTwoFactor, isTrue);
      expect(
        find.text('The server is busy right now. Try again in a moment.'),
        findsOneWidget,
      );

      authService.backupCodeError = null;
      await tester.tap(find.text('Try again'));
      await settle(tester);
      expect(find.text(FakeAuthService.newBackupCodes.first), findsOneWidget);

      // Closing is done as well.
      await tester.tap(find.byTooltip('Close'));
      await settle(tester);
      expect(find.byType(TwoFactorSetupScreen), findsNothing);
      expect(find.text('Two-factor authentication is on'), findsOneWidget);
      expect(authService.twoFactorCalls, [
        'enroll',
        'confirm:factor-1:123456',
        'generate',
        'generate',
      ]);
    });

    testWidgets('backup codes can be skipped, and two-factor stays on', (
      tester,
    ) async {
      authService.backupCodeError = const FunctionException(status: 0);
      await open(tester);
      await turnOn(tester);

      expect(
        find.text(
          'Could not reach the server. Check your connection and try again.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Skip for now'));
      await settle(tester);

      expect(find.byType(TwoFactorSetupScreen), findsNothing);
      expect(
        find.text(
          'Two-factor authentication is on. Make backup codes under '
          'Settings > Security.',
        ),
        findsOneWidget,
      );
      expect(switchedOn(tester), isTrue);
      expect(find.text('New backup codes'), findsOneWidget);
    });

    testWidgets('new backup codes are only offered while it is on', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('New backup codes'), findsNothing);
    });

    testWidgets('new backup codes ask first, then show the codes', (
      tester,
    ) async {
      authService
        ..twoFactorOn = true
        ..aal2 = true;
      await open(tester);

      await tester.tap(find.text('New backup codes'));
      await settle(tester);
      expect(find.text('Make new backup codes?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(authService.twoFactorCalls, isEmpty);

      await tester.tap(find.text('New backup codes'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Make new codes'));
      await settle(tester);

      expect(find.byType(BackupCodesScreen), findsOneWidget);
      for (final code in FakeAuthService.newBackupCodes) {
        expect(find.text(code), findsOneWidget);
      }
      await tester.tap(find.widgetWithText(FilledButton, 'I saved them'));
      await settle(tester);

      expect(find.byType(BackupCodesScreen), findsNothing);
      expect(authService.twoFactorCalls, ['generate']);
      expect(switchedOn(tester), isTrue);
    });

    testWidgets('new backup codes that cannot be made say why', (tester) async {
      authService
        ..twoFactorOn = true
        ..aal2 = true
        ..backupCodeError = const FunctionException(
          status: 403,
          details: {'code': 'MFA_REQUIRED'},
        );
      await open(tester);

      await tester.tap(find.text('New backup codes'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Make new codes'));
      await settle(tester);

      expect(find.byType(BackupCodesScreen), findsNothing);
      expect(
        find.text(
          'Sign in again with the code from your authenticator app, then '
          'make new backup codes.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('leaving the setup drops the unfinished factor', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(twoFactorSwitch());
      await settle(tester);

      await tester.tap(find.byTooltip('Close'));
      await settle(tester);

      expect(find.byType(TwoFactorSetupScreen), findsNothing);
      expect(authService.twoFactorCalls, ['enroll', 'cancel:factor-1']);
      expect(switchedOn(tester), isFalse);
    });

    testWidgets('a setup that cannot start says why and can be tried again', (
      tester,
    ) async {
      authService.twoFactorError = const AuthException(
        'MFA enroll is disabled for TOTP',
        code: 'mfa_totp_enroll_not_enabled',
      );
      await open(tester);
      await tester.tap(twoFactorSwitch());
      await settle(tester);

      expect(
        find.text("Two-factor authentication isn't available right now."),
        findsOneWidget,
      );

      authService.twoFactorError = null;
      await tester.tap(find.text('Try again'));
      await settle(tester);
      expect(find.byType(QrCodeView), findsOneWidget);
    });

    testWidgets('turning it off asks first', (tester) async {
      authService
        ..twoFactorOn = true
        ..aal2 = true;
      await open(tester);
      expect(switchedOn(tester), isTrue);

      await tester.tap(twoFactorSwitch());
      await settle(tester);
      expect(find.text('Turn off two-factor authentication?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(authService.twoFactorCalls, isEmpty);
      expect(switchedOn(tester), isTrue);

      await tester.tap(twoFactorSwitch());
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
      await settle(tester);

      expect(authService.twoFactorCalls, ['disable']);
      expect(find.text('Two-factor authentication is off'), findsOneWidget);
      expect(switchedOn(tester), isFalse);
    });
  });
}
