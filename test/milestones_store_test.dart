import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/lists_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/milestones_store.dart';
import 'package:checkpoint/state/profile_store.dart';

import 'support/fakes.dart';

void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late LocalCache cache;
  late AuthStore auth;
  late ProfileStore profile;
  late LibraryStore library;
  late ListsStore lists;
  late MilestonesStore store;
  late List<MilestoneUnlock> announced;

  final now = DateTime.utc(2026, 10, 21, 12);
  final longAgo = DateTime.utc(2026, 2, 1);

  setUp(() {
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
    lists = ListsStore(
      repository: repo,
      auth: auth,
      ensureInCatalog: library.ensureInCatalog,
    );
    store = MilestonesStore(
      repository: repo,
      auth: auth,
      library: library,
      profile: profile,
      lists: lists,
      cache: cache,
      now: () => now,
      utcOffsetMinutes: () => 120,
    );
    announced = [];
    // Taken as the app shell does, on each change.
    store.addListener(() {
      if (store.takeAnnouncement() case final unlock?) announced.add(unlock);
    });
  });

  tearDown(() {
    debugPrint = debugPrintThrottled;
    store.dispose();
    lists.dispose();
    library.dispose();
    profile.dispose();
    auth.dispose();
  });

  /// Signs in with the library the server has, and waits for the milestones.
  Future<void> start() async {
    lists.initialize();
    store.initialize();
    await library.initialize();
    await pumpEventQueue();
  }

  List<String> ids(Iterable<Milestone> list) => [for (final m in list) m.id];

  group('on sign-in', () {
    test(
      'reads what the member earned and has the server award the rest',
      () async {
        repo.library = [testGame('a')];
        repo.memberMilestones['u1'] = {'member_1m': longAgo};
        repo.reachable = {'library_1': now};

        await start();

        expect(repo.awardCalls, [120]);
        expect(repo.milestoneReads, ['u1']);
        expect(store.status, LoadStatus.ready);
        expect(
          store.earned.unlockedAt.keys,
          unorderedEquals(['member_1m', 'library_1']),
        );
        expect(
          (await cache.readMilestones('u1'))!.value.has('library_1'),
          isTrue,
        );
      },
    );

    test(
      'sums up what was earned long ago on a device that never showed it',
      () async {
        repo.library = [testGame('a')];
        repo.memberMilestones['u1'] = {
          'library_1': longAgo,
          'sessions_1': longAgo,
          'member_1m': longAgo,
        };

        await start();

        expect(announced, hasLength(1));
        expect(announced.single.fromHistory, isTrue);
        expect(ids(announced.single.milestones), hasLength(3));
      },
    );

    test('celebrates a milestone earned just now', () async {
      repo.library = [testGame('a')];
      repo.reachable = {'library_1': now.subtract(const Duration(minutes: 1))};

      await start();

      expect(announced, hasLength(1));
      expect(announced.single.fromHistory, isFalse);
      expect(ids(announced.single.milestones), ['library_1']);
    });

    test(
      'announces only what is new to a device that showed them before',
      () async {
        await cache.writeMilestones(
          'u1',
          EarnedMilestones({'member_1m': longAgo}),
        );
        repo.library = [testGame('a')];
        repo.memberMilestones['u1'] = {'member_1m': longAgo};
        repo.reachable = {'library_1': now};

        await start();

        expect(ids(announced.single.milestones), ['library_1']);
        expect(announced.single.fromHistory, isFalse);
      },
    );

    test('shows the milestones saved on the device when the server is out of reach', () async {
      await cache.writeMilestones(
        'u1',
        EarnedMilestones({'member_1m': longAgo}),
      );
      repo.offline = true;

      await start();

      expect(store.earned.has('member_1m'), isTrue);
      expect(store.status, LoadStatus.ready);
      expect(announced, isEmpty);
    });
  });

  group('after a change', () {
    setUp(() {
      repo.library = [for (var i = 0; i < 9; i++) testGame('g$i')];
      repo.popular = [testGame('new', status: null)];
    });

    test(
      'asks the server once the edit reached it, and announces what it awards',
      () async {
        await start();
        expect(repo.awardCalls, hasLength(1));

        repo.reachable = {'library_10': now};
        repo.userGameGate = Completer<void>();
        final adding = library.addToLibrary('new', GameStatus.playing);
        await pumpEventQueue();

        // The tenth game is still on its way.
        expect(store.progress.reached(milestoneById('library_10')!), isTrue);
        expect(repo.awardCalls, hasLength(1));

        repo.userGameGate!.complete();
        await adding;
        await pumpEventQueue();

        expect(repo.awardCalls, hasLength(2));
        expect(store.earned.has('library_10'), isTrue);
        expect(ids(announced.last.milestones), ['library_10']);
      },
    );

    test('does not ask again for what the server would not award, until there is more of it', () async {
      repo.library = [testGame('a')];
      await start();
      expect(repo.awardCalls, hasLength(1));

      // The server disagrees: library_1 stays unearned.
      await library.toggleFavorite('a');
      await pumpEventQueue();
      expect(repo.awardCalls, hasLength(1));

      await library.addToLibrary('new', GameStatus.playing);
      await pumpEventQueue();
      expect(repo.awardCalls, hasLength(2));
    });

    test('tries again on the next change when the award failed', () async {
      repo.failAwards = true;
      await start();
      expect(store.status, LoadStatus.failed);

      repo.failAwards = false;
      repo.reachable = {'library_10': now};
      await library.addToLibrary('new', GameStatus.playing);
      await pumpEventQueue();

      expect(store.status, LoadStatus.ready);
      expect(store.earned.has('library_10'), isTrue);
    });
  });

  group('without Steam', () {
    test('marking a Platinum asks for Perfectionist and announces it', () async {
      repo.library = [testGame('a', playedOn: GamePlatform.ps5)];
      await start();
      expect(repo.awardCalls, hasLength(1));

      repo.reachable = {'perfect_game': now};
      await library.setPerfected('a', true);
      await pumpEventQueue();

      expect(repo.perfectedSent['a'], isTrue);
      expect(repo.awardCalls, hasLength(2));
      expect(store.earned.has('perfect_game'), isTrue);
      expect(ids(announced.last.milestones), ['perfect_game']);
    });

    test('connecting Steam asks once the profile has the Steam ID', () async {
      repo.library = [testGame('a')];
      await profile.initialize();
      await start();
      expect(repo.awardCalls, hasLength(1));
      expect(store.progress.valueOf(MilestoneMetric.gameAccount), 0);

      repo.reachable = {'steam_connected': now};
      repo.steamId = '76561198000000000'; // what the steam-link function saves
      await profile.refresh();
      await pumpEventQueue();

      expect(store.progress.valueOf(MilestoneMetric.gameAccount), 1);
      expect(repo.awardCalls, hasLength(2));
      expect(store.earned.has('steam_connected'), isTrue);
      expect(ids(announced.last.milestones), ['steam_connected']);
    });
  });

  test('forgets the milestones when another account signs in', () async {
    repo.library = [testGame('a')];
    repo.memberMilestones['u1'] = {'library_1': longAgo};
    await start();
    expect(store.earned.has('library_1'), isTrue);

    authService.emit(testUser('u2'));
    await pumpEventQueue();

    expect(store.earned.has('library_1'), isFalse);
  });
}
