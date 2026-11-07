import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/activity_entry.dart';
import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/library_csv.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/models/milestone_progress.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/services/game_api_service.dart';
import 'package:checkpoint/services/playstation/psn_client.dart';
import 'package:checkpoint/services/playstation/psn_device.dart';
import 'package:checkpoint/services/playstation/psn_library.dart';
import 'package:checkpoint/services/playstation/psn_sessions.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_import.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/recent_activity_panel.dart';

import 'support/fakes.dart';

/// Play sessions from PlayStation play time, and the exact time shown on Recent
/// Activity: against made-up answers, nothing here talks to Sony.

void _quiet() {
  final print = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {};
  addTearDown(() => debugPrint = print);
}

class _Api extends GameApiService {
  _Api(this.answers);
  final Map<String, List<Game>> answers;

  @override
  Future<ResultsPage<Game>?> searchGames(String query, {FilterOptions filters = FilterOptions.none, int offset = 0, int limit = 20}) async =>
      ResultsPage(answers[query.toLowerCase()] ?? const [], hasMore: false);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('the rules', () {
    final now = DateTime.utc(2026, 11, 7, 12);
    final lastPlayed = DateTime.utc(2026, 11, 6, 19, 30);

    PsnPlaytimeUpdate update({required int minutes, int? before, DateTime? played}) =>
        psnPlaytimeUpdate(minutes: minutes, before: before, lastPlayed: played ?? lastPlayed, now: now);

    test('a game seen for the first time is history: only the baseline is kept', () {
      final u = update(minutes: 600);
      expect(u.baseline, 600);
      expect(u.session, isNull);
    });

    test('a rise is logged as a session, dated when Sony says it was last played', () {
      final u = update(minutes: 690, before: 600);
      expect(u.baseline, 690);
      expect(u.session!.hours, 1.5);
      expect(u.session!.at, lastPlayed);
    });

    test('hours are rounded to hundredths', () {
      expect(update(minutes: 107, before: 100).session!.hours, 0.12);
    });

    test('a rise under five minutes keeps the old baseline, so short plays add up', () {
      final u = update(minutes: 603, before: 600);
      expect(u.baseline, 600);
      expect(u.session, isNull);
      expect(update(minutes: 605, before: 600).session!.hours, 0.08);
    });

    test('a play time that went down is the new baseline, with no session', () {
      final u = update(minutes: 500, before: 600);
      expect(u.baseline, 500);
      expect(u.session, isNull);
    });

    test('an unchanged play time logs nothing', () {
      final u = update(minutes: 600, before: 600);
      expect(u.baseline, 600);
      expect(u.session, isNull);
    });

    test('without a last-played time, or with one in the future, the session is dated now', () {
      final none = psnPlaytimeUpdate(minutes: 700, before: 600, lastPlayed: null, now: now);
      expect(none.session!.at, now);
      expect(update(minutes: 700, before: 600, played: DateTime.utc(2026, 12, 1)).session!.at, now);
    });
  });

