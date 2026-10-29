part of '../checkpoint_repository.dart';

/// The discussions: boards, threads and replies are read and deleted here; they are written by the `discussions` Edge Function.
mixin _DiscussionQueries on _RepositoryBase {
  /// The boards with how many threads each has and when one was last written in.
  /// One request. Empty without a session.
  Future<List<DiscussionBoard>> fetchDiscussionBoards() async {
    final data = await _client.rpc(Db.rpcDiscussionBoards);
    if (data is! List) return const [];
    return List.unmodifiable([
      for (final raw in data)
        if (raw is Map)
          if (_text(raw['id']) case final String id)
            DiscussionBoard(
              id: id,
              titleFallback: _text(raw['title']) ?? id,
              descriptionFallback: _text(raw['description']) ?? '',
              threadCount: _int(raw['thread_count']),
              latestAt: _date(raw['latest_at']),
            ),
    ]);
  }

  /// One page of threads, the ones written in last first: those of [boardId] (every
  /// board when null) and those about the game [gameId] (a catalog id; any when
  /// null). A full page means there may be another.
  Future<ResultsPage<DiscussionThread>> fetchDiscussionThreads({
    String? boardId,
    String? gameId,
    int offset = 0,
    int limit = CheckpointRepository.discussionThreadsPageSize,
  }) async {
    final data = await _client.rpc(
      Db.rpcDiscussionThreads,
      params: {
        'board': boardId,
        'about_game': gameId,
        'page_size': limit,
        'page_offset': offset,
      },
    );
    if (data is! List) return ResultsPage(const [], hasMore: false);
    return ResultsPage(
      List.unmodifiable([
        for (final raw in data)
          if (raw is Map) ?_threadFromRow(Map<String, dynamic>.from(raw), 'preview'),
      ]),
      hasMore: data.length >= limit,
      fetched: data.length,
    );
  }

  /// The thread [id] with its whole opening text, or null when it is gone (or the
  /// signed-in member blocked or reported it).
  Future<DiscussionThread?> fetchDiscussionThread(String id) async {
    final data = await _client.rpc(
      Db.rpcDiscussionThread,
      params: {'thread': id},
    );
    if (data is! List || data.isEmpty || data.first is! Map) return null;
    return _threadFromRow(Map<String, dynamic>.from(data.first as Map), 'body');
  }

  /// One page of the replies to [threadId], oldest first.
  Future<ResultsPage<DiscussionPost>> fetchDiscussionPosts(
    String threadId, {
    int offset = 0,
    int limit = CheckpointRepository.discussionPostsPageSize,
  }) async {
    final data = await _client.rpc(
      Db.rpcDiscussionPosts,
      params: {
        'thread': threadId,
        'page_size': limit,
        'page_offset': offset,
      },
    );
    if (data is! List) return ResultsPage(const [], hasMore: false);
    final posts = <DiscussionPost>[];
    for (final raw in data) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final id = _text(row['id']);
      final text = _text(row['body']);
      final at = _date(row['created_at']);
      if (id == null || text == null || at == null) continue;
      posts.add(
        DiscussionPost(
          id: id,
          threadId: '${row['thread_id']}',
          author: _authorFromRow(row),
          text: text,
          createdAt: at,
        ),
      );
    }
    return ResultsPage(
      List.unmodifiable(posts),
      hasMore: data.length >= limit,
      fetched: data.length,
    );
  }

  /// Deletes the signed-in member's own thread (with its replies); false when it
  /// was not theirs or is gone.
  Future<bool> deleteDiscussionThread(String id) async {
    final data = await _client.rpc(Db.rpcDeleteDiscussionThread, params: {'thread': id});
    return data == true;
  }

  /// Deletes the signed-in member's own reply; false when it was not theirs or is gone.
  Future<bool> deleteDiscussionPost(String id) async {
    final data = await _client.rpc(Db.rpcDeleteDiscussionPost, params: {'post': id});
    return data == true;
  }
}
