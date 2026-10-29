import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/game_friends.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/utils/lru_cache.dart';

/// One game's [GameFriends], with where the request stands.
@immutable
class GameFriendsView {
  const GameFriendsView({
    this.status = LoadStatus.idle,
    this.friends = const GameFriends(),
  });

  final LoadStatus status;
  final GameFriends friends;
}

/// Which of the members the signed-in one follows have a game, for the Friends
/// panel on the game's screen. Asked for each time that screen opens, showing
/// the copy held meanwhile: who you follow and what they play change under you.
/// Kept in memory only (the 30 games opened last), dropped when the account
/// changes.
class GameFriendsStore extends AccountScopedStore {
  GameFriendsStore({
    required this._repository,
    required AuthStore auth,
    int capacity = 30,
  }) : _views = LruCache(capacity),
       super(auth);

  final CheckpointRepository _repository;

  final LruCache<String, GameFriendsView> _views;
  final Map<String, Future<void>> _loading = {};

  @override
  void resetForAccount() {
    _views.clear();
    _loading.clear();
  }

  /// Takes the blocked member [memberId] off every game held.
  void forgetMember(String memberId) {
    _views.updateAll(
      (_, view) => GameFriendsView(
        status: view.status,
        friends: view.friends.without(memberId),
      ),
    );
    notifyIfAlive();
  }

  GameFriendsView viewOf(String gameId) =>
      _views.peek(gameId) ?? const GameFriendsView();

  /// Fetches who has [gameId]. Does nothing when signed out, or while a request
  /// for the game is running.
  Future<void> load(String gameId) {
    if (accountId == null) return Future.value();
    final running = _loading[gameId];
    if (running != null) return running;

    late final Future<void> request;
    request = _fetch(gameId).whenComplete(() {
      if (identical(_loading[gameId], request)) _loading.remove(gameId);
    });
    return _loading[gameId] = request;
  }

  Future<void> _fetch(String gameId) async {
    final epoch = this.epoch;
    final cached = _views[gameId];
    final hasContent = cached != null && cached.status == LoadStatus.ready;
    if (!hasContent) {
      _views[gameId] = const GameFriendsView(status: LoadStatus.loading);
      notifyIfAlive();
    }
    try {
      final friends = await _repository.fetchFriendsWithGame(gameId);
      if (isStale(epoch)) return;
      _views[gameId] = GameFriendsView(
        status: LoadStatus.ready,
        friends: friends,
      );
    } catch (e, st) {
      debugPrint('Loading the friends who have $gameId failed: $e\n$st');
      if (isStale(epoch)) return;
      if (!hasContent) {
        _views[gameId] = const GameFriendsView(status: LoadStatus.failed);
      }
    }
    notifyIfAlive();
  }
}
