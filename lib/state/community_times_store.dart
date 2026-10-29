import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/completion_time.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/utils/lru_cache.dart';

/// One game's [CommunityTimes], with where the request stands.
@immutable
class CommunityTimesView {
  const CommunityTimesView({
    this.status = LoadStatus.idle,
    this.times = const CommunityTimes(),
  });

  final LoadStatus status;
  final CommunityTimes times;
}

/// How long Gamebit's members took to finish a game, for the time to beat on
/// the game's screen. Asked for each time that screen opens, and again when the
/// member's own time for the game reached the server (`LibraryStore` says so),
/// showing the copy held meanwhile. Kept in memory only (the 30 games opened
/// last), dropped when the account changes; signed out, nothing is asked.
class CommunityTimesStore extends AccountScopedStore {
  CommunityTimesStore({
    required this._repository,
    required AuthStore auth,
    int capacity = 30,
  }) : _views = LruCache(capacity),
       super(auth);

  final CheckpointRepository _repository;

  final LruCache<String, CommunityTimesView> _views;
  final Map<String, Future<void>> _loading = {};

  /// Games whose times changed while a request for them was running: that
  /// answer may predate the change, so they are asked about again after it.
  final Set<String> _stale = {};

  @override
  void resetForAccount() {
    _views.clear();
    _loading.clear();
    _stale.clear();
  }

  CommunityTimesView viewOf(String gameId) =>
      _views.peek(gameId) ?? const CommunityTimesView();

  /// Fetches the members' times for [gameId]. Does nothing when signed out. A
  /// call while a request for the game is running asks again once it is done.
  Future<void> load(String gameId) {
    if (accountId == null) return Future.value();
    final running = _loading[gameId];
    if (running != null) {
      _stale.add(gameId);
      return running;
    }

    late final Future<void> request;
    request = _fetch(gameId).whenComplete(() {
      if (!identical(_loading[gameId], request)) return;
      _loading.remove(gameId);
      if (_stale.remove(gameId)) unawaited(load(gameId));
    });
    return _loading[gameId] = request;
  }

  Future<void> _fetch(String gameId) async {
    final epoch = this.epoch;
    final cached = _views[gameId];
    final hasContent = cached != null && cached.status == LoadStatus.ready;
    if (!hasContent) {
      _views[gameId] = const CommunityTimesView(status: LoadStatus.loading);
      notifyIfAlive();
    }
    try {
      final times = await _repository.fetchCommunityTimes(gameId);
      if (isStale(epoch)) return;
      _views[gameId] = CommunityTimesView(
        status: LoadStatus.ready,
        times: times,
      );
    } catch (e, st) {
      debugPrint('Loading the completion times of $gameId failed: $e\n$st');
      if (isStale(epoch)) return;
      if (!hasContent) {
        _views[gameId] = const CommunityTimesView(status: LoadStatus.failed);
      }
    }
    notifyIfAlive();
  }
}
