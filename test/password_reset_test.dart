import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthWeakPasswordException, User;

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/new_password_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// A password reset link signs the user in; the real app shell then asks for
/// the new password.
void main() {
  late FakeAuthService authService;
  late AppStores stores;

  User emailUser([String id = 'u1']) => User(
    id: id,
    appMetadata: const {'provider': 'email'},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
    email: 'ada@example.com',
  );

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

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: buildTheme(), home: const AppShell()),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
  }

  Future<void> start(WidgetTester tester) async {
    // As in the app: the stores start before the first frame.
    await tester.runAsync(stores.initialize);
    await pumpShell(tester);
  }

  /// Lets the stores take in an auth event, and a screen slide in or out.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    // The route starts its transition, ends it, and is taken off the screen.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openResetLink(WidgetTester tester) async {
    authService.openResetLink(emailUser());
    await settle(tester);
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  Finder saveButton() => find.widgetWithText(FilledButton, 'Save password');

  Future<void> fill(
    WidgetTester tester,
    String password, {
    String? confirm,
  }) async {
    await tester.enterText(field('New password'), password);
    await tester.enterText(field('Confirm new password'), confirm ?? password);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await settle(tester);
  }

  testWidgets('a reset link asks for a new password and saves it', (
    tester,
  ) async {
    await start(tester);
    await openResetLink(tester);

    expect(stores.auth.isLoggedIn, isTrue);
    expect(stores.auth.isRecoveringPassword, isTrue);
    expect(find.byType(NewPasswordScreen), findsOneWidget);
    expect(find.text('Choose a new password'), findsOneWidget);
    expect(
      find.textContaining('password reset link for ada@example.com'),
      findsOneWidget,
    );

    await fill(tester, 'correct horse');
    await tap(tester, saveButton());

    expect(authService.passwordUpdates, ['correct horse']);
    expect(find.byType(NewPasswordScreen), findsNothing);
    expect(find.text('Password changed'), findsOneWidget);
    expect(stores.auth.isRecoveringPassword, isFalse);
    expect(stores.auth.isLoggedIn, isTrue);
  });

  testWidgets('a password under 8 characters is refused before anything is sent', (
    tester,
  ) async {
    await start(tester);
    await openResetLink(tester);

    await fill(tester, 'short');
    await tap(tester, saveButton());

    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(authService.passwordUpdates, isEmpty);

    await fill(tester, 'long enough');
    await tester.pump();
    expect(find.text('Use at least 8 characters.'), findsNothing);
  });

  testWidgets('the password is checked before anything is sent', (
    tester,
  ) async {
    await start(tester);
    await openResetLink(tester);

    await tap(tester, saveButton());
    expect(find.text('Choose a password'), findsOneWidget);

    await fill(tester, 'correct horse', confirm: 'correct hose');
    await tester.pump();
    expect(find.text('Choose a password'), findsNothing);
    expect(find.text("The passwords don't match"), findsOneWidget);

    await tap(tester, saveButton());
    expect(authService.passwordUpdates, isEmpty);
    expect(find.byType(NewPasswordScreen), findsOneWidget);
  });

  testWidgets('a weak password says what is missing and keeps the screen', (
    tester,
  ) async {
    authService.passwordError = AuthWeakPasswordException(
      message: 'Password should be at least 6 characters.',
      statusCode: '422',
      reasons: ['length'],
    );
    await start(tester);
    await openResetLink(tester);

    await fill(tester, 'letmein1');
    await tap(tester, saveButton());

    expect(
      find.text(
        'That password is too weak. Password should be at least 6 characters.',
      ),
      findsOneWidget,
    );
    expect(find.byType(NewPasswordScreen), findsOneWidget);
    expect(stores.auth.isRecoveringPassword, isTrue);
    // It can be tried again straight away.
    expect(tester.widget<FilledButton>(saveButton()).onPressed, isNotNull);
  });

  testWidgets('Not now keeps the old password and the user signed in', (
    tester,
  ) async {
    await start(tester);
    await openResetLink(tester);

    await tap(tester, find.text('Not now'));

    expect(find.byType(NewPasswordScreen), findsNothing);
    expect(authService.passwordUpdates, isEmpty);
    expect(stores.auth.isRecoveringPassword, isFalse);
    expect(stores.auth.isLoggedIn, isTrue);
  });

  testWidgets('closing the screen puts it off too', (tester) async {
    await start(tester);
    await openResetLink(tester);

    await tap(tester, find.byType(CloseButton));

    expect(find.byType(NewPasswordScreen), findsNothing);
    expect(stores.auth.isRecoveringPassword, isFalse);
  });

  testWidgets('signing out closes the screen', (tester) async {
    await start(tester);
    await openResetLink(tester);

    authService.emit(null);
    await settle(tester);

    expect(find.byType(NewPasswordScreen), findsNothing);
    expect(stores.auth.isRecoveringPassword, isFalse);
    expect(stores.auth.isLoggedIn, isFalse);
  });

  testWidgets('an ordinary sign-in does not ask for a password', (
    tester,
  ) async {
    await start(tester);

    authService.emit(emailUser());
    await settle(tester);

    expect(stores.auth.isLoggedIn, isTrue);
    expect(stores.auth.isRecoveringPassword, isFalse);
    expect(find.byType(NewPasswordScreen), findsNothing);
  });

  testWidgets('only the browser tab that opened the link asks', (tester) async {
    await start(tester);

    // Another tab opened the link; Supabase passes the sign-in on to this one.
    authService.openResetLink(emailUser(), fromBroadcast: true);
    await settle(tester);

    expect(stores.auth.isLoggedIn, isTrue);
    expect(stores.auth.isRecoveringPassword, isFalse);
    expect(find.byType(NewPasswordScreen), findsNothing);
  });

  testWidgets('a link taken in before the shell was built still asks', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await stores.initialize();
      authService.openResetLink(emailUser());
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(stores.auth.isRecoveringPassword, isTrue);

    await pumpShell(tester);
    await settle(tester);

    expect(find.byType(NewPasswordScreen), findsOneWidget);
  });

  testWidgets('another account signing in ends the request', (tester) async {
    await start(tester);
    await openResetLink(tester);

    authService.emit(emailUser('u2'));
    await settle(tester);

    expect(stores.auth.user?.id, 'u2');
    expect(stores.auth.isRecoveringPassword, isFalse);
    expect(find.byType(NewPasswordScreen), findsNothing);
  });
}
