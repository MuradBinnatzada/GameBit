import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/friend_activity.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';

/// "From people you follow" on Home: the sessions, completions and ratings of
/// the members the signed-in one follows, newest first. Asked for when Home shows
/// and again once the answer is older than [cacheLifetime], showing the copy held
/// meanwhile. Kept in memory only, dropped when the account changes.
class FriendsFeedStore extends AccountScopedStore {
  FriendsFeedStore({
    required this._repository,
    required AuthStore auth,
    this.cacheLifetime = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       super(auth);

  final CheckpointRepository _repository;
  final Duration cacheLifetime;
  final DateTime Function() _now;

  LoadStatus _status = LoadStatus.idle;
  List<FriendActivity> _items = const [];
  DateTime? _askedAt;
  Future<void>? _loading;

  LoadStatus get status => _status;

  /// Newest first; empty until an answer is here.
  List<FriendActivity> get items => _items;

  @override
  void resetForAccount() {
    _status = LoadStatus.idle;
    _items = const [];
    _askedAt = null;
    _loading = null;
  }

  /// Takes the blocked member [memberId]'s activity off the feed.
  void forgetMember(String memberId) {
    _items = [
      for (final item in _items)
        if (item.member.id != memberId) item,
    ];
    notifyIfAlive();
  }

  /// A game of the feed, as the catalog knows it (none of the member's state is
  /// on it). This is how a cover tapped on Home is found by the game screen.
  Game? gameById(String id) {
    for (final item in _items) {
      if (item.game.id == id) return item.game;
    }
    return null;
  }

  /// Fetches the feed. Does nothing when signed out, while a request is running,
  /// or within [cacheLifetime] of the last request, answered or failed, so Home
  /// can call it on every rebuild; [force] asks whatever the age.
  Future<void> load({bool force = false}) {
    if (accountId == null) return Future.value();
    final running = _loading;
    if (running != null) return running;
    final askedAt = _askedAt;
    if (!force &&
        askedAt != null &&
        _now().difference(askedAt) < cacheLifetime) {
      return Future.value();
    }

    late final Future<void> request;
    request = _fetch().whenComplete(() {
      if (identical(_loading, request)) _loading = null;
    });
    return _loading = request;
  }

  Future<void> _fetch() async {
    final epoch = this.epoch;
    _askedAt = _now();
    final hasContent = _status == LoadStatus.ready;
    if (!hasContent) {
      _status = LoadStatus.loading;
      notifyIfAlive();
    }
    try {
      final items = await _repository.fetchFollowingActivity();
      if (isStale(epoch)) return;
      _items = items;
      _status = LoadStatus.ready;
    } catch (e, st) {
      debugPrint('Loading what the members you follow did failed: $e\n$st');
      if (isStale(epoch)) return;
      if (!hasContent) _status = LoadStatus.failed;
    }
    notifyIfAlive();
  }
}
