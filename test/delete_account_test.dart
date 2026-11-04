import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException, FunctionsFetchException;

import 'package:checkpoint/models/user_profile.dart';
import 'package:checkpoint/screens/settings/account_section.dart';
import 'package:checkpoint/screens/settings/settings_screen.dart';
import 'package:checkpoint/services/delete_account_failure.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/services/pending_edits.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// The keys that hold u1's data on the device: the saved copy (LocalCache), the
/// edits still waiting for the server (PendingEditsStorage) and the flag that the
/// first-run walk-through was shown (OnboardingStore).
const u1Keys = {
  'cache.v1.library.u1',
  'cache.v1.profile.u1',
  'pending.v1.u1',
  'pending.v1.follows.u1',
  'onboarding.v1.u1',
};

/// A device with u1 (the account that gets deleted), u2 and the app's own data
/// saved the way the stores save them. Pair it with `FakeRepository.writesDown`
/// when stores load, so the queued edits are not sent (and removed) on the way.
Future<void> seedDevice() async {
  SharedPreferences.setMockInitialValues({
    'onboarding.v1.u1': true,
    'onboarding.v1.u2': true,
    'theme': 'dark',
  });
  final cache = LocalCache();
  await cache.writeLibrary('u1', [testGame('a')]);
  await cache.writeProfile(
    'u1',
    UserProfile(name: 'Ada', handle: '@ada', bio: '', joined: DateTime.utc(2026, 1, 1), followers: 0, following: 0),
  );
  await cache.writeLibrary('u2', [testGame('b')]);
  await cache.writePopular([testGame('c', status: null)]);
  await PendingEditsStorage().write('u1', PendingEdits()..markRemoved('a'));
  await PendingEditsStorage(PendingScope.follows).write('u1', PendingEdits()..putFollow('u9', following: true));
  await PendingEditsStorage().write('u2', PendingEdits()..markRemoved('b'));
}

const otherData = [
  'cache.v1.library.u2',
  'pending.v1.u2',
  'onboarding.v1.u2',
  'cache.v1.popular',
  'theme',
];

Future<Set<String>> savedKeys() async => (await SharedPreferences.getInstance()).getKeys();

