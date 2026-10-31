import 'dart:convert';

import 'package:checkpoint/data/db_schema.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/limits.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/utils/csv.dart';

/// The columns of an exported library, in order. An import reads the same
/// names (and a few others: see [ImportRow.parse]).
const libraryCsvColumns = [
  'title', 'igdb_id', 'status', 'rating', 'hours_played', 'played_on',
  'date_added', 'completed_at', 'favorite', 'review', 'release_year',
  'platforms', 'genres',
];

/// The member's library as CSV: one game per line, A to Z.
String libraryCsv(List<Game> games) {
  final sorted = [for (final g in games) if (g.inLibrary) g]
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return toCsv([
    libraryCsvColumns,
    for (final g in sorted)
      [
        g.title,
        g.igdbId,
        gameStatusToDb(g.status!),
        g.rating > 0 ? g.rating : '',
        g.hoursPlayed,
        g.playedOn == null ? '' : gamePlatformToDb(g.playedOn!),
        _day(g.dateAdded),
        _day(g.completedAt),
        g.isFavorite ? 'yes' : '',
        g.review,
        g.hasReleaseYear ? g.releaseYear : '',
        g.platforms.map(gamePlatformToDb).join(';'),
        g.genres.join(';'),
      ],
  ]);
}

/// Every play session as CSV, newest first, with the game's title and IGDB id.
String sessionsCsv(List<LogEntry> sessions, Game? Function(String gameId) gameOf) => toCsv([
  ['logged_at', 'title', 'igdb_id', 'hours', 'platform', 'note', 'source'],
  for (final s in sessions)
    [
      s.timestamp.toUtc().toIso8601String(),
      gameOf(s.gameId)?.title ?? '',
      gameOf(s.gameId)?.igdbId,
      s.hours,
      gamePlatformToDb(s.platform),
      s.note,
      s.fromSteam ? 'steam' : '',
    ],
]);

String _day(DateTime? d) => d == null ? '' : d.toIso8601String().substring(0, 10);

/// One game of an imported file, as far as it could be read.
class ImportRow {
  const ImportRow({
    required this.line,
    required this.title,
    this.igdbId,
    this.releaseYear,
    this.status = GameStatus.toPlay,
    this.rating,
    this.hours,
    this.playedOn,
    this.review,
  });

  /// The line of the file it came from (the header is line 1).
  final int line;
  final String title;
  final int? igdbId;
  final int? releaseYear;
  final GameStatus status;

  /// Out of 5, in halves; null when the file has none.
  final double? rating;
  final double? hours;
  final GamePlatform? playedOn;
  final String? review;

  /// The most rows one import takes.
  static const maxRows = 500;

