part of '../checkpoint_repository.dart';

/// Finding members, following them, and the people-you-follow reads: follower lists, who has a game, the friends feed.
mixin _SocialQueries on _RepositoryBase {
  /// Members per page of the Users tab.
  static const int _socialUsersPageSize = 30;

  /// One page of other members, for the Users tab: [limit] members starting at
  /// [offset], by display name. A non-empty [query] keeps those whose name or
  /// @handle contains it (case-insensitive). The search runs in the database, so
  /// the app never holds the whole member list.
  ///
  /// Reads the `public_profiles` view, which only has the public fields;
  /// `profiles` itself holds `email` / `steam_id` and is readable only for your
  /// own row. Keep the column list in sync with what [_socialUserFromProfile]
  /// reads and with the view.
  Future<ResultsPage<SocialUser>> searchSocialUsers(
    String currentUserId, {
    String query = '',
    int offset = 0,
    int limit = _socialUsersPageSize,
  }) async {
    var request = _client
        .from(Db.publicProfiles)
        .select(_memberWithCountsColumns)
        .neq(Db.id, currentUserId);
    final term = _likeTerm(query);
    if (term.isNotEmpty) {
      request = request.or(
        '${Db.displayName}.ilike.%$term%,${Db.handle}.ilike.%$term%',
      );
    }
    // `id` breaks ties between equal names, so a page boundary is stable.
    final rows = await request
        .order(Db.displayName, ascending: true)
        .order(Db.id, ascending: true)
        .range(offset, offset + limit - 1);
    final users = rows
        .map<SocialUser>((row) => _socialUserFromProfile(row))
        .toList(growable: false);
    // A full page means there may be another.
    return ResultsPage<SocialUser>(users, hasMore: users.length >= limit);
  }

  /// Makes [query] safe to put inside a PostgREST `or(...)` filter and an
  /// `ilike` pattern: a leading "@" is dropped, and the characters that would end
  /// the value or act as wildcards become spaces.
  static String _likeTerm(String query) => query
      .trim()
      .replaceFirst(RegExp(r'^@+'), '')
      .replaceAll(RegExp(r'[,()"\\%*]'), ' ')
      .trim();

  Future<Set<String>> fetchFollowingIds(String userId) async {
    final rows = await _client
        .from(Db.socialFollows)
        .select(Db.followeeId)
        .eq(Db.followerId, userId);
    return rows.map<String>((row) => '${row[Db.followeeId]}').toSet();
  }

  Future<int> fetchFollowersCount(String userId) async {
    final rows = await _client
        .from(Db.socialFollows)
        .select(Db.followerId)
        .eq(Db.followeeId, userId);
    return rows.length;
  }

  Future<void> follow({
    required String followerId,
    required String followeeId,
  }) async {
    await _client.from(Db.socialFollows).insert({
      Db.followerId: followerId,
      Db.followeeId: followeeId,
    });
  }

  Future<void> unfollow({
    required String followerId,
    required String followeeId,
  }) async {
    await _client
        .from(Db.socialFollows)
        .delete()
        .eq(Db.followerId, followerId)
        .eq(Db.followeeId, followeeId);
  }

  /// The members who follow [userId], newest follow first. A full page means
  /// there may be another.
  Future<ResultsPage<SocialUser>> fetchFollowers(
    String userId, {
    int offset = 0,
    int limit = CheckpointRepository.followListPageSize,
  }) => _fetchFollowList(Db.publicFollowers, userId, offset, limit);

  /// The members [userId] follows, newest follow first.
  Future<ResultsPage<SocialUser>> fetchFollowing(
    String userId, {
    int offset = 0,
    int limit = CheckpointRepository.followListPageSize,
  }) => _fetchFollowList(Db.publicFollowing, userId, offset, limit);

  Future<ResultsPage<SocialUser>> _fetchFollowList(
    String view,
    String userId,
    int offset,
    int limit,
  ) async {
    final rows = await _client
        .from(view)
        .select(_memberColumns)
        .eq(Db.userId, userId)
        .order(Db.followedAt, ascending: false)
        // `id` breaks ties between follows made at the same moment.
        .order(Db.id, ascending: true)
        .range(offset, offset + limit - 1);
    final users = rows
        .map<SocialUser>(_socialUserFromProfile)
        .toList(growable: false);
    return ResultsPage<SocialUser>(users, hasMore: users.length >= limit);
  }

  /// The members the signed-in one follows who have [gameId] in their library,
  /// with their status and rating: [CheckpointRepository.friendsPerStatus] at most per status (rated
  /// first, then the most recently added) and how many there are in all. One
  /// request. Empty without a session.
  Future<GameFriends> fetchFriendsWithGame(String gameId) async {
    final data = await _client.rpc(
      Db.rpcFollowingGameActivity,
      params: {'target_game': gameId, 'per_status': CheckpointRepository.friendsPerStatus},
    );
    if (data is! List) return const GameFriends();
    final friends = <FriendWithGame>[];
    final totals = <GameStatus, int>{};
    for (final raw in data) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final status = gameStatusFromDb(row[Db.status]);
      if (status == null) continue;
      totals[status] = _int(row['status_total']);
      friends.add(
        FriendWithGame(
          member: _socialUserFromProfile(row),
          status: status,
          rating: _double(row[Db.rating]),
          dateAdded: _date(row[Db.dateAdded]),
        ),
      );
    }
    return GameFriends(
      friends: List.unmodifiable(friends),
      totals: Map.unmodifiable(totals),
    );
  }

  /// What the members the signed-in one follows did lately, newest first: the
  /// sessions they logged (the latest of each game), the games they completed and
  /// the ratings they gave, at most [limit] in all. One request. Empty without a
  /// session.
  Future<List<FriendActivity>> fetchFollowingActivity({
    int limit = CheckpointRepository.friendsFeedLimit,
  }) async {
    final data = await _client.rpc(
      Db.rpcFollowingRecentActivity,
      params: {'max_rows': limit},
    );
    if (data is! List) return const [];
    final items = <FriendActivity>[];
    for (final raw in data) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final kind = switch (row['kind']) {
        'session' => FriendActivityKind.session,
        'completed' => FriendActivityKind.completed,
        'rated' => FriendActivityKind.rated,
        _ => null,
      };
      final at = _date(row['occurred_at']);
      if (kind == null || at == null) continue;
      items.add(
        FriendActivity(
          member: _socialUserFromProfile({...row, Db.id: row[Db.userId]}),
          game: _gameFromCatalogRow({...row, Db.id: row[Db.gameId]}),
          kind: kind,
          at: at,
          hours: _double(row[Db.hours]),
          rating: _double(row[Db.rating]),
        ),
      );
    }
    return List.unmodifiable(items);
  }

  Stream<List<Map<String, dynamic>>> watchFollows(String userId) => _client
      .from(Db.socialFollows)
      .stream(primaryKey: [Db.followerId, Db.followeeId])
      .eq(Db.followerId, userId);
}
