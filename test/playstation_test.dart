import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/library_csv.dart';
import 'package:checkpoint/screens/settings/data_section.dart';
import 'package:checkpoint/screens/settings/psn_import.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/services/playstation/psn_client.dart';
import 'package:checkpoint/services/playstation/psn_library.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// The import from PlayStation, against made-up answers: nothing here talks to
/// Sony, and none of it proves the real service still answers this way.

/// A sign-in credential of the shape the build is given: `id:secret` in base64.
String basic([String id = 'client-id', String secret = 'client-secret']) =>
    base64.encode(utf8.encode('$id:$secret'));

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> trophyTitle(
  String name, {
  String platform = 'PS5',
  List<int> earned = const [0, 0, 0, 0],
  List<int> defined = const [10, 5, 2, 1],
  String updated = '2026-10-01T10:00:00Z',
}) => {
  'trophyTitleName': name,
  'trophyTitlePlatform': platform,
  'definedTrophies': {'bronze': defined[0], 'silver': defined[1], 'gold': defined[2], 'platinum': defined[3]},
  'earnedTrophies': {'bronze': earned[0], 'silver': earned[1], 'gold': earned[2], 'platinum': earned[3]},
  'lastUpdatedDateTime': updated,
};

Map<String, dynamic> played(String name, String duration, {String category = 'ps5_native_game', String last = '2026-10-02T10:00:00Z'}) => {
  'name': name,
  'category': category,
  'playDuration': duration,
  'lastPlayedDateTime': last,
};

