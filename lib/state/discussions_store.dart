import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/discussion.dart';
import 'package:checkpoint/models/game_reviews.dart' show ReportReason;
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/services/discussion_api_service.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';

/// A list of threads (a board's, a game's, or the latest of all), with where its
/// requests stand.
@immutable
class ThreadList {
  const ThreadList({
    this.status = LoadStatus.idle,
    this.threads = const [],
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.loadedAt,
  });

  final LoadStatus status;
  final List<DiscussionThread> threads;
  final bool hasMore;
  final bool loadingMore;
  final bool loadMoreFailed;

  /// When the first page was fetched; null once it may be out of date.
  final DateTime? loadedAt;

  ThreadList _copy({
    LoadStatus? status,
    List<DiscussionThread>? threads,
    bool? hasMore,
    bool? loadingMore,
    bool? loadMoreFailed,
    DateTime? Function()? loadedAt,
  }) => ThreadList(
    status: status ?? this.status,
    threads: threads ?? this.threads,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    loadedAt: loadedAt != null ? loadedAt() : this.loadedAt,
  );
}

/// One thread open on screen: the thread itself and its replies, paged.
@immutable
class ThreadView {
  const ThreadView({
    this.status = LoadStatus.idle,
    this.thread,
    this.posts = const [],
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
  });

  /// Of the thread and the first page of replies. A thread that is gone (deleted,
  /// blocked, reported) is [LoadStatus.ready] with no [thread].
  final LoadStatus status;
  final DiscussionThread? thread;
  final List<DiscussionPost> posts;
  final bool hasMore;
  final bool loadingMore;
  final bool loadMoreFailed;

  ThreadView _copy({
    LoadStatus? status,
    DiscussionThread? thread,
    List<DiscussionPost>? posts,
    bool? hasMore,
    bool? loadingMore,
    bool? loadMoreFailed,
  }) => ThreadView(
    status: status ?? this.status,
    thread: thread ?? this.thread,
    posts: posts ?? this.posts,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
  );
}

/// The discussions: the boards, the threads on them and the replies to a thread,
/// read through the database; posting through the `discussions` Edge Function,
/// which holds the rate limit and the word filter; and reporting, blocking and
/// deleting your own.
///
/// What is fetched stays in memory (and is asked for again when it is older than
/// [freshFor]), and is dropped when the account changes; signed out, nothing is
/// asked. Reading is by member: a thread or reply of a member you blocked, or one
/// you reported, is not sent (and is taken out of what is held when you do).
class DiscussionsStore extends AccountScopedStore {
  DiscussionsStore({
    required this._repository,
    required AuthStore auth,
    DiscussionApiService? api,
  }) : _api = api ?? DiscussionApiService(),
       super(auth);

  final CheckpointRepository _repository;
  final DiscussionApiService _api;

  /// How long what was fetched is shown again without asking.
  static const Duration freshFor = Duration(minutes: 2);

  /// Most pages of replies a [reply] reads on to find the end of a long thread.
  static const int _maxCatchUpPages = 10;

  /// Most lists and open threads held: the oldest go.
  static const int _held = 40;

  bool _fresh(DateTime? at) =>
      at != null && DateTime.now().difference(at) < freshFor;

  // ---- Boards ----

  LoadStatus _boardsStatus = LoadStatus.idle;
  List<DiscussionBoard> _boards = const [];
  DateTime? _boardsAt;
  Future<void>? _loadingBoards;

  LoadStatus get boardsStatus => _boardsStatus;
  List<DiscussionBoard> get boards => _boards;

