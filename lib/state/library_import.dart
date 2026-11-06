import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/library_csv.dart';
import 'package:checkpoint/services/game_api_service.dart';
import 'package:checkpoint/state/library_store.dart';

/// One import of a library file, game by game: a game already in the library
/// is updated in place; any other is looked up on IGDB by its title (one
/// search per game, [pause] apart, so a long file doesn't flood IGDB's shared
/// quota) and added when there is a sure match ([matchImportRow]). What isn't
/// matched is listed in [unmatched]. [cancel] stops it after the game in hand.
class LibraryImport extends ChangeNotifier {
  LibraryImport({
    required this.rows,
    required this._api,
    required this._library,
    this.pause = const Duration(milliseconds: 300),
    this.onRowImported,
  });

  final List<ImportRow> rows;
  final GameApiService _api;
  final LibraryStore _library;
  final Duration pause;

  /// Told of each row once its game is in the library and, when the row carries a
  /// trophy list, that list is stored too.
  final void Function(ImportRow row)? onRowImported;

  int _done = 0;
  int _imported = 0;
  bool _running = false;
  bool _cancelled = false;
  bool _searchFailed = false;
  final List<ImportRow> _unmatched = [];

  int get done => _done;
  int get imported => _imported;
  bool get isRunning => _running;
  bool get isFinished => !_running && (_done == rows.length || _cancelled);
  bool get wasCancelled => _cancelled;

  /// A search couldn't reach IGDB, so some games may be unmatched for that.
  bool get searchFailed => _searchFailed;
  List<ImportRow> get unmatched => List.unmodifiable(_unmatched);

  void cancel() {
    if (!_running) return;
    _cancelled = true;
    notifyListeners();
  }

  Future<void> run() async {
    if (_running || _done > 0) return;
    _running = true;
    notifyListeners();
    var searched = false;
    for (final row in rows) {
      if (_cancelled) break;
      var game = _inLibrary(row);
      if (game == null) {
        if (searched) await Future<void>.delayed(pause);
        searched = true;
        final page = await _api.searchGames(row.title);
        if (page == null) _searchFailed = true;
        game = page == null ? null : matchImportRow(row, page.items);
        // A store's "Minecraft: PlayStation 3 Edition" is IGDB's "Minecraft": one
        // more search with the label cut, matched as strictly as the first.
        final base = game == null && page != null && row.igdbId == null ? titleWithoutEdition(row.title) : null;
        if (base != null) {
          await Future<void>.delayed(pause);
          final basePage = await _api.searchGames(base);
          if (basePage == null) _searchFailed = true;
          game = basePage == null ? null : matchImportRow(row, basePage.items, title: base);
        }
        if (game == null && kDebugMode) {
          final seen = [for (final g in page?.items.take(6) ?? const <Game>[]) g.title];
          debugPrint('IMPORT: no match for "${row.title}" (${row.playedOn?.name}); search gave ${page?.items.length} games: $seen');
        }
      }
      if (game == null) {
        _unmatched.add(row);
      } else {
        await _library.importGame(
          game,
          status: row.status,
          rating: row.rating,
          hours: row.hours,
          playedOn: row.playedOn,
          review: row.review,
          trophiesEarned: row.trophiesEarned,
          trophiesTotal: row.trophiesTotal,
          perfected: row.perfected,
          fillGapsOnly: row.fillGapsOnly,
        );
        final trophies = row.trophyList;
        final meta = row.trophyMeta;
        final stored = (trophies == null && meta == null) || await _library.saveTrophies(game.id, trophies: trophies, meta: meta);
        if (stored) onRowImported?.call(row);
        _imported++;
      }
      _done++;
      notifyListeners();
    }
    _running = false;
    notifyListeners();
  }

  /// The library's game for [row]: by IGDB id when the file has one, otherwise
  /// by the same title (and year, when the file gives one).
  Game? _inLibrary(ImportRow row) {
    final games = _library.libraryGames;
    if (row.igdbId != null) {
      for (final g in games) {
        if (g.igdbId == row.igdbId) return g;
      }
      return null;
    }
    return matchImportRow(row, games);
  }
}
