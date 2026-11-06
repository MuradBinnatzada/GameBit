import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/library_csv.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/models/trophy.dart';
import 'package:checkpoint/screens/profile/game_trophies_dialog.dart';
import 'package:checkpoint/screens/settings/psn_import.dart';
import 'package:checkpoint/services/game_api_service.dart';
import 'package:checkpoint/services/playstation/psn_client.dart';
import 'package:checkpoint/services/playstation/psn_device.dart';
import 'package:checkpoint/services/playstation/psn_library.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_import.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// PlayStation trophy lists, the saved sign-in and the once-a-day limit, against
/// made-up answers: nothing here talks to Sony.

String basic() => base64.encode(utf8.encode('client-id:client-secret'));

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

PsnClient clientWith(http.Response Function(http.Request request) answer, {Duration pace = Duration.zero, String? language}) =>
    PsnClient(clientBasic: basic(), client: MockClient((request) async => answer(request)), pace: pace, language: language);

PsnTrophyTitle set(String name, {String id = 'NPWR1_00', String service = 'trophy', int earned = 1, int total = 10, DateTime? updated, String platform = 'PS4'}) =>
    PsnTrophyTitle(
      name: name,
      platform: platform,
      earned: earned,
      total: total,
      platinumEarned: false,
      lastUpdated: updated ?? DateTime.utc(2026, 10, 1),
      npCommunicationId: id,
      npServiceName: service,
    );

Map<String, dynamic> titleTrophy(int id, String type, String name, {String detail = '', bool hidden = false}) => {
  'trophyId': id,
  'trophyHidden': hidden,
  'trophyType': type,
  'trophyName': name,
  'trophyDetail': detail,
  'trophyIconUrl': 'https://image.api.playstation.com/t$id.png',
};

Map<String, dynamic> mine(int id, {bool earned = false, String? at, int rare = 3, String rate = '50.5'}) => {
  'trophyId': id,
  'trophyHidden': false,
  'earned': earned,
  'earnedDateTime': ?at,
  'trophyType': 'bronze',
  'trophyRare': rare,
  'trophyEarnedRate': rate,
};

