part of '../checkpoint_repository.dart';

/// Another member's profile, library and latest activity, read through the `public_*` views.
mixin _PublicMemberQueries on _RepositoryBase {
  /// Everything `public_profiles` has: see 20261018120000_public_profile_details.sql.
  static final String _publicProfileColumns = [
    _memberColumns,
    Db.steamConnected,
    Db.connectedServices,
    Db.bio,
    Db.steamId,
    Db.psnId,
    Db.xboxId,
    Db.discordId,
    Db.instagramId,
    Db.twitchId,
    Db.joinedAt,
    Db.showSteamAchievements,
    Db.avatarFrame,
    Db.titleMilestone,
    Db.showcasedMilestones,
  ].join(', ');

  /// The header of [userId]'s profile, or null when no such member exists.
  Future<PublicProfile?> fetchPublicProfile(String userId) async {
    final row = await _client
        .from(Db.publicProfiles)
        .select(_publicProfileColumns)
        .eq(Db.id, userId)
        .maybeSingle();
    return row == null ? null : _publicProfileFromRow(row);
  }

  /// Follower, following and game counts of [userId], and whether the signed-in
  /// member follows them. One request. Throws when the server returns no row,
  /// which it does without a session.
  Future<PublicProfileStats> fetchPublicProfileStats(String userId) async {
    final data = await _client.rpc(
      Db.rpcProfileStats,
      params: {'target_user': userId},
    );
    final row = data is List ? data.firstOrNull : data;
    if (row is! Map) throw StateError('No profile stats for $userId.');
    return PublicProfileStats(
      followers: _int(row['followers']),
      following: _int(row['following']),
      viewerFollows: row['viewer_follows'] == true,
      games: _int(row['games']),
    );
  }

  /// Columns of `public_user_games`. No purchase price, no achievements.
  static final String _publicGameColumns = [
    Db.gameId,
    Db.status,
    Db.rating,
    Db.hoursPlayed,
    Db.playedOn,
    Db.dateAdded,
    Db.isFavorite,
    Db.customBackdropUrl,
    Db.review,
    Db.completedAt,
    Db.perfected,
    ..._catalogColumns,
  ].join(', ');

  /// What [LibraryStats] needs and nothing more, so a big library is a small read.
  static final String _statsColumns = [
    Db.gameId,
    Db.status,
    Db.rating,
    Db.hoursPlayed,
    Db.playedOn,
    Db.platforms,
  ].join(', ');

  /// Columns of `public_recent_activity`.
  static final String _activityColumns = [
    Db.gameId,
    Db.hours,
    Db.platform,
    Db.loggedAt,
    ..._catalogColumns,
  ].join(', ');

  PostgrestFilterBuilder<List<Map<String, dynamic>>> _publicGames(
    String userId, [
    String? columns,
  ]) => _client
      .from(Db.publicUserGames)
      .select(columns ?? _publicGameColumns)
      .eq(Db.userId, userId);

  /// [userId]'s favorite games, newest first, at most [CheckpointRepository.publicFavoritesLimit].
  Future<List<Game>> fetchPublicFavorites(String userId) async {
    final rows = await _publicGames(userId)
        .eq(Db.isFavorite, true)
        .order(Db.dateAdded, ascending: false, nullsFirst: false)
        .order(Db.gameId, ascending: true)
        .limit(CheckpointRepository.publicFavoritesLimit);
    return rows.map<Game>(_gameFromPublicRow).toList(growable: false);
  }

  /// Counts and sums over [userId]'s whole library (games per status, hours,
  /// ratings). Reads only the few columns they need, a page of 500 at a time, so
  /// even a big library is a small payload.
  Future<LibraryStats> fetchPublicLibraryStats(String userId) async {
    final rows = await _readAllPages(Db.gameId, (after) {
      final query = _publicGames(userId, _statsColumns);
      return (after == null ? query : query.gt(Db.gameId, after))
          .order(Db.gameId, ascending: true)
          .limit(_pageSize);
    });
    return LibraryStats.of(rows.map<Game>(_gameFromPublicRow));
  }

  /// [userId]'s whole library, newest first, for their Library screen. Read like
  /// [fetchUserGames]: a page of 500 at a time, keyed on `game_id`.
  Future<List<Game>> fetchPublicLibrary(String userId) async {
    final rows = await _readAllPages(Db.gameId, (after) {
      final query = _publicGames(userId);
      return (after == null ? query : query.gt(Db.gameId, after))
          .order(Db.gameId, ascending: true)
          .limit(_pageSize);
    });
    return rows.map<Game>(_gameFromPublicRow).toList()..sort(_newestFirst);
  }

  /// [userId]'s latest play sessions, newest first, one per game (the latest of
  /// each), at most [limit]. The notes they wrote are not readable.
  Future<List<ActivityEntry>> fetchPublicActivity(
    String userId, {
    int limit = CheckpointRepository.publicActivityLimit,
  }) async {
    // Several sessions of one game count once, so ask for more rows than [limit].
    final rows = await _client
        .from(Db.publicRecentActivity)
        .select(_activityColumns)
        .eq(Db.userId, userId)
        .order(Db.loggedAt, ascending: false)
        .order(Db.id, ascending: true)
        .limit(limit * 10);
    final seen = <String>{};
    final entries = <ActivityEntry>[];
    for (final row in rows) {
      if (!seen.add('${row[Db.gameId]}')) continue;
      entries.add(_activityFromRow(row));
      if (entries.length >= limit) break;
    }
    return entries;
  }
}
