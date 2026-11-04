import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/user_profile.dart';
import 'package:checkpoint/services/local_cache.dart';

import 'support/fakes.dart';

void main() {
  late LocalCache cache;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    cache = LocalCache();
  });

  test('a library read back is the library that was written', () async {
    final written = [
      testGame('a', favorite: true),
      testGame('b', status: GameStatus.completed, hours: 40),
    ];
    await cache.writeLibrary('u1', written);

    final read = (await cache.readLibrary('u1'))!.value;
    expect(read, hasLength(2));
    for (var i = 0; i < written.length; i++) {
      final w = written[i];
      final r = read[i];
      expect(r.id, w.id);
      expect(r.title, w.title);
      expect(r.status, w.status);
      expect(r.rating, w.rating);
      expect(r.hoursPlayed, w.hoursPlayed);
      expect(r.playedOn, w.playedOn);
      expect(r.purchasePrice, w.purchasePrice);
      expect(r.isFavorite, w.isFavorite);
      expect(r.platforms, w.platforms);
      expect(r.genres, w.genres);
      expect(r.igdbId, w.igdbId);
      expect(r.steamAppId, w.steamAppId);
      expect(r.coverUrl, w.coverUrl);
      expect(r.dateAdded!.toUtc(), w.dateAdded!.toUtc());
      // Derived, not stored: rebuilt the same way the database path builds them.
      expect(r.coverColors, w.coverColors);
      expect(r.coverIcon, w.coverIcon);
    }
  });

  test('a catalog game with no library state keeps it unset', () async {
    await cache.writePopular([testGame('c', status: null)]);

    final game = (await cache.readPopular())!.value.single;
    expect(game.status, isNull);
    expect(game.inLibrary, isFalse);
    expect(game.dateAdded, isNull);
    expect(game.playedOn, isNull);
  });

  test('a profile saved by a build that kept typed-in service names still reads', () {
    final profile = UserProfile.fromJson({
      'name': 'Ada',
      'handle': '@ada',
      'joined': '2026-01-01T00:00:00.000Z',
      'followers': 0,
      'following': 0,
      'connectedServices': ['psn', 'nintendo'],
      'psnId': 'ps_user',
      'instagramId': 'ada.plays',
    });

    expect(profile.name, 'Ada');
    expect(profile.toJson(), isNot(contains('psnId')));
    expect(profile.toJson(), isNot(contains('connectedServices')));
  });

  test('logs, profile and follows round-trip', () async {
    await cache.writeLogs('u1', [testLog('l1', 'a')]);
    final profile = UserProfile(
      name: 'Ada',
      handle: '@ada',
      bio: 'hi',
      avatarUrl: 'https://example.com/a.png',
      steamId: '7656',
      joined: DateTime.utc(2026, 1, 1),
      followers: 0,
      following: 0,
    );
    await cache.writeProfile('u1', profile);
    await cache.writeSocial(
      'u1',
      const SocialSnapshot(followingIds: {'x', 'y'}, followersCount: 9),
    );

    final log = (await cache.readLogs('u1'))!.value.single;
    expect(log.gameId, 'a');
    expect(log.hours, 1.5);
    expect(log.note, 'a note');

    final readProfile = (await cache.readProfile('u1'))!.value;
    expect(readProfile.name, 'Ada');
    expect(readProfile.steamId, '7656');
    expect(readProfile.avatarUrl, 'https://example.com/a.png');

    final social = (await cache.readSocial('u1'))!.value;
    expect(social.followingIds, {'x', 'y'});
    expect(social.followersCount, 9);
  });

  test('reports when an entry was saved', () async {
    final before = DateTime.now().subtract(const Duration(seconds: 1));
    await cache.writeLibrary('u1', [testGame('a')]);
    final saved = (await cache.readLibrary('u1'))!.savedAt;
    expect(saved.isAfter(before), isTrue);
    expect(saved.isBefore(DateTime.now().add(const Duration(seconds: 1))), isTrue);
  });

  test('each account has its own copy', () async {
    await cache.writeLibrary('u1', [testGame('a')]);

    expect(await cache.readLibrary('u2'), isNull);
    expect((await cache.readLibrary('u1'))!.value, hasLength(1));
  });

  test('nothing saved reads as null', () async {
    expect(await cache.readLibrary('u1'), isNull);
    expect(await cache.readPopular(), isNull);
  });

  test('an unreadable entry reads as null and is deleted', () async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'cache.v1.library.u1';
    await prefs.setString(key, '{"v":1,"savedAt":"2026-01-01T00:00:00Z","data":[{"id":');

    expect(await cache.readLibrary('u1'), isNull);
    expect(prefs.containsKey(key), isFalse);
  });

  test('an entry with a game missing a required field reads as null and is deleted', () async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'cache.v1.library.u1';
    await cache.writeLibrary('u1', [testGame('a'), testGame('b')]);
    final entry = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
    ((entry['data'] as List)[1] as Map<String, dynamic>)['title'] = null;
    await prefs.setString(key, jsonEncode(entry));

    expect(await cache.readLibrary('u1'), isNull);
    expect(prefs.containsKey(key), isFalse);
  });

  test('an entry of another version reads as null', () async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'cache.v1.library.u1';
    await prefs.setString(key, '{"v":99,"savedAt":"2026-01-01T00:00:00Z","data":[]}');

    expect(await cache.readLibrary('u1'), isNull);
    expect(prefs.containsKey(key), isFalse);
  });

  test('clearAccount deletes that account only', () async {
    await cache.writeLibrary('u1', [testGame('a')]);
    await cache.writeLogs('u1', [testLog('l1', 'a')]);
    await cache.writeLibrary('u2', [testGame('b')]);
    await cache.writePopular([testGame('c', status: null)]);

    await cache.clearAccount('u1');

    expect(await cache.readLibrary('u1'), isNull);
    expect(await cache.readLogs('u1'), isNull);
    expect(await cache.readLibrary('u2'), isNotNull);
    expect(await cache.readPopular(), isNotNull);
  });

  test('removeGame drops the game and its sessions', () async {
    await cache.writeLibrary('u1', [testGame('a'), testGame('b')]);
    await cache.writeLogs('u1', [testLog('l1', 'a'), testLog('l2', 'b')]);

    await cache.removeGame('u1', 'a');

    expect((await cache.readLibrary('u1'))!.value.map((g) => g.id), ['b']);
    expect((await cache.readLogs('u1'))!.value.map((l) => l.id), ['l2']);
  });

  group('timing the library entry', () {
    late List<String> logged;
    final timing = RegExp(
      r'^LocalCache: (read|write) of library took \d+ ms '
      r'\(storage \d+ ms, JSON \d+ ms\) for (\d+) KB$',
    );

    setUp(() {
      logged = [];
      debugPrint = (String? message, {int? wrapWidth}) => logged.add(message ?? '');
    });

    tearDown(() => debugPrint = debugPrintThrottled);

    List<String> timingLines() =>
        logged.where((l) => l.startsWith('LocalCache:')).toList();

    test('stays quiet while reads and writes are fast', () async {
      final games = [for (var i = 0; i < 50; i++) testGame('g$i')];
      await cache.writeLibrary('u1', games);
      await cache.readLibrary('u1');

      expect(timingLines(), isEmpty);
    });

    test('says how long a slow read and write took, and how big the entry is', () async {
      final slow = LocalCache(slowAfter: Duration.zero);
      final games = [for (var i = 0; i < 200; i++) testGame('g$i')];

      await slow.writeLibrary('u1', games);
      await slow.readLibrary('u1');

      final lines = timingLines();
      expect(lines, hasLength(2));
      expect(lines.every(timing.hasMatch), isTrue, reason: '$lines');
      expect(timing.firstMatch(lines[0])!.group(1), 'write');
      expect(timing.firstMatch(lines[1])!.group(1), 'read');

      final prefs = await SharedPreferences.getInstance();
      final kb = (prefs.getString('cache.v1.library.u1')!.length / 1024).round();
      expect(kb, greaterThan(10)); // not just rounding noise
      for (final line in lines) {
        expect(int.parse(timing.firstMatch(line)!.group(2)!), kb);
      }
    });

    test('only the library entry is timed', () async {
      final slow = LocalCache(slowAfter: Duration.zero);
      final profile = UserProfile(
        name: 'Ada',
        handle: '@ada',
        bio: '',
        joined: DateTime.utc(2026, 1, 1),
        followers: 0,
        following: 0,
      );

      await slow.writeLogs('u1', [testLog('l1', 'a')]);
      await slow.readLogs('u1');
      await slow.writeProfile('u1', profile);
      await slow.readProfile('u1');
      await slow.writeSocial('u1', const SocialSnapshot(followingIds: {'x'}, followersCount: 1));
      await slow.readSocial('u1');
      await slow.writePopular([testGame('c', status: null)]);
      await slow.readPopular();

      expect(timingLines(), isEmpty);
    });

    test('says nothing about a library that is not there', () async {
      await LocalCache(slowAfter: Duration.zero).readLibrary('u1');

      expect(timingLines(), isEmpty);
    });
  });
}
