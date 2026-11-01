import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/services/sync_failure.dart';
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
  late FakeBackfillApi api;

  setUp(() async {
    debugPrint = (String? message, {int? wrapWidth}) {};
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository()..steamId = '76561198000000000';
    authService = FakeAuthService(testUser('u1'));
    cache = LocalCache();
    auth = AuthStore(authService)..initialize();
    profile = ProfileStore(repository: repo, auth: auth, cache: cache);
    api = FakeBackfillApi();
    library = LibraryStore(
      repository: repo,
      auth: auth,
      profile: profile,
      cache: cache,
      apiService: api,
    );
    await profile.initialize();
    await library.initialize();
  });

  tearDown(() {
    debugPrint = debugPrintThrottled;
    library.dispose();
    profile.dispose();
    auth.dispose();
  });

  /// The library re-read that follows a sync is debounced (300 ms).
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 400));

  test('the games a sync imported get their catalog rows filled in once they are on screen', () async {
    expect(repo.unsyncedReads, 1); // the load's own pass found nothing to do
    repo.library = [testGame('imported', platforms: [GamePlatform.pc], igdbId: 7)];
    repo.unsyncedIgdbIds = [7];

    await library.syncLibrary();
    expect(api.calls, isEmpty); // not before the re-read has put them on screen
    await settle();

    expect(api.calls, [
      [7],
    ]);
    expect(library.gameById('imported').platforms, FakeBackfillApi.backfilledPlatforms);
  });

  test('a complete sync reports nothing and refreshes the library', () async {
    final fetchesBefore = repo.libraryFetches;

    final message = await library.syncLibrary();
    await settle();

    expect(message, isNull);
    expect(library.syncStatus, SyncStatus.synced);
    expect(library.syncFailure, isNull);
    expect(library.isSyncing, isFalse);
    expect(repo.libraryFetches, greaterThan(fetchesBefore));
  });

  test('a sync that moved games to Hidden, because Steam no longer lists them, says so', () async {
    repo.syncData = {
      'success': true,
      'summary': {'steam_unlisted_hidden': 2},
    };
    expect(await library.syncLibrary(), contains('2 games Steam no longer lists'));
    expect(library.syncStatus, SyncStatus.synced);
    expect(library.syncFailure, isNull);

    repo.syncData = {
      'success': true,
      'summary': {'steam_unlisted_hidden': 1},
    };
    expect(await library.syncLibrary(), contains('1 game Steam no longer lists'));

    // None moved, or an older function that doesn't say: nothing to report.
    repo.syncData = {
      'success': true,
      'summary': {'steam_unlisted_hidden': 0},
    };
    expect(await library.syncLibrary(), isNull);
    repo.syncData = {'success': true};
    expect(await library.syncLibrary(), isNull);
  });

  test('what IGDB left for later is reported before the games moved to Hidden', () async {
    repo.syncData = {
      'success': true,
      'summary': {'steam_unlisted_hidden': 3},
      'delayed': {'code': 'IGDB_RATE_LIMITED', 'retry_after': 120, 'deferred': 30},
    };

    final message = await library.syncLibrary();

    expect(library.syncStatus, SyncStatus.delayed);
    expect(message, library.syncFailure!.message);
  });

  test('a sync that IGDB cut short is "delayed", and the games it did match still show', () async {
    repo.syncData = {
      'success': true,
      'delayed': {'code': 'IGDB_RATE_LIMITED', 'retry_after': 120, 'deferred': 30},
    };
    repo.library = [testGame('matched')];

    final message = await library.syncLibrary();
    await settle();

    expect(library.syncStatus, SyncStatus.delayed);
    expect(library.syncFailure!.code, SyncFailureCode.igdbRateLimited);
    expect(message, library.syncFailure!.message);
    expect(message, contains('Try again in 2 minutes'));
    // Partial progress is kept: the library was refreshed after the sync.
    expect(library.libraryGames.map((g) => g.id), ['matched']);
  });

  test('Steam rate limiting is delayed, a private profile is a failure', () async {
    repo.syncError = const FunctionException(
      status: 429,
      details: {'code': 'STEAM_RATE_LIMITED', 'retry_after': 300},
    );
    await library.syncLibrary();
    expect(library.syncStatus, SyncStatus.delayed);

    repo.syncError = const FunctionException(status: 403, details: {'code': 'STEAM_PROFILE_PRIVATE'});
    final message = await library.syncLibrary();
    expect(library.syncStatus, SyncStatus.failed);
    expect(message, contains('Game details'));
  });

  test('an unreachable server is delayed, not a failure', () async {
    repo.syncError = Exception('network down');

    final message = await library.syncLibrary();

    expect(library.syncStatus, SyncStatus.delayed);
    expect(library.syncFailure!.code, SyncFailureCode.offline);
    expect(message, contains('Check your connection'));
  });

  test('a later success clears the delayed state', () async {
    repo.syncError = const FunctionException(status: 503, details: {'code': 'STEAM_UNAVAILABLE'});
    await library.syncLibrary();
    expect(library.syncStatus, SyncStatus.delayed);

    repo.syncError = null;
    await library.syncLibrary();

    expect(library.syncStatus, SyncStatus.synced);
    expect(library.syncFailure, isNull);
  });

  test('does not call the server without a connected Steam account', () async {
    repo.steamId = null;
    await profile.initialize();

    final message = await library.syncLibrary();

    expect(message, contains('Connect your Steam account'));
    expect(repo.syncCalls, 0);
    expect(library.syncStatus, SyncStatus.idle);
  });

  test('signing out forgets how the last sync went', () async {
    repo.syncError = const FunctionException(status: 503, details: {'code': 'STEAM_UNAVAILABLE'});
    await library.syncLibrary();
    expect(library.syncStatus, SyncStatus.delayed);

    authService.emit(null);
    await pumpEventQueue();

    expect(library.syncStatus, SyncStatus.idle);
    expect(library.syncFailure, isNull);
  });
}
