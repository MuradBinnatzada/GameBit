import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show AuthorizationErrorCode, SignInWithAppleAuthorizationException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthApiException, AuthWeakPasswordException;

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/auth_gate.dart';
import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/app/sign_in_panel.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// Email-and-password sign-in on the log-in overlay of the real app shell,
/// and on the screen the other "Log in" buttons open.
void main() {
  late FakeAuthService authService;
  late AppStores stores;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    authService = FakeAuthService();
    stores = AppStores(
      repository: FakeRepository(),
      authService: authService,
      connectivity: FakeConnectivity(),
      // Home asks IGDB for what is popular.
      apiService: FakeBrowseApi(),
    );
  });

  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    // As in the app: the stores start before the first frame.
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: buildTheme(), home: home),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
  }

  /// Opens the Library tab, which a signed-out visitor sees behind the overlay.
  Future<void> openGate(WidgetTester tester) async {
    await pumpApp(tester, const AppShell());
    stores.nav.select(NavTab.library);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  Finder button(String label) => find.widgetWithText(FilledButton, label);

  Future<void> tap(WidgetTester tester, Finder finder) async {
    // The panel scrolls when the window is short.
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump();
  }

  Future<void> fill(WidgetTester tester, Map<String, String> values) async {
    for (final MapEntry(:key, :value) in values.entries) {
      await tester.enterText(field(key), value);
    }
  }

  /// Lets the stores load the account that signed in.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the overlay offers Google and an email form', (tester) async {
    await openGate(tester);

    expect(find.text('Log in to track games'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(field('Email'), findsOneWidget);
    expect(field('Password'), findsOneWidget);
    expect(button('Sign in'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    // The name is only asked for when creating an account.
    expect(field('Display name'), findsNothing);
  });

  testWidgets('Apple is offered only where the device can do it', (
    tester,
  ) async {
    await openGate(tester);
    expect(find.text('Continue with Apple'), findsNothing);
  });

  testWidgets('Continue with Apple signs in, and a cancelled sheet says so', (
    tester,
  ) async {
    authService.offersApple = true;
    authService.appleError = const SignInWithAppleAuthorizationException(
      code: AuthorizationErrorCode.canceled,
      message: 'The user canceled.',
    );
    await openGate(tester);

    await tap(tester, find.text('Continue with Apple'));
    await settle(tester);
    expect(find.text('Apple sign-in was cancelled.'), findsOneWidget);
    expect(stores.auth.isLoggedIn, isFalse);

    authService.appleError = null;
    await tap(tester, find.text('Continue with Apple'));
    await settle(tester);
    expect(authService.appleCalls, 2);
    expect(stores.auth.isLoggedIn, isTrue);
    expect(find.text('Log in to track games'), findsNothing);
  });

  testWidgets('signing in with an email and password lifts the overlay', (
    tester,
  ) async {
    await openGate(tester);

    await fill(tester, {'Email': ' ada@example.com ', 'Password': 'hunter22'});
    await tap(tester, button('Sign in'));
    await settle(tester);

    expect(authService.emailCalls, ['signIn:ada@example.com:hunter22']);
    expect(stores.auth.isLoggedIn, isTrue);
    expect(find.text('Log in to track games'), findsNothing);
  });

  testWidgets('the fields are checked before anything is sent', (tester) async {
    await openGate(tester);

    await tap(tester, button('Sign in'));
    expect(find.text('Enter your email address'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);

    await fill(tester, {'Email': 'ada@example', 'Password': 'x'});
    await tester.pump();
    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(find.text('Enter your password'), findsNothing);

    await tap(tester, find.text('Create account'));
    await fill(tester, {'Email': 'ada@example.com'});
    await tap(tester, button('Create account'));
    expect(find.text('Enter a name for your profile'), findsOneWidget);

    expect(authService.emailCalls, isEmpty);
    expect(stores.auth.isLoggedIn, isFalse);
  });

  testWidgets('a new password must be at least 8 characters, a sign-in is not held to it', (
    tester,
  ) async {
    await openGate(tester);

    await tap(tester, find.text('Create account'));
    await fill(tester, {
      'Display name': 'Ada',
      'Email': 'ada@example.com',
      'Password': 'short',
    });
    await tap(tester, button('Create account'));
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(authService.emailCalls, isEmpty);

    // An older account may have a shorter password: signing in sends it.
    await tap(tester, find.text('Sign in')); // the segment: this is the Create account form
    await tap(tester, button('Sign in'));
    await settle(tester);
    expect(find.text('Use at least 8 characters.'), findsNothing);
    expect(authService.emailCalls, ['signIn:ada@example.com:short']);
  });

  testWidgets('it says that continuing means agreeing to the terms and the privacy policy', (
    tester,
  ) async {
    await openGate(tester);

    final sentence = find.textContaining('you agree to the', findRichText: true);
    expect(sentence, findsOneWidget);
    expect(find.textContaining('Terms of Use', findRichText: true), findsOneWidget);
    expect(find.textContaining('Privacy Policy', findRichText: true), findsOneWidget);
  });

  testWidgets('a wrong password says so and keeps the overlay', (tester) async {
    authService.emailError = const AuthApiException(
      'Invalid login credentials',
      statusCode: '400',
      code: 'invalid_credentials',
    );
    await openGate(tester);

    await fill(tester, {'Email': 'ada@example.com', 'Password': 'wrong'});
    await tap(tester, button('Sign in'));

    expect(find.textContaining('Wrong email or password.'), findsOneWidget);
    expect(stores.auth.isLoggedIn, isFalse);
    expect(find.text('Log in to track games'), findsOneWidget);
    // The form can be used again straight away.
    expect(tester.widget<FilledButton>(button('Sign in')).onPressed, isNotNull);
  });

  testWidgets('an unconfirmed email says to confirm it first', (tester) async {
    authService.emailError = const AuthApiException(
      'Email not confirmed',
      statusCode: '400',
      code: 'email_not_confirmed',
    );
    await openGate(tester);

    await fill(tester, {'Email': 'ada@example.com', 'Password': 'hunter22'});
    await tap(tester, button('Sign in'));

    expect(
      find.text(
        'Confirm your email first: open the link we sent you, then sign in.',
      ),
      findsOneWidget,
    );
    expect(stores.auth.isLoggedIn, isFalse);
  });

  testWidgets('Create account sends the name and signs the new member in', (
    tester,
  ) async {
    await openGate(tester);

    await tap(tester, find.text('Create account'));
    expect(find.text('Forgot password?'), findsNothing);
    await fill(tester, {
      'Display name': ' Ada Lovelace ',
      'Email': 'ada@example.com',
      'Password': 'correct horse',
    });
    await tap(tester, button('Create account'));
    await settle(tester);

    expect(authService.emailCalls, [
      'signUp:ada@example.com:correct horse:Ada Lovelace',
    ]);
    expect(stores.auth.isLoggedIn, isTrue);
    expect(find.text('Log in to track games'), findsNothing);
  });

  testWidgets('a sign-up that must be confirmed says to check the inbox', (
    tester,
  ) async {
    authService.signUpNeedsConfirmation = true;
    await openGate(tester);

    await tap(tester, find.text('Create account'));
    await fill(tester, {
      'Display name': 'Ada',
      'Email': 'ada@example.com',
      'Password': 'correct horse',
    });
    await tap(tester, button('Create account'));

    expect(
      find.textContaining('we sent a confirmation link to ada@example.com'),
      findsOneWidget,
    );
    expect(stores.auth.isLoggedIn, isFalse);
    // Back on Sign in, with the address kept for after confirming.
    expect(button('Sign in'), findsOneWidget);
    expect(field('Display name'), findsNothing);
    expect(find.text('ada@example.com'), findsOneWidget);
  });

  testWidgets('an email that is already registered says so', (tester) async {
    authService.emailError = const AuthApiException(
      'User already registered',
      statusCode: '422',
      code: 'user_already_exists',
    );
    await openGate(tester);

    await tap(tester, find.text('Create account'));
    await fill(tester, {
      'Display name': 'Ada',
      'Email': 'ada@example.com',
      'Password': 'correct horse',
    });
    await tap(tester, button('Create account'));

    expect(
      find.textContaining('That email is already registered.'),
      findsOneWidget,
    );
    expect(stores.auth.isLoggedIn, isFalse);
  });

  testWidgets('a weak password says what is missing', (tester) async {
    authService.emailError = AuthWeakPasswordException(
      message: 'Password should be at least 6 characters.',
      statusCode: '422',
      reasons: ['length'],
    );
    await openGate(tester);

    await tap(tester, find.text('Create account'));
    await fill(tester, {
      'Display name': 'Ada',
      'Email': 'ada@example.com',
      'Password': 'letmein1',
    });
    await tap(tester, button('Create account'));

    expect(
      find.text(
        'That password is too weak. Password should be at least 6 characters.',
      ),
      findsOneWidget,
    );
    expect(stores.auth.isLoggedIn, isFalse);
  });

  testWidgets('Forgot password? emails a reset link to the address typed in', (
    tester,
  ) async {
    await openGate(tester);

    await tap(tester, find.text('Forgot password?'));
    expect(find.text('Enter your email address'), findsOneWidget);
    // Only the address is needed.
    expect(find.text('Enter your password'), findsNothing);
    expect(authService.emailCalls, isEmpty);

    await fill(tester, {'Email': 'ada@example.com'});
    await tap(tester, find.text('Forgot password?'));

    expect(authService.emailCalls, ['reset:ada@example.com']);
    expect(
      find.textContaining('a link to choose a new password is on its way'),
      findsOneWidget,
    );
  });

  testWidgets('a reset email that could not be sent says why', (tester) async {
    authService.emailError = const AuthApiException(
      'email rate limit exceeded',
      statusCode: '429',
      code: 'over_email_send_rate_limit',
    );
    await openGate(tester);

    await fill(tester, {'Email': 'ada@example.com'});
    await tap(tester, find.text('Forgot password?'));

    expect(
      find.text('Too many emails were sent. Wait a few minutes and try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('is on its way'), findsNothing);
  });

  testWidgets('other Log in buttons open the sign-in screen, which closes '
      'once signed in', (tester) async {
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => logIn(context),
              child: const Text('Log in'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);

    await fill(tester, {'Email': 'ada@example.com', 'Password': 'hunter22'});
    await tap(tester, button('Sign in'));
    await settle(tester);
    await tester.pumpAndSettle();

    expect(stores.auth.isLoggedIn, isTrue);
    expect(find.byType(SignInScreen), findsNothing);
    expect(find.text('Log in'), findsOneWidget);
  });

  testWidgets('the sign-in screen shows why a sign-in failed', (tester) async {
    authService.emailError = const AuthApiException(
      'Invalid login credentials',
      statusCode: '400',
      code: 'invalid_credentials',
    );
    await pumpApp(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => logIn(context),
              child: const Text('Log in'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();

    await fill(tester, {'Email': 'ada@example.com', 'Password': 'wrong'});
    await tap(tester, button('Sign in'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Wrong email or password.'), findsOneWidget);
    expect(find.byType(SignInScreen), findsOneWidget);
  });
}