void main() {
  group('ProfileStore.deleteAccount', () {
    late FakeRepository repo;
    late FakeAuthService authService;
    late AppStores stores;
    late DebugPrintCallback originalDebugPrint;

    setUp(() async {
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {};
      await seedDevice();
      repo = FakeRepository()..writesDown = true;
      authService = FakeAuthService(testUser('u1'));
      stores = AppStores(repository: repo, authService: authService, connectivity: FakeConnectivity());
    });

    tearDown(() {
      debugPrint = originalDebugPrint;
      stores.dispose();
    });

    test('signs out and erases what the device holds for the account, and only that', () async {
      await stores.initialize();
      expect(await savedKeys(), containsAll(u1Keys));

      final error = await stores.profile.deleteAccount();
      await pumpEventQueue();

      expect(error, isNull);
      expect(authService.deleteCalls, 1);
      expect(stores.auth.isLoggedIn, isFalse);
      expect(stores.profile.profile.handle, '@guest');
      final keys = await savedKeys();
      expect(keys.intersection(u1Keys), isEmpty);
      expect(keys, containsAll(otherData));
    });

    test('leaves the account, its session and its saved data alone when the server cannot be reached', () async {
      await stores.initialize();
      authService.deleteError = const FunctionsFetchException(details: 'no route to host');

      final error = await stores.profile.deleteAccount();

      expect(error, deleteAccountMessage(const FunctionsFetchException()));
      expect(error, contains('Could not reach the server'));
      expect(stores.auth.isLoggedIn, isTrue);
      expect(await savedKeys(), containsAll(u1Keys));
    });

    test('says which failures are worth trying again', () {
      String messageFor(int status, [Object? details]) =>
          deleteAccountMessage(FunctionException(status: status, details: details));

      expect(messageFor(401, {'code': 'UNAUTHENTICATED'}), contains('Sign in again'));
      expect(messageFor(401), contains('Sign in again')); // a gateway 401 has no body
      expect(messageFor(500, {'code': 'INTERNAL'}), contains('Try again in a moment'));
      expect(messageFor(503), contains('Try again in a moment'));
      expect(messageFor(400), 'Could not delete your account. Please try again.');
      expect(deleteAccountMessage(StateError('x')), 'Sign in to delete your account.');
      expect(deleteAccountMessage(Exception('x')), contains('Could not reach the server'));
    });

    test('does not call the server while the session has not been restored', () async {
      authService
        ..user = null
        ..persistedId = 'u1'; // the app started offline with an expired session
      await stores.initialize();
      expect(stores.auth.isSessionPending, isTrue);

      final error = await stores.profile.deleteAccount();

      expect(authService.deleteCalls, 0);
      expect(error, contains('Could not reach the server'));
      expect(await savedKeys(), containsAll(u1Keys));
    });

    test('asks to sign in when nobody is', () async {
      authService.user = null;
      await stores.initialize();

      expect(await stores.profile.deleteAccount(), 'Sign in to delete your account.');
      expect(authService.deleteCalls, 0);
    });
  });

  group('LocalCache.eraseAccount', () {
    test('removes only keys that end in the account id', () async {
      await seedDevice();
      // Another account whose id starts the same.
      await LocalCache().writeLibrary('u10', [testGame('d')]);
      expect(await savedKeys(), containsAll(u1Keys));

      await LocalCache().eraseAccount('u1');

      final keys = await savedKeys();
      expect(keys.intersection(u1Keys), isEmpty);
      expect(keys, containsAll([...otherData, 'cache.v1.library.u10']));
    });
  });

  group('Delete account in Settings > Account', () {
    late FakeAuthService authService;
    late AppStores stores;

    setUp(() {
      authService = FakeAuthService(testUser('u1'));
      stores = AppStores(
        repository: FakeRepository()..writesDown = true,
        authService: authService,
        connectivity: FakeConnectivity(),
      );
    });

    /// The screen, opened from a first screen the way the Profile tab opens it.
    Future<void> openScreen(WidgetTester tester) async {
      await tester.runAsync(() async {
        await seedDevice();
        await stores.initialize();
      });
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    final deleteButton = find.byIcon(Icons.delete_forever_rounded);
    final confirmButton = find.widgetWithText(TextButton, 'Delete account');

    Future<void> askToDelete(WidgetTester tester) async {
      // The list builds what is near the window: scroll until the button exists.
      await tester.scrollUntilVisible(
        deleteButton,
        300,
        scrollable: find.descendant(
          of: find.byType(AccountSection),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.ensureVisible(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
    }

    testWidgets('asks first, and cancelling deletes nothing', (tester) async {
      await openScreen(tester);

      await askToDelete(tester);
      expect(find.text('Delete your account?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(authService.deleteCalls, 0);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Delete your account?'), findsNothing);
    });

    testWidgets('confirming deletes the account and leaves the screen', (tester) async {
      await openScreen(tester);

      await askToDelete(tester);
      await tester.runAsync(() async {
        await tester.tap(confirmButton);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(authService.deleteCalls, 1);
      expect(stores.auth.isLoggedIn, isFalse);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.text('Your account was deleted'), findsOneWidget);
      expect((await savedKeys()).intersection(u1Keys), isEmpty);
    });

    testWidgets('a failed deletion keeps the screen and says why', (tester) async {
      authService.deleteError = const FunctionException(status: 503);
      await openScreen(tester);

      await askToDelete(tester);
      await tester.runAsync(() async {
        await tester.tap(confirmButton);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(authService.deleteCalls, 1);
      expect(stores.auth.isLoggedIn, isTrue);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.textContaining('Try again in a moment'), findsOneWidget);
      // Back to normal: the button works again.
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Delete account')).onPressed, isNotNull);
    });
  });
}
