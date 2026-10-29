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
            .copyWith(rating: 3.5, review: 'Hard'),
      ]));
      final row = file.rows.single;
      expect(file.skipped, isEmpty);
      expect((row.title, row.igdbId, row.status, row.rating, row.hours, row.playedOn, row.review),
          ('Celeste', 1, GameStatus.dropped, 3.5, 3.25, GamePlatform.nswitch, 'Hard'));
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
        'Odd,2020,borrowed,,\n',
      );
      expect([for (final r in file.rows) (r.title, r.releaseYear, r.status, r.rating, r.hours)], [
        ('Hollow Knight', 2017, GameStatus.completed, 4.5, 40.5),
        ('Hades', null, GameStatus.toPlay, 4.5, null),
        ('Celeste', 2018, GameStatus.wishlist, null, null),
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
          'title,status,rating,hours_played\n'
          'Hades,completed,5,12\n'
          'Celeste,playing,4,3\n'
          'Nonexistent Game,to_play,,\n',
        ).rows,
        api: api,
        library: stores.library,
        pause: Duration.zero,
      );
      await run.run();

      expect(api.searched, ['Celeste', 'Nonexistent Game']); // Hades is in the library
      final hades = stores.library.gameById(gameIdForIgdb(10));
      expect((hades.status, hades.rating, hades.hoursPlayed), (GameStatus.completed, 5.0, 50.0)); // hours never go down
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
