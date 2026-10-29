import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/completion_time.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_details.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/services/pending_edits.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/community_times_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

const _mainExtras = CompletionTime(CompletionCategory.mainExtras, 750);
const _completionist = CompletionTime(CompletionCategory.completionist, 3000);

/// [count] members' times in a category, with [hours] as their median.
CommunityTime _times(int hours, int count) => CommunityTime(
  median: Duration(hours: hours),
  count: count,
);

/// Silences what the stores log for the rest of the test.
void _quiet() {
  final print = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {};
  addTearDown(() => debugPrint = print);
}

/// How long members took to finish a game: the member's own time under the
/// status buttons of a completed game, saved like any library edit, and the
/// members' medians in the game's time to beat.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the data', () {
    test('a time reads back from what it saves; anything else is none', () {
      expect(CompletionTime.fromJson(_mainExtras.toJson()), _mainExtras);
      expect(_mainExtras.toJson(), {'category': 'main_extra', 'minutes': 750});
      for (final json in [
        null,
        'main',
        {'category': 'speedrun', 'minutes': 30},
        {'category': 'main', 'minutes': 0},
        {'category': 'main', 'minutes': 'NaN'},
        {'category': 'main'},
      ]) {
        expect(CompletionTime.fromJson(json), isNull, reason: '$json');
      }
    });

    test(
      'a game keeps its time in the saved copy and through status changes',
      () {
        final game = testGame(
          'g1',
          status: GameStatus.completed,
        ).withCompletionTime(_mainExtras);

        expect(Game.fromJson(game.toJson()).completionTime, _mainExtras);
        expect(
          game.copyWith(status: GameStatus.playing).completionTime,
          _mainExtras,
        );
        expect(game.withCompletedAt(null).completionTime, _mainExtras);
        expect(
          game.withBackdrop('https://example.com/a.jpg').completionTime,
          _mainExtras,
        );
        expect(game.withoutUserState().completionTime, isNull);
        expect(game.withCompletionTime(null).completionTime, isNull);
        // A copy saved before there were times reads as none.
        expect(Game.fromJson(testGame('g2').toJson()).completionTime, isNull);
      },
    );

    test('a category is shown from $minCommunityTimes times on', () {
      final times = CommunityTimes({
        CompletionCategory.mainStory: _times(20, minCommunityTimes - 1),
        CompletionCategory.completionist: _times(80, minCommunityTimes),
      });

      expect(times.shown(CompletionCategory.mainStory), isNull);
      expect(times.shown(CompletionCategory.mainExtras), isNull);
      expect(
        times.shown(CompletionCategory.completionist)!.median,
        const Duration(hours: 80),
      );
      expect(times.hasShown, isTrue);
      expect(const CommunityTimes().hasShown, isFalse);
    });

    test(
      'queued times survive being saved; a queued delete stays a delete',
      () {
        final edits = PendingEdits()
          ..putCompletionTime('a', _mainExtras)
          ..putCompletionTime('b', null);
        final json = jsonDecode(
          jsonEncode(edits.toJson(PendingScope.library)),
        ) as Map<String, dynamic>;
        json['completionTimes']['c'] = {'category': 'speedrun', 'minutes': 5};

        final read = PendingEdits.fromJson(json);

        expect(read.completionTimes, {'a': _mainExtras, 'b': null});
        expect(read.count, 2);
        expect(read.isEmptyIn(PendingScope.library), isFalse);
        expect(
          edits.toJson(PendingScope.follows).containsKey('completionTimes'),
          isFalse,
        );
        // Removing the game removes its time on the server too.
        read.markRemoved('a');
        expect(read.completionTimes, {'b': null});
      },
    );
  });

  group('your own time', () {
    late FakeRepository repo;
    late FakeConnectivity network;
    late LocalCache cache;
    late AuthStore auth;
    late ProfileStore profile;
    late LibraryStore library;
    late List<String> savedFor;

    LibraryStore newLibrary() => LibraryStore(
      repository: repo,
      auth: auth,
      profile: profile,
      cache: cache,
      connectivity: network,
      onCompletionTimeSaved: savedFor.add,
    );

    setUp(() async {
      _quiet();
      repo = FakeRepository()
        ..library = [
          testGame('a', status: GameStatus.completed),
          testGame('b'),
        ];
      network = FakeConnectivity();
      cache = LocalCache();
      auth = AuthStore(FakeAuthService(testUser('u1')));
      await auth.initialize();
      profile = ProfileStore(repository: repo, auth: auth, cache: cache);
      savedFor = [];
      library = newLibrary();
      await library.initialize();
      await pumpEventQueue();
    });

    tearDown(() {
      library.dispose();
      profile.dispose();
      auth.dispose();
    });

    Game game(String id) => library.libraryGames.firstWhere((g) => g.id == id);

    test('is shown at once, sent, and can be changed and removed', () async {
      await library.setCompletionTime('a', _mainExtras);
      expect(game('a').completionTime, _mainExtras);

      await library.setCompletionTime('a', _completionist);
      await library.setCompletionTime(
        'a',
        _completionist,
      ); // no change: not sent
      await library.setCompletionTime('a', null);

      expect(game('a').completionTime, isNull);
      expect(repo.writes, [
        'time:a:main_extra:750',
        'time:a:completionist:3000',
        'time-delete:a',
      ]);
      // Each one asks for the members' times again.
      expect(savedFor, ['a', 'a', 'a']);
      expect(library.pendingCount, 0);
    });

    test('stays when the game moves away from Completed', () async {
      await library.setCompletionTime('a', _mainExtras);
      await library.setStatus('a', GameStatus.playing);

      expect(game('a').completionTime, _mainExtras);
      expect(repo.writes, isNot(contains('time-delete:a')));
    });

    test('is only for a game in the library', () async {
      repo.popular = [testGame('p', status: null)];
      await library.refresh();

      await library.setCompletionTime('p', _mainExtras);

      expect(library.gameById('p').completionTime, isNull);
      expect(repo.writes, isEmpty);
    });

    test(
      'waits for the game\'s own save when that is still on its way',
      () async {
        repo.userGameGate = Completer<void>();
        final marking = library.setStatus('b', GameStatus.completed);
        final timing = library.setCompletionTime('b', _mainExtras);
        await pumpEventQueue();
        expect(repo.writes, isEmpty);

        repo.userGameGate!.complete();
        await Future.wait([marking, timing]);

        expect(repo.writes, [
          'game:b:GameStatus.completed:4.5',
          'time:b:main_extra:750',
        ]);
      },
    );

    test('made offline, it is kept on the device and sent when the connection is back', () async {
      repo.offline = true;
      await library.setCompletionTime('a', _mainExtras);

      expect(game('a').completionTime, _mainExtras);
      expect(library.pendingCount, 1);
      expect(library.isOffline, isTrue);
      expect(library.notice, queuedNotice);

      // The app closed and opened again, still offline.
      library.dispose();
      library = newLibrary();
      await library.initialize();
      expect(game('a').completionTime, _mainExtras);
      expect(library.pendingCount, 1);
      expect(repo.writes, isEmpty);

      repo.offline = false;
      network.controller.add(true);
      await pumpEventQueue();

      expect(repo.writes, ['time:a:main_extra:750']);
      expect(library.pendingCount, 0);
      expect(savedFor, ['a']);
    });

    test('for a game whose save is queued, it is queued behind it', () async {
      repo.offline = true;
      await library.setStatus('b', GameStatus.completed);
      repo.offline = false; // back, but nothing has been sent yet

      await library.setCompletionTime('b', _mainExtras);
      expect(repo.writes, isEmpty);
      expect(library.pendingCount, 2);

      await library.flushPending();

      expect(repo.writes, [
        'game:b:GameStatus.completed:4.5',
        'time:b:main_extra:750',
      ]);
      expect(library.pendingCount, 0);
    });

    test('a refresh while a time is queued does not undo it', () async {
      repo.offline = true;
      await library.setCompletionTime('a', _mainExtras);
      // Reads work again, writes not yet.
      repo.offline = false;
      repo.writesDown = true;

      await library.refresh();
      await pumpEventQueue();

      expect(game('a').completionTime, _mainExtras);
      expect(library.pendingCount, 1);
    });

    test(
      'a queued edit of the game neither sends nor brings back the time',
      () async {
        repo.library = [
          testGame(
            'a',
            status: GameStatus.completed,
          ).withCompletionTime(_mainExtras),
        ];
        await library.refresh();
        repo.offline = true;
        await library.setRating('a', 3); // queued with the time it has now
        await library.setCompletionTime('a', null);
        library.dispose();

        library = newLibrary(); // the saved copy still has the time
        await library.initialize();
        expect(game('a').completionTime, isNull);
        expect(game('a').rating, 3);

        repo.offline = false;
        await library.flushPending();
        expect(repo.writes, [
          'game:a:GameStatus.completed:3.0',
          'time-delete:a',
        ]);
      },
    );

    test('one the server refuses is put back as the server has it', () async {
      repo.library = [
        testGame(
          'a',
          status: GameStatus.completed,
        ).withCompletionTime(_mainExtras),
      ];
      await library.refresh();
      repo.rejectWrites = true;

      await library.setCompletionTime('a', _completionist);
      // The library is read again after a short pause.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(library.notice, 'Could not save your completion time.');
      expect(game('a').completionTime, _mainExtras);
      expect(library.pendingCount, 0);
    });

    test('a queued one goes when its game is removed: the server removes it with the game', () async {
      repo.offline = true;
      await library.setCompletionTime('a', _mainExtras);
      repo.offline = false;

      await library.removeFromLibrary('a');
      await library.flushPending();

      expect(library.pendingCount, 0);
      expect(repo.writes, ['delete:a']);
    });
  });

  group('the members\' times', () {
    late FakeRepository repo;
    late AuthStore auth;
    late CommunityTimesStore store;

    Future<void> start({bool signedIn = true}) async {
      repo = FakeRepository();
      auth = AuthStore(FakeAuthService(signedIn ? testUser('u1') : null));
      await auth.initialize();
      store = CommunityTimesStore(repository: repo, auth: auth)..initialize();
      addTearDown(() {
        store.dispose();
        auth.dispose();
      });
    }

    test('are read per game, and asked again after a change that came in meanwhile', () async {
      await start();
      repo.communityTimes['g1'] = CommunityTimes({
        CompletionCategory.mainStory: _times(24, 37),
      });
      repo.communityGate = Completer<void>();

      final first = store.load('g1');
      expect(store.viewOf('g1').status, LoadStatus.loading);
      unawaited(store.load('g1')); // the member's own time reached the server
      expect(repo.communityReads, ['g1']);

      repo.communityGate!.complete();
      await first;
      await pumpEventQueue();

      expect(repo.communityReads, ['g1', 'g1']);
      final view = store.viewOf('g1');
      expect(view.status, LoadStatus.ready);
      expect(view.times.shown(CompletionCategory.mainStory)!.count, 37);
    });

    test('a failed read keeps what was shown', () async {
      _quiet();
      await start();
      repo.communityTimes['g1'] = CommunityTimes({
        CompletionCategory.mainStory: _times(24, 37),
      });
      await store.load('g1');

      repo.failCommunityReads = true;
      await store.load('g1');
      expect(store.viewOf('g1').times.hasShown, isTrue);

      await store.load('g2');
      expect(store.viewOf('g2').status, LoadStatus.failed);
    });

    test('signed out, nothing is asked', () async {
      await start(signedIn: false);

      await store.load('g1');

      expect(repo.communityReads, isEmpty);
      expect(store.viewOf('g1').status, LoadStatus.idle);
    });
  });

  group('on the game\'s screen', () {
    late FakeRepository repo;
    late FakeDetailsApi detailsApi;
    late AppStores stores;

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> open(
      WidgetTester tester,
      Game game, {
      GameDetails? details,
    }) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      repo.library = [game];
      detailsApi.answer = (id) => details;
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(testUser('u1')),
        connectivity: FakeConnectivity(),
        apiService: detailsApi,
      );
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: GameDetailScreen(gameId: game.id),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await tester.pumpAndSettle();
      await settle(tester);
    }

    setUp(() {
      repo = FakeRepository();
      detailsApi = FakeDetailsApi();
    });

    Game hades({
      GameStatus status = GameStatus.playing,
      CompletionTime? time,
    }) => testGame(
      'g1',
      title: 'Hades',
      status: status,
      igdbId: 472,
      cover: false,
    ).withCompletionTime(time);

    Finder field(String label) => find.widgetWithText(TextField, label);
    VoidCallback? saveButton(WidgetTester tester) => tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
        .onPressed;

    testWidgets(
      'marking a game completed asks how long it took, right under the status buttons',
      (tester) async {
        await open(tester, hades());
        expect(find.text('How long did it take?'), findsNothing);

        await tester.tap(find.text('Mark as Completed'));
        await settle(tester);

        expect(find.text('How long did it take?'), findsOneWidget);
        final question = tester
            .getTopLeft(find.text('How long did it take?'))
            .dy;
        expect(
          question,
          greaterThan(tester.getTopLeft(find.text('Mark as Completed')).dy),
        );
        expect(
          question,
          lessThan(tester.getTopLeft(find.text('Remove from Library')).dy),
        );
        expect(saveButton(tester), isNull);

        await tester.tap(find.text('Main + Extras'));
        await tester.enterText(field('Hours'), '12.5');
        await tester.pump();
        await tester.tap(find.text('Save'));
        await settle(tester);

        expect(repo.writes, contains('time:g1:main_extra:750'));
        expect(find.text('How long did it take?'), findsNothing);
        expect(find.text('12 h 30 min · Main + Extras'), findsOneWidget);
      },
    );

    testWidgets(
      'hours and minutes add up, and a time that isn\'t one says why',
      (tester) async {
        await open(tester, hades(status: GameStatus.completed));
        await tester.tap(find.text('Add how long it took'));
        await tester.pumpAndSettle();

        await tester.enterText(field('Hours'), '1');
        await tester.enterText(field('Minutes'), '75');
        await tester.pump();
        expect(find.text('Minutes go from 0 to 59.'), findsOneWidget);
        expect(saveButton(tester), isNull);

        await tester.enterText(field('Minutes'), '5');
        await tester.pump();
        expect(
          find.text('Pick Main Story, Main + Extras or Completionist.'),
          findsOneWidget,
        );
        expect(saveButton(tester), isNull);

        await tester.enterText(field('Hours'), '1.2.3');
        await tester.pump();
        expect(
          find.text('Enter the hours as a number, like 12.5.'),
          findsOneWidget,
        );

        await tester.enterText(field('Hours'), '1');
        await tester.tap(find.text('Main Story'));
        await tester.pump();
        await tester.tap(find.text('Save'));
        await settle(tester);

        expect(repo.writes, contains('time:g1:main:65'));
        expect(find.text('1 h 5 min · Main Story'), findsOneWidget);
      },
    );

    testWidgets('it is optional: skipped, it is one line to tap later', (
      tester,
    ) async {
      await open(tester, hades());
      await tester.tap(find.text('Mark as Completed'));
      await settle(tester);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(find.text('How long did it take?'), findsNothing);
      expect(find.text('Add how long it took'), findsOneWidget);
      expect(repo.writes, isNot(contains(startsWith('time'))));
    });

    testWidgets('a saved time is edited or removed from the same place', (
      tester,
    ) async {
      await open(
        tester,
        hades(status: GameStatus.completed, time: _mainExtras),
      );
      expect(find.text('12 h 30 min · Main + Extras'), findsOneWidget);

      await tester.tap(find.text('12 h 30 min · Main + Extras'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field('Hours')).controller!.text, '12');
      expect(tester.widget<TextField>(field('Minutes')).controller!.text, '30');
      expect(saveButton(tester), isNull); // nothing changed yet

      await tester.enterText(field('Minutes'), '45');
      await tester.tap(find.text('Completionist'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);
      expect(repo.writes, contains('time:g1:completionist:765'));
      expect(find.text('12 h 45 min · Completionist'), findsOneWidget);

      await tester.tap(find.text('12 h 45 min · Completionist'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await settle(tester);

      expect(repo.writes, contains('time-delete:g1'));
      expect(find.text('Add how long it took'), findsOneWidget);
    });

    testWidgets('moved away from Completed, the time is hidden but kept', (
      tester,
    ) async {
      await open(
        tester,
        hades(status: GameStatus.completed, time: _mainExtras),
      );

      await tester.tap(find.text('Move to To Play'));
      await settle(tester);
      expect(find.text('12 h 30 min · Main + Extras'), findsNothing);
      expect(find.text('Add how long it took'), findsNothing);
      expect(stores.library.gameById('g1').completionTime, _mainExtras);

      await tester.tap(find.text('Mark as Completed'));
      await settle(tester);
      // Back with the time it had, not asking again.
      expect(find.text('12 h 30 min · Main + Extras'), findsOneWidget);
      expect(find.text('How long did it take?'), findsNothing);
      expect(repo.writes, isNot(contains('time-delete:g1')));
    });

    testWidgets(
      'the time to beat is Gamebit\'s where $minCommunityTimes members reported one, and IGDB\'s are not shown',
      (tester) async {
        repo.communityTimes['g1'] = CommunityTimes({
          CompletionCategory.mainStory: _times(24, 37),
          CompletionCategory.mainExtras: _times(40, minCommunityTimes - 1),
        });
        await open(tester, hades(), details: testDetails(igdbId: 472));

        expect(find.text('Time to beat'), findsOneWidget);
        expect(find.text('24 h'), findsOneWidget);
        expect(find.text('37 Gamebit players'), findsOneWidget);
        expect(find.text('40 h'), findsNothing); // too few of ours
        // None of IGDB's: the main story, main + extras and completionist runs.
        for (final igdb in ['25 h', '50 h', '150 h']) {
          expect(find.text(igdb), findsNothing, reason: igdb);
        }
        expect(find.text('–'), findsNWidgets(2));
        expect(find.text('IGDB'), findsNothing);
        expect(find.textContaining('on IGDB'), findsNothing);
        expect(
          find.text(
            'Gamebit players: the median of the times reported here.',
          ),
          findsOneWidget,
        );
        expect(find.text('View on HowLongToBeat'), findsOneWidget);
      },
    );

    testWidgets('Gamebit\'s times show without IGDB\'s', (tester) async {
      repo.communityTimes['g1'] = CommunityTimes({
        for (final c in CompletionCategory.values)
          c: _times(10, minCommunityTimes),
      });
      await open(tester, hades()); // IGDB can't be reached

      expect(find.text('Time to beat'), findsOneWidget);
      expect(find.text('10 h'), findsNWidgets(3));
      expect(
        find.text('$minCommunityTimes Gamebit players'),
        findsNWidgets(3),
      );
      expect(find.text('IGDB'), findsNothing);
      expect(find.textContaining('on IGDB'), findsNothing);
    });

    testWidgets('saving your time reads the members\' times again', (
      tester,
    ) async {
      await open(tester, hades(status: GameStatus.completed));
      expect(repo.communityReads, ['g1']);

      await tester.tap(find.text('Add how long it took'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Main Story'));
      await tester.enterText(field('Hours'), '20');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settle(tester);

      expect(repo.communityReads, ['g1', 'g1']);
    });
  });
}