  group('the import', () {
    final now = DateTime.utc(2026, 11, 7, 12);

    PsnPlayedGame pg(String name, {int minutes = 0, String category = 'ps5_native_game', DateTime? last}) =>
        PsnPlayedGame(name: name, category: category, playTime: Duration(minutes: minutes), lastPlayed: last ?? DateTime.utc(2026, 11, 6, 19, 30));

    ImportFile build(List<PsnPlayedGame> played, Map<String, int> before) =>
        buildPsnImport(PsnLibrary(played: played, trophies: const []), playtimeBefore: before, now: now);

    test('a game the phone has not seen only has its play time remembered', () {
      final row = build([pg('Hades', minutes: 600)], const {}).rows.single;
      expect(row.session, isNull);
      expect((row.playtimeKey, row.playtimeMinutes), ('hades', 600));
      expect(row.hours, 10);
    });

    test('a game played since the last sync carries the rise as a session', () {
      final row = build([pg('Hades', minutes: 690)], {'hades': 600}).rows.single;
      expect(row.session!.hours, 1.5);
      expect(row.session!.at, DateTime.utc(2026, 11, 6, 19, 30));
      expect((row.playtimeKey, row.playtimeMinutes), ('hades', 690));
      // The hours are the game's total, as before: the session is part of them.
      expect(row.hours, 11.5);
    });

    test('a game not played since has nothing to log or to remember', () {
      final row = build([pg('Hades', minutes: 600)], {'hades': 600}).rows.single;
      expect(row.session, isNull);
      expect(row.playtimeKey, isNull);
      expect(row.playtimeMinutes, isNull);
    });

    test('a game with no play time (a PS3 game) is not tracked', () {
      final row = build([pg('Journey', category: 'unknown')], const {}).rows.single;
      expect(row.session, isNull);
      expect(row.playtimeKey, isNull);
    });

    test('the same game on two consoles is one rise, dated by the newer play', () {
      final row = build(
        [
          pg('Hades', minutes: 400, category: 'ps4_game', last: DateTime.utc(2026, 11, 1)),
          pg('Hades', minutes: 350, category: 'ps5_native_game', last: DateTime.utc(2026, 11, 5)),
        ],
        {'hades': 700},
      ).rows.single;
      expect(row.session!.hours, 0.83);
      expect(row.session!.at, DateTime.utc(2026, 11, 5));
      expect(row.playedOn, GamePlatform.ps5);
    });

    test('the trophy list\'s date is not play time', () {
      final file = buildPsnImport(
        PsnLibrary(
          played: [pg('Hades', minutes: 700, last: DateTime.utc(2026, 11, 2))],
          trophies: [
            PsnTrophyTitle(name: 'Hades', platform: 'PS5', earned: 1, total: 10, platinumEarned: false, lastUpdated: DateTime.utc(2026, 11, 6)),
          ],
        ),
        playtimeBefore: {'hades': 600},
        now: now,
      );
      expect(file.rows.single.session!.at, DateTime.utc(2026, 11, 2));
    });

    test('hands both callbacks on', () {
      final file = buildPsnImport(PsnLibrary(played: const [], trophies: const []), onPlaytimeLogged: (_) {}, onRowImported: (_) {});
      expect(file.onPlaytimeLogged, isNotNull);
      expect(file.onRowImported, isNotNull);
    });
  });

  group('into the library', () {
    late FakeRepository repo;
    late AppStores stores;
    final id = gameIdForIgdb(20);

    setUp(() async {
      _quiet();
      repo = FakeRepository();
      stores = AppStores(repository: repo, authService: FakeAuthService(testUser('u1')), connectivity: FakeConnectivity(), apiService: FakeBrowseApi());
      await stores.initialize();
    });
    tearDown(() => stores.dispose());

    LibraryImport run(List<ImportRow> rows, {List<String>? told}) => LibraryImport(
      rows: rows,
      api: _Api({'celeste': [testGame(id, title: 'Celeste', status: null, igdbId: 20, cover: false, hours: 0)]}),
      library: stores.library,
      pause: Duration.zero,
      onPlaytimeLogged: told == null ? null : (r) => told.add('${r.playtimeKey}:${r.playtimeMinutes}'),
    );

    final at = DateTime.utc(2026, 11, 6, 19, 30);
    ImportRow row({ImportSession? session, double hours = 12}) => ImportRow(
      line: 1,
      title: 'Celeste',
      status: GameStatus.playing,
      hours: hours,
      playedOn: GamePlatform.ps5,
      session: session,
      playtimeKey: 'celeste',
      playtimeMinutes: (hours * 60).round(),
    );

    test('logs the rise as a PlayStation session at the time Sony gave, and leaves the hours alone', () async {
      final told = <String>[];
      final import = run([row(session: ImportSession(hours: 2, at: at))], told: told);
      await import.run();

      expect(repo.playStationLogs, [id]);
      expect(repo.logTimes.single!.toUtc(), at);
      // 12 hours is PlayStation's total; the 2 hours are part of it, not on top.
      expect(stores.library.gameById(id).hoursPlayed, 12);
      expect(told, ['celeste:720']);
    });

    test('shows the session at once, tagged, and reads the real ones once at the end', () async {
      final import = run([row(session: ImportSession(hours: 2, at: at))]);
      final reads = repo.logFetches;
      await import.run();

      final session = stores.library.sessions.firstWhere((s) => s.fromPlayStation);
      expect(session.hours, 2);
      expect(session.platform, GamePlatform.ps5);
      expect(session.fromSteam, isFalse);
      expect(session.isSynced, isTrue);
      expect(repo.logFetches, reads + 1);
    });

    test('a row with no session still tells the phone its play time, and reads no sessions', () async {
      final told = <String>[];
      final reads = repo.logFetches;
      await run([row()], told: told).run();
      expect(repo.playStationLogs, isEmpty);
      expect(told, ['celeste:720']);
      expect(repo.logFetches, reads);
    });

    test('a session the server did not keep is not told, so the next sync finds the rise again', () async {
      repo.writesDown = true;
      final told = <String>[];
      final import = run([row(session: ImportSession(hours: 2, at: at))], told: told);
      await import.run();

      expect(repo.playStationLogs, isEmpty);
      expect(told, isEmpty);
      expect(stores.library.sessions.where((s) => s.fromPlayStation), isEmpty);
      expect(import.imported, 1);
    });

    test('a session of a game that was not imported is not logged', () async {
      final import = LibraryImport(
        rows: [row(session: ImportSession(hours: 2, at: at))],
        api: _Api(const {}),
        library: stores.library,
        pause: Duration.zero,
      );
      await import.run();
      expect(repo.playStationLogs, isEmpty);
      expect(import.unmatched, hasLength(1));
    });
  });

