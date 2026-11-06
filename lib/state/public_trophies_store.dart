import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/trophy.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/utils/lru_cache.dart';

/// Which of a member's games have PlayStation trophies, and how far they got in
/// each, with where the request stands.
@immutable
class TrophySummaryView {
  const TrophySummaryView({this.status = LoadStatus.idle, this.games = const []});

  final LoadStatus status;
  final List<GameTrophySummary> games;

  TrophyTotals get totals => TrophyTotals.of(games);
}

/// One game's trophies for one member. [trophies] is null until loaded, and stays
/// null when none are stored (or the member does not share them).
@immutable
class GameTrophiesView {
  const GameTrophiesView({this.status = LoadStatus.idle, this.trophies});

  final LoadStatus status;
  final List<Trophy>? trophies;
}

/// A member's PlayStation trophies (another member's, or the signed-in member's
/// own), in two steps. [loadSummary] gets the progress per game, counts only; the
/// profile's Trophies card is made of it. [loadGame] gets one game's list when it
/// is opened. Both are cached in memory until the account changes. What the server
/// answers for a member who keeps their trophies to themselves is nothing, which
/// reads as "no trophies".
class PublicTrophiesStore extends AccountScopedStore {
  PublicTrophiesStore({
    required this._repository,
    required AuthStore auth,
    int summaryCapacity = 10,
    int gameCapacity = 60,
  }) : _summaries = LruCache(summaryCapacity),
       _games = LruCache(gameCapacity),
       super(auth);

  final CheckpointRepository _repository;
  final LruCache<String, TrophySummaryView> _summaries;
  final LruCache<(String, String), GameTrophiesView> _games;
  final Map<Object, Future<void>> _loading = {};

  @override
  void resetForAccount() {
    _summaries.clear();
    _games.clear();
    _loading.clear();
  }

  TrophySummaryView summaryOf(String userId) => _summaries.peek(userId) ?? const TrophySummaryView();

  GameTrophiesView gameOf(String userId, String gameId) => _games.peek((userId, gameId)) ?? const GameTrophiesView();

  /// Forgets what is held of [userId]'s trophies (they just synced PlayStation):
  /// the lists are fetched again when opened, the summary now.
  void refreshAfterSync(String userId) {
    _games.removeWhere((key) => key.$1 == userId);
    if (_summaries[userId] != null) loadSummary(userId, force: true);
    notifyIfAlive();
  }

  /// Fetches [userId]'s trophy progress per game. Does nothing while it is loading
  /// or already loaded, unless [force] (a retry or refresh); a copy already held
  /// stays on screen while a forced one is on its way.
  Future<void> loadSummary(String userId, {bool force = false}) {
    final running = _loading[userId];
    if (running != null) return running;
    final cached = _summaries[userId];
    if (!force && cached != null && cached.status == LoadStatus.ready) return Future.value();

    late final Future<void> request;
    request = _fetchSummary(userId, cached).whenComplete(() {
      if (identical(_loading[userId], request)) _loading.remove(userId);
    });
    return _loading[userId] = request;
  }

  Future<void> _fetchSummary(String userId, TrophySummaryView? cached) async {
    final epoch = this.epoch;
    final hasContent = cached != null && cached.status == LoadStatus.ready;
    if (!hasContent) {
      _summaries[userId] = const TrophySummaryView(status: LoadStatus.loading);
      notifyIfAlive();
    }
    try {
      final games = await _repository.fetchTrophySummary(userId);
      if (isStale(epoch)) return;
      _summaries[userId] = TrophySummaryView(status: LoadStatus.ready, games: List.unmodifiable(games));
    } catch (e, st) {
      debugPrint('Loading trophies of $userId failed: $e\n$st');
      if (isStale(epoch)) return;
      if (!hasContent) _summaries[userId] = const TrophySummaryView(status: LoadStatus.failed);
    }
    notifyIfAlive();
  }

  /// Fetches [userId]'s trophies for [gameId]. Does nothing while loading or when
  /// loaded, unless [force].
  Future<void> loadGame(String userId, String gameId, {bool force = false}) {
    final key = (userId, gameId);
    final running = _loading[key];
    if (running != null) return running;
    final cached = _games[key];
    if (!force && cached != null && cached.status == LoadStatus.ready) return Future.value();

    late final Future<void> request;
    request = _fetchGame(userId, gameId, cached).whenComplete(() {
      if (identical(_loading[key], request)) _loading.remove(key);
    });
    return _loading[key] = request;
  }

  Future<void> _fetchGame(String userId, String gameId, GameTrophiesView? cached) async {
    final epoch = this.epoch;
    final key = (userId, gameId);
    final hasContent = cached != null && cached.status == LoadStatus.ready;
    if (!hasContent) {
      _games[key] = const GameTrophiesView(status: LoadStatus.loading);
      notifyIfAlive();
    }
    try {
      final list = await _repository.fetchGameTrophies(userId, gameId);
      if (isStale(epoch)) return;
      _games[key] = GameTrophiesView(status: LoadStatus.ready, trophies: list == null ? null : List.unmodifiable(list));
    } catch (e, st) {
      debugPrint('Loading trophies of $userId in $gameId failed: $e\n$st');
      if (isStale(epoch)) return;
      if (!hasContent) _games[key] = const GameTrophiesView(status: LoadStatus.failed);
    }
    notifyIfAlive();
  }
}
