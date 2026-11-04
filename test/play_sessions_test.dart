import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/services/pending_edits.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/profile_store.dart';

import 'support/fakes.dart';

/// Play sessions after they are logged: backdating, editing, deleting (with
/// Undo), and all of it while the server can't be reached.
void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late FakeConnectivity network;
  late LocalCache cache;
  late AuthStore auth;
  late ProfileStore profile;
  late LibraryStore library;

  LibraryStore newLibrary() => LibraryStore(
    repository: repo,
    auth: auth,
    profile: profile,
    cache: cache,
    connectivity: network,
  );

  LogEntry session(String id, {double hours = 2, DateTime? at}) => LogEntry(
    id: id,
    gameId: 'a',
    timestamp: at ?? DateTime(2026, 10, 1, 20),
    hours: hours,
    platform: GamePlatform.pc,
    note: 'boss fight',
  );

  setUp(() async {
    debugPrint = (String? message, {int? wrapWidth}) {};
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository()
      ..library = [testGame('a', hours: 10), testGame('b')]
      ..logs = [session('s1')];
    authService = FakeAuthService(testUser('u1'));
    network = FakeConnectivity();
    cache = LocalCache();
    auth = AuthStore(authService);
    await auth.initialize();
    profile = ProfileStore(repository: repo, auth: auth, cache: cache);
    library = newLibrary();
    await library.initialize();
    await pumpEventQueue();
  });

  tearDown(() {
    debugPrint = debugPrintThrottled;
    library.dispose();
    profile.dispose();
    auth.dispose();
  });

  Game game(String id) => library.libraryGames.firstWhere((g) => g.id == id);

  group('logging', () {
    test('a backdated session is sent with its own time and sorted by it', () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));

      await library.logSession(gameId: 'a', hours: 1.5, at: yesterday);

      expect(repo.writes, contains('log:a:1.5'));
      expect(repo.logTimes.single, yesterday);
      expect(game('a').hoursPlayed, 11.5);
    });

    test('a time in the future is taken as now', () async {
      final before = DateTime.now();
      await library.logSession(
        gameId: 'a',
        hours: 1,
        at: DateTime.now().add(const Duration(days: 3)),
      );
      final sent = repo.logTimes.single!;
      expect(sent.isBefore(before), isFalse);
      expect(sent.isAfter(DateTime.now()), isFalse);
    });

    test('a session longer than one sitting, or of no time, is not logged', () async {
      await library.logSession(gameId: 'a', hours: 25);
      await library.logSession(gameId: 'a', hours: 0);
      await library.logSession(gameId: 'a', hours: -2);

      expect(repo.writes, isEmpty);
      expect(game('a').hoursPlayed, 10);
    });

    test('a total typed past the limit is saved at the limit', () async {
      await library.updateTime(gameId: 'a', totalHours: 5e6);
      expect(game('a').hoursPlayed, 100000);
    });

    test('a rating out of range is saved within 0 to 10', () async {
      await library.setRating('a', 12);
      expect(game('a').rating, 10);
      await library.setRating('a', -1);
      expect(game('a').rating, 0);
    });
  });

  group('editing', () {
    test('changes the session and moves the game total by the difference', () async {
      final at = DateTime(2026, 9, 30, 18);
      await library.editSession(
        's1',
        hours: 3.5,
        platform: GamePlatform.steamDeck,
        at: at,
        note: '  on the train ',
      );

      expect(repo.writes, ['edit-log:s1:3.5', 'game:a:GameStatus.playing:4.5']);
      final edited = library.sessionById('s1')!;
      expect(edited.hours, 3.5);
      expect(edited.platform, GamePlatform.steamDeck);
      expect(edited.timestamp, at);
      expect(edited.note, 'on the train');
      expect(game('a').hoursPlayed, 11.5);
    });

    test('a refused edit puts the session and the total back', () async {
      repo.rejectWrites = true;

      await library.editSession(
        's1',
        hours: 5,
        platform: GamePlatform.pc,
        at: DateTime(2026, 10, 1, 20),
      );
      await pumpEventQueue();

      expect(library.notice, 'Could not save that change to the session.');
      expect(library.sessionById('s1')!.hours, 2);
      expect(game('a').hoursPlayed, 10);
    });

    test('an edit made offline is kept and sent when the connection is back', () async {
      repo.offline = true;
      await library.editSession(
        's1',
        hours: 4,
        platform: GamePlatform.pc,
        at: DateTime(2026, 10, 1, 20),
      );

      expect(library.pendingCount, 2); // the session and the game's total
      expect(library.sessionById('s1')!.hours, 4);

      // Reopened offline: the edit is still on screen.
      library.dispose();
      library = newLibrary();
      await library.initialize();
      expect(library.sessionById('s1')!.hours, 4);

      repo.offline = false;
      network.controller.add(true);
      await pumpEventQueue();

      expect(repo.writes, containsAllInOrder(['edit-log:s1:4.0']));
      expect(library.pendingCount, 0);
      expect(repo.logs.single.hours, 4);
    });

    test('editing a session logged offline changes the queued insert', () async {
      repo.offline = true;
      await library.logSession(gameId: 'b', hours: 1);
      final local = library.logsFor('b').single;

      await library.editSession(
        local.id,
        hours: 2,
        platform: GamePlatform.ps5,
        at: local.timestamp,
      );
      repo.offline = false;
      await library.flushPending();

      expect(repo.writes.where((w) => w.startsWith('log:')), ['log:b:2.0']);
      expect(repo.writes.where((w) => w.startsWith('edit-log:')), isEmpty);
    });
  });

  group('deleting', () {
    test('takes the hours off the total, and Undo logs it again as it was', () async {
      final removed = await library.deleteSession('s1');

      expect(removed!.id, 's1');
      expect(repo.writes, ['delete-log:s1', 'game:a:GameStatus.playing:4.5']);
      expect(library.logsFor('a'), isEmpty);
      expect(game('a').hoursPlayed, 8);

      await library.restoreSession(removed);

      expect(repo.writes.last, 'log:a:2.0');
      expect(repo.logTimes.last, removed.timestamp);
      expect(game('a').hoursPlayed, 10);
    });

    test('the total never goes below zero', () async {
      repo.logs = [session('big', hours: 50)];
      await library.refresh();
      await pumpEventQueue();

      await library.deleteSession('big');

      expect(game('a').hoursPlayed, 0);
    });

    test('a delete made offline is sent later, and a session logged offline is just dropped', () async {
      repo.offline = true;
      await library.deleteSession('s1');
      await library.logSession(gameId: 'b', hours: 1);
      final local = library.logsFor('b').single;
      await library.deleteSession(local.id);

      repo.offline = false;
      await library.flushPending();

      expect(repo.writes, contains('delete-log:s1'));
      expect(repo.writes.where((w) => w.startsWith('log:')), isEmpty);
      expect(library.pendingCount, 0);
    });
  });

  test('queued session changes read back from what an older app saved', () {
    final edits = PendingEdits.fromJson({
      'games': [],
      'removed': [],
      'logs': [],
    });
    expect(edits.logEdits, isEmpty);
    expect(edits.logDeletes, isEmpty);

    edits
      ..editLog(
        PendingLog(
          localId: 's1',
          gameId: 'a',
          hours: 1,
          platform: GamePlatform.pc,
          note: '',
          timestamp: DateTime.utc(2026, 10, 1),
        ),
      )
      ..removeLog('s2');
    final again = PendingEdits.fromJson(edits.toJson(PendingScope.library));
    expect(again.logEdits.keys, ['s1']);
    expect(again.logDeletes, {'s2'});
    expect(again.count, 2);

    // Removing the game drops its session edits; deleting it deletes them.
    again.markRemoved('a');
    expect(again.logEdits, isEmpty);
  });
}
