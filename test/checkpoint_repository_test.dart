import 'dart:convert';

import 'package:flutter/material.dart' show Color, Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/models/completion_time.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/services/sync_failure.dart';

import 'support/fakes.dart';

/// The Supabase REST API, answered from memory. Each request is recorded in
/// [requests]; [reply] queues what the next ones get (an empty queue answers
/// `[]`), so a test reads like "the server says X, the repository returns Y".
class _FakeApi {
  final requests = <http.Request>[];
  final _replies = <(int, Object?)>[];
  Object? Function(http.Request)? _table;

  /// From now on, answer every request from [rows] the way PostgREST answers a
  /// keyset-paged read: it honours `<column>=gt.<cursor>`, `order=<column>.asc|desc`
  /// and `limit`. Lets a test check that paging really reaches every row.
  void serveTable(List<Map<String, dynamic>> rows, String column) {
    _table = (request) {
      final query = request.url.queryParameters;
      var matching = [...rows];
      final after = query[column];
      if (after != null && after.startsWith('gt.')) {
        final cursor = after.substring(3);
        matching = [
          for (final r in matching)
            if ((r[column] as String).compareTo(cursor) > 0) r,
        ];
      }
      matching.sort((a, b) => (a[column] as String).compareTo(b[column] as String));
      if ((query['order'] ?? '').split('.').skip(1).firstOrNull == 'desc') {
        matching = matching.reversed.toList();
      }
      return matching.take(int.parse(query['limit'] ?? '1000')).toList();
    };
  }

  void reply(Object? body, {int status = 200}) => _replies.add((status, body));

  http.Request get last => requests.last;

  /// The request body as JSON.
  Object? bodyOf(http.Request request) => jsonDecode(request.body);

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final table = _table;
    if (table != null) {
      return http.Response(
        jsonEncode(table(request)),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }
    final (status, body) = _replies.isEmpty ? (200, const <Object?>[]) : _replies.removeAt(0);
    return http.Response(
      jsonEncode(body),
      status,
      request: request, // the client library reads the request back off the response
      headers: {'content-type': 'application/json'},
    );
  }
}

Map<String, dynamic> userGameRow(
  String gameId, {
  String title = 'Hades',
  Object? hours = 12.5,
  String? addedAt = '2026-03-01T10:00:00+00:00',
  Map<String, dynamic>? gameOverrides,
}) => {
  'id': 'ug-$gameId',
  'user_id': 'u1',
  'game_id': gameId,
  'status': 'playing',
  'rating': 4.5,
  'hours_played': hours,
  'played_on': 'ps5',
  'purchase_price': 24.99,
  'date_added': addedAt,
  'is_favorite': true,
  'games': {
    'id': gameId,
    'igdb_id': 113112,
    'steam_app_id': 1145360,
    'slug': 'hades',
    'title': title,
    'publisher': 'Supergiant Games',
    'developer': 'Supergiant Games',
    'release_year': 2020,
    'platforms': ['pc', 'switch'],
    'genres': ['Roguelike', 'Action'],
    'summary': 'Escape the underworld.',
    'cover_url': 'https://images.igdb.com/hades.jpg',
    'created_at': '2026-01-01T00:00:00+00:00',
    ...?gameOverrides,
  },
};

/// A catalog game as search returns it: its id is derived from [igdbId], or it
/// is a legacy Steam-keyed row when [igdbId] is null.
Game catalogGame({int? igdbId = 7, int releaseYear = 2020}) => Game(
  id: igdbId == null ? '57e40000-0000-0000-0000-000000000440' : gameIdForIgdb(igdbId),
  title: 'Seven',
  publisher: 'Publisher',
  developer: 'Developer',
  releaseYear: releaseYear,
  platforms: const [GamePlatform.pc, GamePlatform.ps5],
  genres: const ['RPG'],
  synopsis: 'A game.',
  coverColors: const [Color(0xFF000000), Color(0xFF111111)],
  coverIcon: Icons.sports_esports_rounded,
  igdbId: igdbId,
);

