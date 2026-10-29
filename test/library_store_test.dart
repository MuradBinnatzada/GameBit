import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_details.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/profile_store.dart';

import 'support/fakes.dart';

void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late LocalCache cache;
  late AuthStore auth;
  late ProfileStore profile;
  late LibraryStore library;

  setUp(() {
    // The stores log every failure they handle; these tests cause plenty.
    debugPrint = (String? message, {int? wrapWidth}) {};
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    authService = FakeAuthService(testUser('u1'));
    cache = LocalCache();
    auth = AuthStore(authService)..initialize();
    profile = ProfileStore(repository: repo, auth: auth, cache: cache);
    library = LibraryStore(
      repository: repo,
      auth: auth,
      profile: profile,
      cache: cache,
    );
  });

  tearDown(() {
    debugPrint = debugPrintThrottled;
    library.dispose();
    profile.dispose();
    auth.dispose();
  });

  List<String> ids(List<Game> games) => [for (final g in games) g.id];

  test('shows the saved library while the server answers, then the fresh one', () async {
    await cache.writeLibrary('u1', [testGame('old')]);
    repo.library = [testGame('new')];
    repo.gate = Completer<void>();

    final loading = library.initialize();
    await pumpEventQueue();

    // The server hasn't answered, but the saved copy is already on screen: no
    // spinner, and a refresh running quietly behind it.
    expect(ids(library.libraryGames), ['old']);
    expect(library.isLoading, isFalse);
    expect(library.isRefreshing, isTrue);
    expect(library.isOffline, isFalse);

    repo.gate!.complete();
    await loading;

    expect(ids(library.libraryGames), ['new']);
    expect(library.isRefreshing, isFalse);
    expect(library.isOffline, isFalse);
    await pumpEventQueue();
    expect(ids((await cache.readLibrary('u1'))!.value), ['new']);
  });

  test('with nothing saved, the first load shows a spinner and then saves the library', () async {
    repo.library = [testGame('a'), testGame('b')];
    repo.logs = [testLog('l1', 'a')];
    repo.gate = Completer<void>();

    final loading = library.initialize();
    await pumpEventQueue();
    expect(library.isLoading, isTrue);

    repo.gate!.complete();
    await loading;
    await pumpEventQueue();

    expect(library.isLoading, isFalse);
    expect(ids(library.libraryGames), ['a', 'b']);
    expect(ids((await cache.readLibrary('u1'))!.value), ['a', 'b']);
    expect((await cache.readLogs('u1'))!.value.single.id, 'l1');
  });

  test('keeps the saved library, and says so, when the server cannot be reached', () async {
    await cache.writeLibrary('u1', [testGame('old')]);
    await cache.writeLogs('u1', [testLog('l1', 'old')]);
    repo.offline = true;

    await library.initialize();

    expect(ids(library.libraryGames), ['old']);
    expect(library.logsFor('old'), hasLength(1));
    expect(library.isOffline, isTrue);
    expect(library.loadError, isNull);
    expect(library.isLoading, isFalse);
    expect(library.lastSyncedAt, isNotNull);
  });

  test('a second auth event during startup does not lose the saved library', () async {
    await cache.writeLibrary('u1', [testGame('old')]);
    repo.offline = true;

    final loading = library.initialize();
    authService.emit(testUser('u1')); // e.g. Supabase's own "signed in" event
    await loading;
    await pumpEventQueue();

    expect(ids(library.libraryGames), ['old']);
    expect(library.isOffline, isTrue);
    expect(library.loadError, isNull);
  });

  test('a failed fetch leaves the saved copy untouched', () async {
    await cache.writeLibrary('u1', [testGame('old')]);
    repo.offline = true;

    await library.initialize();
    await pumpEventQueue();

    expect(ids((await cache.readLibrary('u1'))!.value), ['old']);
  });

  test('with nothing saved and no server, the load fails with an error', () async {
    repo.offline = true;

    await library.initialize();

    expect(library.loadError, isNotNull);
    expect(library.isOffline, isFalse);
    expect(library.isLoading, isFalse);
    expect(library.libraryGames, isEmpty);
  });

  test('recovers when the server comes back', () async {
    await cache.writeLibrary('u1', [testGame('old')]);
    repo.offline = true;
    await library.initialize();
    expect(library.isOffline, isTrue);

    repo.offline = false;
    repo.library = [testGame('new')];
    await library.refresh();

    expect(library.isOffline, isFalse);
    expect(ids(library.libraryGames), ['new']);
  });

  test('another account never sees the first account\'s saved library', () async {
    await cache.writeLibrary('u1', [testGame('mine')]);
    authService.emit(testUser('u2'));
    await pumpEventQueue();
    repo.offline = true;

    await library.initialize();

    expect(library.libraryGames, isEmpty);
    expect(library.loadError, isNotNull);
  });

  test('signing out empties the library and deletes the saved copy', () async {
    repo.library = [testGame('a')];
    await library.initialize();
    await pumpEventQueue();
    expect(await cache.readLibrary('u1'), isNotNull);

    authService.emit(null);
    await pumpEventQueue();

    expect(library.libraryGames, isEmpty);
    expect(await cache.readLibrary('u1'), isNull);
    expect(await cache.readLogs('u1'), isNull);
  });

  test('a signed-out visitor still gets the saved Home carousels offline', () async {
    authService.emit(null);
    await pumpEventQueue();
    await cache.writePopular([testGame('p1', status: null)]);
    repo.offline = true;

    await library.initialize();

    expect(ids(library.recentlyAdded), ['p1']);
    expect(library.loadError, isNull);
  });

  test('removing a game removes it from the saved copy too', () async {
    repo.library = [testGame('a'), testGame('b')];
    await library.initialize();
    await pumpEventQueue();

    await library.removeFromLibrary('a');
    await pumpEventQueue();

    expect(ids(library.libraryGames), ['b']);
    expect(ids((await cache.readLibrary('u1'))!.value), ['b']);
  });

  test('removing a game takes its play sessions off screen too', () async {
    repo.library = [testGame('a'), testGame('b')];
    repo.logs = [testLog('l1', 'a'), testLog('l2', 'b')];
    await library.initialize();
    await pumpEventQueue();

    await library.removeFromLibrary('a');

    // The server deletes them with the game, and Realtime doesn't say so: left
    // on screen, Home would look up a game that is no longer there.
    expect(library.logsFor('a'), isEmpty);
    expect([for (final l in library.recentActivity()) l.gameId], ['b']);
  });

  test('an edit made while the server is out of reach is kept and shown', () async {
    repo.library = [testGame('a')];
    await library.initialize();
    await pumpEventQueue();
    repo.offline = true;

    await library.setRating('a', 3);

    expect(library.notice, contains('sync when you'));
    expect(library.pendingCount, 1);
    expect(library.loadError, isNull);
    expect(library.libraryGames.single.rating, 3);
  });

  group('setBackdrop', () {
    const art = 'https://images.igdb.com/igdb/image/upload/t_1080p/ar5l8.jpg';

    test('shows and saves the chosen backdrop, then the default again', () async {
      repo.library = [testGame('a')];
      await library.initialize();
      await pumpEventQueue();

      await library.setBackdrop('a', art);
      expect(library.libraryGames.single.customBackdropUrl, art);
      expect(repo.backdrops['a'], art);

      await library.setBackdrop('a', null);
      expect(library.libraryGames.single.customBackdropUrl, isNull);
      expect(repo.backdrops.containsKey('a'), isTrue);
      expect(repo.backdrops['a'], isNull);
    });

    test('is kept on later edits of the game', () async {
      repo.library = [testGame('a')];
      await library.initialize();
      await pumpEventQueue();

      await library.setBackdrop('a', art);
      await library.setRating('a', 2);

      expect(repo.backdrops['a'], art);
    });

    test('does nothing for a game outside the library', () async {
      repo.library = [testGame('a')];
      repo.popular = [testGame('p', status: null)];
      await library.initialize();
      await pumpEventQueue();
      final writes = repo.writes.length;

      await library.setBackdrop('p', art);

      expect(repo.writes, hasLength(writes));
      expect(library.gameById('p').customBackdropUrl, isNull);
    });
  });

  group('applyDetails', () {
    test('puts the exact platforms and genres on the game, in the library and the combined list', () async {
      repo.library = [testGame('a', platforms: [GamePlatform.pc], status: GameStatus.playing)];
      await library.initialize();
      await pumpEventQueue();
      var notified = 0;
      library.addListener(() => notified++);

      library.applyDetails(
        'a',
        testDetails(platforms: [GamePlatform.pc, GamePlatform.ps3, GamePlatform.xbox360]),
      );

      final game = library.gameById('a');
      expect(game.platforms, [GamePlatform.pc, GamePlatform.ps3, GamePlatform.xbox360]);
      expect(game.genres, ['Role-playing (RPG)', 'Adventure']);
      expect(library.libraryGames.single.platforms, game.platforms);
      expect(game.playedOnOptions, [
        GamePlatform.pc,
        GamePlatform.steamDeck,
        GamePlatform.ps3,
        GamePlatform.xbox360,
        GamePlatform.emulator,
      ]);
      expect(notified, 1);
    });

    test('keeps what the user set on the game', () async {
      repo.library = [
        testGame('a', platforms: [GamePlatform.pc], hours: 33, favorite: true, playedOn: GamePlatform.pc),
      ];
      await library.initialize();
      await pumpEventQueue();

      library.applyDetails('a', testDetails());

      final game = library.gameById('a');
      expect(game.hoursPlayed, 33);
      expect(game.isFavorite, isTrue);
      expect(game.playedOn, GamePlatform.pc);
      expect(game.status, GameStatus.playing);
    });

    test('changes nothing when IGDB had no platforms or genres, or they are the same', () async {
      repo.library = [testGame('a', platforms: [GamePlatform.pc], status: GameStatus.playing)];
      await library.initialize();
      await pumpEventQueue();
      var notified = 0;
      library.addListener(() => notified++);

      library.applyDetails('a', const GameDetails(igdbId: 7));
      library.applyDetails(
        'a',
        GameDetails(igdbId: 7, platforms: [GamePlatform.pc], genres: library.gameById('a').genres),
      );
      library.applyDetails('unknown', testDetails());

      expect(library.gameById('a').platforms, [GamePlatform.pc]);
      expect(notified, 0);
    });
  });

  group('onCatalogFilled', () {
    late int filled;
    late FakeBackfillApi api;

    setUp(() {
      filled = 0;
      api = FakeBackfillApi();
      library.dispose();
      library = LibraryStore(
        repository: repo,
        auth: auth,
        profile: profile,
        cache: cache,
        apiService: api,
        onCatalogFilled: () => filled++,
      );
    });

    test('hears of a game whose details loaded, even when the library changes nothing', () async {
      repo.library = [testGame('a', platforms: [GamePlatform.pc])];
      await library.initialize();
      await pumpEventQueue();

      // The same platforms and genres: nothing to change on the game, but the
      // server saved the themes and developers (which the library does not hold).
      library.applyDetails(
        'a',
        GameDetails(igdbId: 7, platforms: [GamePlatform.pc], genres: library.gameById('a').genres),
      );

      expect(filled, 1);
    });

    test('hears of each backfill batch, once', () async {
      repo.library = [testGame('a', igdbId: 7), testGame('b', igdbId: 8)];
      repo.unsyncedIgdbIds = [7, 8];

      await library.initialize();
      await pumpEventQueue();

      expect(api.calls, [
        [7, 8],
      ]);
      expect(filled, 1);
    });

    test('is not called for a backfill that filled nothing in', () async {
      library.applyCatalogUpdates(const []);
      repo.library = [testGame('a', igdbId: 7)];
      await library.initialize();
      await pumpEventQueue(); // nothing unsynced: no backfill

      expect(filled, 0);
    });
  });

  group('catalog backfill', () {
    late FakeBackfillApi api;

    setUp(() {
      api = FakeBackfillApi();
      library.dispose();
      library = LibraryStore(
        repository: repo,
        auth: auth,
        profile: profile,
        cache: cache,
        apiService: api,
      );
    });

    test('after the library loads, the games IGDB never filled in get their exact platforms', () async {
      repo.library = [
        testGame('a', platforms: [GamePlatform.pc], igdbId: 7),
        testGame('b', platforms: [GamePlatform.pc], igdbId: 8),
      ];
      repo.unsyncedIgdbIds = [7];
      api.gate = Completer<void>();

      // The load is done (and nothing spins) before IGDB has answered.
      await library.initialize();
      await pumpEventQueue();
      expect(library.isLoading, isFalse);
      expect(api.calls, [
        [7],
      ]);
      var notified = 0;
      library.addListener(() => notified++);

      api.gate!.complete();
      await pumpEventQueue();

      expect(library.gameById('a').platforms, FakeBackfillApi.backfilledPlatforms);
      expect(library.gameById('a').genres, FakeBackfillApi.backfilledGenres);
      expect(library.libraryGames.firstWhere((g) => g.id == 'a').platforms, FakeBackfillApi.backfilledPlatforms);
      expect(library.gameById('b').platforms, [GamePlatform.pc]);
      expect(notified, 1);
    });

    test('a library that is all filled in asks IGDB nothing', () async {
      repo.library = [testGame('a', igdbId: 7)];
      await library.initialize();
      await pumpEventQueue();

      expect(repo.unsyncedReads, 1);
      expect(api.calls, isEmpty);
    });

    test('nothing is filled in while the server is out of reach', () async {
      await cache.writeLibrary('u1', [testGame('a', igdbId: 7)]);
      repo.unsyncedIgdbIds = [7];
      repo.offline = true;
      await library.initialize();
      await pumpEventQueue();

      expect(library.isOffline, isTrue);
      expect(repo.unsyncedReads, 0);
      expect(api.calls, isEmpty);
    });

    test('signing out stops it: an answer that arrives later changes nothing', () async {
      repo.library = [testGame('a', platforms: [GamePlatform.pc], igdbId: 7)];
      repo.popular = [testGame('a', status: null, platforms: [GamePlatform.pc], igdbId: 7)];
      repo.unsyncedIgdbIds = [7];
      api.gate = Completer<void>();
      await library.initialize();
      await pumpEventQueue();

      authService.emit(null);
      await pumpEventQueue();
      api.gate!.complete();
      await pumpEventQueue();

      expect(library.libraryGames, isEmpty);
      expect(library.gameById('a').platforms, [GamePlatform.pc]);
    });

    test('applyCatalogUpdates patches every game with that IGDB id, with one notification', () async {
      repo.library = [testGame('a', platforms: [GamePlatform.pc], igdbId: 7)];
      repo.popular = [testGame('c', status: null, platforms: [GamePlatform.pc], igdbId: 9)];
      await library.initialize();
      await pumpEventQueue();
      var notified = 0;
      library.addListener(() => notified++);

      library.applyCatalogUpdates(const [
        GameDetails(igdbId: 7, platforms: [GamePlatform.ps3]),
        GameDetails(igdbId: 9, platforms: [GamePlatform.wiiU]),
        GameDetails(igdbId: 404, platforms: [GamePlatform.ps5]),
      ]);

      expect(library.gameById('a').platforms, [GamePlatform.ps3]);
      expect(library.gameById('c').platforms, [GamePlatform.wiiU]);
      expect(notified, 1);

      // The same again, or nothing to say: no change, no notification.
      library.applyCatalogUpdates(const [
        GameDetails(igdbId: 7, platforms: [GamePlatform.ps3]),
        GameDetails(igdbId: 9),
      ]);
      expect(notified, 1);
    });
  });

  group('clearLibrary', () {
    test('empties the library, the sessions and the saved copy, and keeps the catalog', () async {
      repo.library = [testGame('a'), testGame('b')];
      repo.logs = [testLog('l1', 'a')];
      repo.popular = [testGame('c', status: null)];
      await library.initialize();
      await pumpEventQueue();
      expect(ids(library.libraryGames), ['a', 'b']);

      final error = await library.clearLibrary();
      await pumpEventQueue();

      expect(error, isNull);
      expect(repo.writes, contains('clear-library'));
      expect(library.libraryGames, isEmpty);
      expect(library.logsFor('a'), isEmpty);
      expect(library.recentActivity(), isEmpty);
      // The Home carousels' games are the shared catalog, not the library.
      expect(ids(library.games), ['c']);
      expect(library.maybeGame('a'), isNull);
      // Offline, the saved copy opens empty instead of bringing the games back.
      expect((await cache.readLibrary('u1'))!.value, isEmpty);
      expect((await cache.readLogs('u1'))!.value, isEmpty);
    });

    test('drops the edits still waiting for the server', () async {
      repo.library = [testGame('a')];
      await library.initialize();
      await pumpEventQueue();
      repo.writesDown = true;
      await library.setRating('a', 3);
      expect(library.pendingCount, 1);
      repo.writesDown = false;

      expect(await library.clearLibrary(), isNull);

      expect(library.pendingCount, 0);
    });

    test('leaves the library alone when the server cannot be reached', () async {
      repo.library = [testGame('a')];
      await library.initialize();
      await pumpEventQueue();
      repo.writesDown = true;

      final error = await library.clearLibrary();

      expect(error, contains('Could not reach the server'));
      expect(ids(library.libraryGames), ['a']);
      expect(library.pendingCount, 0);
    });

    test('a review the server refuses for its words is put back, and says why', () async {
      repo.library = [testGame('a')];
      await library.initialize();
      await pumpEventQueue();
      repo
        ..rejectWrites = true
        ..rejectCode = 'CP422';

      await library.setReview('a', 'some words');
      await library.whenSaved();
      await pumpEventQueue(); // the library is read again

      expect(library.notice, startsWith('That text breaks the community rules'));
      expect(repo.reviews, isEmpty); // nothing was saved
    });

    test('leaves the library alone when the server refuses', () async {
      repo.library = [testGame('a')];
      await library.initialize();
      await pumpEventQueue();
      repo.rejectWrites = true;

      final error = await library.clearLibrary();

      expect(error, 'Could not clear your library. Please try again.');
      expect(ids(library.libraryGames), ['a']);
    });
  });

  test('looks a game up in the library, the catalog, then the external source', () async {
    final searched = testGame('searched', status: null);
    final store = LibraryStore(
      repository: repo,
      auth: auth,
      profile: profile,
      cache: cache,
      externalGame: (id) => id == 'searched' ? searched : null,
    );
    addTearDown(store.dispose);
    repo.library = [testGame('a')];
    await store.initialize();

    expect(store.maybeGame('a')!.inLibrary, isTrue);
    expect(store.maybeGame('searched'), same(searched));
    expect(store.maybeGame('nope'), isNull);
  });
}
