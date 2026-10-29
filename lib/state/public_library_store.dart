import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/utils/lru_cache.dart';

/// One member's whole library as other members see it.
@immutable
class PublicLibraryView {
  const PublicLibraryView({
    this.status = LoadStatus.idle,
    this.games = const [],
    this.loadedAt,
  });

  final LoadStatus status;

  /// Newest first. Each game carries the owner's status, rating and hours.
  final List<Game> games;
  final DateTime? loadedAt;
}

/// Another member's whole library, for the Library screen that opens from their
/// profile. It is loaded when that screen opens, not with the profile: a library
/// can hold hundreds of games. Kept in memory only (the 5 most recently opened),
/// dropped when the account changes.
class PublicLibraryStore extends AccountScopedStore {
  PublicLibraryStore({
    required this._repository,
    required AuthStore auth,
    this.cacheLifetime = const Duration(minutes: 5),
    DateTime Function()? now,
    int capacity = 5,
  }) : _now = now ?? DateTime.now,
       _views = LruCache(capacity),
       super(auth);

  final CheckpointRepository _repository;
  final Duration cacheLifetime;
  final DateTime Function() _now;

  final LruCache<String, PublicLibraryView> _views;
  final Map<String, Future<void>> _loading = {};

  @override
  void resetForAccount() {
    _views.clear();
    _loading.clear();
  }

  /// Forgets the blocked member [memberId]'s library.
  void forgetMember(String memberId) {
    _views.remove(memberId);
    _loading.remove(memberId);
    notifyIfAlive();
  }

  PublicLibraryView viewOf(String userId) =>
      _views.peek(userId) ?? const PublicLibraryView();

  /// A game from any loaded library, as the catalog knows it (the owner's status,
  /// rating and hours cleared), for the game screen: a game tapped in someone's
  /// library is usually not in the signed-in member's own.
  Game? gameById(String id) {
    for (final view in _views.values) {
      for (final game in view.games) {
        if (game.id == id) return game.withoutUserState();
      }
    }
    return null;
  }

  /// Makes sure [userId]'s library is loaded: does nothing while a request is
  /// running or the copy held is fresh, otherwise fetches it. A copy that is stale
  /// stays on screen while the new one is on its way (and if that fails). [force]
  /// fetches whatever the age: pull-to-refresh and retry.
  Future<void> load(String userId, {bool force = false}) {
    final running = _loading[userId];
    if (running != null) return running;
    final cached = _views[userId];
    final at = cached?.loadedAt;
    if (!force &&
        cached != null &&
        cached.status == LoadStatus.ready &&
        at != null &&
        _now().difference(at) < cacheLifetime) {
      return Future.value();
    }

    late final Future<void> request;
    request = _fetch(userId, cached).whenComplete(() {
      if (identical(_loading[userId], request)) _loading.remove(userId);
    });
    return _loading[userId] = request;
  }

  Future<void> _fetch(String userId, PublicLibraryView? cached) async {
    final epoch = this.epoch;
    final hasContent = cached != null && cached.status == LoadStatus.ready;
    if (!hasContent) {
      _views[userId] = const PublicLibraryView(status: LoadStatus.loading);
      notifyIfAlive();
    }
    try {
      final games = await _repository.fetchPublicLibrary(userId);
      if (isStale(epoch)) return;
      _views[userId] = PublicLibraryView(
        status: LoadStatus.ready,
        games: List.unmodifiable(games),
        loadedAt: _now(),
      );
    } catch (e, st) {
      debugPrint('Loading the library of $userId failed: $e\n$st');
      if (isStale(epoch)) return;
      if (!hasContent) {
        _views[userId] = const PublicLibraryView(status: LoadStatus.failed);
      }
    }
    notifyIfAlive();
  }
}