void quiet() {
  final print = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {};
  addTearDown(() => debugPrint = print);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('the trophy', () {
    const gold = Trophy(
      id: 3,
      grade: TrophyGrade.gold,
      name: 'Hard Mode',
      detail: 'Finish on Hard',
      iconUrl: 'https://image.api.playstation.com/x.png',
      earned: true,
      rarity: 1,
      earnedRate: 2.5,
    );

    test('is stored with short keys and read back the same', () {
      final back = Trophy.fromJson(jsonDecode(jsonEncode(gold.toJson())));
      expect((back!.id, back.grade, back.name, back.detail, back.iconUrl, back.earned, back.rarity, back.earnedRate, back.hidden),
          (3, TrophyGrade.gold, 'Hard Mode', 'Finish on Hard', gold.iconUrl, true, 1, 2.5, false));
      expect(gold.toJson().keys, containsAll(['i', 'g', 'n', 'd', 'u', 'e', 'r', 'p']));
      const bare = Trophy(id: 1, grade: TrophyGrade.bronze, name: 'First');
      expect(bare.toJson().keys, unorderedEquals(['i', 'g', 'n']));
    });

    test('keeps the day it was earned, and drops what is not a trophy', () {
      final at = DateTime.utc(2026, 5, 6, 7);
      final list = Trophy.listFromJson([
        Trophy(id: 1, grade: TrophyGrade.silver, name: 'A', earned: true, earnedAt: at).toJson(),
        'junk',
        {'i': 2, 'g': 'x', 'n': 'bad grade'},
        {'g': 'b', 'n': 'no id'},
        {'i': 4, 'g': 'p', 'n': 'Insecure icon', 'u': 'http://example.com/a.png'},
      ])!;
      expect(list.map((t) => t.id), [1, 4]);
      expect(list.first.earnedAt!.toUtc(), at);
      expect(list.last.iconUrl, isNull);
      expect(list.last.grade, TrophyGrade.platinum);
    });

    test('a list that was never stored is null, an empty one is empty', () {
      expect(Trophy.listFromJson(null), isNull);
      expect(Trophy.listFromJson('x'), isNull);
      expect(Trophy.listFromJson(<Object>[]), isEmpty);
    });

    test('counts the earned ones by grade, and adds games up', () {
      final counts = TrophyCounts.earnedIn(const [
        Trophy(id: 0, grade: TrophyGrade.platinum, name: 'P', earned: true),
        Trophy(id: 1, grade: TrophyGrade.bronze, name: 'B1', earned: true),
        Trophy(id: 2, grade: TrophyGrade.bronze, name: 'B2'),
      ]);
      expect((counts.platinum, counts.bronze, counts.total), (1, 1, 2));
      final totals = TrophyTotals.of(const [
        GameTrophySummary(gameId: 'a', title: 'A', earned: 3, total: 3, counts: TrophyCounts(bronze: 3)),
        GameTrophySummary(gameId: 'b', title: 'B', earned: 1, total: 4, counts: TrophyCounts(gold: 1)),
      ]);
      expect((totals.earned, totals.total, totals.games, totals.completedGames, totals.counts.bronze, totals.counts.gold), (4, 7, 2, 1, 3, 1));
      expect(const TrophyTotals().isEmpty, isTrue);
    });
  });

  group('title matching', () {
    test('cuts an edition label, and only a label', () {
      expect(titleWithoutEdition('Minecraft: PlayStation 3 Edition'), 'Minecraft');
      expect(titleWithoutEdition('Minecraft: PlayStation®3 Edition'), 'Minecraft');
      expect(titleWithoutEdition('Borderlands Game of the Year Edition'), 'Borderlands');
      expect(titleWithoutEdition('Grand Theft Auto V - Premium Edition'), 'Grand Theft Auto V');
      expect(titleWithoutEdition('Alan Wake Remastered'), isNull);
      expect(titleWithoutEdition("Marvel's Spider-Man 2"), isNull);
      expect(titleWithoutEdition('Edition'), isNull);
      expect(titleWithoutEdition('Dark Souls: Prepare to Die Edition'), 'Dark Souls');
    });

    test('a sign becomes a space, so PlayStation®3 reads PlayStation 3', () {
      final file = buildPsnImport(PsnLibrary(trophies: [
        set('Minecraft: PlayStation®3 Edition', id: 'A', platform: 'PS3'),
        set('Battlefield™ Hardline', id: 'B'),
        set('Rocket League®', id: 'C'),
      ]));
      expect(file.rows.map((r) => r.title), unorderedEquals(['Minecraft: PlayStation 3 Edition', 'Battlefield Hardline', 'Rocket League']));
    });

    test('the word Sony puts after an older game\'s trophy set is not part of the game', () {
      expect(psnGameName('Battlefield Hardline Trophies'), 'Battlefield Hardline');
      expect(psnGameName('Borderlands 2 Trophy Set'), 'Borderlands 2');
      expect(psnGameName('Rocket League®'), 'Rocket League');
      expect(psnGameName('Trophies'), 'Trophies');
      expect(psnGameName('Trophy Hunter'), 'Trophy Hunter');
      // The trophy set and the play history of one game name the same row.
      final file = buildPsnImport(PsnLibrary(
        played: [PsnPlayedGame(name: 'Battlefield™ Hardline', category: 'ps4_game', playTime: const Duration(hours: 3), lastPlayed: DateTime.utc(2026, 10, 1))],
        trophies: [set('Battlefield Hardline Trophies', id: 'H', platform: 'PS3')],
      ));
      expect(file.rows.single.title, 'Battlefield Hardline');
      expect(file.rows.single.hours, 3);
    });

    test('the import tries again without the edition, and matches as strictly', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = FakeRepository();
      final stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      await stores.initialize();
      addTearDown(stores.dispose);
      final minecraft = testGame(gameIdForIgdb(1), title: 'Minecraft', status: null, igdbId: 1, cover: false).copyWith(platforms: [GamePlatform.ps3, GamePlatform.pc]);
      final api = _Api({'minecraft': [minecraft], 'minecraft: playstation 3 edition': const []});
      final run = LibraryImport(
        rows: const [
          ImportRow(line: 1, title: 'Minecraft: PlayStation 3 Edition', playedOn: GamePlatform.ps3),
          ImportRow(line: 2, title: 'Dark Souls: Prepare to Die Edition'),
        ],
        api: api,
        library: stores.library,
        pause: Duration.zero,
      );
      await run.run();
      expect(api.searched, ['minecraft: playstation 3 edition', 'minecraft', 'dark souls: prepare to die edition', 'dark souls']);
      expect(run.imported, 1);
      expect(stores.library.gameById(gameIdForIgdb(1)).playedOn, GamePlatform.ps3);
      expect(run.unmatched.map((r) => r.title), ['Dark Souls: Prepare to Die Edition']);
    });
  });

  group('the trophies of one game', () {
    final title = set('Hades', id: 'NPWR9_00', service: 'trophy2');
    const tokens = PsnTokens(accessToken: 'tok');

    http.Response answer(http.Request r) {
      expect(r.headers['Authorization'], 'Bearer tok');
      expect(r.url.queryParameters['npServiceName'], 'trophy2');
      if (r.url.path.contains('/users/me/')) {
        return json({
          'trophies': [
            mine(1, earned: true, at: '2026-03-04T05:06:07Z', rare: 0, rate: '0.8'),
            mine(0),
            mine(2),
          ],
        });
      }
      return json({
        'trophies': [
          titleTrophy(2, 'silver', 'Secret one', detail: 'Hidden task', hidden: true),
          titleTrophy(1, 'gold', 'Escape', detail: 'Leave the House'),
          titleTrophy(0, 'platinum', 'Hades', detail: 'Get them all'),
        ],
      });
    }

    test('joins what each trophy is with what the member earned, in Sony\'s order', () async {
      final requests = <String>[];
      final client = clientWith((r) {
        requests.add(r.url.path);
        return answer(r);
      });
      final list = await client.trophiesOf(tokens, title);
      expect(requests, [
        '/api/trophy/v1/npCommunicationIds/NPWR9_00/trophyGroups/all/trophies',
        '/api/trophy/v1/users/me/npCommunicationIds/NPWR9_00/trophyGroups/all/trophies',
      ]);
      expect(list.map((t) => t.id), [0, 1, 2]);
      final escape = list[1];
      expect((escape.name, escape.detail, escape.grade, escape.earned, escape.rarity, escape.earnedRate), ('Escape', 'Leave the House', TrophyGrade.gold, true, 0, 0.8));
      expect(escape.earnedAt!.toUtc(), DateTime.utc(2026, 3, 4, 5, 6, 7));
      expect(escape.iconUrl, 'https://image.api.playstation.com/t1.png');
      expect(list[0].earned, isFalse);
      expect(list[2].hidden, isTrue);
    });

    test('asks in the language it was given, and not at all without one', () async {
      String? asked;
      await clientWith((r) {
        asked = r.headers['Accept-Language'];
        return answer(r);
      }, language: 'ru-RU')
          .trophiesOf(tokens, title);
      expect(asked, 'ru-RU');
      await clientWith((r) {
        asked = r.headers['Accept-Language'];
        return answer(r);
      }).trophiesOf(tokens, title);
      expect(asked, isNull);
    });

    test('follows the pages of a long list', () async {
      final offsets = <String>[];
      final client = clientWith((r) {
        if (r.url.path.contains('/users/me/')) return json({'trophies': <Object>[]});
        offsets.add(r.url.queryParameters['offset']!);
        return r.url.queryParameters['offset'] == '0'
            ? json({'trophies': [titleTrophy(0, 'bronze', 'A')], 'nextOffset': 1})
            : json({'trophies': [titleTrophy(1, 'bronze', 'B')]});
      });
      expect((await client.trophiesOf(tokens, set('X', service: 'trophy'))).map((t) => t.name), ['A', 'B']);
      expect(offsets, ['0', '1']);
    });

    test('says why Sony would not give them', () async {
      quiet();
      await expectLater(
        clientWith((_) => json({}, 429)).trophiesOf(tokens, title),
        throwsA(isA<PsnException>().having((e) => e.failure, 'failure', PsnFailure.rateLimited)),
      );
      await expectLater(
        clientWith((_) => json({'nope': 1})).trophiesOf(tokens, title),
        throwsA(isA<PsnException>().having((e) => e.failure, 'failure', PsnFailure.unexpected)),
      );
    });

    test('the gaps between requests are at least the pace and not all alike', () async {
      final stamps = <DateTime>[];
      final client = PsnClient(
        clientBasic: basic(),
        client: MockClient((r) async {
          stamps.add(DateTime.now());
          return answer(r);
        }),
        pace: const Duration(milliseconds: 40),
        random: Random(7),
      );
      for (var i = 0; i < 3; i++) {
        await client.trophiesOf(tokens, title);
      }
      final gaps = [for (var i = 1; i < stamps.length; i++) stamps[i].difference(stamps[i - 1]).inMilliseconds];
      expect(gaps, hasLength(5));
      // At least the pace (a little under for timer rounding), at most the pace
      // and its spread (plus slack for a slow machine).
      expect(gaps.every((g) => g >= 36), isTrue, reason: '$gaps');
      expect(gaps.toSet().length, greaterThan(1), reason: '$gaps');
    });

    test('waits between requests, so a long import is no burst', () async {
      final client = clientWith((r) => answer(r), pace: const Duration(milliseconds: 120));
      final watch = Stopwatch()..start();
      await client.trophiesOf(tokens, title);
      // Two requests: one wait of the pace between them.
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(110));
    });
  });

  group('signing in again', () {
    test('a sign-in carries the refresh token and when it ends', () async {
      quiet();
      final client = clientWith((_) => json({'access_token': 'a', 'refresh_token': 'r', 'refresh_token_expires_in': 5184000}));
      final tokens = await client.exchangeCode('c');
      expect((tokens.accessToken, tokens.refreshToken), ('a', 'r'));
      expect(tokens.refreshExpiresAt!.difference(DateTime.now()).inDays, closeTo(60, 1));
    });

    test('the refresh token is swapped for an access token the way the phone app does', () async {
      quiet();
      late http.Request seen;
      final client = clientWith((r) {
        seen = r;
        return json({'access_token': 'new', 'refresh_token': 'r2'});
      });
      final tokens = await client.refresh('r1');
      expect(seen.url.path, '/api/authz/v3/oauth/token');
      expect(seen.headers['Authorization'], 'Basic ${basic()}');
      expect(Uri.splitQueryString(seen.body), {
        'refresh_token': 'r1',
        'grant_type': 'refresh_token',
        'token_format': 'jwt',
        'scope': 'psn:mobile.v2.core psn:clientapp',
      });
      expect((tokens.accessToken, tokens.refreshToken), ('new', 'r2'));
    });

    test('Sony turning it down is a refused sign-in', () async {
      quiet();
      await expectLater(
        clientWith((_) => json({'error': 'invalid_grant'}, 400)).refresh('old'),
        throwsA(isA<PsnException>().having((e) => e.failure, 'failure', PsnFailure.signInRejected)),
      );
    });
  });

  group('which trophy lists a sync reads', () {
    PsnLibrary library(List<PsnTrophyTitle> sets) => PsnLibrary(trophies: sets);

    test('the games the member earned something in, most recent first, and not again at the same progress', () {
      final sets = [
        set('Old', id: 'OLD', updated: DateTime.utc(2025, 1, 1)),
        set('New', id: 'NEW', updated: DateTime.utc(2026, 6, 1), earned: 4, total: 9),
        set('Untouched', id: 'ZERO', earned: 0),
        set('Same', id: 'SAME', updated: DateTime.utc(2026, 5, 1), earned: 2, total: 8),
        set('No id', id: ''),
      ];
      final read = trophySetsToRead(library(sets), {'SAME': PsnDevice.listMark(2, 8)});
      expect(read.map((s) => s.npCommunicationId), ['NEW', 'OLD']);
      // More earned since: it is read again.
      expect(trophySetsToRead(library(sets), {'SAME': PsnDevice.listMark(1, 8)}).map((s) => s.npCommunicationId), contains('SAME'));
    });

    test('at most the number a sync allows', () {
      final sets = [for (var i = 0; i < 5; i++) set('G$i', id: 'ID$i', updated: DateTime.utc(2026, 1, 1 + i))];
      expect(trophySetsToRead(library(sets), const {}, max: 3).map((s) => s.name), ['G4', 'G3', 'G2']);
      expect(psnMaxTrophyLists, 100);
    });

    test('of one game on two consoles, the set the member got furthest in', () {
      final read = trophySetsToRead(library([set('Game', id: 'PS4', earned: 3), set('Game', id: 'PS5', service: 'trophy2', earned: 8)]), const {});
      expect(read.map((s) => s.npCommunicationId), ['PS5']);
    });

    PsnClient listClient(http.Response Function(http.Request) answer) => clientWith(answer);
    http.Response okLists(http.Request r) => r.url.path.contains('/users/me/')
        ? json({'trophies': [mine(0, earned: true)]})
        : json({'trophies': [titleTrophy(0, 'bronze', 'First')]});

    test('reads them and puts them on the rows', () async {
      final lib = library([set('Hades', id: 'H1', earned: 1, total: 1)]);
      final read = await loadTrophyLists(listClient(okLists), const PsnTokens(accessToken: 't'), lib);
      expect(read.trophyLists.keys, ['H1']);
      expect(read.trophyListsCut, isFalse);
      final row = buildPsnImport(read).rows.single;
      expect((row.trophyList!.single.name, row.trophySet), ('First', 'H1'));
      final progress = <(int, int)>[];
      await loadTrophyLists(listClient(okLists), const PsnTokens(accessToken: 't'), lib, onProgress: (d, t) => progress.add((d, t)));
      expect(progress.first, (0, 1));
      expect(progress.last, (1, 1));
    });

    test('a game with no list read has none on its row, and keeps what is stored', () {
      final row = buildPsnImport(library([set('Hades', id: 'H1')])).rows.single;
      expect((row.trophyList, row.trophySet), (null, null));
    });

    test('stops when Sony says to slow down, and says so', () async {
      quiet();
      var calls = 0;
      final lib = library([for (var i = 0; i < 4; i++) set('G$i', id: 'ID$i', updated: DateTime.utc(2026, 1, 1 + i))]);
      final read = await loadTrophyLists(
        listClient((r) {
          calls++;
          return calls <= 2 ? okLists(r) : json({}, 429);
        }),
        const PsnTokens(accessToken: 't'),
        lib,
      );
      expect(read.trophyLists, hasLength(1));
      expect(read.trophyListsCut, isTrue);
      expect(calls, 3);
      expect(buildPsnImport(read).notes.single, contains('Not every trophy list was read'));
    });

    test('skips one set Sony will not give, but gives up after three in a row', () async {
      quiet();
      final lib = library([for (var i = 0; i < 6; i++) set('G$i', id: 'ID$i', updated: DateTime.utc(2026, 1, 1 + i))]);
      final skipOne = await loadTrophyLists(
        listClient((r) => r.url.path.contains('ID5') ? json({}, 404) : okLists(r)),
        const PsnTokens(accessToken: 't'),
        lib,
      );
      expect(skipOne.trophyLists.length, 5);
      expect(skipOne.trophyListsCut, isFalse);
      final allFail = await loadTrophyLists(listClient((_) => json({}, 404)), const PsnTokens(accessToken: 't'), lib);
      expect(allFail.trophyLists, isEmpty);
      expect(allFail.trophyListsCut, isTrue);
    });
  });

  group('what the phone keeps', () {
    late PsnDevice device;
    var now = DateTime.utc(2026, 11, 6, 12);
    setUp(() {
      now = DateTime.utc(2026, 11, 6, 12);
      device = PsnDevice(now: () => now);
    });

    PsnTokens signedIn({String? refresh = 'refresh-1', Duration? lasts = const Duration(days: 60)}) =>
        PsnTokens(accessToken: 'a', refreshToken: refresh, refreshExpiresAt: lasts == null ? null : now.add(lasts));

    test('keeps the sign-in per account, and forgets it', () async {
      expect(await device.savedSignIn('u1'), isNull);
      await device.saveSignIn('u1', signedIn());
      expect(await device.savedSignIn('u1'), 'refresh-1');
      expect(await device.savedSignIn('u2'), isNull);
      await device.forget('u1');
      expect(await device.savedSignIn('u1'), isNull);
    });

    test('keeps nothing when Sony gave no refresh token, and lets a lapsed one go', () async {
      await device.saveSignIn('u1', signedIn(refresh: null));
      expect(await device.savedSignIn('u1'), isNull);
      await device.saveSignIn('u1', signedIn(lasts: const Duration(days: 1)));
      expect(await device.savedSignIn('u1'), 'refresh-1');
      now = now.add(const Duration(days: 2));
      expect(await device.savedSignIn('u1'), isNull);
    });

    test('the sign-in is in the encrypted store, not in the plain preferences', () async {
      await device.saveSignIn('u1', signedIn());
      expect((await SharedPreferences.getInstance()).getKeys().where((k) => k.contains('sign_in')), isEmpty);
      expect(await const FlutterSecureStorage().readAll(), isNotEmpty);
    });

    test('allows a sync a day, counting from the last, and forgetting the sign-in is no way round it', () async {
      const day = Duration(hours: 24);
      expect(await device.waitFor('u1', day), isNull);
      await device.markSynced('u1');
      now = now.add(const Duration(hours: 5));
      expect((await device.waitFor('u1', day))!.inHours, 19);
      await device.forget('u1');
      expect(await device.waitFor('u1', day), isNotNull);
      expect(await device.waitFor('u2', day), isNull);
      now = now.add(const Duration(hours: 19));
      expect(await device.waitFor('u1', day), isNull);
      // No limit at all: a debug build, or one built for it.
      await device.markSynced('u1');
      expect(await device.waitFor('u1', Duration.zero), isNull);
    });

    test('remembers which lists are stored, and that is lost with the sign-in', () async {
      await device.rememberList('u1', 'A', PsnDevice.listMark(3, 10));
      await device.rememberList('u1', 'B', PsnDevice.listMark(1, 2));
      expect(await device.storedLists('u1'), {'A': '3/10', 'B': '1/2'});
      expect(await device.storedLists('u2'), isEmpty);
      await device.forget('u1');
      expect(await device.storedLists('u1'), isEmpty);
    });

    test('forgetting everything also forgets the sync time', () async {
      await device.markSynced('u1');
      await device.forgetAll('u1');
      expect(await device.lastSync('u1'), isNull);
    });
  });

  group('the sync screen', () {
    late PsnDevice device;
    late FakeRepository repo;
    late AppStores stores;

    setUp(() async {
      repo = FakeRepository();
      stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      device = PsnDevice();
    });

    http.Response sony(http.Request request, {int refreshStatus = 200}) {
      if (request.url.host == 'ca.account.sony.com') {
        return refreshStatus == 200
            ? json({'access_token': 'tok', 'refresh_token': 'rotated', 'refresh_token_expires_in': 5184000})
            : json({'error': 'invalid_grant'}, refreshStatus);
      }
      if (request.url.path.contains('/trophyTitles')) {
        return json({
          'trophyTitles': [
            {
              'trophyTitleName': 'Hades',
              'npCommunicationId': 'NPWR1_00',
              'npServiceName': 'trophy2',
              'trophyTitlePlatform': 'PS5',
              'definedTrophies': {'bronze': 1, 'silver': 0, 'gold': 0, 'platinum': 0},
              'earnedTrophies': {'bronze': 1, 'silver': 0, 'gold': 0, 'platinum': 0},
              'lastUpdatedDateTime': '2026-10-01T10:00:00Z',
            },
          ],
        });
      }
      if (request.url.path.contains('/npCommunicationIds/')) {
        return request.url.path.contains('/users/me/')
            ? json({'trophies': [mine(0, earned: true)]})
            : json({'trophies': [titleTrophy(0, 'bronze', 'First')]});
      }
      return json({'titles': <Object>[]});
    }

    ImportFile? result;
    var closed = false;
    var signInPageShown = false;

    Future<void> open(WidgetTester tester, PsnClient client, {String? saved}) async {
      result = null;
      closed = false;
      signInPageShown = false;
      await tester.runAsync(stores.initialize);
      addTearDown(stores.dispose);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<ImportFile>(
                      MaterialPageRoute(
                        builder: (_) => PsnImportScreen(
                          client: client,
                          savedSignIn: saved,
                          device: device,
                          userId: 'u1',
                          signInBuilder: (context, uri, onRedirect, onFailed) {
                            signInPageShown = true;
                            return const Text('Sony page');
                          },
                        ),
                      ),
                    );
                    closed = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }

    testWidgets('a saved sign-in skips Sony\'s page, reads the games and their trophy lists, and keeps the new sign-in', (tester) async {
      await open(tester, clientWith(sony), saved: 'old-refresh');
      expect(signInPageShown, isFalse);
      expect(closed, isTrue);
      final row = result!.rows.single;
      expect((row.title, row.trophyList!.single.name, row.trophySet), ('Hades', 'First', 'NPWR1_00'));
      expect(await tester.runAsync(() => device.savedSignIn('u1')), 'rotated');
      expect(await tester.runAsync(() => device.lastSync('u1')), isNotNull);
      // The phone is told which lists were stored once the import saved them.
      result!.onRowImported!(row);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(await tester.runAsync(() => device.storedLists('u1')), {'NPWR1_00': '1/1'});
    });

    testWidgets('a saved sign-in Sony turns down is forgotten, and the page opens instead', (tester) async {
      await tester.runAsync(() => device.saveSignIn('u1', const PsnTokens(accessToken: 'a', refreshToken: 'old-refresh')));
      await open(tester, clientWith((r) => sony(r, refreshStatus: 400)), saved: 'old-refresh');
      expect(signInPageShown, isTrue);
      expect(find.text('Sony page'), findsOneWidget);
      expect(closed, isFalse);
      expect(await tester.runAsync(() => device.savedSignIn('u1')), isNull);
    });

    testWidgets('a trophy list already stored at this progress is not read again', (tester) async {
      await tester.runAsync(() => device.rememberList('u1', 'NPWR1_00', PsnDevice.listMark(1, 1)));
      var listReads = 0;
      await open(
        tester,
        clientWith((r) {
          if (r.url.path.contains('/npCommunicationIds/')) listReads++;
          return sony(r);
        }),
        saved: 'old-refresh',
      );
      expect(listReads, 0);
      expect(result!.rows.single.trophyList, isNull);
      expect(result!.rows.single.trophiesEarned, 1);
    });
  });

  group('the daily limit', () {
    testWidgets('a second sync the same day is turned away before Sony is asked, in words', (tester) async {
      final stores = AppStores(repository: FakeRepository(), authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      await tester.runAsync(stores.initialize);
      addTearDown(stores.dispose);
      final device = PsnDevice(now: () => DateTime.now());
      await tester.runAsync(() => device.markSynced('u1'));
      var built = 0;
      ImportFile? result;
      var returned = false;
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await readPlayStationLibrary(
                      context,
                      device: device,
                      userId: 'u1',
                      cooldown: const Duration(hours: 24),
                      makeClient: () {
                        built++;
                        return clientWith((_) => json({}));
                      },
                    );
                    returned = true;
                  },
                  child: const Text('sync'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('sync'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(result, isNull);
      expect(built, 0);
      expect(find.textContaining('You already synced PlayStation. You can sync again in about 24 h.'), findsOneWidget);
    });

    testWidgets('with no limit (a debug build) the dialog opens at once, and a saved sign-in can be forgotten from it', (tester) async {
      final stores = AppStores(repository: FakeRepository(), authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      await tester.runAsync(stores.initialize);
      addTearDown(stores.dispose);
      final device = PsnDevice();
      await tester.runAsync(() async {
        await device.markSynced('u1');
        await device.saveSignIn('u1', const PsnTokens(accessToken: 'a', refreshToken: 'r'));
      });
      Future<void> run(Future<void> Function() tapDialog) async {
        await tester.pumpWidget(
          AppStoresScope(
            stores: stores,
            child: MaterialApp(
              theme: buildTheme(),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => readPlayStationLibrary(context, device: device, userId: 'u1', cooldown: Duration.zero),
                    child: const Text('sync'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('sync'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        await tapDialog();
      }

      await run(() async {
        expect(find.text('Sync with PlayStation'), findsOneWidget);
        expect(find.textContaining('You are signed in to PlayStation on this phone'), findsOneWidget);
        await tester.tap(find.text('Forget sign-in'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
      });
      expect(find.text('PlayStation sign-in removed from this phone.'), findsOneWidget);
      expect(await tester.runAsync(() => device.savedSignIn('u1')), isNull);
      // The day's sync is still counted.
      expect(await tester.runAsync(() => device.lastSync('u1')), isNotNull);
    });
  });

  group('the trophy list of a game', () {
    late FakeRepository repo;
    late AppStores stores;

    final list = [
      Trophy(id: 0, grade: TrophyGrade.platinum, name: 'The Platinum', detail: 'Get them all'),
      Trophy(id: 1, grade: TrophyGrade.gold, name: 'Escape', detail: 'Leave the House', earned: true, earnedAt: DateTime(2026, 3, 4), rarity: 1, earnedRate: 2.5),
      Trophy(id: 2, grade: TrophyGrade.bronze, name: 'Warm up', detail: 'Win once', earned: true, earnedAt: DateTime(2026, 5, 6)),
      Trophy(id: 3, grade: TrophyGrade.silver, name: 'Real secret name', detail: 'Real secret task', hidden: true),
      Trophy(id: 4, grade: TrophyGrade.silver, name: 'Revealed secret', detail: 'Now known', hidden: true, earned: true, earnedAt: DateTime(2026, 1, 1)),
    ];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repo = FakeRepository();
      stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
    });

    Future<void> openDialog(WidgetTester tester, {String userId = 'u1', bool own = true}) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showGameTrophiesDialog(context, userId: userId, gameId: 'g1', title: 'Hades', own: own),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the progress, the grades, and every trophy with what it asks for', (tester) async {
      repo.gameTrophies[('u1', 'g1')] = list;
      await openDialog(tester);
      expect(find.text('Hades'), findsOneWidget);
      expect(find.text('3'), findsOneWidget); // earned
      expect(find.text('/ 5'), findsOneWidget);
      expect(find.text('Escape'), findsOneWidget);
      expect(find.text('Leave the House'), findsOneWidget);
      expect(find.textContaining('Very rare'), findsOneWidget);
      expect(find.textContaining('2.5% of players'), findsOneWidget);
      expect(find.text('The Platinum'), findsOneWidget);
      expect(find.text('Get them all'), findsOneWidget);
    });

    testWidgets('a secret trophy keeps its name and task until it is earned', (tester) async {
      repo.gameTrophies[('u1', 'g1')] = list;
      await openDialog(tester);
      expect(find.text('Real secret name'), findsNothing);
      expect(find.text('Real secret task'), findsNothing);
      expect(find.text('Secret trophy'), findsOneWidget);
      expect(find.text('Revealed secret'), findsOneWidget);
    });

    testWidgets('earned ones come first, the newest first, and the filter splits them', (tester) async {
      repo.gameTrophies[('u1', 'g1')] = list;
      await openDialog(tester);
      final names = ['Warm up', 'Escape', 'Revealed secret', 'The Platinum'];
      final tops = [for (final n in names) tester.getTopLeft(find.text(n)).dy];
      expect(tops, orderedEquals([...tops]..sort()));

      await tester.tap(find.text('Locked 2'));
      await tester.pumpAndSettle();
      expect(find.text('Escape'), findsNothing);
      expect(find.text('The Platinum'), findsOneWidget);
      await tester.tap(find.text('Unlocked 3'));
      await tester.pumpAndSettle();
      expect(find.text('Escape'), findsOneWidget);
      expect(find.text('The Platinum'), findsNothing);
    });

    testWidgets('your own list says how to fill it when there is none', (tester) async {
      await openDialog(tester);
      expect(find.textContaining('No trophy list for this game yet'), findsOneWidget);
    });

    testWidgets('another member\'s says only that there is nothing to show', (tester) async {
      await openDialog(tester, userId: 'm1', own: false);
      expect(find.text('No trophies to show for this game.'), findsOneWidget);
    });

    testWidgets('a failed read says so and can be tried again; your own are read again each time', (tester) async {
      repo.failTrophyReads = true;
      await openDialog(tester);
      expect(find.text('Could not load the trophies. Try again.'), findsOneWidget);
      repo.failTrophyReads = false;
      repo.gameTrophies[('u1', 'g1')] = list;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Escape'), findsOneWidget);
      final reads = repo.memberReads.where((r) => r == 'trophies:u1:g1').length;
      await tester.tap(find.byTooltip('Refresh trophies'));
      await tester.pumpAndSettle();
      expect(repo.memberReads.where((r) => r == 'trophies:u1:g1').length, reads + 1);
    });
  });

  group('storing the lists', () {
    late FakeRepository repo;
    late AppStores stores;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repo = FakeRepository();
      stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      await stores.initialize();
    });
    tearDown(() => stores.dispose());

    ImportRow row({List<Trophy>? list, String? set}) =>
        ImportRow(line: 1, title: 'Celeste', trophiesEarned: 1, trophiesTotal: 2, trophyList: list, trophySet: set);

    const celeste = [Trophy(id: 0, grade: TrophyGrade.bronze, name: 'First', earned: true), Trophy(id: 1, grade: TrophyGrade.gold, name: 'Last')];

    test('the import stores the list after the game, and tells the phone only then', () async {
      final told = <String?>[];
      final api = _Api({'celeste': [testGame(gameIdForIgdb(20), title: 'Celeste', status: null, igdbId: 20, cover: false)]});
      final run = LibraryImport(
        rows: [row(list: celeste, set: 'NPWR1')],
        api: api,
        library: stores.library,
        pause: Duration.zero,
        onRowImported: (r) => told.add(r.trophySet),
      );
      await run.run();
      expect(repo.savedTrophies[gameIdForIgdb(20)], celeste);
      expect(repo.trophiesSent[gameIdForIgdb(20)], (1, 2));
      expect(told, ['NPWR1']);
    });

    test('a list the server did not keep is not marked as stored, so the next sync reads it again', () async {
      quiet();
      repo.trophySaveRefused = true;
      final told = <String?>[];
      final run = LibraryImport(
        rows: [row(list: celeste, set: 'NPWR1')],
        api: _Api({'celeste': [testGame(gameIdForIgdb(20), title: 'Celeste', status: null, igdbId: 20, cover: false)]}),
        library: stores.library,
        pause: Duration.zero,
        onRowImported: (r) => told.add(r.trophySet),
      );
      await run.run();
      expect(told, isEmpty);
      expect(run.imported, 1);
    });

    test('a row with no list stores none, and is told to the phone all the same', () async {
      final told = <String?>[];
      final run = LibraryImport(
        rows: [row()],
        api: _Api({'celeste': [testGame(gameIdForIgdb(20), title: 'Celeste', status: null, igdbId: 20, cover: false)]}),
        library: stores.library,
        pause: Duration.zero,
        onRowImported: (r) => told.add(r.trophySet),
      );
      await run.run();
      expect(repo.savedTrophies, isEmpty);
      expect(told, [null]);
    });

    test('signing out forgets the saved sign-in of that account', () async {
      final device = PsnDevice();
      await device.saveSignIn('u1', const PsnTokens(accessToken: 'a', refreshToken: 'r'));
      await device.saveSignIn('u2', const PsnTokens(accessToken: 'a', refreshToken: 'r2'));
      stores.auth.onLogOut!('u1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await device.savedSignIn('u1'), isNull);
      expect(await device.savedSignIn('u2'), 'r2');
    });
  });

  gameOnDemandTests();
}


void gameOnDemandTests() {
  const meta = TrophyMeta(
    set: 'NPWR1_00',
    service: 'trophy2',
    earned: TrophyCounts(bronze: 1, gold: 1),
    total: TrophyCounts(bronze: 2, gold: 1, platinum: 1),
  );
  const stale = [
    Trophy(id: 0, grade: TrophyGrade.platinum, name: 'The Platinum'),
    Trophy(id: 1, grade: TrophyGrade.gold, name: 'Escape', earned: true),
    Trophy(id: 2, grade: TrophyGrade.bronze, name: 'Warm up'),
    Trophy(id: 3, grade: TrophyGrade.bronze, name: 'Second'),
  ];
  final current = [
    stale[0],
    stale[1],
    const Trophy(id: 2, grade: TrophyGrade.bronze, name: 'Warm up', earned: true),
    stale[3],
  ];

  group('a game opened before its list was read', () {
    late FakeRepository repo;
    late AppStores stores;
    var loads = 0;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      repo = FakeRepository();
      stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      loads = 0;
    });

    Future<void> openDialog(WidgetTester tester, {bool own = true, TrophyListLoader? loader, String userId = 'u1'}) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showGameTrophiesDialog(context, userId: userId, gameId: 'g1', title: 'Hades', own: own, loadFromPlayStation: loader),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    TrophyListLoader loader() => (context, m) async {
      loads++;
      repo.gameTrophies[('u1', 'g1')] = current;
      return current;
    };

    testWidgets('offers to read the list, reads it on a tap and shows it', (tester) async {
      repo.savedTrophyMeta['g1'] = meta;
      await openDialog(tester, loader: loader());
      expect(find.text("This game's trophy list has not been read from PlayStation yet."), findsOneWidget);
      expect(find.text('Load from PlayStation'), findsOneWidget);
      expect(find.textContaining('No trophy list for this game yet'), findsNothing);
      expect(loads, 0);

      await tester.tap(find.text('Load from PlayStation'));
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.text('Warm up'), findsOneWidget);
      expect(find.text('Load from PlayStation'), findsNothing);
    });

    testWidgets('a list that is behind says so and offers the same', (tester) async {
      repo.savedTrophyMeta['g1'] = meta;
      repo.gameTrophies[('u1', 'g1')] = stale;
      await openDialog(tester, loader: loader());
      expect(find.text('You earned trophies since this list was read.'), findsOneWidget);
      expect(find.text('Escape'), findsOneWidget);
      await tester.tap(find.text('Load from PlayStation'));
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(find.text('You earned trophies since this list was read.'), findsNothing);
    });

    testWidgets('a list that is current has no button', (tester) async {
      repo.savedTrophyMeta['g1'] = meta;
      repo.gameTrophies[('u1', 'g1')] = current;
      await openDialog(tester, loader: loader());
      expect(find.text('Escape'), findsOneWidget);
      expect(find.text('Load from PlayStation'), findsNothing);
    });

    testWidgets('backing out of the sign-in changes nothing', (tester) async {
      repo.savedTrophyMeta['g1'] = meta;
      await openDialog(tester, loader: (context, m) async => null);
      await tester.tap(find.text('Load from PlayStation'));
      await tester.pumpAndSettle();
      expect(find.text('Load from PlayStation'), findsOneWidget);
    });

    testWidgets('no button where the import is not offered, for a game with no set, or on another member\'s list', (tester) async {
      repo.savedTrophyMeta['g1'] = meta;
      await openDialog(tester);
      expect(find.text('Load from PlayStation'), findsNothing);
      expect(find.textContaining('No trophy list for this game yet'), findsOneWidget);
    });

    testWidgets('a game the sync gave no set for keeps the old message', (tester) async {
      await openDialog(tester, loader: loader());
      expect(find.text('Load from PlayStation'), findsNothing);
      expect(find.textContaining('No trophy list for this game yet'), findsOneWidget);
    });

    testWidgets('another member\'s dialog never offers it', (tester) async {
      repo.savedTrophyMeta['g1'] = meta;
      await openDialog(tester, own: false, userId: 'm1', loader: loader());
      expect(find.text('Load from PlayStation'), findsNothing);
    });
  });

  group('the load itself', () {
    late FakeRepository repo;
    late AppStores stores;
    late PsnDevice device;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      repo = FakeRepository();
      stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      device = PsnDevice();
    });

    http.Response sony(http.Request r, {int refresh = 200}) {
      if (r.url.host == 'ca.account.sony.com') {
        return refresh == 200 ? json({'access_token': 'tok', 'refresh_token': 'next', 'refresh_token_expires_in': 5184000}) : json({'error': 'invalid_grant'}, refresh);
      }
      expect(r.url.queryParameters['npServiceName'], 'trophy2');
      return r.url.path.contains('/users/me/')
          ? json({'trophies': [mine(0, earned: true)]})
          : json({'trophies': [titleTrophy(0, 'bronze', 'First')]});
    }

    Future<List<Trophy>?> run(WidgetTester tester, PsnClient client, {bool signedIn = true, bool tapContinue = false}) async {
      List<Trophy>? result;
      var returned = false;
      await tester.runAsync(stores.initialize);
      addTearDown(stores.dispose);
      if (signedIn) await tester.runAsync(() => device.saveSignIn('u1', const PsnTokens(accessToken: 'a', refreshToken: 'saved')));
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await loadTrophyListFromPlayStation(
                      context,
                      gameId: 'g1',
                      meta: const TrophyMeta(set: 'NPWR1_00', service: 'trophy2', earned: TrophyCounts(bronze: 1), total: TrophyCounts(bronze: 1)),
                      device: device,
                      userId: 'u1',
                      makeClient: () => client,
                      signInBuilder: (context, uri, onRedirect, onFailed) => const Text('Sony page'),
                    );
                    returned = true;
                  },
                  child: const Text('load'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('load'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      if (tapContinue) {
        await tester.tap(find.text('I understand, sign in'));
        await tester.pumpAndSettle();
      }
      if (!returned && !tapContinue && signedIn) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('with a saved sign-in it reads, stores and notes the list, with no question and no sync counted', (tester) async {
      final client = clientWith(sony);
      final list = await run(tester, client);
      expect(list!.single.name, 'First');
      expect(repo.savedTrophies['g1']!.single.name, 'First');
      expect(await tester.runAsync(() => device.storedLists('u1')), {'NPWR1_00': '1/1'});
      expect(await tester.runAsync(() => device.lastSync('u1')), isNull);
      expect(await tester.runAsync(() => device.savedSignIn('u1')), 'next');
      // Two requests for the game, one for the sign-in.
      expect(client.traffic.requests, 3);
      expect(client.traffic.statuses, {200: 3});
    });

    testWidgets('with no saved sign-in it says what this is first, then opens Sony\'s page', (tester) async {
      final client = clientWith(sony);
      final list = await run(tester, client, signedIn: false, tapContinue: true);
      expect(list, isNull); // still on Sony's page: nobody signed in
      expect(find.text('Sony page'), findsOneWidget);
      expect(client.traffic.requests, 0);
    });

    testWidgets('a sign-in Sony turns down is forgotten and the page opens', (tester) async {
      final client = clientWith((r) => sony(r, refresh: 400));
      await run(tester, client);
      expect(find.text('Sony page'), findsOneWidget);
      expect(await tester.runAsync(() => device.savedSignIn('u1')), isNull);
      expect(repo.savedTrophies, isEmpty);
    });

    testWidgets('a list the server did not keep is not noted, so it is read again', (tester) async {
      repo.trophySaveRefused = true;
      final list = await run(tester, clientWith(sony));
      expect(list, isNotNull);
      expect(await tester.runAsync(() => device.storedLists('u1')), isEmpty);
    });
  });

  group('connecting PlayStation', () {
    late FakeRepository repo;
    late AppStores stores;
    late PsnDevice device;
    late void Function(String url) redirect;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      repo = FakeRepository();
      stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      device = PsnDevice();
    });

    Future<bool?> run(WidgetTester tester, PsnClient client, {required Future<void> Function() onSonyPage}) async {
      bool? result;
      await tester.runAsync(stores.initialize);
      addTearDown(stores.dispose);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await connectPlayStation(
                      context,
                      device: device,
                      userId: 'u1',
                      makeClient: () => client,
                      signInBuilder: (context, uri, onRedirect, onFailed) {
                        redirect = onRedirect;
                        return const Text('Sony page');
                      },
                    );
                  },
                  child: const Text('connect'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('connect'));
      await tester.pumpAndSettle();
      await onSonyPage();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('says what this is, opens Sony\'s page, keeps the sign-in and reads nothing', (tester) async {
      var requests = <String>[];
      final client = clientWith((r) {
        requests.add(r.url.host);
        return json({'access_token': 'tok', 'refresh_token': 'kept', 'refresh_token_expires_in': 5184000});
      });
      final result = await run(tester, client, onSonyPage: () async {
        expect(find.text('Import from PlayStation'), findsOneWidget);
        await tester.tap(find.text('I understand, sign in'));
        await tester.pumpAndSettle();
        expect(find.text('Sony page'), findsOneWidget);
        redirect('com.scee.psxandroid.scecompcall://redirect/?code=v3.abc');
      });
      expect(result, isTrue);
      expect(await tester.runAsync(() => device.savedSignIn('u1')), 'kept');
      // The sign-in, and nothing from the member's lists; no sync is counted.
      expect(requests, ['ca.account.sony.com']);
      expect(await tester.runAsync(() => device.lastSync('u1')), isNull);
    });

    testWidgets('backing out at the notice connects nothing', (tester) async {
      final client = clientWith((_) => json({}));
      final result = await run(tester, client, onSonyPage: () async {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      });
      expect(result, isFalse);
      expect(await tester.runAsync(() => device.savedSignIn('u1')), isNull);
    });

    testWidgets('a sign-in Sony refuses connects nothing', (tester) async {
      final client = clientWith((_) => json({'error': 'invalid_grant'}, 400));
      await run(tester, client, onSonyPage: () async {
        await tester.tap(find.text('I understand, sign in'));
        await tester.pumpAndSettle();
        redirect('com.scee.psxandroid.scecompcall://redirect/?code=bad');
      });
      expect(find.text('PlayStation did not accept the sign-in. Try again.'), findsOneWidget);
      expect(await tester.runAsync(() => device.savedSignIn('u1')), isNull);
    });
  });

  group('the counts of every game', () {
    test('the overview gives the set and the counts by grade', () async {
      final client = clientWith((_) => json({
        'trophyTitles': [
          {
            'trophyTitleName': 'Hades',
            'npCommunicationId': 'NPWR9_00',
            'npServiceName': 'trophy2',
            'trophyTitlePlatform': 'PS5',
            'definedTrophies': {'bronze': 10, 'silver': 4, 'gold': 2, 'platinum': 1},
            'earnedTrophies': {'bronze': 7, 'silver': 1, 'gold': 0, 'platinum': 0},
            'lastUpdatedDateTime': '2026-10-01T10:00:00Z',
          },
        ],
      }));
      final title = (await client.trophyTitles(const PsnTokens(accessToken: 't'))).single;
      expect((title.npCommunicationId, title.npServiceName), ('NPWR9_00', 'trophy2'));
      expect(title.earnedByGrade, const TrophyCounts(bronze: 7, silver: 1));
      expect(title.definedByGrade, const TrophyCounts(bronze: 10, silver: 4, gold: 2, platinum: 1));
      expect((title.earned, title.total), (8, 17));
    });

    test('every game with a set gets its counts on its row, whether or not its list was read', () {
      final withSet = PsnTrophyTitle(
        name: 'Hades',
        platform: 'PS5',
        earned: 3,
        total: 5,
        platinumEarned: false,
        lastUpdated: DateTime.utc(2026, 10, 1),
        npCommunicationId: 'NPWR9_00',
        npServiceName: 'trophy2',
        earnedByGrade: const TrophyCounts(bronze: 3),
        definedByGrade: const TrophyCounts(bronze: 4, platinum: 1),
      );
      final row = buildPsnImport(PsnLibrary(trophies: [withSet, set('No grades', id: 'X'), set('No id', id: '')])).rows.firstWhere((r) => r.title == 'Hades');
      expect(row.trophyList, isNull);
      expect(row.trophyMeta!.set, 'NPWR9_00');
      expect(row.trophyMeta!.service, 'trophy2');
      expect(row.trophyMeta!.earned, const TrophyCounts(bronze: 3));
      expect(row.trophyMeta!.total.total, 5);
      final others = buildPsnImport(PsnLibrary(trophies: [set('No grades', id: 'X'), set('No id', id: '')])).rows;
      expect(others.map((r) => r.trophyMeta), [null, null]);
    });

    test('the meta is stored as short lists, read back, and refused when it is not that shape', () {
      const meta = TrophyMeta(set: 'NPWR9_00', service: 'trophy2', earned: TrophyCounts(bronze: 7, silver: 1), total: TrophyCounts(bronze: 10, silver: 4, gold: 2, platinum: 1));
      expect(meta.toJson(), {'s': 'NPWR9_00', 'v': 'trophy2', 'e': [7, 1, 0, 0], 't': [10, 4, 2, 1]});
      final back = TrophyMeta.fromJson(jsonDecode(jsonEncode(meta.toJson())));
      expect((back!.set, back.earned, back.total), ('NPWR9_00', meta.earned, meta.total));
      for (final bad in [null, 'x', {'s': 'a', 'v': 't', 'e': [1, 2, 3], 't': [1, 2, 3, 4]}, {'s': '', 'v': 't', 'e': [0, 0, 0, 0], 't': [0, 0, 0, 0]}, {'s': 'a', 'v': 't', 'e': [-1, 0, 0, 0], 't': [0, 0, 0, 0]}, {'s': 'a', 'v': 't', 'e': [1.5, 0, 0, 0], 't': [0, 0, 0, 0]}]) {
        expect(TrophyMeta.fromJson(bad), isNull, reason: '$bad');
      }
    });

    test('the import stores the counts of a game with no list, and the store reads them back', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = FakeRepository();
      final stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      await stores.initialize();
      addTearDown(stores.dispose);
      const meta = TrophyMeta(set: 'NPWR1_00', service: 'trophy', earned: TrophyCounts(bronze: 1), total: TrophyCounts(bronze: 2));
      final told = <String?>[];
      final run = LibraryImport(
        rows: const [ImportRow(line: 1, title: 'Celeste', trophiesEarned: 1, trophiesTotal: 2, trophyMeta: meta)],
        api: _Api({'celeste': [testGame(gameIdForIgdb(20), title: 'Celeste', status: null, igdbId: 20, cover: false)]}),
        library: stores.library,
        pause: Duration.zero,
        onRowImported: (r) => told.add(r.title),
      );
      await run.run();
      expect(repo.savedTrophyMeta[gameIdForIgdb(20)], meta);
      expect(repo.savedTrophies, isEmpty);
      expect(told, ['Celeste']);
      await stores.publicTrophies.loadMeta('u1', gameIdForIgdb(20));
      expect(stores.publicTrophies.metaOf('u1', gameIdForIgdb(20))!.set, 'NPWR1_00');
      expect(stores.publicTrophies.metaOf('u1', 'other'), isNull);
    });
  });

  group('what the client counted', () {
    test('requests, bytes and statuses, for the debug log', () async {
      final client = clientWith((r) => r.url.path.contains('trophyTitles') ? json({'trophyTitles': <Object>[]}) : json({}, 429));
      await client.trophyTitles(const PsnTokens(accessToken: 't'));
      await expectLater(client.playedGames(const PsnTokens(accessToken: 't')), throwsA(isA<PsnException>()));
      expect(client.traffic.requests, 2);
      expect(client.traffic.statuses, {200: 1, 429: 1});
      expect(client.traffic.bytesReceived, greaterThan(0));
      expect(client.traffic.describe(), startsWith('2 requests, '));
    });
  });
}

/// IGDB search answered from a list by exact query (lower case); other queries find nothing.
class _Api extends GameApiService {
  _Api(this.answers);
  final Map<String, List<Game>> answers;
  final List<String> searched = [];

  @override
  Future<ResultsPage<Game>?> searchGames(String query, {FilterOptions filters = FilterOptions.none, int offset = 0, int limit = 20}) async {
    searched.add(query.toLowerCase());
    return ResultsPage(answers[query.toLowerCase()] ?? const [], hasMore: false);
  }
}