  /// The board [id] (to show its title), or null.
  DiscussionBoard? boardById(String id) {
    for (final b in _boards) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// Fetches the boards, unless they are fresh (and [force] is not set). The
  /// boards on screen stay until the new ones are here.
  Future<void> loadBoards({bool force = false}) {
    if (accountId == null) return Future.value();
    if (!force && _boardsStatus == LoadStatus.ready && _fresh(_boardsAt)) {
      return Future.value();
    }
    return _loadingBoards ??= _fetchBoards().whenComplete(
      () => _loadingBoards = null,
    );
  }

  Future<void> _fetchBoards() async {
    final epoch = this.epoch;
    if (_boardsStatus != LoadStatus.ready) {
      _boardsStatus = LoadStatus.loading;
      notifyIfAlive();
    }
    try {
      final boards = await _repository.fetchDiscussionBoards();
      if (isStale(epoch)) return;
      _boards = boards;
      _boardsStatus = LoadStatus.ready;
      _boardsAt = DateTime.now();
    } catch (e, st) {
      debugPrint('Loading the discussion boards failed: $e\n$st');
      if (isStale(epoch)) return;
      if (_boardsStatus != LoadStatus.ready) _boardsStatus = LoadStatus.failed;
    }
    notifyIfAlive();
  }

  // ---- Lists of threads ----

  final Map<DiscussionScope, ThreadList> _lists = {};
  final Map<DiscussionScope, Future<void>> _loadingLists = {};

  ThreadList listOf(DiscussionScope scope) =>
      _lists[scope] ?? const ThreadList();

  void _setList(DiscussionScope scope, ThreadList list) {
    _lists.remove(scope);
    _lists[scope] = list;
    while (_lists.length > _held) {
      _lists.remove(_lists.keys.first);
    }
  }

  /// Fetches the first page of the threads of [scope], unless it is fresh (and
  /// [force] is not set). The list on screen stays until the new one is here; a
  /// failed refresh keeps it.
  Future<void> loadThreads(DiscussionScope scope, {bool force = false}) {
    if (accountId == null) return Future.value();
    final held = listOf(scope);
    if (!force && held.status == LoadStatus.ready && _fresh(held.loadedAt)) {
      return Future.value();
    }
    // A block body: `remove` would return this very future, and wait for itself.
    return _loadingLists[scope] ??= _fetchThreads(scope).whenComplete(() {
      _loadingLists.remove(scope);
    });
  }

  Future<void> _fetchThreads(DiscussionScope scope) async {
    final epoch = this.epoch;
    var held = listOf(scope);
    if (held.status != LoadStatus.ready) {
      _setList(scope, held._copy(status: LoadStatus.loading));
      notifyIfAlive();
    }
    try {
      final page = await _repository.fetchDiscussionThreads(
        boardId: scope.boardId,
        gameId: scope.gameId,
      );
      if (isStale(epoch)) return;
      _setList(
        scope,
        ThreadList(
          status: LoadStatus.ready,
          threads: page.items,
          hasMore: page.hasMore,
          loadedAt: DateTime.now(),
        ),
      );
    } catch (e, st) {
      debugPrint('Loading the discussions of $scope failed: $e\n$st');
      if (isStale(epoch)) return;
      held = listOf(scope);
      if (held.status != LoadStatus.ready) {
        _setList(scope, held._copy(status: LoadStatus.failed));
      }
    }
    notifyIfAlive();
  }

  /// Fetches the next page of the threads of [scope] and appends it. Safe to call
  /// whenever: it does nothing unless there is a next page and none is loading.
  Future<void> loadMoreThreads(DiscussionScope scope) async {
    final held = listOf(scope);
    if (accountId == null ||
        !held.hasMore ||
        held.loadingMore ||
        held.status != LoadStatus.ready) {
      return;
    }
    final epoch = this.epoch;
    _setList(scope, held._copy(loadingMore: true, loadMoreFailed: false));
    notifyIfAlive();
    try {
      final page = await _repository.fetchDiscussionThreads(
        boardId: scope.boardId,
        gameId: scope.gameId,
        offset: held.threads.length,
      );
      if (isStale(epoch)) return;
      final current = listOf(scope);
      final seen = {for (final t in current.threads) t.id};
      final fresh = [
        for (final t in page.items)
          if (seen.add(t.id)) t,
      ];
      _setList(
        scope,
        current._copy(
          threads: List.unmodifiable([...current.threads, ...fresh]),
          // A page with nothing new means the source is not advancing: stop there.
          hasMore: page.hasMore && !(page.items.isNotEmpty && fresh.isEmpty),
          loadingMore: false,
        ),
      );
    } catch (e, st) {
      debugPrint('Loading more discussions of $scope failed: $e\n$st');
      if (isStale(epoch)) return;
      _setList(
        scope,
        listOf(scope)._copy(loadingMore: false, loadMoreFailed: true),
      );
    }
    notifyIfAlive();
  }

  // ---- One thread ----

  final Map<String, ThreadView> _views = {};
  final Map<String, Future<void>> _loadingViews = {};

  ThreadView viewOf(String threadId) => _views[threadId] ?? const ThreadView();

  void _setView(String id, ThreadView view) {
    _views.remove(id);
    _views[id] = view;
    while (_views.length > _held) {
      _views.remove(_views.keys.first);
    }
  }

  /// Fetches the thread [id] and its first page of replies, each time its screen
  /// opens, showing the copy held meanwhile.
  Future<void> loadThread(String id) {
    if (accountId == null) return Future.value();
    return _loadingViews[id] ??= _fetchThread(id).whenComplete(() {
      _loadingViews.remove(id);
    });
  }

  Future<void> _fetchThread(String id) async {
    final epoch = this.epoch;
    final held = viewOf(id);
    final hasContent = held.status == LoadStatus.ready && held.thread != null;
    if (!hasContent) {
      _setView(id, held._copy(status: LoadStatus.loading));
      notifyIfAlive();
    }
    try {
      final (thread, page) = await (
        _repository.fetchDiscussionThread(id),
        _repository.fetchDiscussionPosts(id),
      ).wait;
      if (isStale(epoch)) return;
      _setView(
        id,
        thread == null
            ? const ThreadView(status: LoadStatus.ready)
            : ThreadView(
                status: LoadStatus.ready,
                thread: thread,
                posts: page.items,
                hasMore: page.hasMore,
              ),
      );
    } catch (e, st) {
      debugPrint('Loading the thread $id failed: $e\n$st');
      if (isStale(epoch)) return;
      if (!hasContent) {
        _setView(id, const ThreadView(status: LoadStatus.failed));
      }
    }
    notifyIfAlive();
  }

  /// Fetches the next page of the replies of [id] and appends it. Safe to call
  /// whenever: it does nothing unless there is a next page and none is loading.
  Future<void> loadMorePosts(String id) async {
    final held = viewOf(id);
    if (accountId == null ||
        !held.hasMore ||
        held.loadingMore ||
        held.status != LoadStatus.ready) {
      return;
    }
    final epoch = this.epoch;
    _setView(id, held._copy(loadingMore: true, loadMoreFailed: false));
    notifyIfAlive();
    try {
      final page = await _repository.fetchDiscussionPosts(
        id,
        offset: held.posts.length,
      );
      if (isStale(epoch)) return;
      final current = viewOf(id);
      final seen = {for (final p in current.posts) p.id};
      final fresh = [
        for (final p in page.items)
          if (seen.add(p.id)) p,
      ];
      _setView(
        id,
        current._copy(
          posts: List.unmodifiable([...current.posts, ...fresh]),
          hasMore: page.hasMore && !(page.items.isNotEmpty && fresh.isEmpty),
          loadingMore: false,
        ),
      );
    } catch (e, st) {
      debugPrint('Loading more replies of $id failed: $e\n$st');
      if (isStale(epoch)) return;
      _setView(id, viewOf(id)._copy(loadingMore: false, loadMoreFailed: true));
    }
    notifyIfAlive();
  }

  // ---- Posting ----

  /// Starts a thread on [boardId] (optionally about the game [gameId], a catalog
  /// id) and answers its id. Throws a [DiscussionFailure] when it was refused (a
  /// word the chat rules refuse, posting too fast...) or could not be sent. The
  /// lists it belongs on are asked for again.
  Future<String> createThread({
    required String boardId,
    required String title,
    required String text,
    String? gameId,
  }) async {
    final id = await _api.createThread(
      boardId: boardId,
      title: title,
      text: text,
      gameId: gameId,
    );
    _boardsAt = null;
    for (final scope in _lists.keys.toList()) {
      final matches =
          (scope.boardId == null || scope.boardId == boardId) &&
          (scope.gameId == null || scope.gameId == gameId);
      if (matches) unawaited(loadThreads(scope, force: true));
    }
    return id;
  }

  /// Replies to the thread [threadId], then reads on to the end of the thread so
  /// the reply is there. Throws a [DiscussionFailure] when it was refused or could
  /// not be sent.
  Future<void> reply(String threadId, String text) async {
    await _api.reply(threadId, text);
    final epoch = this.epoch;
    try {
      // The thread again (its count, whether it was locked meanwhile).
      final thread = await _repository.fetchDiscussionThread(threadId);
      if (isStale(epoch)) return;
      if (thread != null) {
        _setView(threadId, viewOf(threadId)._copy(thread: thread));
      }
      // Whatever came after the replies held: the new one, and any by others.
      for (var i = 0; i < _maxCatchUpPages; i++) {
        final held = viewOf(threadId);
        final page = await _repository.fetchDiscussionPosts(
          threadId,
          offset: held.posts.length,
        );
        if (isStale(epoch)) return;
        final seen = {for (final p in held.posts) p.id};
        _setView(
          threadId,
          held._copy(
            posts: List.unmodifiable([
              ...held.posts,
              for (final p in page.items)
                if (seen.add(p.id)) p,
            ]),
            hasMore: page.hasMore,
          ),
        );
        if (!page.hasMore) break;
      }
    } catch (e, st) {
      debugPrint('Reading on after a reply to $threadId failed: $e\n$st');
    }
    _refreshListsOf(threadId);
    notifyIfAlive();
  }

  /// The thread's reply count and activity in the lists that hold it, as the open
  /// thread has them now.
  void _refreshListsOf(String threadId) {
    final thread = viewOf(threadId).thread;
    if (thread == null) return;
    for (final scope in _lists.keys.toList()) {
      final list = _lists[scope]!;
      if (list.threads.any((t) => t.id == threadId)) {
        _lists[scope] = list._copy(
          threads: [
            for (final t in list.threads)
              if (t.id == threadId) _withCounts(t, thread) else t,
          ],
        );
      }
    }
  }

  DiscussionThread _withCounts(DiscussionThread t, DiscussionThread from) =>
      DiscussionThread(
        id: t.id,
        boardId: t.boardId,
        author: t.author,
        title: t.title,
        text: t.text,
        createdAt: t.createdAt,
        lastPostAt: from.lastPostAt,
        replyCount: from.replyCount,
        pinned: t.pinned,
        locked: from.locked,
        game: t.game,
      );

  // ---- Deleting, reporting, blocking ----

  /// Deletes the signed-in member's own thread (and its replies) and takes it off
  /// every list. Throws when it could not be sent.
  Future<void> deleteThread(String id) async {
    await _repository.deleteDiscussionThread(id);
    _takeOut(thread: id);
    _boardsAt = null;
  }

  /// Deletes the signed-in member's own reply to [threadId]. Throws when it could
  /// not be sent.
  Future<void> deletePost(String threadId, String postId) async {
    await _repository.deleteDiscussionPost(postId);
    final view = viewOf(threadId);
    final posts = [
      for (final p in view.posts)
        if (p.id != postId) p,
    ];
    final thread = view.thread;
    if (posts.length != view.posts.length && thread != null) {
      _setView(
        threadId,
        ThreadView(
          status: view.status,
          thread: DiscussionThread(
            id: thread.id,
            boardId: thread.boardId,
            author: thread.author,
            title: thread.title,
            text: thread.text,
            createdAt: thread.createdAt,
            lastPostAt: thread.lastPostAt,
            replyCount: thread.replyCount > 0 ? thread.replyCount - 1 : 0,
            pinned: thread.pinned,
            locked: thread.locked,
            game: thread.game,
          ),
          posts: posts,
          hasMore: view.hasMore,
          loadingMore: view.loadingMore,
          loadMoreFailed: view.loadMoreFailed,
        ),
      );
      _refreshListsOf(threadId);
    }
    notifyIfAlive();
  }

  /// Reports the thread [threadId]; it goes off the lists, as the server leaves
  /// it out for the member who reported it. Throws when it could not be sent.
  Future<void> reportThread(String threadId, ReportReason reason) async {
    await _repository.reportDiscussion(threadId: threadId, reason: reason);
    _takeOut(thread: threadId);
  }

  /// Reports the reply [postId] of [threadId]; it goes off the thread. Throws when
  /// it could not be sent.
  Future<void> reportPost(
    String threadId,
    String postId,
    ReportReason reason,
  ) async {
    await _repository.reportDiscussion(postId: postId, reason: reason);
    final view = viewOf(threadId);
    _setView(
      threadId,
      view._copy(
        posts: [
          for (final p in view.posts)
            if (p.id != postId) p,
        ],
      ),
    );
    notifyIfAlive();
  }

  /// Takes the blocked member [memberId]'s threads and replies off everything
  /// held; the server leaves them out from now on.
  void forgetMember(String memberId) {
    _takeOut(author: memberId);
    _boardsAt = null;
  }

  /// A member was unblocked: what the server left out comes back, so everything
  /// held is asked for again when it is next opened.
  void refreshAfterUnblock() {
    _boardsAt = null;
    for (final scope in _lists.keys.toList()) {
      _lists[scope] = _lists[scope]!._copy(loadedAt: () => null);
    }
    for (final id in _views.keys.toList()) {
      _views.remove(id); // opened again from the server
    }
    notifyIfAlive();
  }

  /// Takes the thread [thread], and everything by the member [author], off every
  /// list and open thread held.
  void _takeOut({String? thread, String? author}) {
    bool keepsThread(DiscussionThread t) =>
        t.id != thread && t.author.id != author;
    for (final scope in _lists.keys.toList()) {
      final list = _lists[scope]!;
      _lists[scope] = list._copy(
        threads: [
          for (final t in list.threads)
            if (keepsThread(t)) t,
        ],
      );
    }
    for (final id in _views.keys.toList()) {
      final view = _views[id]!;
      final held = view.thread;
      if (id == thread || (held != null && held.author.id == author)) {
        _views[id] = const ThreadView(status: LoadStatus.ready);
      } else if (author != null) {
        _views[id] = view._copy(
          posts: [
            for (final p in view.posts)
              if (p.author.id != author) p,
          ],
        );
      }
    }
    notifyIfAlive();
  }

  // ---- The chat rules ----

  String get _rulesKey => 'chat_rules_accepted_${accountId ?? ''}';

  /// Whether the signed-in member has agreed to the chat rules on this device.
  Future<bool> hasAcceptedRules() async {
    if (accountId == null) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_rulesKey) ?? false;
  }

  /// Remembers that the signed-in member agreed to the chat rules.
  Future<void> acceptRules() async {
    if (accountId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_rulesKey, true);
  }

  @override
  void resetForAccount() {
    _boardsStatus = LoadStatus.idle;
    _boards = const [];
    _boardsAt = null;
    _loadingBoards = null;
    _lists.clear();
    _loadingLists.clear();
    _views.clear();
    _loadingViews.clear();
  }
}
