import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'package:checkpoint/models/browse.dart';
import 'package:checkpoint/models/friend_activity.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/screens/home/home_screen.dart';
import 'package:checkpoint/screens/profile/public_profile_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// The Home tab's carousel: IGDB's popular list for a signed-in member, the
/// newest catalog games otherwise, and never a made-up figure. And what the
/// members you follow did lately.
void main() {
  late FakeRepository repo;
  late FakeBrowseApi browseApi;
  late FakeAuthService authService;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository()
      ..popular = [
        testGame(
          'p1',
          title: 'Fresh Catalog Game',
          status: null,
          cover: false,
          year: 2024,
        ),
      ];
    browseApi = FakeBrowseApi()
      ..answer = (mode, offset) => ResultsPage([
        testEntry('hot-1', title: 'Hot Game', score: 91.6),
      ], hasMore: false);
  });

  Future<void> start(WidgetTester tester, {User? user, FakeReleaseNotifier? device}) async {
    // Tall enough to have the whole page built.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    authService = FakeAuthService(user);
    final stores = AppStores(
      repository: repo,
      authService: authService,
      connectivity: FakeConnectivity(),
      apiService: browseApi,
      releaseNotifier: device,
    );
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(
          theme: buildTheme(),
          home: const Scaffold(body: HomeScreen()),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pumpAndSettle();
  }

  void expectNoMadeUpFigures() {
    expect(find.textContaining('players'), findsNothing);
    expect(find.textContaining('friends playing'), findsNothing);
    expect(find.textContaining('friend playing'), findsNothing);
    expect(find.text('Trending Among Friends'), findsNothing);
  }

  testWidgets(
    'a signed-in member sees what is popular on IGDB, with its score',
    (tester) async {
      await start(tester, user: testUser('u1'));

      expect(browseApi.callsFor(BrowseMode.popular), 1);
      expect(find.text('Popular Right Now'), findsOneWidget);
      expect(find.text('Hot Game'), findsWidgets);
      expect(find.text('92 / 100'), findsOneWidget);
      expect(find.text('Recently Added'), findsNothing);
      expectNoMadeUpFigures();
    },
  );

  group('release day reminders', () {
    FakeReleaseNotifier device = FakeReleaseNotifier();

    setUp(() {
      device = FakeReleaseNotifier();
      repo.library = [
        testGame('w', title: 'Soon Game', cover: false, status: GameStatus.wishlist)
            .copyWith(releaseDate: DateTime.now().add(const Duration(days: 10))),
      ];
    });

    testWidgets('Remind me on the releases row turns them on, and goes away', (tester) async {
      await start(tester, user: testUser('u1'), device: device);
      expect(find.text('Wishlist Releases'), findsOneWidget);

      await tester.tap(find.text('Remind me'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pumpAndSettle();

      expect(find.text('Reminders are on'), findsOneWidget);
      expect(find.text('Remind me'), findsNothing);
      expect(device.scheduled, [
        ['w'],
      ]);
    });

    testWidgets('a refusal is said, and Remind me stays', (tester) async {
      device.allow = false;
      await start(tester, user: testUser('u1'), device: device);

      await tester.tap(find.text('Remind me'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pumpAndSettle();

      expect(find.textContaining('turned off for Gamebit'), findsOneWidget);
      expect(find.text('Remind me'), findsOneWidget);
    });

    testWidgets('is not offered where they cannot be shown', (tester) async {
      device.isSupported = false;
      await start(tester, user: testUser('u1'), device: device);

      expect(find.text('Wishlist Releases'), findsOneWidget);
      expect(find.text('Remind me'), findsNothing);
    });
  });

  testWidgets('a visitor sees the newest catalog games, as what they are', (
    tester,
  ) async {
    await start(tester);

    expect(browseApi.calls, isEmpty); // IGDB answers signed-in members only
    expect(find.text('Recently Added'), findsOneWidget);
    expect(find.text('Fresh Catalog Game'), findsWidgets);
    expect(find.text('2024'), findsOneWidget);
    expectNoMadeUpFigures();
  });

  testWidgets(
    'when IGDB fails the catalog stands in, and it is asked only once',
    (tester) async {
      browseApi.answer = (mode, offset) => null;

      await start(tester, user: testUser('u1'));

      expect(browseApi.callsFor(BrowseMode.popular), 1);
      expect(find.text('Recently Added'), findsOneWidget);
      expect(find.text('Popular Right Now'), findsNothing);
    },
  );

  group('From people you follow', () {
    setUp(() {
      repo.followingActivity = [
        testActivity(
          'a',
          'f1',
          FriendActivityKind.session,
          name: 'Ann',
          title: 'Feed Session Game',
          hours: 2,
          at: DateTime.now().subtract(const Duration(hours: 3, minutes: 10)),
        ),
        testActivity(
          'b',
          'f2',
          FriendActivityKind.completed,
          name: 'Ben',
          title: 'Feed Completed Game',
          rating: 4,
        ),
        testActivity(
          'c',
          'f3',
          FriendActivityKind.rated,
          name: 'Cy',
          title: 'Feed Rated Game',
          rating: 4.5,
        ),
      ];
    });

    testWidgets('shows who did what, with the time of a session', (
      tester,
    ) async {
      await start(tester, user: testUser('u1'));

      expect(repo.feedReads, 1);
      expect(find.text('From people you follow'), findsOneWidget);
      for (final name in ['Ann', 'Ben', 'Cy']) {
        expect(find.byTooltip(name), findsOneWidget, reason: name);
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.text('+2h · 3h ago'), findsOneWidget);
      expect(find.text('Completed'), findsWidgets); // the stat tile too
      expect(find.text('Rated 4.5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a photo opens the member\'s profile', (tester) async {
      await start(tester, user: testUser('u1'));

      await tester.tap(find.byTooltip('Ben'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<PublicProfileScreen>(find.byType(PublicProfileScreen))
            .userId,
        'b',
      );
    });

    testWidgets(
      'tapping a cover opens the game, though it is not in the library',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await start(tester, user: testUser('u1'));

        await tester.tap(find.bySemanticsLabel('Open Feed Rated Game'));
        await tester.pumpAndSettle();

        expect(find.byType(GameDetailScreen), findsOneWidget);
        expect(find.text('Game not found'), findsNothing);
        expect(find.text('Not in your library'), findsOneWidget);
        semantics.dispose();
      },
    );

    testWidgets('is left out when none of them did anything', (tester) async {
      repo.followingActivity = [];

      await start(tester, user: testUser('u1'));

      expect(repo.feedReads, 1);
      expect(find.text('From people you follow'), findsNothing);
    });

    testWidgets('is left out when the request fails', (tester) async {
      repo.failFeedReads = true;

      await start(tester, user: testUser('u1'));

      expect(find.text('From people you follow'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a visitor is not asked; signing in shows it, signing out hides it',
      (tester) async {
        await start(tester);

        expect(repo.feedReads, 0);
        expect(find.text('From people you follow'), findsNothing);

        // The stores follow the session from outside the test's fake clock (they
        // were initialized in runAsync), so the change is announced there too.
        Future<void> announce(User? user) async {
          await tester.runAsync(() async {
            authService.emit(user);
            await pumpEventQueue();
          });
          await tester.pumpAndSettle();
        }

        await announce(testUser('u1'));
        expect(repo.feedReads, 1);
        expect(find.text('From people you follow'), findsOneWidget);

        await announce(null);
        expect(find.text('From people you follow'), findsNothing);
        expect(find.byTooltip('Ann'), findsNothing);
      },
    );
  });
}