void main() {
  late _FakeApi api;
  late SupabaseClient client;
  late CheckpointRepository repo;

  setUp(() {
    api = _FakeApi();
    client = SupabaseClient(
      'http://localhost:54321',
      'anon-key',
      httpClient: MockClient(api.handle),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    repo = CheckpointRepository(client);
  });

  tearDown(() async {
    await client.dispose();
  });

  /// Gives the client a stored session for [userId], which is where the
  /// repository reads the signed-in user from. Nothing goes over the network.
  Future<void> signIn(String userId) async {
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': 'token',
        'refresh_token': 'refresh',
        'token_type': 'bearer',
        'expires_in': 3600,
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
        'user': {
          'id': userId,
          'aud': 'authenticated',
          'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{},
          'created_at': '2026-01-01T00:00:00Z',
        },
      }),
    );
    api.requests.clear();
  }

  group('fetchUserGames', () {
    test('turns a library row into a Game', () async {
      api.reply([userGameRow('00000000-0000-4000-8000-000000113112')]);

      final games = await repo.fetchUserGames('u1');

      expect(games, hasLength(1));
      final game = games.single;
      expect(game.id, '00000000-0000-4000-8000-000000113112');
      expect(game.title, 'Hades');
      expect(game.igdbId, 113112);
      expect(game.steamAppId, 1145360);
      expect(game.developer, 'Supergiant Games');
      expect(game.releaseYear, 2020);
      expect(game.platforms, [GamePlatform.pc, GamePlatform.nswitch]);
      expect(game.genres, ['Roguelike', 'Action']);
      expect(game.coverUrl, 'https://images.igdb.com/hades.jpg');
      // The user's own fields.
      expect(game.status, GameStatus.playing);
      expect(game.rating, 9); // the database's 4.5 is nine stars
      expect(game.hoursPlayed, 12.5);
      expect(game.playedOn, GamePlatform.ps5);
      expect(game.purchasePrice, 24.99);
      expect(game.isFavorite, isTrue);
      expect(game.dateAdded!.toUtc(), DateTime.utc(2026, 3, 1, 10));
      expect(game.inLibrary, isTrue);
    });

    test('reads a rating as the database keeps it, to the tenth, back to the half star', () async {
      // Half a star is a quarter of the 0 to 5 scale: 0.5 stars is stored as 0.3, 7.5 as 3.8.
      final stored = [0, 0.3, 0.5, 0.8, 1.3, 3.3, 3.5, 3.8, 4.5, 4.8, 5];
      api.reply([for (var i = 0; i < stored.length; i++) {...userGameRow('g$i'), 'rating': stored[i]}]);

      final games = await repo.fetchUserGames('u1');

      expect([for (final g in games) g.rating], [0, 0.5, 1, 1.5, 2.5, 6.5, 7, 7.5, 9, 9.5, 10]);
    });

    test('reads whether the member hid the game from others, and asks for the column', () async {
      api.reply([
        {...userGameRow('g1'), 'is_hidden': true},
        userGameRow('g2'),
      ]);

      final games = await repo.fetchUserGames('u1');

      expect(games.firstWhere((g) => g.id == 'g1').isHidden, isTrue);
      expect(games.firstWhere((g) => g.id == 'g2').isHidden, isFalse);
      expect(api.last.url.queryParameters['select'], contains('is_hidden'));
    });

    test('reads the member\'s chosen backdrop, and none when the row has none', () async {
      const art = 'https://images.igdb.com/igdb/image/upload/t_1080p/ar5l8.jpg';
      api.reply([
        {...userGameRow('g1'), 'custom_backdrop_url': art},
        userGameRow('g2'),
      ]);

      final games = await repo.fetchUserGames('u1');

      expect(api.last.url.queryParameters['select'], contains('custom_backdrop_url'));
      expect(games.firstWhere((g) => g.id == 'g1').customBackdropUrl, art);
      expect(games.firstWhere((g) => g.id == 'g2').customBackdropUrl, isNull);
      // The cover is always the catalog's.
      expect(games.firstWhere((g) => g.id == 'g1').coverUrl, 'https://images.igdb.com/hades.jpg');
    });

    test('reads whether the member marked a game perfected', () async {
      api.reply([
        {...userGameRow('g1'), 'perfected': true},
        userGameRow('g2'),
      ]);

      final games = await repo.fetchUserGames('u1');

      expect(api.last.url.queryParameters['select'], contains('perfected'));
      expect(games.firstWhere((g) => g.id == 'g1').perfected, isTrue);
      expect(games.firstWhere((g) => g.id == 'g2').perfected, isFalse);
    });

    test('asks for the user\'s rows only, and never for the heavy achievements column', () async {
      await repo.fetchUserGames('u1');

      final query = api.last.url.queryParameters;
      expect(api.last.url.path, '/rest/v1/user_games');
      expect(query['user_id'], 'eq.u1');
      expect(query['select'], isNot(contains('achievements')));
      expect(query['select'], contains('games!inner'));
      // The read continues with `game_id > cursor`, so it has to run oldest id first.
      expect(query['order'], startsWith('game_id.asc'));
      expect(query['limit'], '500');
    });

    test('copes with numbers sent as text and with missing catalog fields', () async {
      api.reply([
        userGameRow(
          'g1',
          hours: '7.25', // numeric columns can arrive as strings
          gameOverrides: {
            'title': '   ',
            'publisher': null,
            'developer': '',
            'release_year': null,
            'platforms': null,
            'genres': 'Strategy', // a bare string instead of a list
            'summary': null,
            'cover_url': '',
            'igdb_id': '42',
            'steam_app_id': null,
          },
        ),
      ]);

      final game = (await repo.fetchUserGames('u1')).single;

      expect(game.hoursPlayed, 7.25);
      expect(game.title, 'Untitled Game');
      expect(game.publisher, 'Unknown publisher');
      expect(game.developer, 'Unknown developer');
      expect(game.releaseYear, 0);
      expect(game.platforms, isEmpty); // no platform data is not guessed to be PC
      expect(game.genres, ['Strategy']);
      expect(game.synopsis, '');
      expect(game.coverUrl, isNull);
      expect(game.igdbId, 42);
      expect(game.steamAppId, isNull);
    });

    test('a game owned on Steam with no platform data is a PC game', () async {
      api.reply([
        userGameRow('g1', gameOverrides: {'platforms': <String>[], 'steam_app_id': 440}),
        userGameRow(
          '57e40000-0000-0000-0000-000000000730',
          gameOverrides: {'platforms': null, 'steam_app_id': null, 'igdb_id': null},
        ),
      ]);

      final games = await repo.fetchUserGames('u1');

      expect(games.map((g) => g.platforms), everyElement([GamePlatform.pc]));
    });

    test('Steam Deck and Emulator are never read as release platforms', () async {
      api.reply([
        userGameRow('g1', gameOverrides: {
          'platforms': ['steamdeck', 'mobile', 'retro', 'emulator', 'android', 'Steam Deck'],
          'steam_app_id': null,
        }),
      ]);

      final game = (await repo.fetchUserGames('u1')).single;

      expect(game.platforms, [GamePlatform.mobile, GamePlatform.android]);
      // + the saved "ps5"
      expect(game.playedOnOptions, [GamePlatform.ps5, GamePlatform.android, GamePlatform.mobile]);
    });

    test('returns the newest additions first, undated rows last', () async {
      api.reply([
        userGameRow('a', addedAt: '2026-01-01T00:00:00+00:00'),
        userGameRow('b', addedAt: null),
        userGameRow('c', addedAt: '2026-06-01T00:00:00+00:00'),
      ]);

      final games = await repo.fetchUserGames('u1');

      expect([for (final g in games) g.id], ['c', 'a', 'b']);
    });

    test('reads a library bigger than one page, every game exactly once', () async {
      api.serveTable([
        for (var i = 0; i < 1200; i++) userGameRow('g${i.toString().padLeft(4, '0')}'),
      ], 'game_id');

      final games = await repo.fetchUserGames('u1');

      expect(games.map((g) => g.id).toSet(), hasLength(1200));
      expect(games, hasLength(1200)); // no game read twice
      expect(api.requests, hasLength(3)); // 500 + 500 + 200
      expect(api.requests[0].url.queryParameters.containsKey('game_id'), isFalse);
      expect(api.requests[1].url.queryParameters['game_id'], 'gt.g0499');
    });

    test('a library of exactly one page needs one more request to know it is done', () async {
      api.serveTable([
        for (var i = 0; i < 500; i++) userGameRow('g${i.toString().padLeft(4, '0')}'),
      ], 'game_id');

      final games = await repo.fetchUserGames('u1');

      expect(games, hasLength(500));
      expect(api.requests, hasLength(2));
    });
  });

  group('fetchUnsyncedIgdbIds', () {
    test('asks only for the user\'s games whose catalog row IGDB never filled in', () async {
      api.reply([
        {'game_id': 'g1', 'games': {'igdb_id': 472}},
        {'game_id': 'g2', 'games': {'igdb_id': '1942'}},
        {'game_id': 'g3', 'games': {'igdb_id': null}},
        {'game_id': 'g4', 'games': null},
      ]);

      final ids = await repo.fetchUnsyncedIgdbIds('u1');

      expect(ids, [472, 1942]);
      final query = api.requests.first.url.queryParameters;
      expect(api.last.url.path, endsWith('/user_games'));
      expect(query['user_id'], 'eq.u1');
      expect(query['games.igdb_synced_at'], 'is.null');
      expect(query['games.igdb_id'], 'not.is.null');
      // Only the ids, through an inner join, so the rows of filled-in games are
      // not sent at all.
      final select = query['select']!.replaceAll(RegExp(r'\s'), '');
      expect(select, 'game_id,games!inner(igdb_id)');
    });

    test('reads every page of a long list, each game once', () async {
      api.serveTable([
        for (var i = 0; i < 700; i++)
          {
            'game_id': 'g${i.toString().padLeft(4, '0')}',
            'games': {'igdb_id': i + 1},
          },
      ], 'game_id');

      final ids = await repo.fetchUnsyncedIgdbIds('u1');

      expect(ids, hasLength(700));
      expect(ids.toSet(), hasLength(700));
      // Two pages for each of the two reads (the table here answers both).
      expect(api.requests, hasLength(4));
      expect(
        api.requests.where((r) => r.url.queryParameters['game_id'] == 'gt.g0499'),
        hasLength(2),
      );
    });

    test('also asks for wishlist and To Play games not out yet whose row is a week old', () async {
      api.reply(const <Object?>[]);
      api.reply([
        {'game_id': 'g5', 'games': {'igdb_id': 99}},
      ]);

      final ids = await repo.fetchUnsyncedIgdbIds('u1');

      expect(ids, [99]);
      final query = api.requests[1].url.queryParameters;
      expect(query['status'], 'in.("wishlist","to_play")');
      expect(query['games.igdb_synced_at'], startsWith('lt.'));
      expect(query['games.or'], matches(RegExp(r'^\(release_date\.is\.null,release_date\.gte\.\d{4}-\d{2}-\d{2}\)$')));
    });
  });

  group('fetchLibraryAttributes', () {
    test('reads only the IGDB lists of the user\'s games IGDB has filled in', () async {
      api.reply([
        {
          'game_id': 'g1',
          'games': {
            'themes': ['Horror', 'Fantasy'],
            'game_modes': ['Single player'],
            'player_perspectives': ['First person'],
            'game_engines': ['Unreal Engine 4'],
            'developers': ['Studio One'],
            'publishers': ['Pub', 'Pub Two'],
          },
        },
        // IGDB had nothing for this one: still listed, so it counts as looked up.
        {
          'game_id': 'g2',
          'games': {
            'themes': [],
            'game_modes': null,
            'player_perspectives': [''],
            'game_engines': [],
            'developers': [],
            'publishers': [],
          },
        },
      ]);

      final byGame = await repo.fetchLibraryAttributes('u1');

      expect(byGame.keys, ['g1', 'g2']);
      final first = byGame['g1']!;
      expect(first.themes, ['Horror', 'Fantasy']);
      expect(first.gameModes, ['Single player']);
      expect(first.perspectives, ['First person']);
      expect(first.engines, ['Unreal Engine 4']);
      expect(first.developers, ['Studio One']);
      expect(first.publishers, ['Pub', 'Pub Two']);
      final second = byGame['g2']!;
      expect(second.themes, isEmpty);
      expect(second.gameModes, isEmpty);
      expect(second.perspectives, isEmpty);

      final query = api.last.url.queryParameters;
      expect(api.last.url.path, endsWith('/user_games'));
      expect(query['user_id'], 'eq.u1');
      expect(query['games.igdb_synced_at'], 'not.is.null');
      // The lists and nothing else, through an inner join: not the title, the
      // synopsis or the cover of every game.
      final select = query['select']!.replaceAll(RegExp(r'\s'), '');
      expect(
        select,
        'game_id,games!inner(themes,game_modes,player_perspectives,game_engines,developers,publishers)',
      );
    });

    test('is not part of the library read, which stays as small as it was', () async {
      api.reply([userGameRow('g1')]);
      await repo.fetchUserGames('u1');

      final select = api.last.url.queryParameters['select']!;
      for (final column in [
        'themes',
        'game_modes',
        'player_perspectives',
        'game_engines',
        'developers',
        'publishers',
        'igdb_synced_at',
      ]) {
        expect(select, isNot(contains(column)));
      }
    });

    test('reads every page of a long library, each game once', () async {
      api.serveTable([
        for (var i = 0; i < 700; i++)
          {
            'game_id': 'g${i.toString().padLeft(4, '0')}',
            'games': {
              'themes': ['Theme $i'],
            },
          },
      ], 'game_id');

      final byGame = await repo.fetchLibraryAttributes('u1');

      expect(byGame, hasLength(700));
      expect(byGame['g0699']!.themes, ['Theme 699']);
      expect(api.requests, hasLength(2));
      expect(api.requests[1].url.queryParameters['game_id'], 'gt.g0499');
    });

    test('a library with nothing filled in yet is an empty answer, not an error', () async {
      api.reply(<Object?>[]);

      expect(await repo.fetchLibraryAttributes('u1'), isEmpty);
    });
  });

  group('fetchLogEntries', () {
    test('reads more sessions than one page holds, every one exactly once', () async {
      api.serveTable([
        for (var i = 0; i < 1100; i++)
          {
            'id': 'l${i.toString().padLeft(4, '0')}',
            'game_id': 'g1',
            'logged_at': '2026-02-01T08:00:00+00:00',
            'hours': 1,
            'platform': 'pc',
            'note': '',
          },
      ], 'id');

      final logs = await repo.fetchLogEntries('u1');

      expect(logs.map((l) => l.id).toSet(), hasLength(1100));
      expect(logs, hasLength(1100));
    });

    test('a session the Steam sync logged says so, in the saved copy too', () async {
      api.reply([
        {'id': 'l1', 'game_id': 'g1', 'logged_at': '2026-02-01T08:00:00+00:00', 'hours': 1.5, 'platform': 'pc', 'note': '', 'source': 'steam'},
        {'id': 'l2', 'game_id': 'g1', 'logged_at': '2026-01-01T08:00:00+00:00', 'hours': 1, 'platform': 'pc', 'note': '', 'source': null},
      ]);

      final logs = await repo.fetchLogEntries('u1');

      expect(logs.map((l) => l.fromSteam), [true, false]);
      final saved = LogEntry.fromJson(logs.first.toJson());
      expect(saved.fromSteam, isTrue);
      expect(LogEntry.fromJson(logs.last.toJson()).fromSteam, isFalse);
    });

    test('an edited session is saved with its new hours, platform, note and time', () async {
      await repo.updateLogEntry(
        id: 'l1',
        hours: 2.5,
        platform: GamePlatform.steamDeck,
        note: '  on the bus ',
        loggedAt: DateTime.utc(2026, 9, 30, 18),
      );

      expect(api.last.method, 'PATCH');
      expect(api.last.url.path, '/rest/v1/log_entries');
      expect(api.last.url.queryParameters['id'], 'eq.l1');
      expect(api.bodyOf(api.last), {
        'hours': 2.5,
        'platform': 'steamDeck',
        'note': 'on the bus',
        'logged_at': '2026-09-30T18:00:00.000Z',
      });

      await repo.deleteLogEntry('l1');
      expect(api.last.method, 'DELETE');
      expect(api.last.url.queryParameters['id'], 'eq.l1');
    });

    test('parses sessions and returns the newest first', () async {
      api.reply([
        {
          'id': 'l1',
          'game_id': 'g1',
          'logged_at': '2026-02-01T08:00:00+00:00',
          'hours': 1.5,
          'platform': 'pc',
          'note': '  first run  ',
        },
        {
          'id': 'l2',
          'game_id': 'g2',
          'logged_at': '2026-04-01T08:00:00+00:00',
          'hours': '2', // numeric as text
          'platform': 'nonsense', // unknown platform falls back to PC
          'note': null,
        },
      ]);

      final logs = await repo.fetchLogEntries('u1');

      expect([for (final l in logs) l.id], ['l2', 'l1']);
      expect(logs[0].hours, 2);
      expect(logs[0].platform, GamePlatform.pc);
      expect(logs[0].note, '');
      expect(logs[1].hours, 1.5);
      expect(logs[1].note, 'first run');
      expect(logs[1].timestamp.toUtc(), DateTime.utc(2026, 2, 1, 8));
    });
  });

  group('sessions with missing fields', () {
    test(
      'a session row with null or unreadable columns still parses',
      () async {
        api.reply([
          {
            'id': 'l1',
            'game_id': 'g1',
            'logged_at': null, // falls back to now
            'hours': null,
            'platform': null,
            'note': '   ',
          },
          {
            'id': 'l2',
            'game_id': 'g1',
            'logged_at': 'not a date',
            'hours': 'a lot',
            'platform': 'retro',
          },
        ]);

        final logs = await repo.fetchLogEntries('u1');

        expect(logs, hasLength(2));
        for (final log in logs) {
          expect(log.hours, 0);
          expect(log.note, '');
          expect(
            log.timestamp.difference(DateTime.now()).abs(),
            lessThan(const Duration(minutes: 1)),
          );
        }
        expect(
          logs.map((l) => l.platform),
          containsAll([GamePlatform.pc, GamePlatform.emulator]),
        );
      },
    );
  });

  group('profiles', () {
    test('ensureProfile reads an existing row and prefixes the handle with @', () async {
      api.reply({
        'id': 'u1',
        'display_name': 'Ada',
        'handle': 'ada',
        'bio': ' Speedrunner ',
        'avatar_url': ' ',
        'steam_id': '76561198000000000',
        'created_at': '2026-01-05T00:00:00+00:00',
      });

      final profile = await repo.ensureProfile(testUser('u1'));

      expect(profile.name, 'Ada');
      expect(profile.handle, '@ada');
      expect(profile.bio, 'Speedrunner');
      expect(profile.avatarUrl, isNull); // blank text is no avatar
      expect(profile.steamId, '76561198000000000');
      expect(profile.joined.toUtc(), DateTime.utc(2026, 1, 5));
      expect(api.requests, hasLength(1)); // nothing was written
    });

    test('the profile carries whether other members see the achievements', () async {
      api.reply({'id': 'u1', 'display_name': 'Ada', 'handle': 'ada', 'show_steam_achievements': false});
      expect((await repo.fetchProfile(testUser('u1'))).showSteamAchievements, isFalse);

      // A row from before the setting existed shows them, like the column's default.
      api.reply({'id': 'u1', 'display_name': 'Ada', 'handle': 'ada'});
      expect((await repo.fetchProfile(testUser('u1'))).showSteamAchievements, isTrue);
    });

    test('a blank steam_id means no Steam account is connected', () async {
      api.reply({'id': 'u1', 'display_name': 'Ada', 'handle': 'ada', 'steam_id': '  '});

      final profile = await repo.ensureProfile(testUser('u1'));

      expect(profile.steamId, isNull);
    });

    test('ensureProfile creates the row for a new user from their sign-in details', () async {
      api.reply(null); // maybeSingle: no row yet
      api.reply(null); // the upsert
      api.reply({
        'id': 'u9',
        'display_name': 'Grace Hopper',
        'handle': 'grace_hopper_u9abc',
        'created_at': '2026-02-02T00:00:00+00:00',
      });
      final user = User(
        id: 'u9abcdef-0000',
        appMetadata: const {},
        userMetadata: const {'full_name': 'Grace Hopper', 'picture': 'https://example.com/g.png'},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00Z',
        email: 'grace@example.com',
      );

      final profile = await repo.ensureProfile(user);

      final upsert = api.requests[1];
      expect(upsert.method, 'POST');
      expect(upsert.url.path, '/rest/v1/profiles');
      final row = api.bodyOf(upsert) as Map<String, dynamic>;
      expect(row['id'], 'u9abcdef-0000');
      expect(row['email'], 'grace@example.com');
      expect(row['display_name'], 'Grace Hopper');
      expect(row['avatar_url'], 'https://example.com/g.png');
      expect(row['bio'], '');
      // lowercase, only [a-z0-9_], unique per user, and within the 24 character limit
      expect(row['handle'], matches(RegExp(r'^grace_hopper_u9abcd$')));
      expect((row['handle'] as String).length, lessThanOrEqualTo(24));
      expect(profile.name, 'Grace Hopper');
    });

    test('the display name falls back to "Player", never to the email address', () async {
      api.reply({'id': 'u1', 'display_name': null, 'handle': null});

      final fromEmail = await repo.ensureProfile(
        User(
          id: 'abcdef12',
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00Z',
          email: 'ada.l@example.com',
        ),
      );
      expect(fromEmail.name, 'Player');
      expect(fromEmail.handle, '@player_abcdef');

      api.reply({'id': 'u2'});
      final anonymous = await repo.ensureProfile(testUser('u2'));
      expect(anonymous.name, 'Player');
    });

    test('a stand-in profile takes the name Apple shared after it was made', () async {
      User apple(Map<String, dynamic> metadata) => User(
        id: 'abcdef12',
        appMetadata: const {'provider': 'apple'},
        userMetadata: metadata,
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00Z',
      );
      api.reply({'id': 'abcdef12', 'display_name': 'Player', 'handle': 'player_abcdef'});
      api.reply({'id': 'abcdef12', 'display_name': 'Ada Lovelace', 'handle': 'ada_lovelace_abcdef'});

      final profile = await repo.ensureProfile(apple({'full_name': 'Ada Lovelace'}));

      final update = api.requests[1];
      expect(update.method, 'PATCH');
      expect(update.url.queryParameters['id'], 'eq.abcdef12');
      expect(api.bodyOf(update), {'display_name': 'Ada Lovelace', 'handle': 'ada_lovelace_abcdef'});
      expect(profile.name, 'Ada Lovelace');

      // A name the member chose is kept, even one that is "Player".
      api.requests.clear();
      api.reply({'id': 'abcdef12', 'display_name': 'Player', 'handle': 'the_player'});
      await repo.ensureProfile(apple({'full_name': 'Ada Lovelace'}));
      expect(api.requests, hasLength(1));
    });

    test('a new email sign-up gets the name it typed in, and no part of the address', () async {
      api.reply(null); // maybeSingle: no row yet
      api.reply(null); // the upsert
      api.reply({'id': 'e1', 'display_name': 'Ada Lovelace', 'handle': 'ada_lovelace_e1abcd'});
      final user = User(
        id: 'e1abcdef-0000',
        appMetadata: const {'provider': 'email'},
        // What AuthService.signUpWithEmail sends as the sign-up's data.
        userMetadata: const {'full_name': 'Ada Lovelace'},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00Z',
        email: 'countess.1815@example.com',
      );

      await repo.ensureProfile(user);

      final row = api.bodyOf(api.requests[1]) as Map<String, dynamic>;
      expect(row['email'], 'countess.1815@example.com'); // own-row only
      expect(row['display_name'], 'Ada Lovelace');
      expect(row['handle'], 'ada_lovelace_e1abcd');
      expect(row['avatar_url'], isNull);
    });

    test('isHandleAvailable ignores the @ and the case, and excludes the caller', () async {
      api.reply(<Object?>[]);

      expect(await repo.isHandleAvailable('  @@Ada ', 'u1'), isTrue);

      expect(api.last.url.path, '/rest/v1/public_profiles'); // never the private table
      expect(api.last.url.queryParameters['handle'], 'eq.ada');
      expect(api.last.url.queryParameters['id'], 'neq.u1');
    });

    test('isHandleAvailable is false when someone else has it, and for an empty handle', () async {
      api.reply([
        {'id': 'u2'},
      ]);
      expect(await repo.isHandleAvailable('taken', 'u1'), isFalse);

      final before = api.requests.length;
      expect(await repo.isHandleAvailable(' @ ', 'u1'), isFalse);
      expect(api.requests, hasLength(before)); // answered without asking the server
    });
  });

  group('social', () {
    test('searchSocialUsers reads only public columns and flags a full page', () async {
      api.reply([
        {'id': 'm1', 'handle': 'zed', 'display_name': 'Zed', 'avatar_url': 'https://example.com/z.png'},
        {'id': 'm2', 'handle': null, 'display_name': null, 'avatar_url': null},
      ]);

      final page = await repo.searchSocialUsers('u1', limit: 2);

      expect(api.last.url.path, '/rest/v1/public_profiles');
      expect(api.last.url.queryParameters['select'], isNot(contains('email')));
      expect(api.last.url.queryParameters['id'], 'neq.u1');
      expect(page.hasMore, isTrue); // a full page: there may be another
      expect(page.items[0].name, 'Zed');
      expect(page.items[0].handle, '@zed');
      expect(page.items[0].avatarUrl, 'https://example.com/z.png');
      expect(page.items[1].name, 'Player');
      expect(page.items[1].handle, startsWith('@player_'));
    });

    test('searchSocialUsers reads each member\'s counts and follow state', () async {
      api.reply([
        {'id': 'm1', 'handle': 'zed', 'display_name': 'Zed', 'games_count': 12, 'followers_count': 3, 'viewer_follows': true},
        {'id': 'm2', 'handle': 'amy', 'display_name': 'Amy', 'games_count': 0, 'followers_count': 0, 'viewer_follows': false},
      ]);

      final page = await repo.searchSocialUsers('u1');

      final select = api.last.url.queryParameters['select']!;
      expect(select, allOf(contains('games_count'), contains('followers_count'), contains('viewer_follows')));
      final zed = page.items[0];
      expect((zed.gamesLogged, zed.followers, zed.startsFollowed), (12, 3, true));
      // the count follows the button: unfollowing takes the viewer's own follow off
      expect(zed.followersFor(viewerFollows: true), 3);
      expect(zed.followersFor(viewerFollows: false), 2);
      final amy = page.items[1];
      expect((amy.gamesLogged, amy.followers, amy.startsFollowed), (0, 0, false));
      expect(amy.followersFor(viewerFollows: true), 1);
    });

    test('searchSocialUsers makes the typed text safe for the or() filter', () async {
      await repo.searchSocialUsers('u1', query: ' @Ada,(x)"%*\\ ');

      final filter = api.last.url.queryParameters['or']!;
      expect(filter, startsWith('(display_name.ilike.%'));
      // none of the characters that would end the value or act as wildcards survive
      final term = RegExp(r'display_name\.ilike\.%(.*?)%,').firstMatch(filter)!.group(1)!;
      expect(term, isNot(matches(RegExp(r'[,()"\\%*]'))));
      expect(term.trim(), startsWith('Ada'));
    });

    test('searchSocialUsers asks for the right slice', () async {
      await repo.searchSocialUsers('u1', offset: 30, limit: 30);

      expect(api.last.url.queryParameters['offset'], '30');
      expect(api.last.url.queryParameters['limit'], '30');
    });

    test('a short page ends the member list', () async {
      api.reply([
        {'id': 'm1', 'handle': 'zed', 'display_name': 'Zed'},
      ]);

      final page = await repo.searchSocialUsers('u1', limit: 30);

      expect(page.hasMore, isFalse);
    });

    test('fetchFollowingIds and fetchFollowersCount count what the server lists', () async {
      api.reply([
        {'followee_id': 'a'},
        {'followee_id': 'b'},
        {'followee_id': 'a'},
      ]);
      expect(await repo.fetchFollowingIds('u1'), {'a', 'b'});

      api.reply([
        {'follower_id': 'x'},
        {'follower_id': 'y'},
      ]);
      expect(await repo.fetchFollowersCount('u1'), 2);
    });
  });

  group('other members', () {
    Map<String, dynamic> publicGameRow(
      String gameId, {
      bool favorite = false,
      Object? rating = 4.5,
    }) => {
      'game_id': gameId,
      'status': 'completed',
      'rating': rating,
      'hours_played': 31.5,
      'played_on': 'pc',
      'date_added': '2026-03-01T10:00:00+00:00',
      'is_favorite': favorite,
      'igdb_id': 113112,
      'steam_app_id': 1145360,
      'title': 'Hades',
      'publisher': 'Supergiant Games',
      'developer': 'Supergiant Games',
      'release_year': 2020,
      'platforms': ['pc'],
      'genres': ['Roguelike'],
      'summary': 'Escape the underworld.',
      'cover_url': 'https://images.igdb.com/hades.jpg',
    };

    test('fetchPublicProfile reads the public view, never the email', () async {
      api.reply({
        'id': 'm1',
        'handle': 'zed',
        'display_name': 'Zed',
        'avatar_url': ' https://example.com/zed.png ',
        'steam_connected': true,
      });

      final profile = await repo.fetchPublicProfile('m1');

      final query = api.last.url.queryParameters;
      expect(api.last.url.path, '/rest/v1/public_profiles');
      expect(query['id'], 'eq.m1');
      expect(query['select'], contains('steam_connected'));
      expect(query['select'], isNot(contains('email')));
      expect(profile!.name, 'Zed');
      expect(profile.handle, '@zed');
      expect(profile.avatarUrl, 'https://example.com/zed.png');
      expect(profile.steamConnected, isTrue);
    });

    test('fetchPublicProfile reads the bio and the Steam ID, and nothing that was only typed in', () async {
      api.reply({
        'id': 'm1',
        'handle': 'zed',
        'display_name': 'Zed',
        'bio': ' Speedrunner ',
        'steam_connected': true,
        'steam_id': '76561198000000000',
        'joined_at': '2026-03-04T00:00:00+00:00',
      });

      final profile = (await repo.fetchPublicProfile('m1'))!;

      final select = api.last.url.queryParameters['select']!;
      for (final column in ['bio', 'steam_id', 'joined_at']) {
        expect(select, contains(column));
      }
      // The columns of the services that could be typed in are gone from the view.
      for (final column in [
        'email',
        'connected_services',
        'psn_id',
        'xbox_id',
        'discord_id',
        'instagram_id',
        'twitch_id',
      ]) {
        expect(select, isNot(contains(column)));
      }
      expect(profile.bio, 'Speedrunner');
      expect(profile.steamId, '76561198000000000');
      expect(profile.joined!.toUtc(), DateTime.utc(2026, 3, 4));
      expect(profile.connectedServices, {ConnectedService.steam});
      expect(profile.accountNames, {ConnectedService.steam: '76561198000000000'});
    });

    test('fetchPublicProfile is null for a member who does not exist', () async {
      api.reply(null);

      expect(await repo.fetchPublicProfile('ghost'), isNull);
    });

    test('fetchPublicProfile reads whether the member shares their achievements', () async {
      api.reply({'id': 'm1', 'handle': 'zed', 'steam_connected': true, 'show_steam_achievements': false});

      final profile = (await repo.fetchPublicProfile('m1'))!;

      expect(api.last.url.queryParameters['select'], contains('show_steam_achievements'));
      expect(profile.showSteamAchievements, isFalse);
    });

    test('a profile without a Steam flag or a name still reads', () async {
      api.reply({'id': 'm9', 'handle': null, 'display_name': null});

      final profile = (await repo.fetchPublicProfile('m9'))!;

      expect(profile.name, 'Player');
      expect(profile.handle, startsWith('@player_'));
      expect(profile.steamConnected, isFalse);
      expect(profile.showSteamAchievements, isTrue);
      expect(profile.connectedServices, isEmpty);
    });

    test('fetchPublicProfileStats calls the function for that member and reads its one row', () async {
      api.reply([
        {'followers': 12, 'following': 3, 'viewer_follows': true, 'games': 40},
      ]);

      final stats = await repo.fetchPublicProfileStats('m1');

      expect(api.last.url.path, '/rest/v1/rpc/public_profile_stats');
      expect(api.bodyOf(api.last), {'target_user': 'm1'});
      expect(stats.followers, 12);
      expect(stats.following, 3);
      expect(stats.viewerFollows, isTrue);
      expect(stats.games, 40);
    });

    test('fetchPublicProfileStats fails when the server returns no row', () async {
      api.reply(<Object?>[]); // no session

      expect(repo.fetchPublicProfileStats('m1'), throwsStateError);
    });

    test('a profile\'s games come from the public view, without the price or achievements', () async {
      api.reply([publicGameRow('g1', favorite: true)]);

      final games = await repo.fetchPublicFavorites('m1');

      final query = api.last.url.queryParameters;
      expect(api.last.url.path, '/rest/v1/public_user_games');
      expect(query['user_id'], 'eq.m1');
      expect(query['is_favorite'], 'eq.true');
      expect(query['limit'], '4');
      expect(query['select'], isNot(contains('purchase_price')));
      expect(query['select'], isNot(contains('achievements')));
      final game = games.single;
      expect(game.id, 'g1');
      expect(game.title, 'Hades');
      expect(game.status, GameStatus.completed);
      expect(game.rating, 9);
      expect(game.hoursPlayed, 31.5);
      expect(game.playedOn, GamePlatform.pc);
      expect(game.isFavorite, isTrue);
      expect(game.purchasePrice, 0);
      expect(game.achievements, isNull);
      expect(game.coverUrl, 'https://images.igdb.com/hades.jpg');
    });

    test('library stats read only the columns they need, a keyed page at a time', () async {
      api.serveTable([
        for (var i = 0; i < 3; i++)
          {
            'game_id': 'g$i',
            'status': i == 0 ? 'completed' : 'playing',
            'rating': i == 0 ? 5 : 0,
            'hours_played': 10 + i,
            'played_on': 'ps5',
            'platforms': ['pc'],
          },
      ], 'game_id');

      final stats = await repo.fetchPublicLibraryStats('m1');

      final query = api.last.url.queryParameters;
      expect(api.last.url.path, '/rest/v1/public_user_games');
      expect(query['user_id'], 'eq.m1');
      expect(query['limit'], '500');
      for (final heavy in ['title', 'summary', 'cover_url', 'purchase_price', 'achievements']) {
        expect(query['select'], isNot(contains(heavy)));
      }
      expect(stats.games, 3);
      expect(stats.count(GameStatus.playing), 2);
      expect(stats.count(GameStatus.completed), 1);
      expect(stats.totalHours, 33);
      expect(stats.hoursByPlatform, {GamePlatform.ps5: 33});
      expect(stats.ratedCount, 1);
      expect(stats.ratingCounts, {10: 1});
    });

    test('library stats reach every row of a library bigger than a page', () async {
      api.serveTable([
        for (var i = 0; i < 1200; i++)
          {
            'game_id': 'g${i.toString().padLeft(5, '0')}',
            'status': 'playing',
            'rating': 0,
            'hours_played': 1,
            'played_on': 'pc',
            'platforms': ['pc'],
          },
      ], 'game_id');

      final stats = await repo.fetchPublicLibraryStats('m1');

      expect(stats.games, 1200);
      expect(stats.totalHours, 1200);
      expect(api.requests, hasLength(3)); // 500 + 500 + 200
    });

    test('the whole library comes with its covers, newest first, from the public view', () async {
      api.serveTable([
        publicGameRow('g1'),
        {...publicGameRow('g2'), 'date_added': '2026-05-01T10:00:00+00:00', 'title': 'Newer'},
      ], 'game_id');

      final games = await repo.fetchPublicLibrary('m1');

      final query = api.last.url.queryParameters;
      expect(query['user_id'], 'eq.m1');
      expect(query['select'], contains('cover_url'));
      expect(query['select'], isNot(contains('purchase_price')));
      expect(query['select'], isNot(contains('achievements')));
      expect(games.map((g) => g.title), ['Newer', 'Hades']);
      expect(games.first.rating, 9);
    });

    test('another member\'s library shows the games they marked perfected', () async {
      api.serveTable([
        {...publicGameRow('g1'), 'perfected': true},
        publicGameRow('g2'),
      ], 'game_id');

      final games = await repo.fetchPublicLibrary('m1');

      expect(api.last.url.queryParameters['select'], contains('perfected'));
      expect(games.firstWhere((g) => g.id == 'g1').perfected, isTrue);
      expect(games.firstWhere((g) => g.id == 'g2').perfected, isFalse);
    });

    test('recent activity is one row per game, newest first, without the note', () async {
      Map<String, dynamic> session(String gameId, String title, String at, {Object? hours = 2}) => {
        'game_id': gameId,
        'hours': hours,
        'platform': 'ps5',
        'logged_at': at,
        'igdb_id': 7,
        'title': title,
        'publisher': 'P',
        'developer': 'D',
        'release_year': 2020,
        'platforms': ['ps5'],
        'genres': ['RPG'],
        'summary': 's',
        'cover_url': 'https://images.igdb.com/c.jpg',
      };
      api.reply([
        session('g1', 'Hades', '2026-03-03T10:00:00+00:00', hours: '1.5'),
        session('g1', 'Hades', '2026-03-02T10:00:00+00:00'),
        session('g2', 'Celeste', '2026-03-01T10:00:00+00:00'),
        session('g3', 'Tunic', '2026-02-28T10:00:00+00:00'),
      ]);

      final activity = await repo.fetchPublicActivity('m1', limit: 2);

      final query = api.last.url.queryParameters;
      expect(api.last.url.path, '/rest/v1/public_recent_activity');
      expect(query['user_id'], 'eq.m1');
      expect(query['order'], startsWith('logged_at.desc'));
      expect(query['select'], isNot(contains('note')));
      expect(query['limit'], '20'); // more rows than asked, to skip repeats of a game
      expect(activity.map((e) => e.game.title), ['Hades', 'Celeste']);
      expect(activity.first.hours, 1.5);
      expect(activity.first.platform, GamePlatform.ps5);
      expect(activity.first.at.toUtc(), DateTime.utc(2026, 3, 3, 10));
      // The game is the catalog one: none of the player's own state.
      expect(activity.first.game.status, isNull);
      expect(activity.first.game.id, 'g1');
    });

    test('followers come from the followers view, newest follow first, with their photo', () async {
      api.reply([
        {'id': 'f1', 'handle': 'zed', 'display_name': 'Zed', 'avatar_url': 'https://example.com/z.png'},
        {'id': 'f2', 'handle': 'amy', 'display_name': 'Amy', 'avatar_url': null},
      ]);

      final page = await repo.fetchFollowers('m1', limit: 2);

      final query = api.last.url.queryParameters;
      expect(api.last.url.path, '/rest/v1/public_followers');
      expect(query['user_id'], 'eq.m1');
      expect(query['order'], 'followed_at.desc.nullslast,id.asc.nullslast');
      expect(query['select'], isNot(contains('email')));
      expect(page.hasMore, isTrue);
      expect(page.items.map((u) => u.id), ['f1', 'f2']);
      expect(page.items[0].handle, '@zed');
      expect(page.items[0].avatarUrl, 'https://example.com/z.png');
      expect(page.items[1].avatarUrl, isNull);
    });

    test('following comes from the following view, and a short page ends the list', () async {
      api.reply([
        {'id': 'f1', 'handle': 'zed', 'display_name': 'Zed'},
      ]);

      final page = await repo.fetchFollowing('m1', offset: 30);

      expect(api.last.url.path, '/rest/v1/public_following');
      expect(api.last.url.queryParameters['offset'], '30');
      expect(page.hasMore, isFalse);
    });

    test('the achievement summary is one function call and reads counts, not achievements', () async {
      api.reply([
        {'game_id': 'g1', 'title': 'Hades', 'cover_url': ' ', 'unlocked': 12, 'total': 40},
        {'game_id': 'g2', 'title': null, 'cover_url': 'https://images.igdb.com/c.jpg', 'unlocked': '3', 'total': '10'},
      ]);

      final games = await repo.fetchAchievementSummary('m1');

      expect(api.last.url.path, '/rest/v1/rpc/public_achievement_summary');
      expect(api.bodyOf(api.last), {'target_user': 'm1'});
      expect(games[0].unlocked, 12);
      expect(games[0].total, 40);
      expect(games[0].coverUrl, isNull); // blank text is no cover
      expect(games[1].title, 'Untitled Game');
      expect(games[1].unlocked, 3);
      expect(games[1].coverUrl, 'https://images.igdb.com/c.jpg');
    });

    test('one game\'s achievements come from the per-game function; null means none stored', () async {
      api.reply([
        {'name': 'First', 'description': 'd', 'icon_url': 'u', 'unlocked': true, 'unlocked_at': '2026-01-01T00:00:00Z'},
      ]);

      final achievements = await repo.fetchPublicGameAchievements('m1', 'g1');

      expect(api.last.url.path, '/rest/v1/rpc/public_game_achievements');
      expect(api.bodyOf(api.last), {'target_user': 'm1', 'target_game': 'g1'});
      expect(achievements!.single.name, 'First');
      expect(achievements.single.unlocked, isTrue);

      api.reply(null);
      expect(await repo.fetchPublicGameAchievements('m1', 'g2'), isNull);
    });

    test('friends with a game are one function call: each with their status, rating and photo, and the counts', () async {
      api.reply([
        {
          'id': 'm1',
          'handle': 'zed',
          'display_name': 'Zed',
          'avatar_url': 'https://example.com/zed.jpg',
          'status': 'completed',
          'rating': 4.5,
          'date_added': '2026-03-01T10:00:00+00:00',
          'status_total': 3,
        },
        {
          'id': 'm2',
          'handle': 'amy',
          'display_name': null,
          'avatar_url': null,
          'status': 'to_play',
          'rating': '0',
          'date_added': null,
          'status_total': '1',
        },
        // A status this build does not know is skipped, not a failed read.
        {'id': 'm3', 'handle': 'bo', 'status': 'abandoned', 'rating': 0, 'status_total': 1},
      ]);

      final friends = await repo.fetchFriendsWithGame('g1');

      expect(api.last.url.path, '/rest/v1/rpc/following_game_activity');
      expect(api.bodyOf(api.last), {'target_game': 'g1', 'per_status': CheckpointRepository.friendsPerStatus});
      expect(friends.friends.map((f) => f.member.id), ['m1', 'm2']);
      final zed = friends.friends.first;
      expect(zed.member.name, 'Zed');
      expect(zed.member.handle, '@zed');
      expect(zed.member.avatarUrl, 'https://example.com/zed.jpg');
      expect(zed.status, GameStatus.completed);
      expect(zed.rating, 9);
      expect(zed.dateAdded, DateTime.utc(2026, 3, 1, 10).toLocal());
      final amy = friends.friends.last;
      expect(amy.member.name, 'amy'); // no display name: the handle
      expect(amy.rating, 0);
      expect(amy.dateAdded, isNull);
      expect(friends.totals, {GameStatus.completed: 3, GameStatus.toPlay: 1});

      api.reply(null);
      expect((await repo.fetchFriendsWithGame('g2')).isEmpty, isTrue);
    });

    test('no request for another member ever touches the private tables', () async {
      api.reply({'id': 'm1', 'handle': 'zed', 'display_name': 'Zed'});
      await repo.fetchPublicProfile('m1');
      await repo.fetchPublicFavorites('m1');
      await repo.fetchPublicLibraryStats('m1');
      await repo.fetchPublicLibrary('m1');
      await repo.fetchPublicActivity('m1');
      await repo.fetchFollowers('m1');
      await repo.fetchFollowing('m1');
      await repo.fetchFriendsWithGame('g1');

      for (final request in api.requests) {
        expect(request.url.path, isNot('/rest/v1/profiles'));
        expect(request.url.path, isNot('/rest/v1/user_games'));
        expect(request.url.path, isNot('/rest/v1/social_follows'));
        expect(request.url.path, isNot('/rest/v1/log_entries'));
      }
    });
  });

  group('achievements', () {
    test('null means never loaded; an empty list means the game has none', () async {
      api.reply({'achievements': null});
      expect(await repo.fetchGameAchievements('u1', 'g1'), isNull);

      api.reply(null); // the game is not in the library
      expect(await repo.fetchGameAchievements('u1', 'g1'), isNull);

      api.reply({'achievements': <Object?>[]});
      expect(await repo.fetchGameAchievements('u1', 'g1'), isEmpty);
    });

    test('parses stored achievements', () async {
      api.reply({
        'achievements': [
          {
            'name': 'First Blood',
            'description': 'Win a fight',
            'icon_url': 'https://example.com/a.jpg',
            'unlocked': true,
            'unlocked_at': '2026-05-05T12:00:00.000Z',
          },
          {'name': 'Hidden', 'unlocked': false, 'unlocked_at': null},
        ],
      });

      final list = (await repo.fetchGameAchievements('u1', 'g1'))!;

      expect(list, hasLength(2));
      expect(list[0].unlocked, isTrue);
      expect(list[0].unlockedAt!.toUtc(), DateTime.utc(2026, 5, 5, 12));
      expect(list[1].description, '');
      expect(list[1].unlockedAt, isNull);
    });
  });

  group('writes', () {
    test('addToCatalog sends only the IGDB id: the server builds the row from IGDB', () async {
      api.reply({'added': [7], 'existing': [], 'unknown': []});
      await repo.addToCatalog(catalogGame());

      expect(api.requests, hasLength(1));
      expect(api.last.method, 'POST');
      expect(api.last.url.path, '/functions/v1/igdb-handler');
      expect(api.bodyOf(api.last), {
        'mode': 'add',
        'igdb_ids': [7],
      });
    });

    test('addToCatalog is done when the game is already in the catalog', () async {
      api.reply({'added': [], 'existing': [7], 'unknown': []});
      await repo.addToCatalog(catalogGame());
      expect(api.requests, hasLength(1));
    });

    test('addToCatalog fails when IGDB has no such game', () async {
      api.reply({'added': [], 'existing': [], 'unknown': [7]});
      await expectLater(repo.addToCatalog(catalogGame()), throwsStateError);
    });

    test('a game and its sessions are removed in one request', () async {
      await repo.deleteUserGame('u1', 'g1');

      expect(api.requests, hasLength(1));
      expect(api.last.method, 'POST');
      expect(api.last.url.path, '/rest/v1/rpc/remove_library_game');
      expect(api.bodyOf(api.last), {'target_game': 'g1'});
    });

    test('the whole library is cleared in one request', () async {
      await repo.clearLibrary('u1');

      expect(api.requests, hasLength(1));
      expect(api.last.method, 'POST');
      expect(api.last.url.path, '/rest/v1/rpc/clear_library');
    });

    test('addToCatalog refuses a game without an IGDB id', () async {
      await expectLater(repo.addToCatalog(catalogGame(igdbId: null)), throwsStateError);
      expect(api.requests, isEmpty);
    });

    test('upsertUserGame writes the status in its database spelling, keyed on user and game', () async {
      await repo.upsertUserGame(
        userId: 'u1',
        gameId: 'g1',
        status: GameStatus.toPlay,
        rating: 3,
        hoursPlayed: 4.5,
        playedOn: GamePlatform.emulator,
        purchasePrice: 0,
        isFavorite: false,
        dateAdded: DateTime.utc(2026, 7, 1, 9),
      );

      expect(api.last.url.queryParameters['on_conflict'], 'user_id,game_id');
      final row = api.bodyOf(api.last) as Map<String, dynamic>;
      expect(row['status'], 'to_play');
      expect(row['rating'], 1.5); // three stars of ten, as the database rates (0 to 5)
      expect(row['played_on'], 'retro'); // how Emulator is stored
      expect(row['date_added'], '2026-07-01T09:00:00.000Z');
      expect(row['is_favorite'], isFalse);
      expect(row.containsKey('custom_backdrop_url'), isTrue);
      expect(row['custom_backdrop_url'], isNull); // the blurred cover
    });

    test('upsertUserGame writes a rating as the database has it: ten stars are 0 to 5', () async {
      // Half a star is a quarter of the database's scale, kept to the tenth.
      for (final (stars, stored) in [
        (0.0, 0.0), (0.5, 0.3), (1.0, 0.5), (6.5, 3.3), (7.0, 3.5), (7.5, 3.8), (9.0, 4.5), (9.5, 4.8), (10.0, 5.0),
        (12.0, 5.0), (-3.0, 0.0),
      ]) {
        await repo.upsertUserGame(
          userId: 'u1',
          gameId: 'g1',
          status: GameStatus.completed,
          rating: stars,
          hoursPlayed: 0,
          playedOn: null,
          purchasePrice: 0,
          isFavorite: false,
        );
        expect((api.bodyOf(api.last) as Map<String, dynamic>)['rating'], stored, reason: '$stars stars');
      }
    });

    test('upsertUserGame sends the chosen backdrop', () async {
      const art = 'https://images.igdb.com/igdb/image/upload/t_1080p/ar5l8.jpg';
      await repo.upsertUserGame(
        userId: 'u1',
        gameId: 'g1',
        status: GameStatus.playing,
        rating: 0,
        hoursPlayed: 1,
        playedOn: null,
        purchasePrice: 0,
        isFavorite: false,
        customBackdropUrl: art,
      );

      final row = api.bodyOf(api.last) as Map<String, dynamic>;
      expect(row['custom_backdrop_url'], art);
    });

    test('upsertUserGame sends whether the game is perfected, false unless said', () async {
      await repo.upsertUserGame(
        userId: 'u1',
        gameId: 'g1',
        status: GameStatus.completed,
        rating: 0,
        hoursPlayed: 1,
        playedOn: GamePlatform.ps5,
        purchasePrice: 0,
        isFavorite: false,
      );
      expect((api.bodyOf(api.last) as Map)['perfected'], isFalse);

      await repo.upsertUserGame(
        userId: 'u1',
        gameId: 'g1',
        status: GameStatus.completed,
        rating: 0,
        hoursPlayed: 1,
        playedOn: GamePlatform.ps5,
        purchasePrice: 0,
        isFavorite: false,
        perfected: true,
      );
      expect((api.bodyOf(api.last) as Map)['perfected'], isTrue);
    });

    test('upsertUserGame sends whether the game is hidden from other members, false unless said', () async {
      Future<void> save({bool? hidden}) => hidden == null
          ? repo.upsertUserGame(
              userId: 'u1',
              gameId: 'g1',
              status: GameStatus.playing,
              rating: 0,
              hoursPlayed: 1,
              playedOn: null,
              purchasePrice: 0,
              isFavorite: false,
            )
          : repo.upsertUserGame(
              userId: 'u1',
              gameId: 'g1',
              status: GameStatus.playing,
              rating: 0,
              hoursPlayed: 1,
              playedOn: null,
              purchasePrice: 0,
              isFavorite: false,
              isHidden: hidden,
            );

      await save();
      expect((api.bodyOf(api.last) as Map)['is_hidden'], isFalse);
      await save(hidden: true);
      expect((api.bodyOf(api.last) as Map)['is_hidden'], isTrue);
    });

    test('setShowSteamAchievements writes only that column of the signed-in user\'s row', () async {
      await signIn('u1');

      await repo.setShowSteamAchievements(false);

      expect(api.last.method, 'PATCH');
      expect(api.last.url.path, '/rest/v1/profiles');
      expect(api.last.url.queryParameters['id'], 'eq.u1');
      expect(api.bodyOf(api.last), {'show_steam_achievements': false});
    });

    test('insertLogEntry trims the note', () async {
      await repo.insertLogEntry(
        userId: 'u1',
        gameId: 'g1',
        hours: 2,
        platform: GamePlatform.ps5,
        note: '  boss down  ',
      );

      final row = api.bodyOf(api.last) as Map<String, dynamic>;
      expect(row['note'], 'boss down');
      expect(row['platform'], 'ps5');
    });
  });

  group('Edge Functions', () {
    test('syncSteamLibrary posts to sync-steam and returns the reply', () async {
      api.reply({
        'success': true,
        'delayed': null,
        'summary': {'added': 3},
      });

      final data = await repo.syncSteamLibrary();

      expect(api.last.method, 'POST');
      expect(api.last.url.path, '/functions/v1/sync-steam');
      expect((data as Map)['summary'], {'added': 3});
      expect(SyncFailure.fromDelayed(data), isNull);
    });

    test('a coded error from the function reaches the app as a SyncFailure', () async {
      api.reply(
        {'error': 'Steam is limiting requests right now', 'code': 'STEAM_RATE_LIMITED', 'retry_after': 300},
        status: 429,
      );

      final error = await repo.syncSteamLibrary().then<Object?>((_) => null, onError: (Object e) => e);

      expect(error, isA<FunctionException>());
      final failure = SyncFailure.from(error!);
      expect(failure.code, SyncFailureCode.steamRateLimited);
      expect(failure.isDelayed, isTrue);
      expect(failure.retryAfter, const Duration(minutes: 5));
    });

    test('syncGameAchievements sends only the game id', () async {
      api.reply({'success': true, 'achievements': <Object?>[]});

      await repo.syncGameAchievements('g1');

      expect(api.last.url.path, '/functions/v1/sync-achievements');
      expect(api.bodyOf(api.last), {'game_id': 'g1'});
    });

    test(
      'startSteamLink asks steam-link for Steam sign-in, and where to come back',
      () async {
        const page =
            'https://steamcommunity.com/openid/login?openid.mode=checkid_setup';
        api
          ..reply({'url': page})
          ..reply({'url': page});

        final opened = await repo.startSteamLink(
          returnTo: Uri.parse('http://127.0.0.1:5000/steam-link'),
        );
        expect(api.last.method, 'POST');
        expect(api.last.url.path, '/functions/v1/steam-link');
        expect(api.bodyOf(api.last), {
          'return_to': 'http://127.0.0.1:5000/steam-link',
        });
        expect(opened, Uri.parse(page));

        // A phone has nowhere to come back to. The Steam ID is never sent.
        await repo.startSteamLink();
        expect(api.bodyOf(api.last), <String, Object?>{});
      },
    );

    test('startSteamLink opens nothing but Steam\'s own page', () async {
      for (final url in [
        'https://evil.example/openid/login',
        'http://steamcommunity.com/openid/login',
        null,
      ]) {
        api.reply({'url': url});
        await expectLater(repo.startSteamLink(), throwsFormatException);
      }
    });

    test('a refused steam-link start reaches the app as a SyncFailure', () async {
      api.reply(
        {'error': 'Too many Steam sign-ins, try again later', 'code': 'RATE_LIMITED', 'retry_after': 1200},
        status: 429,
      );

      final error = await repo.startSteamLink().then<Object?>((_) => null, onError: (Object e) => e);

      final failure = SyncFailure.from(error!);
      expect(failure.code, SyncFailureCode.rateLimited);
      expect(failure.retryAfter, const Duration(minutes: 20));
    });
  });

  group('completion times', () {
    test('the member\'s own time comes with the library row; none is null', () async {
      api.reply([
        {...userGameRow('g1'), 'completion_times': {'category': 'main_extra', 'minutes': 750}},
        // Also read when the API embeds it as a list of one.
        {...userGameRow('g2'), 'completion_times': [{'category': 'completionist', 'minutes': '3000'}]},
        {...userGameRow('g3'), 'completion_times': null},
        // A category this build does not know is no time, not a failed read.
        {...userGameRow('g4'), 'completion_times': {'category': 'speedrun', 'minutes': 30}},
      ]);

      final games = await repo.fetchUserGames('u1');

      expect(api.last.url.queryParameters['select'], contains('completion_times'));
      Game game(String id) => games.firstWhere((g) => g.id == id);
      expect(game('g1').completionTime, const CompletionTime(CompletionCategory.mainExtras, 750));
      expect(game('g2').completionTime, const CompletionTime(CompletionCategory.completionist, 3000));
      expect(game('g3').completionTime, isNull);
      expect(game('g4').completionTime, isNull);
      expect(game('g4').title, 'Hades');
    });

    test('a time is upserted on user and game, in its database spelling', () async {
      await repo.upsertCompletionTime(
        userId: 'u1',
        gameId: 'g1',
        time: const CompletionTime(CompletionCategory.mainStory, 95),
      );

      expect(api.last.url.path, '/rest/v1/completion_times');
      expect(api.last.url.queryParameters['on_conflict'], 'user_id,game_id');
      expect(api.bodyOf(api.last), {'user_id': 'u1', 'game_id': 'g1', 'category': 'main', 'minutes': 95});
    });

    test('a time is deleted for that user and game only', () async {
      await repo.deleteCompletionTime('u1', 'g1');

      expect(api.last.method, 'DELETE');
      expect(api.last.url.path, '/rest/v1/completion_times');
      expect(api.last.url.queryParameters['user_id'], 'eq.u1');
      expect(api.last.url.queryParameters['game_id'], 'eq.g1');
    });

    test('the members\' times are one function call: a median and a count per category', () async {
      api.reply([
        {'category': 'main', 'median_minutes': 1440, 'submissions': 37},
        {'category': 'completionist', 'median_minutes': '6000', 'submissions': '4'},
        // A category this build does not know, and an empty one, are skipped.
        {'category': 'speedrun', 'median_minutes': 30, 'submissions': 9},
        {'category': 'main_extra', 'median_minutes': null, 'submissions': 0},
      ]);

      final times = await repo.fetchCommunityTimes('g1');

      expect(api.last.url.path, '/rest/v1/rpc/completion_time_stats');
      expect(api.bodyOf(api.last), {'target_game': 'g1'});
      expect(times.byCategory.keys, [CompletionCategory.mainStory, CompletionCategory.completionist]);
      final main = times.byCategory[CompletionCategory.mainStory]!;
      expect(main.median, const Duration(hours: 24));
      expect(main.count, 37);
      expect(times.byCategory[CompletionCategory.completionist]!.median, const Duration(hours: 100));

      api.reply(null);
      expect((await repo.fetchCommunityTimes('g2')).byCategory, isEmpty);
    });
  });
}
