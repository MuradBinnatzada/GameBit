import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_details.dart';
import 'package:checkpoint/models/game_friends.dart';
import 'package:checkpoint/screens/game_detail/friends_panel.dart';
import 'package:checkpoint/screens/profile/public_profile_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/screens/game_detail/igdb_sections.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/empty_state.dart';
import 'package:checkpoint/widgets/panel.dart';
import 'package:checkpoint/widgets/platform_widgets.dart';
import 'package:checkpoint/widgets/star_rating.dart';

import 'support/fakes.dart';

/// The game detail screen on top of fake data sources.
void main() {
  late FakeRepository repo;
  late FakeDetailsApi detailsApi;
  late AppStores stores;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    // IGDB can't be reached unless a test says what it answers.
    detailsApi = FakeDetailsApi();
    stores = AppStores(
      repository: repo,
      authService: FakeAuthService(),
      connectivity: FakeConnectivity(),
      apiService: detailsApi,
    );
  });

  Future<void> start(WidgetTester tester, Widget home) async {
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

  group('what IGDB says about the game', () {
    Future<void> openWithDetails(WidgetTester tester, {List<GamePlatform>? library, GameDetails? details}) async {
      // Tall enough to have the whole page on screen.
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(testUser('u1')),
        connectivity: FakeConnectivity(),
        apiService: detailsApi,
      );
      repo.library = [testGame('g1', title: 'Skyrim', platforms: library ?? [GamePlatform.pc], igdbId: 472, cover: false)];
      detailsApi.answer = (id) => details;
      await start(tester, const GameDetailScreen(gameId: 'g1'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the game info, story, time to beat and similar games once they load', (tester) async {
      await openWithDetails(tester, details: testDetails(igdbId: 472));

      expect(detailsApi.calls, [472]);
      // Description, story and game info are one panel.
      expect(find.text('About'), findsOneWidget);
      expect(find.text('Game info'), findsNothing);
      for (final text in [
        'Main developers',
        'Bethesda Game Studios',
        'Publishers',
        'Bethesda Softworks',
        'Themes',
        'Fantasy',
        'Game modes',
        'Single player',
        'Player perspectives',
        'First person',
        'Game engine',
        'Creation Engine',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.text('Story'), findsOneWidget);
      expect(find.text('The Empire of Tamriel is on the edge.'), findsOneWidget);
      // Only a link to HowLongToBeat: IGDB's times are not shown.
      expect(find.text('Time to beat'), findsOneWidget);
      expect(find.text('View on HowLongToBeat'), findsOneWidget);
      for (final text in ['25 h', '50 h', '150 h', 'Main Story', 'IGDB']) {
        expect(find.text(text), findsNothing, reason: text);
      }
      expect(find.textContaining('on IGDB'), findsNothing);
      expect(find.text('Similar games'), findsOneWidget);
      expect(find.text('Oblivion'), findsOneWidget);
    });

    testWidgets('"Played on" offers exactly the platforms the game is on, and not Mobile', (tester) async {
      // The library only knew PC (a game Steam sync added before it read IGDB's platforms).
      await openWithDetails(tester, details: testDetails(igdbId: 472));

      Finder chip(GamePlatform p) => find.descendant(of: find.byType(PlatformChips), matching: find.text(p.label));
      for (final p in [GamePlatform.pc, GamePlatform.steamDeck, GamePlatform.ps3, GamePlatform.xbox360, GamePlatform.emulator]) {
        expect(chip(p), findsOneWidget, reason: p.name);
      }
      for (final p in [GamePlatform.mobile, GamePlatform.ios, GamePlatform.android, GamePlatform.ps5, GamePlatform.nswitch]) {
        expect(chip(p), findsNothing, reason: p.name);
      }
      // The game's platform badges are exact too.
      expect(find.text('PS3'), findsWidgets);
      expect(find.text('Xbox 360'), findsWidgets);
    });

    testWidgets('a game IGDB could not be reached for shows what it had, without the extra panels', (tester) async {
      await openWithDetails(tester, details: null);

      expect(detailsApi.calls, [472]);
      expect(find.text('Main developers'), findsNothing);
      expect(find.text('Story'), findsNothing);
      expect(find.text('Similar games'), findsNothing);
      // The link to HowLongToBeat does not need IGDB.
      expect(find.text('Time to beat'), findsOneWidget);
      expect(find.text('View on HowLongToBeat'), findsOneWidget);
      // About still has what the library holds: genres and the developer.
      expect(find.text('About'), findsOneWidget);
      expect(find.text('Genres'), findsOneWidget);
      expect(find.text('Developer'), findsWidgets);
      expect(find.text('Played on'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a panel with nothing to show is left out', (tester) async {
      await openWithDetails(
        tester,
        details: GameDetails(igdbId: 472, platforms: const [GamePlatform.pc]),
      );

      expect(find.text('Main developers'), findsNothing);
      expect(find.text('Story'), findsNothing);
      expect(find.text('Similar games'), findsNothing);
    });

    testWidgets('time to beat is only a link to HowLongToBeat', (tester) async {
      await openWithDetails(tester, details: testDetails(igdbId: 472));

      expect(find.text('Time to beat'), findsOneWidget);
      expect(find.text('View on HowLongToBeat'), findsOneWidget);
      expect(find.textContaining('IGDB'), findsNothing);
      expect(
        howLongToBeatSearch('Metro 2033: Redux').toString(),
        'https://howlongtobeat.com/?q=Metro%202033%3A%20Redux',
      );
    });

    testWidgets('has no play timer button, signed in or not', (tester) async {
      await openWithDetails(tester, details: testDetails(igdbId: 472));

      expect(find.text('Start timer'), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.text('Log Hours'), findsOneWidget);
    });

    testWidgets('tapping a similar game opens its screen', (tester) async {
      await openWithDetails(tester, details: testDetails(igdbId: 472));

      await tester.tap(find.text('Oblivion'));
      await tester.pumpAndSettle();

      final screen = tester.widget<GameDetailScreen>(find.byType(GameDetailScreen).last);
      expect(screen.gameId, 'similar-1');
      expect(find.text('Game not found'), findsNothing);
    });
  });

  group('friends who have the game', () {
    Future<void> openWithFriends(WidgetTester tester, GameFriends friends, {bool signedIn = true}) async {
      // Tall enough to have the whole page on screen.
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(signedIn ? testUser('u1') : null),
        connectivity: FakeConnectivity(),
        apiService: detailsApi,
      );
      repo.library = [testGame('g1', cover: false)];
      repo.popular = [testGame('g1', status: null, cover: false)];
      repo.friendsWithGame['g1'] = friends;
      await start(tester, const GameDetailScreen(gameId: 'g1'));
      await tester.pumpAndSettle();
    }

    Finder inPanel(Finder finder) => find.descendant(of: find.byType(FriendsPanel), matching: finder);

    testWidgets('shows who completed it, is playing it and wants to play it, with the stars they gave', (tester) async {
      await openWithFriends(
        tester,
        testGameFriends([
          testFriend('a', GameStatus.completed, rating: 4.5, name: 'Ann'),
          testFriend('b', GameStatus.completed, name: 'Ben'),
          testFriend('c', GameStatus.playing, name: 'Cy'),
          testFriend('d', GameStatus.wishlist, name: 'Di'),
          testFriend('e', GameStatus.toPlay, name: 'Ed'),
          testFriend('f', GameStatus.dropped, name: 'Fay'),
        ]),
      );

      expect(repo.friendReads, ['g1']);
      expect(inPanel(find.text('Friends')), findsOneWidget);
      expect(find.text('2 friends completed it'), findsOneWidget);
      expect(find.text('1 friend is playing'), findsOneWidget);
      expect(find.text('2 friends want to play'), findsOneWidget);
      for (final name in ['Ann', 'Ben', 'Cy', 'Di', 'Ed']) {
        expect(find.byTooltip(name), findsOneWidget, reason: name);
      }
      // Dropped is not a row.
      expect(find.byTooltip('Fay'), findsNothing);
      // Only Ann rated it.
      expect(tester.widget<StarRating>(inPanel(find.byType(StarRating))).rating, 4.5);
      expect(tester.takeException(), isNull);
    });

    testWidgets('says how many more have it than were sent', (tester) async {
      await openWithFriends(
        tester,
        testGameFriends([testFriend('a', GameStatus.completed, name: 'Ann')], totals: {GameStatus.completed: 25}),
      );

      expect(find.text('25 friends completed it'), findsOneWidget);
      expect(find.text('+24'), findsOneWidget);
      expect(find.text('1 friend is playing'), findsNothing);
    });

    testWidgets('tapping a friend opens their profile', (tester) async {
      await openWithFriends(tester, testGameFriends([testFriend('a', GameStatus.playing, name: 'Ann')]));

      await tester.tap(find.byTooltip('Ann'));
      await tester.pumpAndSettle();

      expect(tester.widget<PublicProfileScreen>(find.byType(PublicProfileScreen)).userId, 'a');
    });

    testWidgets('is left out when none of them has the game', (tester) async {
      await openWithFriends(tester, testGameFriends([testFriend('f', GameStatus.dropped)]));

      expect(repo.friendReads, ['g1']);
      expect(inPanel(find.text('Friends')), findsNothing);
      expect(find.byType(Panel), findsWidgets); // the rest of the page is there
    });

    testWidgets('is left out when the read fails', (tester) async {
      repo.failFriendsReads = true;
      await openWithFriends(tester, testGameFriends([testFriend('a', GameStatus.playing, name: 'Ann')]));

      expect(inPanel(find.text('Friends')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('signed out, nothing is asked and nothing is shown', (tester) async {
      await openWithFriends(tester, testGameFriends([testFriend('a', GameStatus.playing, name: 'Ann')]), signedIn: false);

      expect(repo.friendReads, isEmpty);
      expect(inPanel(find.text('Friends')), findsNothing);
    });

    test('the headline counts in words', () {
      expect(friendGroupHeadline(FriendGroup.completed, 1), '1 friend completed it');
      expect(friendGroupHeadline(FriendGroup.playing, 3), '3 friends are playing');
      expect(friendGroupHeadline(FriendGroup.wantToPlay, 1), '1 friend wants to play');
      expect(friendGroupHeadline(FriendGroup.wantToPlay, 2), '2 friends want to play');
    });
  });

  group('a snack bar with an Undo', () {
    setUp(() {
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(testUser('u1')),
        connectivity: FakeConnectivity(),
        apiService: detailsApi,
      );
    });

    testWidgets('goes away by itself after a few seconds', (tester) async {
      // Tall enough to have the status buttons on screen.
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      repo.library = [testGame('g1', status: GameStatus.playing, cover: false)];
      await start(tester, const GameDetailScreen(gameId: 'g1'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mark as Completed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.text('Marked as completed'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      // Still there while the user can reach for the Undo.
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Marked as completed'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Marked as completed'), findsNothing);
    });
  });

  testWidgets(
    'an id that matches no game shows "Game not found", not a blank or red screen',
    (tester) async {
      await start(tester, const GameDetailScreen(gameId: 'no-such-game'));

      expect(tester.takeException(), isNull);
      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('Game not found'), findsOneWidget);
    },
  );

  testWidgets(
    'openGame with an unknown or empty id lands on the same screen and can go back',
    (tester) async {
      await start(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => openGame(context, 'no-such-game'),
                  child: const Text('open unknown'),
                ),
                TextButton(
                  onPressed: () => openGame(context, ''),
                  child: const Text('open empty'),
                ),
              ],
            ),
          ),
        ),
      );

      for (final button in ['open unknown', 'open empty']) {
        await tester.tap(find.text(button));
        await tester.pumpAndSettle();
        expect(find.text('Game not found'), findsOneWidget, reason: button);

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Game not found'), findsNothing, reason: button);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a game IGDB gave no release date for shows no year', (
    tester,
  ) async {
    repo.popular = [testGame('g1', status: null, cover: false, year: 0)];
    await start(tester, const GameDetailScreen(gameId: 'g1'));

    expect(tester.takeException(), isNull);
    expect(find.text('Game g1'), findsWidgets);
    expect(find.textContaining('Released'), findsNothing);
  });

  testWidgets('a game with a release date shows its year', (tester) async {
    repo.popular = [testGame('g1', status: null, cover: false, year: 2020)];
    await start(tester, const GameDetailScreen(gameId: 'g1'));

    expect(tester.takeException(), isNull);
    expect(find.text('Released 2020'), findsOneWidget);
  });

  group('"Played on" choices', () {
    // Only the "Played on" chips: the game's own platform badge is a Text too.
    Finder chip(GamePlatform p) => find.descendant(of: find.byType(PlatformChips), matching: find.text(p.label));

    testWidgets(
      'a mobile-only game offers Mobile, not Steam Deck or Emulator',
      (tester) async {
        repo.popular = [
          testGame(
            'g1',
            title: 'Dream League Soccer',
            status: null,
            cover: false,
            platforms: const [GamePlatform.mobile],
          ),
        ];
        await start(tester, const GameDetailScreen(gameId: 'g1'));
        await tester.scrollUntilVisible(
          chip(GamePlatform.mobile),
          300,
          scrollable: find.byType(Scrollable).first,
        );

        expect(tester.takeException(), isNull);
        expect(chip(GamePlatform.mobile), findsOneWidget);
        expect(chip(GamePlatform.steamDeck), findsNothing);
        expect(chip(GamePlatform.emulator), findsNothing);
      },
    );

    testWidgets('a PC and console game offers Steam Deck and Emulator', (
      tester,
    ) async {
      repo.popular = [
        testGame(
          'g1',
          status: null,
          cover: false,
          platforms: const [GamePlatform.pc, GamePlatform.nswitch],
        ),
      ];
      await start(tester, const GameDetailScreen(gameId: 'g1'));
      await tester.scrollUntilVisible(
        chip(GamePlatform.steamDeck),
        300,
        scrollable: find.byType(Scrollable).first,
      );

      expect(chip(GamePlatform.steamDeck), findsOneWidget);
      expect(chip(GamePlatform.emulator), findsOneWidget);
    });
  });

  group('wishlist', () {
    setUp(() {
      // Signed in: the wishlist is a part of the library.
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(testUser('u1')),
        connectivity: FakeConnectivity(),
        apiService: detailsApi,
      );
    });

    Future<void> openGameScreen(WidgetTester tester, String id) async {
      await start(tester, GameDetailScreen(gameId: id));
      await tester.pumpAndSettle();
    }

    Finder add() => find.byTooltip('Add to wishlist');
    Finder remove() => find.byTooltip('Remove from wishlist');

    testWidgets('a game that is not in the library can be bookmarked, at once and with an undo', (
      tester,
    ) async {
      repo.popular = [testGame('g1', status: null, cover: false)];
      await openGameScreen(tester, 'g1');
      expect(add(), findsOneWidget);
      expect(remove(), findsNothing);

      await tester.tap(add());
      await tester.pumpAndSettle();

      expect(stores.library.maybeGame('g1')!.status, GameStatus.wishlist);
      expect(remove(), findsOneWidget); // the bookmark is filled now
      expect(add(), findsNothing);
      expect(find.text('Added Game g1 to your wishlist'), findsOneWidget);
      expect(repo.writes.any((w) => w.startsWith('game:g1:GameStatus.wishlist')), isTrue);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(stores.library.maybeGame('g1')!.status, isNull);
      expect(add(), findsOneWidget);
    });

    testWidgets('a wishlisted game can be taken off the wishlist', (tester) async {
      repo.library = [testGame('g1', status: GameStatus.wishlist, cover: false, hours: 0)];
      await openGameScreen(tester, 'g1');
      expect(remove(), findsOneWidget);

      await tester.tap(remove());
      await tester.pumpAndSettle();

      expect(stores.library.maybeGame('g1')!.status, isNull);
      expect(find.text('Removed Game g1 from your wishlist'), findsOneWidget);
      expect(repo.writes, contains('delete:g1'));
      expect(tester.takeException(), isNull); // the page stays; no "Game not found"
      expect(find.text('Game not found'), findsNothing);
    });

    testWidgets(
      'a game being played keeps both buttons: the bookmark is dimmed and explains, the status stays',
      (tester) async {
        repo.library = [testGame('g1', status: GameStatus.playing, cover: false)];
        await openGameScreen(tester, 'g1');

        expect(add(), findsNothing);
        expect(remove(), findsNothing);
        expect(find.byTooltip('Already in your library'), findsOneWidget);
        expect(find.byTooltip('Add to favorites'), findsOneWidget);

        await tester.tap(find.byTooltip('Already in your library'));
        await tester.pumpAndSettle();

        expect(find.text('Game g1 is already in your library as Playing'), findsOneWidget);
        expect(stores.library.maybeGame('g1')!.status, GameStatus.playing);
        expect(repo.writes.where((w) => w.startsWith('game:g1')), isEmpty);
      },
    );

    testWidgets('a wishlisted game can be a favorite too', (tester) async {
      repo.library = [testGame('g1', status: GameStatus.wishlist, cover: false)];
      await openGameScreen(tester, 'g1');

      expect(find.byTooltip('Add to favorites'), findsOneWidget);
    });

    testWidgets('signed out there is no bookmark', (tester) async {
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(),
        connectivity: FakeConnectivity(),
      );
      repo.popular = [testGame('g1', status: null, cover: false)];
      await openGameScreen(tester, 'g1');

      expect(add(), findsNothing);
    });

    testWidgets('a game that is not in the library has both the bookmark and the heart at the top', (
      tester,
    ) async {
      repo.popular = [testGame('g1', status: null, cover: false)];
      await openGameScreen(tester, 'g1');

      expect(add(), findsOneWidget);
      expect(find.byTooltip('Add to favorites'), findsOneWidget);
      // Both are in the app bar, next to each other and on the same row.
      expect(
        tester.getCenter(add()).dy,
        tester.getCenter(find.byTooltip('Add to favorites')).dy,
      );
      expect(
        tester.getCenter(add()).dx,
        lessThan(tester.getCenter(find.byTooltip('Add to favorites')).dx),
      );
    });

    testWidgets('the status actions no longer repeat "Add to Wishlist"', (
      tester,
    ) async {
      repo.popular = [testGame('g1', status: null, cover: false)];
      await openGameScreen(tester, 'g1');
      await tester.scrollUntilVisible(
        find.text('Start Playing'),
        300,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.text('Start Playing'), findsOneWidget);
      expect(find.text('Add to Wishlist'), findsNothing);
    });

    testWidgets('the heart on a game that is not in the library adds it, as a favorite', (
      tester,
    ) async {
      repo.popular = [testGame('g1', status: null, cover: false)];
      await openGameScreen(tester, 'g1');

      await tester.tap(find.byTooltip('Add to favorites'));
      await tester.pumpAndSettle();

      final game = stores.library.maybeGame('g1')!;
      expect(game.isFavorite, isTrue);
      expect(game.status, GameStatus.playing); // the same default as a rating
      expect(repo.writes.any((w) => w.startsWith('game:g1')), isTrue);
      expect(find.byTooltip('Remove from favorites'), findsOneWidget);
    });

    testWidgets('the heart on a wishlisted game keeps it on the wishlist', (
      tester,
    ) async {
      repo.library = [testGame('g1', status: GameStatus.wishlist, cover: false)];
      await openGameScreen(tester, 'g1');

      await tester.tap(find.byTooltip('Add to favorites'));
      await tester.pumpAndSettle();

      final game = stores.library.maybeGame('g1')!;
      expect(game.isFavorite, isTrue);
      expect(game.status, GameStatus.wishlist);
    });

    testWidgets('there is no limit, unlike favorites', (tester) async {
      repo.popular = [
        for (var i = 0; i < 7; i++) testGame('g$i', status: null, cover: false),
      ];
      await tester.runAsync(stores.initialize);

      for (var i = 0; i < 7; i++) {
        await stores.library.addToLibrary('g$i', GameStatus.wishlist);
      }

      expect(stores.library.count(GameStatus.wishlist), 7);
      expect(stores.library.notice, isNull);
      addTearDown(stores.dispose);
    });
  });

  group('removing a game', () {
    setUp(() {
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(testUser('u1')),
        connectivity: FakeConnectivity(),
        apiService: detailsApi,
      );
    });

    Future<void> tapRemove(WidgetTester tester) async {
      await tester.tap(find.text('Remove from Library'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks first, and says its play sessions go with it', (tester) async {
      // Tall enough to have the button on screen.
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      repo.library = [testGame('g1', title: 'Skyrim', cover: false)];
      repo.logs = [testLog('l1', 'g1'), testLog('l2', 'g1')];
      await start(tester, const GameDetailScreen(gameId: 'g1'));
      await tester.pumpAndSettle();

      await tapRemove(tester);
      expect(find.text('Remove Skyrim?'), findsOneWidget);
      expect(find.textContaining('along with 2 play sessions'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.writes, isNot(contains('delete:g1')));
      expect(stores.library.maybeGame('g1')!.inLibrary, isTrue);

      await tapRemove(tester);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(repo.writes, contains('delete:g1'));
      expect(stores.library.libraryGames, isEmpty);
      expect(find.text('Removed Skyrim from library'), findsOneWidget);
    });
  });
}
