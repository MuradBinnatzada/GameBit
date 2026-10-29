import 'package:flutter/foundation.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/utils/lru_cache.dart';

enum FollowListKind {
  /// The members who follow someone.
  followers,

  /// The members someone follows.
  following;

  String get label => switch (this) {
    followers => L10n.current.followers,
    following => L10n.current.following,
  };
}

/// One page-by-page list of members.
@immutable
class FollowListView {
  const FollowListView({
    this.status = LoadStatus.idle,
    this.users = const [],
    this.fetched = 0,
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
  });

  final LoadStatus status;
  final List<SocialUser> users;

  /// Rows the server returned so far, counted before duplicates were dropped:
  /// where the next page starts.
  final int fetched;

  /// The server may have more members after [users].
  final bool hasMore;
  final bool loadingMore;
  final bool loadMoreFailed;

  FollowListView copyWith({
    List<SocialUser>? users,
    int? fetched,
    bool? hasMore,
    bool? loadingMore,
    bool? loadMoreFailed,
  }) => FollowListView(
    status: status,
    users: users ?? this.users,
    fetched: fetched ?? this.fetched,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
  );
}

/// Who follows whom: the follower and following lists of any member, the
/// signed-in one included. Whether the signed-in member follows someone, and
/// the follow button itself, belong to [ProfileStore].
///
/// Lists are fetched a page at a time as they are scrolled, kept in memory (the
/// 20 most recently opened) and dropped when the account changes. Opening a list
/// always asks the server again, showing the copy held meanwhile: who follows
/// whom changes under you.
class SocialGraphStore extends AccountScopedStore {
  SocialGraphStore({
    required this._repository,
    required AuthStore auth,
    int capacity = 20,
  }) : _lists = LruCache(capacity),
       super(auth);

  final CheckpointRepository _repository;

  final LruCache<(String, FollowListKind), FollowListView> _lists;
  final Map<(String, FollowListKind), Future<void>> _loading = {};

  @override
  void resetForAccount() {
    _lists.clear();
    _loading.clear();
  }

  /// Takes the blocked member [memberId] off every list held.
  void forgetMember(String memberId) {
    _lists.updateAll(
      (_, list) => list.copyWith(
        users: [
          for (final u in list.users)
            if (u.id != memberId) u,
        ],
      ),
    );
    notifyIfAlive();
  }

  /// What is known about [userId]'s list; empty and idle before [load].
  FollowListView listOf(String userId, FollowListKind kind) =>
      _lists.peek((userId, kind)) ?? const FollowListView();

  Future<ResultsPage<SocialUser>> _fetchPage(
    String userId,
    FollowListKind kind,
    int offset,
  ) => switch (kind) {
    FollowListKind.followers => _repository.fetchFollowers(
      userId,
      offset: offset,
    ),
    FollowListKind.following => _repository.fetchFollowing(
      userId,
      offset: offset,
    ),
  };

  /// Fetches the first page of [userId]'s [kind] list and makes it the list. The
  /// copy held stays on screen while the page is on its way, and if that fails.
  Future<void> load(String userId, FollowListKind kind) {
    final key = (userId, kind);
    final running = _loading[key];
    if (running != null) return running;

    late final Future<void> request;
    request = _loadFirstPage(userId, kind).whenComplete(() {
      if (identical(_loading[key], request)) _loading.remove(key);
    });
    return _loading[key] = request;
  }

  Future<void> _loadFirstPage(String userId, FollowListKind kind) async {
    final key = (userId, kind);
    final epoch = this.epoch;
    final cached = _lists[key];
    final hasContent = cached != null && cached.status == LoadStatus.ready;
    if (!hasContent) {
      _lists[key] = const FollowListView(status: LoadStatus.loading);
      notifyIfAlive();
    }

    try {
      final page = await _fetchPage(userId, kind, 0);
      if (isStale(epoch)) return;
      _lists[key] = FollowListView(
        status: LoadStatus.ready,
        users: List.unmodifiable(page.items),
        fetched: page.fetched,
        hasMore: page.hasMore,
      );
    } catch (e, st) {
      debugPrint('Loading the ${kind.name} of $userId failed: $e\n$st');
      if (isStale(epoch)) return;
      if (!hasContent) {
        _lists[key] = const FollowListView(status: LoadStatus.failed);
      }
    }
    notifyIfAlive();
  }

  /// Fetches the next page of a list and adds it to the end. Safe to call
  /// whenever, like [SearchStore.loadMoreUsers]: it does nothing unless there is
  /// a next page and none is loading.
  Future<void> loadMore(String userId, FollowListKind kind) async {
    final key = (userId, kind);
    final view = _lists.peek(key);
    if (view == null ||
        view.status != LoadStatus.ready ||
        !view.hasMore ||
        view.loadingMore) {
      return;
    }
    final epoch = this.epoch;
    _lists[key] = view.copyWith(loadingMore: true, loadMoreFailed: false);
    notifyIfAlive();

    try {
      final page = await _fetchPage(userId, kind, view.fetched);
      if (isStale(epoch)) return;
      final current = _lists.peek(key) ?? view;
      final seen = {for (final u in current.users) u.id};
      _lists[key] = current.copyWith(
        users: List.unmodifiable([
          ...current.users,
          for (final u in page.items)
            if (seen.add(u.id)) u,
        ]),
        fetched: current.fetched + page.fetched,
        hasMore: page.hasMore,
        loadingMore: false,
      );
    } catch (e, st) {
      debugPrint('Loading more of the ${kind.name} of $userId failed: $e\n$st');
      if (isStale(epoch)) return;
      _lists[key] = (_lists.peek(key) ?? view).copyWith(
        loadingMore: false,
        loadMoreFailed: true,
      );
    }
    notifyIfAlive();
  }
}