  /// Reads a library file: Gamebit's own export, or a spreadsheet with a
  /// header row naming at least the title. The rows that can't be used are
  /// listed in [ImportFile.skipped] with why.
  static ImportFile parse(String text) {
    final rows = parseCsv(text);
    final l10n = L10n.current;
    if (rows.isEmpty) return ImportFile(rows: const [], skipped: [l10n.importFileEmpty]);
    final header = [for (final h in rows.first) _key(h)];
    int? col(List<String> names) {
      for (final name in names) {
        final i = header.indexOf(name);
        if (i != -1) return i;
      }
      return null;
    }

    final title = col(['title', 'name', 'game', 'gametitle', 'gamename']);
    if (title == null) {
      return ImportFile(rows: const [], skipped: [l10n.importNoTitleColumn]);
    }
    final igdb = col(['igdbid', 'igdb']);
    final year = col(['releaseyear', 'year', 'released', 'releasedate']);
    final status = col(['status', 'state', 'list', 'shelf']);
    final rating = col(['rating', 'score', 'stars', 'myrating']);
    final hours = col(['hoursplayed', 'hours', 'playtime', 'timeplayed', 'playtimehours']);
    final platform = col(['playedon', 'platform', 'console']);
    final review = col(['review', 'notes', 'comment']);
    // Grouvee's export has no status column but "shelves", which no other file
    // has: that is how it is told from a spreadsheet (see [ImportSource.grouvee]).
    final shelves = col(['shelves']);
    final dates = col(['dates']);
    final platforms = col(['platforms']);

    String? cell(List<String> row, int? i) {
      if (i == null || i >= row.length) return null;
      final text = row[i].trim();
      return text.isEmpty ? null : text;
    }

    final parsed = <ImportRow>[];
    final skipped = <String>[];
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      final line = r + 1;
      final name = cell(row, title);
      if (name == null) {
        skipped.add(l10n.importLineNoTitle(line));
        continue;
      }
      if (parsed.length >= maxRows) {
        skipped.add(l10n.importTooManyRows(line, maxRows));
        break;
      }
      final statusText = cell(row, status);
      final readStatus = shelves != null
          ? _grouveeStatus(cell(row, shelves))
          : statusText == null
          ? GameStatus.toPlay
          : _status(statusText);
      if (readStatus == null) {
        skipped.add(l10n.importUnknownStatus(line, name, statusText!));
        continue;
      }
      var reviewText = cell(row, review);
      if (reviewText != null && reviewText.length > Db.reviewMaxLength) {
        reviewText = reviewText.substring(0, Db.reviewMaxLength);
      }
      parsed.add(ImportRow(
        line: line,
        title: name,
        igdbId: int.tryParse(cell(row, igdb) ?? ''),
        releaseYear: _year(cell(row, year)),
        status: readStatus,
        rating: _rating(cell(row, rating)),
        hours: shelves != null ? _grouveeHours(cell(row, dates)) : _hours(cell(row, hours)),
        playedOn: shelves != null ? _grouveePlatform(cell(row, platforms)) : gamePlatformFromDb(cell(row, platform)),
        review: reviewText,
      ));
    }
    return ImportFile(
      rows: parsed,
      skipped: skipped,
      source: shelves != null ? ImportSource.grouvee : ImportSource.generic,
    );
  }

  /// The year of a release given as a year or as a date ("2017", "2017-03-03").
  static int? _year(String? text) {
    if (text == null) return null;
    return int.tryParse(text) ?? int.tryParse(RegExp(r'^(\d{4})[-/.]').firstMatch(text)?[1] ?? '');
  }

  /// The decoded JSON of a cell, or null when it isn't JSON.
  static Object? _json(String? text) {
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// What a game on Grouvee's shelves is here. A game can be on several
  /// ("Playing" and "Played"); the one furthest along wins. A shelf of the
  /// member's own ("Favorites") says nothing, and a game on those alone is
  /// kept in the backlog rather than left out.
  static GameStatus _grouveeStatus(String? shelves) {
    final decoded = _json(shelves);
    final Iterable<String> names = decoded is Map<String, dynamic> ? decoded.keys : (shelves ?? '').split(RegExp('[,;|]'));
    final found = {for (final name in names) ?_status(name)};
    for (final status in _grouveeOrder) {
      if (found.contains(status)) return status;
    }
    return GameStatus.toPlay;
  }

  static const _grouveeOrder = [
    GameStatus.playing,
    GameStatus.completed,
    GameStatus.dropped,
    GameStatus.toPlay,
    GameStatus.wishlist,
  ];

  /// The hours of every playthrough Grouvee logged: `dates` is a list of them,
  /// each with its `seconds_played`.
  static double? _grouveeHours(String? dates) {
    if (_json(dates) case final List<dynamic> playthroughs) {
      var seconds = 0.0;
      for (final p in playthroughs) {
        if (p is Map<String, dynamic>) seconds += num.tryParse('${p['seconds_played']}')?.toDouble() ?? 0;
      }
      if (seconds > 0) return _hours((seconds / 3600).toStringAsFixed(2));
    }
    return null;
  }

  /// The first of the platforms a game is on, which Grouvee names as the keys
  /// of `platforms`, that the app knows.
  static GamePlatform? _grouveePlatform(String? platforms) {
    if (_json(platforms) case final Map<String, dynamic> named) {
      for (final name in named.keys) {
        final platform = gamePlatformFromDb(name);
        if (platform != null) return platform;
      }
    }
    return null;
  }

  static String _key(String header) => header.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// Gamebit's own statuses, and the words other trackers use.
  static GameStatus? _status(String text) => switch (_key(text)) {
    'playing' || 'inprogress' || 'currentlyplaying' || 'started' => GameStatus.playing,
    'toplay' || 'backlog' || 'backlogged' || 'owned' || 'unplayed' || 'shelved' => GameStatus.toPlay,
    'completed' || 'beaten' || 'finished' || 'played' || 'done' || 'mastered' => GameStatus.completed,
    'dropped' || 'abandoned' || 'retired' || 'quit' => GameStatus.dropped,
    'wishlist' || 'wanted' || 'wishlisted' || 'want' || 'wanttoplay' => GameStatus.wishlist,
    _ => null,
  };

  /// Out of 5 in halves; a figure over 5 is read as out of 10, over 10 as out
  /// of 100. Null when there is none (or it is 0).
  static double? _rating(String? text) {
    final value = double.tryParse((text ?? '').replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.]'), ''));
    if (value == null || value <= 0) return null;
    final outOf5 = value <= 5 ? value : (value <= 10 ? value / 2 : (value <= 100 ? value / 20 : 5.0));
    return ((outOf5 * 2).round() / 2).clamp(0.5, 5.0).toDouble();
  }

  /// Hours as a number ("12.5", "12,5") or "h:mm"; within the limit.
  static double? _hours(String? text) {
    if (text == null) return null;
    final clock = RegExp(r'^(\d+):(\d{1,2})$').firstMatch(text);
    final value = clock != null
        ? int.parse(clock[1]!) + int.parse(clock[2]!) / 60
        : double.tryParse(text.replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.]'), ''));
    if (value == null || value < 0) return null;
    final rounded = (value * 100).round() / 100;
    return rounded > maxTotalHours ? maxTotalHours : rounded;
  }
}

/// Whose file [ImportRow.parse] took it for.
enum ImportSource {
  /// Gamebit's own export, or a spreadsheet with a header row.
  generic,

  /// Grouvee's "Export your collection to a CSV file": a `name` column, and
  /// `shelves`, `dates` and `platforms` holding JSON. Read from how the tools
  /// that parse it name the columns; the rating is taken as out of 5.
  grouvee,
}

/// What [ImportRow.parse] read: the games, and the lines it left out.
class ImportFile {
  const ImportFile({required this.rows, required this.skipped, this.source = ImportSource.generic});
  final List<ImportRow> rows;
  final List<String> skipped;
  final ImportSource source;
}

/// The search hit that is [row]'s game: the one with its IGDB id when the file
/// has one; otherwise the one whose title is the same (ignoring case and
/// punctuation), preferring the release year the file gives. Null when none is
/// a sure match.
Game? matchImportRow(ImportRow row, List<Game> hits) {
  if (row.igdbId != null) {
    for (final hit in hits) {
      if (hit.igdbId == row.igdbId) return hit;
    }
    return null;
  }
  String norm(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  final same = [for (final hit in hits) if (norm(hit.title) == norm(row.title)) hit];
  if (same.isEmpty) return null;
  final year = row.releaseYear;
  if (year != null) {
    for (final hit in same) {
      if (hit.releaseYear == year) return hit;
    }
  }
  return same.length == 1 || year == null ? same.first : null;
}