  group('what the phone remembers', () {
    test('each game\'s play time, per account', () async {
      final device = PsnDevice();
      expect(await device.storedPlaytime('u1'), isEmpty);

      await device.rememberPlaytime('u1', 'hades', 600);
      await device.rememberPlaytime('u1', 'celeste', 90);
      await device.rememberPlaytime('u1', 'hades', 690);
      await device.rememberPlaytime('u2', 'hades', 5);

      expect(await device.storedPlaytime('u1'), {'hades': 690, 'celeste': 90});
      expect(await device.storedPlaytime('u2'), {'hades': 5});
    });

    test('forgetting the sign-in keeps them, deleting the account does not', () async {
      final device = PsnDevice();
      await device.rememberPlaytime('u1', 'hades', 600);

      await device.forget('u1');
      expect(await device.storedPlaytime('u1'), {'hades': 600});

      await device.forgetAll('u1');
      expect(await device.storedPlaytime('u1'), isEmpty);
    });

    test('anything unreadable counts as nothing seen', () async {
      SharedPreferences.setMockInitialValues({'psn_playtime_u1': 'not json'});
      expect(await PsnDevice().storedPlaytime('u1'), isEmpty);
      SharedPreferences.setMockInitialValues({'psn_playtime_u1': jsonEncode({'a': 5, 'b': 'x', 'c': 1.5})});
      expect(await PsnDevice().storedPlaytime('u1'), {'a': 5});
    });
  });

  group('a session', () {
    LogEntry session({bool steam = false, bool playStation = false}) => LogEntry(
      id: 's',
      gameId: 'g',
      timestamp: DateTime.utc(2026, 2, 3),
      hours: 1,
      platform: GamePlatform.ps5,
      fromSteam: steam,
      fromPlayStation: playStation,
    );

    test('says it came from PlayStation, in the saved copy too', () {
      final read = LogEntry.fromJson(session(playStation: true).toJson());
      expect(read.fromPlayStation, isTrue);
      expect(read.fromSteam, isFalse);
      expect(session(playStation: true).toJson()['source'], 'playstation');
      expect(LogEntry.fromJson(session().toJson()).isSynced, isFalse);
      expect(session(steam: true).isSynced, isTrue);
    });

    test('is not one the member logged, for the milestones', () {
      final mine = MilestoneProgress.of(library: const [], sessions: [session(), session(steam: true), session(playStation: true)]);
      expect(mine.valueOf(MilestoneMetric.sessions), 1);
    });

    test('is exported with its source', () {
      final csv = sessionsCsv([session(playStation: true), session(steam: true), session()], (_) => null);
      final lines = const LineSplitter().convert(csv.trim());
      expect(lines[1].split(',').last, 'playstation');
      expect(lines[2].split(',').last, 'steam');
      expect(lines[3].split(',').last, '');
    });
  });

  group('the exact time', () {
    test('is written time first, then the day, month and year', () {
      expect(fmtDateTime(DateTime(2026, 1, 1, 19, 30)), '19:30 01.01.2026');
      expect(fmtDateTime(DateTime(2026, 3, 4, 7, 5)), '07:05 04.03.2026');
      expect(fmtDateTime(DateTime(2026, 12, 31, 0, 0)), '00:00 31.12.2026');
    });

    testWidgets('shows on each row of the recent activity panel, beside how long ago', (tester) async {
      final at = DateTime.now().subtract(const Duration(hours: 3));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: RecentActivityPanel(
              entries: [ActivityEntry(game: testGame('a', title: 'Celeste', status: null, cover: false), hours: 2, platform: GamePlatform.ps5, at: at)],
            ),
          ),
        ),
      );
      expect(find.text(fmtDateTime(at)), findsOneWidget);
      expect(find.text(timeAgo(at)), findsOneWidget);
    });
  });
}
