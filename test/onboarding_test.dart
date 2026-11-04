import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/screens/onboarding/onboarding_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/onboarding_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRepository repo;
  late FakeAuthService authService;
  late AppStores stores;

  AppStores newStores() => AppStores(
    repository: repo,
    authService: authService,
    connectivity: FakeConnectivity(),
    apiService: FakeBrowseApi(),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    authService = FakeAuthService();
    stores = newStores();
  });

  tearDown(() => stores.dispose());

  Future<bool?> savedRecord(String userId) async =>
      (await SharedPreferences.getInstance()).getBool(OnboardingStore.prefsKey(userId));

  group('the store', () {
    test('is due for a member whose library the server answered empty, and offers once', () async {
      authService.user = testUser('u1');
      await stores.initialize();

      expect(stores.onboarding.isDue, isTrue);
      expect(stores.onboarding.takeOffer(), 'u1');
      expect(stores.onboarding.isDue, isFalse);
      expect(stores.onboarding.takeOffer(), isNull);
    });

    test('is not due for a member with games', () async {
      repo.library = [testGame('g1', cover: false)];
      authService.user = testUser('u1');
      await stores.initialize();

      expect(stores.onboarding.isDue, isFalse);
    });

    test('is not due signed out', () async {
      await stores.initialize();

      expect(stores.onboarding.isDue, isFalse);
      expect(stores.onboarding.takeOffer(), isNull);
    });

    test('is not due while the library is only the copy saved on the device', () async {
      repo.offline = true;
      authService.user = testUser('u1');
      await stores.initialize();

      expect(stores.onboarding.isDue, isFalse);
    });

    test('is not due after it was finished, and the record is of the account', () async {
      SharedPreferences.setMockInitialValues({OnboardingStore.prefsKey('u1'): true});
      authService.user = testUser('u1');
      await stores.initialize();
      expect(stores.onboarding.isDue, isFalse);

      // Another account on the same device has not seen it.
      authService.emit(testUser('u2'));
      await pumpEventQueue();
      expect(stores.onboarding.takeOffer(), 'u2');
    });

    test('finishing records it for the account it was offered to, and for good', () async {
      authService.user = testUser('u1');
      await stores.initialize();
      final userId = stores.onboarding.takeOffer()!;

      // The member signed in as someone else while it was open.
      authService.emit(testUser('u2'));
      await pumpEventQueue();
      await stores.onboarding.finish(userId);

      expect(await savedRecord('u1'), isTrue);
      expect(await savedRecord('u2'), isNull);
      expect(stores.onboarding.takeOffer(), 'u2');

      // A fresh start of the app doesn't offer it to u1 again.
      stores.dispose();
      authService = FakeAuthService(testUser('u1'));
      stores = newStores();
      await stores.initialize();
      expect(stores.onboarding.isDue, isFalse);
    });
  });

  group('the app shell', () {
    Future<void> start(WidgetTester tester) async {
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(theme: buildTheme(), home: const AppShell()),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('walks a member with no games through it, once', (tester) async {
      authService.user = testUser('u1');
      await start(tester);

      expect(find.text('Welcome to Gamebit'), findsOneWidget);
      expect(find.text('Where do you play?'), findsOneWidget);

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Gamebit'), findsNothing);

      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(await tester.runAsync(() => savedRecord('u1')), isTrue);
      // Not again, even with the library still empty.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Welcome to Gamebit'), findsNothing);
    });

    testWidgets('leaves a member with games to the app', (tester) async {
      repo.library = [testGame('g1', cover: false)];
      authService.user = testUser('u1');
      await start(tester);

      expect(find.text('Welcome to Gamebit'), findsNothing);
    });
  });

  group('the screen', () {
    Future<void> open(WidgetTester tester, {double width = 412}) async {
      tester.view.physicalSize = Size(width, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      authService.user = testUser('u1');
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const OnboardingScreen()),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> next(WidgetTester tester) async {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }

    testWidgets('has three steps, and Back goes back', (tester) async {
      await open(tester);

      expect(find.text('Step 1 of 3'), findsOneWidget);
      expect(find.text('Where do you play?'), findsOneWidget);
      // Steam only: the one service the app can prove, and no typed-in names.
      expect(find.text('Steam'), findsOneWidget);
      for (final name in ['PSN', 'Xbox', 'Nintendo', 'Discord']) {
        expect(find.text(name), findsNothing, reason: name);
      }
      expect(find.text('Back'), findsNothing);

      await next(tester);
      expect(find.text('Step 2 of 3'), findsOneWidget);
      expect(find.text('Bring your games in'), findsOneWidget);
      expect(find.text('Connect Steam'), findsOneWidget);
      expect(find.text('Import from CSV'), findsOneWidget);
      expect(find.text('No games in your library yet'), findsOneWidget);

      await next(tester);
      expect(find.text('Step 3 of 3'), findsOneWidget);
      expect(find.text('Pick your top 4'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      // The last step is finished, not skipped.
      expect(find.text('Skip'), findsNothing);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 3'), findsOneWidget);
    });

    testWidgets('Skip closes it from any step but the last', (tester) async {
      await open(tester);
      await next(tester);

      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
      expect(find.text('Step 2 of 3'), findsNothing);
    });

    testWidgets('the library count follows what is imported', (tester) async {
      await open(tester);
      await next(tester);
      expect(find.text('No games in your library yet'), findsOneWidget);

      await tester.runAsync(() => stores.library.importGame(
        testGame('g1', title: 'Hades', cover: false, status: null),
        status: GameStatus.toPlay,
      ));
      await tester.pump();

      expect(find.text('1 game in your library'), findsOneWidget);
    });

    testWidgets('with no games, Find games ends it on the Search tab', (tester) async {
      await open(tester);
      await next(tester);
      await next(tester);
      expect(find.text('Find games'), findsOneWidget);

      await tester.tap(find.text('Find games'));
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
      expect(stores.nav.index, NavTab.search);
    });

    testWidgets('picks up to four favorites from the most played games', (tester) async {
      repo.library = [
        for (var i = 1; i <= 6; i++)
          testGame('g$i', title: 'Game $i', cover: false, hours: i.toDouble()),
      ];
      await open(tester);
      await next(tester);
      await next(tester);
      expect(find.text('0 of 4 picked'), findsOneWidget);
      // Most hours first.
      expect(
        tester.getTopLeft(find.text('Game 6')).dy <= tester.getTopLeft(find.text('Game 1')).dy,
        isTrue,
      );

      for (final title in ['Game 6', 'Game 5', 'Game 4', 'Game 3']) {
        await tester.tap(find.text(title));
        await tester.pump();
      }
      expect(find.text('4 of 4 picked'), findsOneWidget);

      // A fifth doesn't fit.
      await tester.tap(find.text('Game 2'));
      await tester.pump();
      expect(find.text('4 of 4 picked'), findsOneWidget);
      expect(stores.library.libraryGames.where((g) => g.isFavorite).map((g) => g.title).toSet(), {
        'Game 6',
        'Game 5',
        'Game 4',
        'Game 3',
      });

      // Letting one go makes room.
      await tester.tap(find.text('Game 6'));
      await tester.pump();
      expect(find.text('3 of 4 picked'), findsOneWidget);
    });

    testWidgets('fits a phone at the largest text size', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      repo.library = [
        for (var i = 1; i <= 8; i++)
          testGame('g$i', title: 'A game with a rather long title $i', cover: false, hours: i.toDouble()),
      ];
      await open(tester, width: 360);
      expect(tester.takeException(), isNull);
      await next(tester);
      expect(tester.takeException(), isNull);
      await next(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Done'), findsOneWidget);
    });
  });
}