void _quiet() {
  final print = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {};
  addTearDown(() => debugPrint = print);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('durations', () {
    test('are read the way Sony writes them', () {
      expect(parseIsoDuration('PT228H56M33S'), const Duration(hours: 228, minutes: 56, seconds: 33));
      expect(parseIsoDuration('PT45M'), const Duration(minutes: 45));
      expect(parseIsoDuration('PT12.5S'), const Duration(milliseconds: 12500));
      expect(parseIsoDuration('P1DT2H'), const Duration(days: 1, hours: 2));
      expect(parseIsoDuration('PT0S'), Duration.zero);
    });

    test('are zero for anything else', () {
      expect(parseIsoDuration(null), Duration.zero);
      expect(parseIsoDuration(''), Duration.zero);
      expect(parseIsoDuration('soon'), Duration.zero);
      expect(parseIsoDuration(42), Duration.zero);
    });
  });

  group('the client', () {
    test('needs a credential of the shape id:secret in base64', () {
      for (final bad in ['', '   ', 'not base64!!', base64.encode(utf8.encode('no-colon')), base64.encode(utf8.encode(':secret'))]) {
        expect(
          () => PsnClient(pace: Duration.zero, clientBasic: bad),
          throwsA(isA<PsnException>().having((e) => e.failure, 'failure', PsnFailure.notConfigured)),
          reason: '"$bad"',
        );
      }
      expect(PsnClient(pace: Duration.zero, clientBasic: basic()).clientId, 'client-id');
    });

    test('sends the member to Sony\'s sign-in, which ends at the phone app\'s link', () {
      final uri = PsnClient(pace: Duration.zero, clientBasic: basic('abc', 'xyz')).signInUri;
      expect(uri.host, 'ca.account.sony.com');
      expect(uri.path, '/api/authz/v3/oauth/authorize');
      expect(uri.queryParameters['client_id'], 'abc');
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['redirect_uri'], 'com.scee.psxandroid.scecompcall://redirect');
      expect(uri.queryParameters['scope'], 'psn:mobile.v2.core psn:clientapp');
      expect(uri.queryParameters['access_type'], 'offline');
      // The secret is for the token request only.
      expect(uri.toString(), isNot(contains('xyz')));
    });

    test('tells where the sign-in ended, and reads its code', () {
      const end = 'com.scee.psxandroid.scecompcall://redirect';
      expect(PsnClient.isRedirect('$end/?code=v3.abc&cid=1'), isTrue);
      expect(PsnClient.isRedirect('$end?code=v3.abc'), isTrue);
      expect(PsnClient.isRedirect(end), isTrue);
      expect(PsnClient.isRedirect('https://my.account.sony.com/signin'), isFalse);
      expect(PsnClient.isRedirect('com.scee.psxandroid.scecompcall://redirected'), isFalse);

      expect(PsnClient.codeFromRedirect('$end/?code=v3.abc&cid=1'), 'v3.abc');
      expect(PsnClient.codeFromRedirect('$end/?error=access_denied'), isNull);
      expect(PsnClient.codeFromRedirect('$end/?code='), isNull);
      expect(PsnClient.codeFromRedirect('https://example.com/?code=x'), isNull);
    });

    test('swaps the code for an access token the way the phone app does', () async {
      late http.Request seen;
      final client = PsnClient(pace: Duration.zero, 
        clientBasic: basic(),
        client: MockClient((request) async {
          seen = request;
          return json({'access_token': 'tok', 'refresh_token': 'ref', 'expires_in': 3599});
        }),
      );
      final tokens = await client.exchangeCode('v3.abc');
      expect(tokens.accessToken, 'tok');
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://ca.account.sony.com/api/authz/v3/oauth/token');
      expect(seen.headers['Authorization'], 'Basic ${basic()}');
      expect(seen.bodyFields, {
        'code': 'v3.abc',
        'redirect_uri': 'com.scee.psxandroid.scecompcall://redirect',
        'grant_type': 'authorization_code',
        'token_format': 'jwt',
      });
    });

    test('says why a sign-in failed', () async {
      Future<PsnFailure?> failure(http.Response Function() answer) async {
        final client = PsnClient(pace: Duration.zero, clientBasic: basic(), client: MockClient((_) async => answer()));
        try {
          await client.exchangeCode('x');
          return null;
        } on PsnException catch (e) {
          return e.failure;
        }
      }

      expect(await failure(() => json({'error': 'invalid_grant'}, 400)), PsnFailure.signInRejected);
      expect(await failure(() => json({'nothing': true})), PsnFailure.signInRejected);
      expect(await failure(() => http.Response('<html>', 200)), PsnFailure.signInRejected);
      expect(await failure(() => json({}, 429)), PsnFailure.rateLimited);
      expect(await failure(() => json({}, 503)), PsnFailure.unavailable);

      final offline = PsnClient(pace: Duration.zero, clientBasic: basic(), client: MockClient((_) async => throw http.ClientException('offline')));
      await expectLater(
        offline.exchangeCode('x'),
        throwsA(isA<PsnException>().having((e) => e.failure, 'failure', PsnFailure.unavailable)),
      );
    });

    test('reads the whole play history, page by page, with the access token', () async {
      final requests = <Uri>[];
      final client = PsnClient(pace: Duration.zero, 
        clientBasic: basic(),
        client: MockClient((request) async {
          requests.add(request.url);
          expect(request.headers['Authorization'], 'Bearer tok');
          final offset = int.parse(request.url.queryParameters['offset']!);
          return offset == 0
              ? json({
                  'titles': [
                    played('Hades', 'PT10H30M'),
                    played('Celeste', 'PT3H', category: 'ps4_game', last: '2026-09-01T00:00:00Z'),
                  ],
                  'nextOffset': 2,
                  'totalItemCount': 3,
                })
              : json({
                  'titles': [played('Doom', 'PT1H', category: 'pspc_game')],
                  'totalItemCount': 3,
                });
        }),
      );
      final games = await client.playedGames(const PsnTokens(accessToken: 'tok'));
      expect([for (final g in games) g.name], ['Hades', 'Celeste', 'Doom']);
      expect(games.first.playTime, const Duration(hours: 10, minutes: 30));
      expect(games.first.lastPlayed, DateTime.utc(2026, 10, 2, 10));
      expect(requests.map((u) => u.path).toSet(), {'/api/gamelist/v2/users/me/titles'});
      expect(requests.map((u) => u.queryParameters['offset']), ['0', '2']);
    });

    test('adds up a trophy list: all grades, and whether the Platinum is earned', () async {
      final client = PsnClient(pace: Duration.zero, 
        clientBasic: basic(),
        client: MockClient((request) async {
          expect(request.url.path, '/api/trophy/v1/users/me/trophyTitles');
          return json({
            'trophyTitles': [
              trophyTitle('Hades', earned: [10, 5, 2, 1]),
              trophyTitle('Celeste', platform: 'PS4', earned: [3, 1, 0, 0], defined: [20, 4, 2, 1]),
              {'trophyTitleName': 'Broken'}, // no counts: left out
            ],
            'totalItemCount': 3,
          });
        }),
      );
      final titles = await client.trophyTitles(const PsnTokens(accessToken: 'tok'));
      expect(titles, hasLength(2));
      expect((titles[0].name, titles[0].earned, titles[0].total, titles[0].platinumEarned), ('Hades', 18, 18, true));
      expect((titles[1].name, titles[1].earned, titles[1].total, titles[1].platinumEarned, titles[1].platform), ('Celeste', 4, 27, false, 'PS4'));
    });

    test('stops at an account with no history, and at a page that repeats', () async {
      var calls = 0;
      final empty = PsnClient(pace: Duration.zero, clientBasic: basic(), client: MockClient((_) async => json({})));
      expect(await empty.playedGames(const PsnTokens(accessToken: 't')), isEmpty);
      expect(await empty.trophyTitles(const PsnTokens(accessToken: 't')), isEmpty);

      final stuck = PsnClient(pace: Duration.zero, 
        clientBasic: basic(),
        client: MockClient((_) async {
          calls++;
          // Always says the next page starts where this one did.
          return json({'titles': [played('Hades', 'PT1H')], 'nextOffset': 0});
        }),
      );
      expect(await stuck.playedGames(const PsnTokens(accessToken: 't')), hasLength(1));
      expect(calls, 1);
    });

    test('says why a list could not be read', () async {
      Future<PsnFailure?> failure(http.Response Function() answer) async {
        final client = PsnClient(pace: Duration.zero, clientBasic: basic(), client: MockClient((_) async => answer()));
        try {
          await client.trophyTitles(const PsnTokens(accessToken: 't'));
          return null;
        } on PsnException catch (e) {
          return e.failure;
        }
      }

      expect(await failure(() => json({}, 401)), PsnFailure.signInExpired);
      expect(await failure(() => json({}, 403)), PsnFailure.listNotShared);
      expect(await failure(() => json({}, 429)), PsnFailure.rateLimited);
      expect(await failure(() => json({}, 502)), PsnFailure.unavailable);
      expect(await failure(() => json({'error': {'message': 'no'}})), PsnFailure.unexpected);
      expect(await failure(() => json({'something': 'else'})), PsnFailure.unexpected);
      expect(await failure(() => http.Response('<html>', 200)), PsnFailure.unexpected);
      expect(await failure(() => json({'trophyTitles': []}, 404)), PsnFailure.unexpected);
    });

    test('every failure has words for the member', () {
      for (final f in PsnFailure.values) {
        expect(PsnException(f).message, isNotEmpty, reason: f.name);
      }
    });
  });

  group('the import', () {
    ImportFile build({List<PsnPlayedGame>? playedGames, List<PsnTrophyTitle>? trophies, PsnException? playedError, PsnException? trophyError}) =>
        buildPsnImport(PsnLibrary(played: playedGames, trophies: trophies, playedError: playedError, trophyError: trophyError));

    PsnPlayedGame pg(String name, {int hours = 0, int minutes = 0, String category = 'ps5_native_game', DateTime? last}) => PsnPlayedGame(
      name: name,
      category: category,
      playTime: Duration(hours: hours, minutes: minutes),
      lastPlayed: last ?? DateTime.utc(2026, 10, 1),
    );

    PsnTrophyTitle tt(String name, {String platform = 'PS5', int earned = 0, int total = 10, bool platinum = false, DateTime? updated}) => PsnTrophyTitle(
      name: name,
      platform: platform,
      earned: earned,
      total: total,
      platinumEarned: platinum,
      lastUpdated: updated ?? DateTime.utc(2026, 10, 1),
    );

    test('joins the play history and the trophy list on the name', () {
      final file = build(
        playedGames: [pg('Hades®', hours: 10, minutes: 30)],
        trophies: [tt('HADES™', earned: 4, total: 20)],
      );
      expect(file.source, ImportSource.playstation);
      expect(file.rows, hasLength(1));
      final row = file.rows.single;
      expect(row.title, 'Hades');
      expect(row.hours, 10.5);
      expect(row.trophiesEarned, 4);
      expect(row.trophiesTotal, 20);
      expect(row.status, GameStatus.playing);
      expect(row.playedOn, GamePlatform.ps5);
      expect(row.fillGapsOnly, isTrue);
      expect(row.perfected, isFalse);
    });

    test('keeps games only one list knows', () {
      final file = build(
        playedGames: [pg('Only Played', hours: 2)],
        trophies: [tt('Only In Trophy List', platform: 'PS3', earned: 1)],
      );
      final byTitle = {for (final r in file.rows) r.title: r};
      expect(byTitle['Only Played']!.trophiesTotal, isNull);
      expect(byTitle['Only Played']!.hours, 2);
      expect(byTitle['Only In Trophy List']!.hours, isNull);
      expect(byTitle['Only In Trophy List']!.playedOn, GamePlatform.ps3);
    });

    test('a Platinum or every trophy completes and perfects it; an unplayed title is only to play', () {
      final file = build(
        trophies: [
          tt('Platinum', earned: 10, total: 30, platinum: true),
          tt('Everything', earned: 12, total: 12),
          tt('Half', earned: 6, total: 12),
          tt('Synced', earned: 0, total: 12),
        ],
      );
      final byTitle = {for (final r in file.rows) r.title: r};
      expect(byTitle['Platinum']!.status, GameStatus.completed);
      expect(byTitle['Platinum']!.perfected, isTrue);
      expect(byTitle['Everything']!.status, GameStatus.completed);
      expect(byTitle['Everything']!.perfected, isTrue);
      expect(byTitle['Half']!.status, GameStatus.playing);
      expect(byTitle['Half']!.perfected, isFalse);
      expect(byTitle['Synced']!.status, GameStatus.toPlay);
      expect(byTitle['Synced']!.perfected, isFalse);
    });

    test('a title with no trophies has none to show, and none to complete', () {
      final row = build(trophies: [tt('Empty', earned: 0, total: 0)], playedGames: [pg('Empty', hours: 1)]).rows.single;
      expect(row.trophiesTotal, isNull);
      expect(row.trophiesEarned, isNull);
      expect(row.perfected, isFalse);
      expect(row.status, GameStatus.playing);
    });

    test('one game on two consoles is one row: hours added, newest console, furthest set', () {
      final file = build(
        playedGames: [
          pg('Hades', hours: 4, category: 'ps4_game'),
          pg('Hades', hours: 6, minutes: 30, category: 'ps5_native_game'),
        ],
        trophies: [
          tt('Hades', platform: 'PS4', earned: 8, total: 20),
          tt('Hades', platform: 'PS5', earned: 3, total: 24),
        ],
      );
      final row = file.rows.single;
      expect(row.hours, 10.5);
      expect(row.playedOn, GamePlatform.ps5);
      expect((row.trophiesEarned, row.trophiesTotal), (8, 20));
    });

    test('a set shared between consoles is played on the newest of them', () {
      final row = build(trophies: [tt('Shared', platform: 'PSVITA,PS4', earned: 1)]).rows.single;
      expect(row.playedOn, GamePlatform.ps4);
      expect(build(trophies: [tt('Handheld', platform: 'PSVITA', earned: 1)]).rows.single.playedOn, GamePlatform.vita);
      expect(build(playedGames: [pg('Pc', hours: 1, category: 'pspc_game')]).rows.single.playedOn, GamePlatform.pc);
      expect(build(playedGames: [pg('Unknown', hours: 1, category: 'unknown')]).rows.single.playedOn, isNull);
    });

    test('lists the most recently played first and numbers them', () {
      final file = build(
        playedGames: [
          pg('Old', hours: 1, last: DateTime.utc(2020)),
          pg('New', hours: 1, last: DateTime.utc(2026, 10)),
          pg('Middle', hours: 1, last: DateTime.utc(2024)),
        ],
      );
      expect([for (final r in file.rows) r.title], ['New', 'Middle', 'Old']);
      expect([for (final r in file.rows) r.line], [1, 2, 3]);
    });

    test('takes at most one import\'s worth and says how many were left', () {
      final file = build(
        playedGames: [
          for (var i = 0; i < ImportRow.maxRows + 7; i++) pg('Game $i', hours: 1, last: DateTime.utc(2026).subtract(Duration(days: i))),
        ],
      );
      expect(file.rows, hasLength(ImportRow.maxRows));
      expect(file.rows.first.title, 'Game 0');
      expect(file.skipped, hasLength(1));
      expect(file.skipped.single, contains('7'));
    });

    test('says which list Sony would not share', () {
      final noTrophies = build(playedGames: [pg('A', hours: 1)], trophyError: const PsnException(PsnFailure.listNotShared));
      expect(noTrophies.notes, hasLength(1));
      expect(noTrophies.notes.single, contains('trophy'));
      final noPlayTime = build(trophies: [tt('A', earned: 1)], playedError: const PsnException(PsnFailure.listNotShared));
      expect(noPlayTime.notes.single, contains('play time'));
      expect(build(playedGames: [pg('A', hours: 1)], trophies: [tt('A')]).notes, isEmpty);
    });

    test('a game with no hours reads as no hours, not zero', () {
      expect(build(playedGames: [pg('Zero')]).rows.single.hours, isNull);
      expect(build(playedGames: [pg('Short', minutes: 2)]).rows.single.hours, 0.0);
    });
  });

  group('reading both lists', () {
    PsnClient clientWith(http.Response Function(Uri url) answer) =>
        PsnClient(pace: Duration.zero, clientBasic: basic(), client: MockClient((request) async => answer(request.url)));

    const tokens = PsnTokens(accessToken: 'tok');

    http.Response ok(Uri url) => url.path.contains('trophy')
        ? json({'trophyTitles': [trophyTitle('Hades', earned: [1, 0, 0, 0])]})
        : json({'titles': [played('Hades', 'PT2H')]});

    test('gets both', () async {
      final library = await readPsnLibrary(clientWith(ok), tokens);
      expect(library.played, hasLength(1));
      expect(library.trophies, hasLength(1));
      expect(library.playedError, isNull);
      expect(library.trophyError, isNull);
    });

    test('goes on with one list when Sony will not share the other', () async {
      final noTrophies = await readPsnLibrary(clientWith((u) => u.path.contains('trophy') ? json({}, 403) : ok(u)), tokens);
      expect(noTrophies.trophies, isNull);
      expect(noTrophies.trophyError!.failure, PsnFailure.listNotShared);
      expect(noTrophies.played, hasLength(1));

      final noPlayTime = await readPsnLibrary(clientWith((u) => u.path.contains('trophy') ? ok(u) : json({}, 403)), tokens);
      expect(noPlayTime.played, isNull);
      expect(noPlayTime.playedError!.failure, PsnFailure.listNotShared);
      expect(noPlayTime.trophies, hasLength(1));
    });

    test('fails when neither can be read', () async {
      await expectLater(
        readPsnLibrary(clientWith((_) => json({}, 403)), tokens),
        throwsA(isA<PsnException>().having((e) => e.failure, 'failure', PsnFailure.listNotShared)),
      );
    });

    test('stops at once for an expired sign-in or a rate limit, instead of asking again', () async {
      for (final status in [401, 429]) {
        var calls = 0;
        await expectLater(
          readPsnLibrary(
            clientWith((_) {
              calls++;
              return json({}, status);
            }),
            tokens,
          ),
          throwsA(isA<PsnException>()),
        );
        expect(calls, 1, reason: '$status');
      }
    });
  });

  group('where it is offered', () {
    test('only with a client, on an Android phone or an iPhone', () {
      expect(psnImportAvailable(clientBasic: basic(), web: false, platform: TargetPlatform.android), isTrue);
      expect(psnImportAvailable(clientBasic: basic(), web: false, platform: TargetPlatform.iOS), isTrue);
      expect(psnImportAvailable(clientBasic: '', web: false, platform: TargetPlatform.android), isFalse);
      expect(psnImportAvailable(clientBasic: '  ', web: false, platform: TargetPlatform.android), isFalse);
      expect(psnImportAvailable(clientBasic: basic(), web: true, platform: TargetPlatform.android), isFalse);
      for (final p in [TargetPlatform.linux, TargetPlatform.windows, TargetPlatform.macOS]) {
        expect(psnImportAvailable(clientBasic: basic(), web: false, platform: p), isFalse, reason: p.name);
      }
    });

    test('a build without the define has none', () {
      // The test run passes no --dart-define=PSN_CLIENT_BASIC.
      expect(psnImportAvailable(web: false, platform: TargetPlatform.android), isFalse);
    });
  });

  group('trophies on a game', () {
    test('are kept by the offline cache and by every copy', () {
      final game = testGame('a').copyWith(trophiesEarned: 4, trophiesTotal: 20);
      expect(game.hasTrophies, isTrue);
      final back = Game.fromJson(game.toJson());
      expect((back.trophiesEarned, back.trophiesTotal), (4, 20));
      for (final copy in [
        game.copyWith(status: GameStatus.dropped),
        game.withCompletedAt(null),
        game.withBackdrop(null),
        game.withCompletionTime(null),
      ]) {
        expect((copy.trophiesEarned, copy.trophiesTotal), (4, 20));
      }
      expect(game.withoutUserState().hasTrophies, isFalse);
      // A copy saved before there were trophies reads as having none.
      final old = testGame('b').toJson()
        ..remove('trophiesEarned')
        ..remove('trophiesTotal');
      expect(Game.fromJson(old).hasTrophies, isFalse);
    });

    test('are shown only when the game has some', () {
      expect(testGame('a').hasTrophies, isFalse);
      expect(testGame('a').copyWith(trophiesEarned: 0, trophiesTotal: 0).hasTrophies, isFalse);
      expect(testGame('a').copyWith(trophiesEarned: 0, trophiesTotal: 5).hasTrophies, isTrue);
    });
  });

  group('into the library', () {
    late FakeRepository repo;
    late LocalCache cache;
    late AuthStore auth;
    late ProfileStore profile;
    late LibraryStore library;

    setUp(() async {
      _quiet();
      repo = FakeRepository()
        ..library = [
          testGame('dropped', status: GameStatus.dropped, hours: 5, playedOn: GamePlatform.pc),
          testGame('wish', status: GameStatus.wishlist, hours: 0),
        ];
      cache = LocalCache();
      auth = AuthStore(FakeAuthService(testUser('u1')));
      await auth.initialize();
      profile = ProfileStore(repository: repo, auth: auth, cache: cache);
      library = LibraryStore(repository: repo, auth: auth, profile: profile, cache: cache, connectivity: FakeConnectivity());
      await library.initialize();
      await pumpEventQueue();
    });

    tearDown(() {
      library.dispose();
      profile.dispose();
      auth.dispose();
    });

    Game game(String id) => library.libraryGames.firstWhere((g) => g.id == id);

    test('a new game comes in as the import says, with its trophies saved', () async {
      await library.importGame(
        testGame('new', status: null, cover: false),
        status: GameStatus.completed,
        hours: 20,
        playedOn: GamePlatform.ps5,
        trophiesEarned: 30,
        trophiesTotal: 30,
        perfected: true,
        fillGapsOnly: true,
      );
      final g = game('new');
      expect(g.status, GameStatus.completed);
      expect(g.hoursPlayed, 20);
      expect(g.playedOn, GamePlatform.ps5);
      expect(g.perfected, isTrue);
      expect((g.trophiesEarned, g.trophiesTotal), (30, 30));
      expect(repo.trophiesSent['new'], (30, 30));
      expect(repo.perfectedSent['new'], isTrue);
    });

    test('a game already there keeps its status and platform, and gains hours and trophies', () async {
      await library.importGame(
        testGame('dropped', status: null, cover: false),
        status: GameStatus.playing,
        hours: 40,
        playedOn: GamePlatform.ps5,
        trophiesEarned: 7,
        trophiesTotal: 20,
        fillGapsOnly: true,
      );
      final g = game('dropped');
      expect(g.status, GameStatus.dropped);
      expect(g.playedOn, GamePlatform.pc);
      expect(g.hoursPlayed, 40);
      expect((g.trophiesEarned, g.trophiesTotal), (7, 20));
    });

    test('hours never go down, and a platform is filled in only where there is none', () async {
      await library.importGame(
        testGame('dropped', status: null, cover: false),
        status: GameStatus.playing,
        hours: 1,
        fillGapsOnly: true,
      );
      expect(game('dropped').hoursPlayed, 5);

      await library.setPlayedOn('dropped', GamePlatform.ps4); // the member's choice
      await library.importGame(
        testGame('dropped', status: null, cover: false),
        status: GameStatus.playing,
        playedOn: GamePlatform.ps5,
        fillGapsOnly: true,
      );
      expect(game('dropped').playedOn, GamePlatform.ps4);
    });

    test('perfected is set by the import and never taken away by it', () async {
      await library.importGame(
        testGame('dropped', status: null, cover: false),
        status: GameStatus.completed,
        perfected: true,
        fillGapsOnly: true,
      );
      expect(game('dropped').perfected, isTrue);
      await library.importGame(
        testGame('dropped', status: null, cover: false),
        status: GameStatus.playing,
        fillGapsOnly: true,
      );
      expect(game('dropped').perfected, isTrue);
    });

    test('a wishlisted game stays wished for and is not perfected', () async {
      await library.importGame(
        testGame('wish', status: null, cover: false),
        status: GameStatus.completed,
        perfected: true,
        trophiesEarned: 1,
        trophiesTotal: 10,
        fillGapsOnly: true,
      );
      expect(game('wish').status, GameStatus.wishlist);
      expect(game('wish').perfected, isFalse);
    });

    test('a file import still sets the status it says', () async {
      await library.importGame(testGame('dropped', status: null, cover: false), status: GameStatus.completed);
      expect(game('dropped').status, GameStatus.completed);
    });

    test('an ordinary save leaves out trophies there are none of', () async {
      await library.setRating('dropped', 8);
      expect(repo.trophiesSent['dropped'], (null, null));
    });
  });

  group('the import screen', () {
    Future<void> show(WidgetTester tester, ImportFile file) =>
        tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ImportScreen(file: file)));

    testWidgets('an account with nothing on it says so, not that a file is empty', (tester) async {
      await show(tester, const ImportFile(rows: [], skipped: [], source: ImportSource.playstation));
      expect(find.textContaining('PlayStation returned no games or trophies'), findsOneWidget);
      expect(find.text('Nothing to import in this file.'), findsNothing);

      await show(tester, const ImportFile(rows: [], skipped: []));
      expect(find.text('Nothing to import in this file.'), findsOneWidget);
    });

    testWidgets('a PlayStation import says where it came from, and what Sony would not share', (tester) async {
      await show(
        tester,
        ImportFile(
          rows: const [ImportRow(line: 1, title: 'Hades')],
          skipped: const [],
          source: ImportSource.playstation,
          notes: [L10n.current.psnTrophiesMissing],
        ),
      );
      expect(find.text('1 game to import'), findsOneWidget);
      expect(find.textContaining('Read from your PlayStation account'), findsOneWidget);
      expect(find.textContaining('did not share your trophy list'), findsOneWidget);
    });
  });

  group('the sign-in screen', () {
    PsnClient clientWith(http.Response Function(http.Request request) answer) =>
        PsnClient(pace: Duration.zero, clientBasic: basic(), client: MockClient((request) async => answer(request)));

    http.Response good(http.Request request) {
      if (request.url.host == 'ca.account.sony.com') return json({'access_token': 'tok'});
      return request.url.path.contains('trophy')
          ? json({'trophyTitles': [trophyTitle('Hades', earned: [1, 0, 0, 0])]})
          : json({'titles': [played('Hades', 'PT2H')]});
    }

    late void Function(String url) redirect;
    late VoidCallback pageFailed;
    ImportFile? result;
    var closed = false;

    Future<void> open(WidgetTester tester, PsnClient client) async {
      result = null;
      closed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<ImportFile>(
                    MaterialPageRoute(
                      builder: (_) => PsnImportScreen(
                        client: client,
                        signInBuilder: (context, uri, onRedirect, onFailed) {
                          redirect = onRedirect;
                          pageFailed = onFailed;
                          return Text('Sony page ${uri.host}');
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
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows Sony\'s page, then closes with what it read', (tester) async {
      await open(tester, clientWith(good));
      expect(find.text('Sony page ca.account.sony.com'), findsOneWidget);
      expect(find.textContaining('does not read or keep'), findsOneWidget);

      await tester.runAsync(() async {
        redirect('com.scee.psxandroid.scecompcall://redirect/?code=v3.abc');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(result, isNotNull);
      expect(result!.rows.single.title, 'Hades');
      expect(result!.rows.single.hours, 2);
      expect(result!.source, ImportSource.playstation);
    });

    testWidgets('a second report of the link does not read twice', (tester) async {
      var tokenRequests = 0;
      await open(
        tester,
        clientWith((request) {
          if (request.url.host == 'ca.account.sony.com') tokenRequests++;
          return good(request);
        }),
      );
      await tester.runAsync(() async {
        redirect('com.scee.psxandroid.scecompcall://redirect/?code=v3.abc');
        redirect('com.scee.psxandroid.scecompcall://redirect/?code=v3.abc');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(tokenRequests, 1);
    });

    testWidgets('a refused sign-in says so, and Try again shows the page again', (tester) async {
      await open(tester, clientWith((_) => json({'error': 'invalid_grant'}, 400)));
      await tester.runAsync(() async {
        redirect('com.scee.psxandroid.scecompcall://redirect/?code=bad');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('PlayStation did not accept the sign-in. Try again.'), findsOneWidget);
      expect(closed, isFalse);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Sony page ca.account.sony.com'), findsOneWidget);
    });

    testWidgets('a link without a code is a refused sign-in', (tester) async {
      await open(tester, clientWith(good));
      redirect('com.scee.psxandroid.scecompcall://redirect/?error=access_denied');
      await tester.pumpAndSettle();
      expect(find.text('PlayStation did not accept the sign-in. Try again.'), findsOneWidget);
    });

    testWidgets('a page that will not load says Sony could not be reached; Close backs out', (tester) async {
      await open(tester, clientWith(good));
      pageFailed();
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not reach PlayStation'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result, isNull);
    });

    testWidgets('lists Sony will not share are told, not hidden', (tester) async {
      await open(
        tester,
        clientWith((request) {
          if (request.url.host == 'ca.account.sony.com') return json({'access_token': 'tok'});
          return request.url.path.contains('trophy') ? json({}, 403) : json({'titles': [played('Hades', 'PT2H')]});
        }),
      );
      await tester.runAsync(() async {
        redirect('com.scee.psxandroid.scecompcall://redirect/?code=v3.abc');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(result!.notes, hasLength(1));
      expect(result!.rows.single.trophiesTotal, isNull);
    });
  });
}
