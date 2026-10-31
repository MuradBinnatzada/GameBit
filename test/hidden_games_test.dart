import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/screens/library/library_screen.dart';
import 'package:checkpoint/screens/profile/profile_screen.dart';
import 'package:checkpoint/screens/stats/year_review_screen.dart';
import 'package:checkpoint/sheets/pick_next_sheet.dart';
import 'package:checkpoint/widgets/library_filters.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/library_state.dart';
import 'package:checkpoint/state/library_view_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// Games a member hid from other members: the flag, the Hidden tab of their
/// Library, and the button on a game's screen. (What the server leaves out for
/// other members is in 20261031230000_hidden_games.sql.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Game hidden(String id, String title) => testGame(id, title: title, cover: false).copyWith(isHidden: true);

  group('a game', () {
    test('is not hidden unless it was hidden, and stays so when stored, read and copied', () {
      final game = testGame('g1', cover: false);
      expect(game.isHidden, isFalse);

      final hiddenOne = game.copyWith(isHidden: true);
      expect(hiddenOne.isHidden, isTrue);
      expect(Game.fromJson(hiddenOne.toJson()).isHidden, isTrue);
      expect(Game.fromJson(game.toJson()).isHidden, isFalse);
      // Changing something else, or the backdrop and completion, doesn't show it again.
      expect(hiddenOne.copyWith(rating: 4).isHidden, isTrue);
      expect(hiddenOne.withBackdrop(null).isHidden, isTrue);
      expect(hiddenOne.withCompletedAt(DateTime(2026, 1, 1)).isHidden, isTrue);
    });
  });

  group('the Library view', () {
    final games = [
      testGame('a', title: 'Open', cover: false, status: GameStatus.playing),
      testGame('b', title: 'Secret', cover: false, status: GameStatus.completed).copyWith(isHidden: true),
      testGame('c', title: 'Other', cover: false, status: GameStatus.toPlay),
    ];

    test('has the hidden games only in the Hidden tab, not in All or under their status', () {
      final view = LibraryViewStore();

      expect(view.visible(games, null).map((g) => g.id), unorderedEquals(['a', 'c']));
      expect(view.visible(games, GameStatus.completed), isEmpty); // Secret is completed, and hidden
      expect(view.visible(games, GameStatus.playing).map((g) => g.id), ['a']);
      expect(view.visible(games, null, hiddenOnly: true).map((g) => g.id), ['b']);
      expect(view.count(games, null), 2);
      expect(view.count(games, GameStatus.completed), 0);
      expect(view.count(games, null, hiddenOnly: true), 1);
    });

    test('lets the filters narrow the Hidden tab as the others', () {
      final view = LibraryViewStore()..togglePlatform(GamePlatform.xbox);

      expect(view.visible(games, null, hiddenOnly: true), isEmpty);
    });

    test('has Hidden as the tab after the statuses, and leaving it for another tab', () {
      final view = LibraryViewStore();
      final hiddenTab = GameStatus.values.length + 1;

      view.setTabIndex(hiddenTab);
      expect((view.showingHidden, view.selectedStatus, view.currentTabIndex), (true, null, hiddenTab));

      view.setTabIndex(2);
      expect((view.showingHidden, view.selectedStatus), (false, GameStatus.values[1]));
      expect(view.currentTabIndex, 2);

      view.setTabIndex(hiddenTab);
      view.openTab(null);
      expect((view.showingHidden, view.currentTabIndex), (false, 0));
    });
  });

  group('with the app', () {
    late FakeRepository repo;
    late AppStores stores;

    setUp(() {
      SharedPreferences.setMockInitialValues(onboardingSeenPrefs);
      repo = FakeRepository();
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(testUser('u1')),
        connectivity: FakeConnectivity(),
        apiService: FakeDetailsApi(),
      );
    });

    Future<void> open(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(theme: buildTheme(), home: Scaffold(body: home)),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await tester.pumpAndSettle();
    }

    group('the store', () {
      test('hides a game of the library, shows it again, and saves each', () async {
        repo.library = [testGame('g1', cover: false)];
        await stores.initialize();
        addTearDown(stores.dispose);

        await stores.library.toggleHidden('g1');
        expect(stores.library.gameById('g1').isHidden, isTrue);
        expect(repo.hiddenSent['g1'], isTrue);

        await stores.library.toggleHidden('g1');
        expect(stores.library.gameById('g1').isHidden, isFalse);
        expect(repo.hiddenSent['g1'], isFalse);
      });

      test('has nothing to hide of a game that is not in the library', () async {
        repo.popular = [testGame('p1', status: null, cover: false)];
        await stores.initialize();
        addTearDown(stores.dispose);

        await stores.library.toggleHidden('p1');

        expect(stores.library.maybeGame('p1')!.isHidden, isFalse);
        expect(repo.hiddenSent, isEmpty);
      });
    });

    group('what the app lists, counts and suggests', () {
      setUp(() {
        repo.library = [
          testGame('a', title: 'Open', cover: false, favorite: true).copyWith(rating: 4),
          hidden('b', 'Secret').copyWith(rating: 5, isFavorite: true),
          testGame('w', title: 'Open Wish', cover: false, status: GameStatus.wishlist)
              .copyWith(releaseDate: DateTime.now().add(const Duration(days: 5))),
          testGame('x', title: 'Secret Wish', cover: false, status: GameStatus.wishlist)
              .copyWith(releaseDate: DateTime.now().add(const Duration(days: 6), ), isHidden: true),
        ];
        repo.logs = [testLog('l1', 'a'), testLog('l2', 'b')];
      });

      test('are without the hidden games: the lists, the counts, the activity and the alerts', () async {
        await stores.initialize();
        addTearDown(stores.dispose);
        final library = stores.library;

        expect(library.libraryGames, hasLength(4)); // all of them are still there
        expect(library.listedGames.map((g) => g.id), unorderedEquals(['a', 'w']));
        expect(library.playingNow().map((g) => g.id), ['a']);
        expect(library.count(GameStatus.playing), 1);
        expect(library.count(GameStatus.wishlist), 1);
        // Every fixture game is rated by default; the two hidden ones are the ones left out.
        expect(library.topRated.map((g) => g.id), unorderedEquals(['a', 'w']));
        expect(library.recentActivity().map((l) => l.gameId), ['a']);
        expect(stores.releaseAlerts.alerts.map((a) => a.game.id), ['w']);
      });

      test('still count the hours of a hidden game in the totals', () async {
        await stores.initialize();
        addTearDown(stores.dispose);

        // Out of sight, not out of the member's life: four games of 12.5 h, two hidden.
        expect(stores.library.totalHours, 50);
      });

      testWidgets('the pick-next sheet never suggests a hidden game', (tester) async {
        repo.library = [
          testGame('a', title: 'Open', cover: false),
          hidden('b', 'Secret'),
        ];
        Finder text(String word) => find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').toLowerCase().contains(word),
        );
        await open(tester, const PickNextSheet());

        expect(text('open'), findsWidgets);
        expect(text('secret'), findsNothing);
        // Asking again can only bring up the one game that is listed.
        await tester.tap(find.text('Pick another'));
        await tester.pumpAndSettle();
        expect(text('secret'), findsNothing);
      });

      testWidgets('the profile page lists no hidden favorite and no hidden session', (tester) async {
        Finder text(String word) => find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').toLowerCase().contains(word),
        );
        await open(tester, const ProfileScreen());

        expect(text('open'), findsWidgets);
        expect(text('secret'), findsNothing);
      });

      testWidgets('Year in Review lists and shares no hidden game, though its hours count', (tester) async {
        final year = DateTime.now().year;
        repo.library = [testGame('a', title: 'Open', cover: false), hidden('b', 'Secret')];
        repo.logs = [
          LogEntry(id: 's1', gameId: 'a', timestamp: DateTime(year, 1, 10, 20), hours: 3, platform: GamePlatform.pc),
          LogEntry(id: 's2', gameId: 'b', timestamp: DateTime(year, 1, 11, 20), hours: 5, platform: GamePlatform.pc),
        ];
        Finder text(String word) => find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').toLowerCase().contains(word),
        );
        await open(tester, const YearReviewScreen());

        expect(find.text('8 h'), findsWidgets); // the headline holds both
        expect(text('open'), findsWidgets);
        expect(text('secret'), findsNothing);
      });
    });

    group('the Library screen', () {
      testWidgets('has a Hidden tab with the games hidden, and what it is for', (tester) async {
        repo.library = [testGame('a', title: 'Open', cover: false), hidden('b', 'Secret')];
        await open(tester, const LibraryScreen());

        // All has the open game only; the secret one is under Hidden.
        expect(find.text('OPEN'), findsWidgets);
        expect(find.text('SECRET'), findsNothing);

        await tester.ensureVisible(find.text('Hidden'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hidden'));
        await tester.pumpAndSettle();

        expect(find.text('SECRET'), findsWidgets);
        expect(find.text('OPEN'), findsNothing);
        expect(find.textContaining('Only you can see these games'), findsOneWidget);
      });

      testWidgets('fits a phone at the largest text size, in the grid and the list', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        repo.library = [
          testGame('a', title: 'A game with a rather long title', cover: false, hours: 120),
          testGame('b', title: 'Secret', cover: false, hours: 30).copyWith(isHidden: true),
        ];
        await open(tester, const LibraryScreen());
        tester.view.physicalSize = const Size(360, 800);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.text('Hidden'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hidden'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Only you can see these games'), findsOneWidget);
        expect(tester.takeException(), isNull);

        stores.libraryView.setView(LibraryView.list);
        await tester.pumpAndSettle();
        expect(find.text('Secret'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the filter sheet counts the hidden games among those shown', (tester) async {
        repo.library = [
          testGame('a', title: 'Open', cover: false, platforms: [GamePlatform.pc]),
          hidden('b', 'Secret'),
          testGame('c', title: 'Console', cover: false, platforms: [GamePlatform.ps5], playedOn: GamePlatform.ps5),
        ];
        await open(tester, const LibraryFilterSheet());
        stores.libraryView.togglePlatform(GamePlatform.pc);
        await tester.pumpAndSettle();

        // The open PC game and the hidden one (a PC game too) pass, the console one doesn't.
        expect(find.text('Showing 2 of 3 games'), findsOneWidget);
      });

      testWidgets('says so when nothing is hidden', (tester) async {
        repo.library = [testGame('a', title: 'Open', cover: false)];
        await open(tester, const LibraryScreen());

        await tester.ensureVisible(find.text('Hidden'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hidden'));
        await tester.pumpAndSettle();

        expect(find.text('Nothing hidden'), findsOneWidget);
        expect(find.text('OPEN'), findsNothing);
      });
    });

    group('the game screen', () {
      testWidgets('hides a game of the library from other members, and shows it again', (tester) async {
        repo.library = [testGame('g1', title: 'Skyrim', cover: false)];
        await open(tester, const GameDetailScreen(gameId: 'g1'));

        await tester.tap(find.byTooltip('Hide from other members'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pumpAndSettle();

        expect(stores.library.gameById('g1').isHidden, isTrue);
        expect(repo.hiddenSent['g1'], isTrue);
        expect(find.textContaining('shows only under Hidden'), findsOneWidget);
        expect(find.byTooltip('Hide from other members'), findsNothing);

        await tester.tap(find.byTooltip('Show to other members'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pumpAndSettle();

        expect(stores.library.gameById('g1').isHidden, isFalse);
        expect(find.text('Other members can see this game again.'), findsOneWidget);
      });

      testWidgets('has no button for a game that is not in the library', (tester) async {
        repo.popular = [testGame('p1', title: 'Skyrim', status: null, cover: false)];
        await open(tester, const GameDetailScreen(gameId: 'p1'));

        expect(find.byTooltip('Hide from other members'), findsNothing);
        expect(find.byTooltip('Show to other members'), findsNothing);
      });
    });
  });
}
