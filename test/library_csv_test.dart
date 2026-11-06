import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/library_csv.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/screens/settings/data_section.dart';
import 'package:checkpoint/services/game_api_service.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_import.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/utils/csv.dart';

import 'support/fakes.dart';

/// IGDB search answered from a list, by title words.
class _SearchApi extends GameApiService {
  _SearchApi(this.catalog);
  final List<Game> catalog;
  final List<String> searched = [];
  bool down = false;

  @override
  Future<ResultsPage<Game>?> searchGames(String query, {FilterOptions filters = FilterOptions.none, int offset = 0, int limit = 20}) async {
    searched.add(query);
    if (down) return null;
    final q = query.toLowerCase();
    return ResultsPage([for (final g in catalog) if (g.title.toLowerCase().contains(q)) g], hasMore: false);
  }
}

Game catalogGame(String title, int igdbId, {int year = 2020}) =>
    testGame(gameIdForIgdb(igdbId), title: title, status: null, igdbId: igdbId, year: year, hours: 0, cover: false);

void main() {
  group('export', () {
    test('the library is one game per line, A to Z, with what Gamebit keeps of it', () {
      final rows = parseCsv(libraryCsv([
        testGame('b', title: 'zelda', cover: false, igdbId: 2).copyWith(review: 'Great, "really"'),
        testGame('a', title: 'Celeste', cover: false, igdbId: 1, status: GameStatus.completed).withCompletedAt(DateTime(2026, 3, 2)),
        testGame('c', title: 'Not mine', status: null, cover: false),
      ]));
      expect(rows.first, libraryCsvColumns);
      expect(rows.map((r) => r.first).skip(1), ['Celeste', 'zelda']);
      expect(rows[1][2], 'completed');
      expect(rows[1][7], '2026-03-02');
      expect(rows[2][9], 'Great, "really"');
    });

    test('sessions carry the game, when, how long, where, and whether Steam logged them', () {
      final rows = parseCsv(sessionsCsv(
        [LogEntry(id: 's1', gameId: 'a', timestamp: DateTime.utc(2026, 1, 2, 3), hours: 1.5, platform: GamePlatform.steamDeck, note: 'n', fromSteam: true)],
        (id) => id == 'a' ? testGame('a', title: 'Hades', igdbId: 7) : null,
      ));
      expect(rows[1], ['2026-01-02T03:00:00.000Z', 'Hades', '7', '1.5', 'steamDeck', 'n', 'steam']);
    });

    test('an export reads back in as the same games', () {
      final file = ImportRow.parse(libraryCsv([
        testGame('a', title: 'Celeste', cover: false, igdbId: 1, status: GameStatus.dropped, hours: 3.25, playedOn: GamePlatform.nswitch)
            .copyWith(rating: 7.5, review: 'Hard'),
      ]));
      final row = file.rows.single;
      expect(file.skipped, isEmpty);
      expect((row.title, row.igdbId, row.status, row.rating, row.hours, row.playedOn, row.review),
          ('Celeste', 1, GameStatus.dropped, 7.5, 3.25, GamePlatform.nswitch, 'Hard'));
    });

    test('the rating column says it is out of 10, so a rating of 3 stays 3', () {
      final csv = libraryCsv([testGame('a', title: 'Celeste', cover: false).copyWith(rating: 3)]);
      expect(parseCsv(csv).first[3], 'rating_out_of_10');
      expect(ImportRow.parse(csv).rows.single.rating, 3.0);
    });

    test('an export from before the ten stars has its rating out of 5', () {
      final file = ImportRow.parse('title,status,rating\nCeleste,completed,4.5\nHades,completed,1\n');
      expect([for (final r in file.rows) r.rating], [9.0, 2.0]);
    });

    test('a rating is kept to the half star, within 0.5 to 10', () {
      final file = ImportRow.parse('title,rating_out_of_10\nA,7.4\nB,7.8\nC,0.2\nD,11\nE,6.5\n');
      expect([for (final r in file.rows) r.rating], [7.5, 8.0, 0.5, 10.0, 6.5]);
    });
  });

  group('reading another tracker\'s file', () {
    test('takes other column names, status words and rating scales', () {
      final file = ImportRow.parse(
        'Name,Year,Shelf,My Rating,Playtime\n'
        'Hollow Knight,2017,Beaten,9,40:30\n'
        'Hades,,backlog,85,\n'
        'Celeste,2018,wanted,,\n'
        ',2020,playing,,\n'
        'Odd,2020,borrowed,,\n'
        'Tunic,2022,done,3.5,\n',
      );
      expect([for (final r in file.rows) (r.title, r.releaseYear, r.status, r.rating, r.hours)], [
        ('Hollow Knight', 2017, GameStatus.completed, 9.0, 40.5),
        ('Hades', null, GameStatus.toPlay, 8.5, null),
        ('Celeste', 2018, GameStatus.wishlist, null, null),
        ('Tunic', 2022, GameStatus.completed, 7.0, null),
      ]);
      expect(file.skipped, ['Line 5: no title.', 'Line 6 (Odd): unknown status "borrowed".']);
    });

    test('a file without a title column says so', () {
      expect(ImportRow.parse('foo,bar\n1,2\n').skipped, ['No "title" column in the first row.']);
    });

    test('a game is only matched when sure: its IGDB id, or its exact title and year', () {
      final hits = [catalogGame('Doom', 1, year: 1993), catalogGame('DOOM', 2, year: 2016), catalogGame('Doom Eternal', 3)];
      ImportRow row({int? id, int? year}) => ImportRow(line: 2, title: 'Doom', igdbId: id, releaseYear: year);
      expect(matchImportRow(row(id: 3), hits)?.igdbId, 3);
      expect(matchImportRow(row(id: 9), hits), isNull);
      expect(matchImportRow(row(year: 2016), hits)?.igdbId, 2);
      expect(matchImportRow(row(year: 2005), hits), isNull);
      expect(matchImportRow(ImportRow(line: 2, title: 'Doom Eternal'), hits)?.igdbId, 3);
    });

    test('accents do not tell two titles apart', () {
      final hits = [catalogGame('Pokémon Red', 1)];
      expect(matchImportRow(ImportRow(line: 2, title: 'Pokemon Red'), hits)?.igdbId, 1);
      expect(matchImportRow(ImportRow(line: 2, title: 'POKÉMON  RED'), hits)?.igdbId, 1);
    });

    test('a game played on a console is the entry released on it, and any entry when none was', () {
      Game metroid(int igdbId, GamePlatform platform) =>
          testGame(gameIdForIgdb(igdbId), title: 'Metroid', status: null, igdbId: igdbId, hours: 0, cover: false, platforms: [platform]);
      final original = metroid(1, GamePlatform.nes);
      final remake = metroid(2, GamePlatform.gba);
      ImportRow row(GamePlatform? on) => ImportRow(line: 2, title: 'Metroid', playedOn: on);

      expect(matchImportRow(row(GamePlatform.nes), [remake, original])?.igdbId, 1);
      expect(matchImportRow(row(GamePlatform.gba), [original, remake])?.igdbId, 2);
      // A console that none of them was released on rules none of them out.
      expect(matchImportRow(row(GamePlatform.pc), [original])?.igdbId, 1);
      expect(matchImportRow(row(null), [remake, original])?.igdbId, 2);
    });
  });

  group('reading a Grouvee export', () {
    /// The columns the tools that read Grouvee's file name; the JSON ones are
    /// written as Grouvee's tools read them (only the keys of shelves and
    /// platforms, and the seconds of each playthrough, are used).
    String grouvee(List<List<Object?>> rows) => toCsv([
      ['id', 'name', 'giantbomb_id', 'release_date', 'shelves', 'statuses', 'dates', 'rating', 'platforms'],
      ...rows,
    ]);
    String shelves(List<String> names) => jsonEncode({for (final n in names) n: {'date_added': '2021-01-02'}});
    String playthroughs(List<double> seconds) => jsonEncode([
      for (final s in seconds)
        {'date_started': 'None', 'date_finished': 'None', 'seconds_played': s, 'level_of_completion': 'None'},
    ]);
    String platforms(List<String> names) => jsonEncode({for (final n in names) n: {}});

    test('shelves become statuses, playthroughs hours, and the platform and year come along', () {
      final file = ImportRow.parse(grouvee([
        [1, 'Hades', 111, '2020-09-17', shelves(['Played']), '{}', playthroughs([36000, 7200]), 5, platforms(['PC', 'Nintendo Switch'])],
        [2, 'Celeste', 222, '2018', shelves(['Played', 'Playing']), '{}', '[]', 4, platforms(['Nintendo Switch'])],
        [3, 'Outer Wilds', 333, '', shelves(['Wish List']), '{}', playthroughs([0]), '', '{}'],
        [4, 'Cuphead', 444, '2017-09-29', shelves(['Abandoned']), '{}', '[]', 3, '{}'],
        [5, 'Tunic', 555, '2022-03', shelves(['Backlog']), '{}', '[]', '', '{}'],
        [6, 'Odd', 666, '', shelves(['Favorites']), '{}', '[]', '', '{}'],
      ]));

      expect(file.source, ImportSource.grouvee);
      expect(file.skipped, isEmpty);
      expect([for (final r in file.rows) (r.title, r.releaseYear, r.status, r.rating, r.hours, r.playedOn)], [
        ('Hades', 2020, GameStatus.completed, 10.0, 12.0, GamePlatform.pc),
        ('Celeste', 2018, GameStatus.playing, 8.0, null, GamePlatform.nswitch),
        ('Outer Wilds', null, GameStatus.wishlist, null, null, null),
        ('Cuphead', 2017, GameStatus.dropped, 6.0, null, null),
        ('Tunic', 2022, GameStatus.toPlay, null, null, null),
        // A shelf of the member's own is no reason to leave a game out.
        ('Odd', null, GameStatus.toPlay, null, null, null),
      ]);
      // Grouvee's ids are not IGDB's: games are looked up by title.
      expect(file.rows.every((r) => r.igdbId == null), isTrue);
    });

    test('shelves that are not JSON are read as a list of names', () {
      final file = ImportRow.parse(grouvee([
        [1, 'Hades', '', '', 'Played, Backlog', '', '', '', ''],
      ]));
      expect(file.rows.single.status, GameStatus.completed);
    });

    test('shelves given as a list of objects with a name are read too', () {
      final file = ImportRow.parse(grouvee([
        [1, 'Hades', '', '', jsonEncode([{'name': 'Played', 'added': '2017-01-31T14:30:39+00:00'}]), '', '', '', ''],
        [2, 'Celeste', '', '', jsonEncode([{'name': 'Played'}, {'name': 'Playing'}, {'url': 'x'}, 5]), '', '', '', ''],
        [3, 'Tunic', '', '', jsonEncode(['Wish List']), '', '', '', ''],
      ]));
      expect([for (final r in file.rows) r.status], [GameStatus.completed, GameStatus.playing, GameStatus.wishlist]);
    });

    test('a cell that is not the JSON it should be costs the game nothing but that detail', () {
      final file = ImportRow.parse(grouvee([
        [1, 'Hades', '', '', shelves(['Playing']), '', 'not json', 5, '[1,2'],
      ]));
      expect((file.rows.single.status, file.rows.single.hours, file.rows.single.playedOn), (GameStatus.playing, null, null));
    });

    test('any other file is read as before, and a release date gives its year', () {
      final file = ImportRow.parse('Name,Release Date\nHades,2020-09-17\n');
      expect(file.source, ImportSource.generic);
      expect(file.rows.single.releaseYear, 2020);
    });

    testWidgets('the import screen says the file was recognized', (tester) async {
      Future<void> show(String text) async {
        await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: ImportScreen(file: ImportRow.parse(text))));
      }

      await show(grouvee([
        [1, 'Hades', '', '', shelves(['Played']), '', '', '', ''],
      ]));
      expect(find.text('1 game to import'), findsOneWidget);
      expect(find.textContaining('Grouvee export recognized'), findsOneWidget);

      await show('title\nHades\n');
      expect(find.textContaining('Grouvee export recognized'), findsNothing);
    });
  });

  group('reading a Backloggd export', () {
    /// The header the Backloggd+ extension writes (from its source), and one line
    /// per game from the named columns; the others are empty, as the extension
    /// leaves them for a game with no playthrough.
    const header = [
      'ID', 'Game Name', 'Played', 'Currently Playing', 'In Backlog', 'In Wishlist', 'Liked', 'Rating', 'Mastered',
      'Start Date', 'Finish Date', 'Total Hours', 'Total Minutes', 'Playthrough Hours', 'Playthrough Minutes',
      'Playthrough Hours to Finish', 'Playthrough Minutes to Finish', 'Playthrough Hours to Master',
      'Playthrough Minutes to Master', 'Replay', 'Review', 'Review Contains Spoilers', 'Backloggd URL',
    ];
    String backloggd(List<Map<String, Object?>> games, {List<String> columns = header}) => toCsv([
      columns,
      for (final g in games) [for (final c in columns) g[c] ?? (c == 'Backloggd URL' ? 'https://backloggd.com/games/x/' : '')],
    ]);
    Map<String, Object?> game(String name, {bool played = false, bool playing = false, bool backlog = false, bool wishlist = false, Object? rating = '', Object? hours = 0, Object? minutes = 0, String review = ''}) => {
      'ID': 1,
      'Game Name': name,
      'Played': played,
      'Currently Playing': playing,
      'In Backlog': backlog,
      'In Wishlist': wishlist,
      'Rating': rating,
      'Total Hours': hours,
      'Total Minutes': minutes,
      'Review': review,
    };

    test('the lists become statuses, the one furthest along winning', () {
      final file = ImportRow.parse(backloggd([
        game('Hades', played: true),
        game('Celeste', playing: true, played: true),
        game('Tunic', backlog: true),
        game('Outer Wilds', wishlist: true),
        game('Cuphead', played: true, backlog: true),
        game('Odd'),
      ]));

      expect(file.source, ImportSource.backloggd);
      expect(file.skipped, isEmpty);
      expect([for (final r in file.rows) (r.title, r.status)], [
        ('Hades', GameStatus.completed),
        ('Celeste', GameStatus.playing),
        ('Tunic', GameStatus.toPlay),
        ('Outer Wilds', GameStatus.wishlist),
        ('Cuphead', GameStatus.completed),
        // On none of the lists: kept in the backlog rather than left out.
        ('Odd', GameStatus.toPlay),
      ]);
      // Backloggd's ids are not IGDB's: games are looked up by title.
      expect(file.rows.every((r) => r.igdbId == null), isTrue);
    });

    test('ratings are out of 10, so 10 is the top mark', () {
      final file = ImportRow.parse(backloggd([
        game('A', played: true, rating: 10),
        game('B', played: true, rating: 7),
        game('C', played: true, rating: 1),
        game('D', played: true, rating: ''),
        game('E', played: true, rating: 0),
      ]));
      expect([for (final r in file.rows) r.rating], [10.0, 7.0, 1.0, null, null]);
    });

    test('a file with a fractional rating is in stars out of 5', () {
      final file = ImportRow.parse(backloggd([
        game('A', played: true, rating: 5),
        game('B', played: true, rating: 3.5),
        game('C', played: true, rating: 4),
      ]));
      expect([for (final r in file.rows) r.rating], [10.0, 7.0, 8.0]);
    });

    test('hours are the totals, with the minutes beyond them', () {
      final file = ImportRow.parse(backloggd([
        game('A', played: true, hours: 12, minutes: 30),
        game('B', played: true, hours: 0, minutes: 45),
        game('C', played: true, hours: 8, minutes: 0),
        game('D', played: true),
        // Minutes are those beyond the whole hours: 90 is no such figure.
        game('E', played: true, hours: 5, minutes: 90),
      ]));
      expect([for (final r in file.rows) r.hours], [12.5, 0.75, 8.0, null, 5.0]);
    });

    test('hours come from the first playthrough when the totals are empty', () {
      final file = ImportRow.parse(backloggd([
        {...game('A', played: true), 'Total Hours': '', 'Total Minutes': '', 'Playthrough Hours': 20, 'Playthrough Minutes': 15},
      ]));
      expect(file.rows.single.hours, 20.25);
    });

    test('the review comes along, commas and new lines and all', () {
      final file = ImportRow.parse(backloggd([game('A', played: true, review: 'Great, really.\nSecond line.')]));
      expect(file.rows.single.review, 'Great, really.\nSecond line.');
    });

    test('the lists alone tell it from a spreadsheet when the link is missing', () {
      final file = ImportRow.parse(backloggd(
        [game('Hades', played: true)],
        columns: ['Game Name', 'Played', 'Currently Playing', 'In Backlog', 'In Wishlist', 'Rating'],
      ));
      expect(file.source, ImportSource.backloggd);
      expect(file.rows.single.status, GameStatus.completed);
    });

    test('a spreadsheet with a Played column of its own is not mistaken for one', () {
      final file = ImportRow.parse('Name,Played,Rating\nHades,yes,4\n');
      expect(file.source, ImportSource.generic);
      expect(file.rows.single.status, GameStatus.toPlay);
    });

    testWidgets('the import screen says the file was recognized', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: buildTheme(), home: ImportScreen(file: ImportRow.parse(backloggd([game('Hades', played: true)])))),
      );
      expect(find.text('1 game to import'), findsOneWidget);
      expect(find.textContaining('Backloggd export recognized'), findsOneWidget);
      expect(find.textContaining('Grouvee export recognized'), findsNothing);
    });
  });

  group('importing', () {
    late FakeRepository repo;
    late AppStores stores;
    late _SearchApi api;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repo = FakeRepository()..library = [testGame(gameIdForIgdb(10), title: 'Hades', igdbId: 10, hours: 50, cover: false)];
      stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      api = _SearchApi([catalogGame('Celeste', 20, year: 2018), catalogGame('Outer Wilds', 30)]);
      await stores.initialize();
    });
    tearDown(() => stores.dispose());

    test('updates games already in the library, adds found ones, and lists the rest', () async {
      final run = LibraryImport(
        rows: ImportRow.parse(
          'title,status,rating_out_of_10,hours_played\n'
          'Hades,completed,9,12\n'
          'Celeste,playing,8,3\n'
          'Nonexistent Game,to_play,,\n',
        ).rows,
        api: api,
        library: stores.library,
        pause: Duration.zero,
      );
      await run.run();

      expect(api.searched, ['Celeste', 'Nonexistent Game']); // Hades is in the library
      final hades = stores.library.gameById(gameIdForIgdb(10));
      expect((hades.status, hades.rating, hades.hoursPlayed), (GameStatus.completed, 9.0, 50.0)); // hours never go down
      expect(hades.completedAt, isNotNull);
      final celeste = stores.library.gameById(gameIdForIgdb(20));
      expect((celeste.status, celeste.hoursPlayed), (GameStatus.playing, 3.0));
      expect(repo.writes, contains('base:${gameIdForIgdb(20)}'));
      expect(repo.writes.where((w) => w.startsWith('log:')), isEmpty); // no sessions for history
      expect(run.imported, 2);
      expect(run.unmatched.map((r) => r.title), ['Nonexistent Game']);
      expect(run.isFinished, isTrue);
    });

    test('says when IGDB could not be reached', () async {
      api.down = true;
      final run = LibraryImport(rows: ImportRow.parse('title\nCeleste\n').rows, api: api, library: stores.library, pause: Duration.zero);
      await run.run();
      expect(run.searchFailed, isTrue);
      expect(run.unmatched, hasLength(1));
    });
  });

  testWidgets('Your data saves the library as a file, and imports one', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeRepository()..library = [testGame('g1', title: 'Hades', cover: false)];
    final stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
    await tester.runAsync(stores.initialize);
    String? savedName;
    List<int>? savedBytes;
    await tester.pumpWidget(AppStoresScope(
      stores: stores,
      child: MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: DataSection(
            saveFile: (name, bytes, origin) async {
              savedName = name;
              savedBytes = bytes;
              return true;
            },
            pickFile: () async => 'title,status\nHades,completed\nNope,wishlist\nBad,???\n',
          ),
        ),
      ),
    ));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export library'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(savedName, startsWith('gamebit-library-'));
    expect(String.fromCharCodes(savedBytes!.skip(3)), startsWith('title,igdb_id,status'));
    expect(find.text('Exported $savedName'), findsOneWidget);

    await tester.tap(find.text('Import from CSV'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
    expect(find.byType(ImportScreen), findsOneWidget);
    expect(find.text('2 games to import'), findsOneWidget);
    expect(find.text('Line 4 (Bad): unknown status "???".'), findsOneWidget);
  });
}
