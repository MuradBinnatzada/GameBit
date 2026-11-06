import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/trophy.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/widgets/library_controls.dart';
import 'package:checkpoint/widgets/status_pill.dart';

import 'support/fakes.dart';

/// Silences what the stores log for the rest of the test.
void _quiet() {
  final print = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {};
  addTearDown(() => debugPrint = print);
}

/// A game the member got everything out of: its Platinum trophy on a
/// PlayStation, every achievement on PC or Xbox, 100% anywhere else.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the data', () {
    test('is named by where the game is played', () {
      for (final p in [
        GamePlatform.ps5,
        GamePlatform.ps4,
        GamePlatform.ps3,
        GamePlatform.vita,
      ]) {
        expect(
          PerfectMark.forPlatform(p),
          PerfectMark.platinum,
          reason: p.label,
        );
      }
      for (final p in [
        GamePlatform.pc,
        GamePlatform.steamDeck,
        GamePlatform.xboxSeries,
        GamePlatform.xbox360,
      ]) {
        expect(
          PerfectMark.forPlatform(p),
          PerfectMark.achievements,
          reason: p.label,
        );
      }
      // No trophies or achievements there.
      for (final p in [
        GamePlatform.ps2,
        GamePlatform.psp,
        GamePlatform.nswitch,
        GamePlatform.xboxOriginal,
        GamePlatform.emulator,
        null,
      ]) {
        expect(
          PerfectMark.forPlatform(p),
          PerfectMark.complete,
          reason: p?.label,
        );
      }
      expect(
        testGame('a', playedOn: GamePlatform.ps5).perfectMark.label,
        'Platinum',
      );
    });

    test('counts only for a game in the library, not one wished for', () {
      final perfect = testGame('a').copyWith(perfected: true);
      expect(perfect.canBePerfected, isTrue);
      expect(perfect.isPerfected, isTrue);

      final wished = testGame(
        'b',
        status: GameStatus.wishlist,
      ).copyWith(perfected: true);
      expect(wished.canBePerfected, isFalse);
      expect(wished.isPerfected, isFalse);
      expect(testGame('c', status: null).canBePerfected, isFalse);
    });

    test('the flag is kept in the saved copy and by the other copies', () {
      final perfect = testGame('a').copyWith(perfected: true);

      expect(Game.fromJson(perfect.toJson()).perfected, isTrue);
      expect(perfect.copyWith(status: GameStatus.dropped).perfected, isTrue);
      expect(perfect.withCompletedAt(null).perfected, isTrue);
      expect(perfect.withBackdrop(null).perfected, isTrue);
      expect(perfect.withCompletionTime(null).perfected, isTrue);
      expect(perfect.withoutUserState().perfected, isFalse);
      // A copy saved before there was a flag reads as not perfected.
      final old = testGame('b').toJson()..remove('perfected');
      expect(Game.fromJson(old).perfected, isFalse);
    });
  });

  group('in the library', () {
    late FakeRepository repo;
    late LocalCache cache;
    late AuthStore auth;
    late ProfileStore profile;
    late LibraryStore library;

    setUp(() async {
      _quiet();
      repo = FakeRepository()
        ..library = [
          testGame('a', status: GameStatus.completed),
          testGame('w', status: GameStatus.wishlist),
        ];
      cache = LocalCache();
      auth = AuthStore(FakeAuthService(testUser('u1')));
      await auth.initialize();
      profile = ProfileStore(repository: repo, auth: auth, cache: cache);
      library = LibraryStore(
        repository: repo,
        auth: auth,
        profile: profile,
        cache: cache,
        connectivity: FakeConnectivity(),
      );
      await library.initialize();
      await pumpEventQueue();
    });

    tearDown(() {
      library.dispose();
      profile.dispose();
      auth.dispose();
    });

    Game game(String id) => library.libraryGames.firstWhere((g) => g.id == id);

    test('is saved, and kept when the status changes', () async {
      await library.setPerfected('a', true);
      expect(game('a').perfected, isTrue);
      expect(repo.perfectedSent['a'], isTrue);

      await library.setStatus('a', GameStatus.playing);
      expect(game('a').perfected, isTrue);
      expect(repo.perfectedSent['a'], isTrue);

      await library.setPerfected('a', false);
      expect(game('a').perfected, isFalse);
      expect(repo.perfectedSent['a'], isFalse);
    });

    test('is not marked on a wishlisted game', () async {
      await library.setPerfected('w', true);
      expect(game('w').perfected, isFalse);
      expect(repo.perfectedSent.containsKey('w'), isFalse);
    });
  });

  group('on screen', () {
    late FakeRepository repo;
    late AppStores stores;

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> open(WidgetTester tester, Game game, Widget home) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      repo.library = [game];
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(testUser('u1')),
        connectivity: FakeConnectivity(),
        apiService: FakeDetailsApi(),
      );
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
      await tester.pumpAndSettle();
      await settle(tester);
    }

    setUp(() => repo = FakeRepository());

    Game hades({GameStatus status = GameStatus.completed, GamePlatform? on}) =>
        testGame(
          'g1',
          title: 'Hades',
          status: status,
          playedOn: on,
          cover: false,
        );

    Finder pill(PerfectMark mark) =>
        find.byWidgetPredicate((w) => w is PerfectPill && w.mark == mark);

    testWidgets('a PS5 game is marked with its Platinum trophy', (
      tester,
    ) async {
      await open(
        tester,
        hades(on: GamePlatform.ps5),
        const GameDetailScreen(gameId: 'g1'),
      );
      expect(pill(PerfectMark.platinum), findsNothing);

      await tester.ensureVisible(find.text('Platinum trophy'));
      await tester.tap(find.text('Platinum trophy'));
      await settle(tester);

      expect(repo.perfectedSent['g1'], isTrue);
      expect(pill(PerfectMark.platinum), findsOneWidget);
      expect(find.text('Platinum'), findsOneWidget);
      expect(find.text('Platinum trophy earned'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(repo.perfectedSent['g1'], isFalse);
      expect(pill(PerfectMark.platinum), findsNothing);
    });

    testWidgets('the switch is named by where the game is played', (
      tester,
    ) async {
      await open(
        tester,
        hades(on: GamePlatform.pc),
        const GameDetailScreen(gameId: 'g1'),
      );
      expect(find.text('All achievements'), findsOneWidget);
      expect(find.text('Platinum trophy'), findsNothing);

      // Played on a Switch instead: no achievements there.
      await tester.runAsync(
        () => stores.library.setPlayedOn('g1', GamePlatform.nswitch),
      );
      await settle(tester);
      expect(find.text('100% complete'), findsOneWidget);
      expect(find.text('All achievements'), findsNothing);
    });

    testWidgets('a game with PlayStation trophies has no switch: the trophies say it', (tester) async {
      await open(
        tester,
        hades(on: GamePlatform.ps5).copyWith(trophiesEarned: 12, trophiesTotal: 40),
        const GameDetailScreen(gameId: 'g1'),
      );
      expect(find.text('Platinum trophy'), findsNothing);
      expect(find.text('12 of 40'), findsOneWidget);
    });

    testWidgets('a game with no trophies read still has the switch: the member says so themselves', (tester) async {
      await open(
        tester,
        hades(on: GamePlatform.ps5),
        const GameDetailScreen(gameId: 'g1'),
      );
      expect(find.text('Platinum trophy'), findsOneWidget);
      expect(find.text('Trophies'), findsNothing);
    });

    testWidgets('the trophy card opens the list of the game', (tester) async {
      repo.gameTrophies[('u1', 'g1')] = const [
        Trophy(id: 1, grade: TrophyGrade.gold, name: 'Escape', detail: 'Leave the House', earned: true),
      ];
      await open(
        tester,
        hades(on: GamePlatform.ps5).copyWith(trophiesEarned: 1, trophiesTotal: 1),
        const GameDetailScreen(gameId: 'g1'),
      );
      await tester.ensureVisible(find.text('Trophies'));
      await tester.tap(find.text('Trophies'));
      await settle(tester);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Escape'), findsOneWidget);
      expect(find.text('Leave the House'), findsOneWidget);
    });

    testWidgets('a wishlisted game has no switch', (tester) async {
      await open(
        tester,
        hades(status: GameStatus.wishlist, on: GamePlatform.ps5),
        const GameDetailScreen(gameId: 'g1'),
      );
      expect(find.text('Platinum trophy'), findsNothing);
    });

    testWidgets('the library tiles say so, in the grid and the list', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final game = hades(on: GamePlatform.ps5).copyWith(perfected: true);
      await open(
        tester,
        game,
        Scaffold(
          body: Column(
            children: [
              Expanded(child: LibraryPosterGrid(games: [game])),
              Expanded(child: LibraryGameList(games: [game])),
            ],
          ),
        ),
      );

      expect(find.byIcon(PerfectMark.platinum.icon), findsNWidgets(2));
      expect(
        find.bySemanticsLabel(RegExp('Platinum trophy')),
        findsNWidgets(2),
      );
      semantics.dispose();
    });
  });
}
