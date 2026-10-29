part of '../checkpoint_repository.dart';

/// Achievements (the Steam sync, a member's own and other members') and milestones.
mixin _ProgressQueries on _RepositoryBase {
  /// Reads only the `achievements` column of one `user_games` row.
  ///
  /// Returns `null` when achievements were never loaded (the column is NULL, or
  /// the game isn't in the user's library), and an empty list when they were
  /// loaded but the game has none. See [Achievement.listFromJson].
  Future<List<Achievement>?> fetchGameAchievements(
    String userId,
    String gameId,
  ) async {
    final row = await _client
        .from(Db.userGames)
        .select(_achievementsColumn)
        .eq(Db.userId, userId)
        .eq(Db.gameId, gameId)
        .maybeSingle();
    return Achievement.listFromJson(row?[_achievementsColumn]);
  }

  /// Imports the signed-in user's Steam library through the `sync-steam` Edge
  /// Function. There is no body: the function looks up this user's Steam ID on
  /// `profiles` using the authenticated session, and never trusts one sent by
  /// the client. Returns the function's response data.
  Future<Object?> syncSteamLibrary() async {
    final response = await _client.functions.invoke('sync-steam');
    return response.data;
  }

  /// Loads one game's Steam achievements through the `sync-achievements` Edge
  /// Function. Only the game (and the app's language, for Steam's translations)
  /// goes in the body; the function reads the Steam ID from `profiles` and
  /// ignores any `steam_id` sent by the client. Throws [FunctionException] when
  /// the function answers with an error. Returns the function's response data.
  Future<Object?> syncGameAchievements(String gameId) async {
    final response = await _client.functions.invoke(
      'sync-achievements',
      body: {'game_id': gameId, ..._language},
    );
    return response.data;
  }

  /// Records every milestone the signed-in member has reached, worked out by
  /// the server from everything they have done, and returns the ones that are
  /// new, with when each was reached (often in the past: the 10th game's date
  /// for "10 games"). [utcOffsetMinutes] is the device's offset from UTC, for
  /// the streaks.
  Future<Map<String, DateTime>> awardMilestones(int utcOffsetMinutes) async {
    final data = await _client.rpc(
      Db.rpcAwardMilestones,
      params: {'utc_offset_minutes': utcOffsetMinutes},
    );
    return _milestonesFromRows(data);
  }

  /// Every milestone [userId] has earned, with when.
  Future<Map<String, DateTime>> fetchMilestones(String userId) async {
    final rows = await _client
        .from(Db.userMilestones)
        .select('${Db.milestoneId}, ${Db.unlockedAt}')
        .eq(Db.userId, userId);
    return _milestonesFromRows(rows);
  }

  static Map<String, DateTime> _milestonesFromRows(Object? rows) => {
    if (rows is List)
      for (final row in rows)
        if (row is Map && _date(row[Db.unlockedAt]) != null)
          '${row[Db.milestoneId]}': _date(row[Db.unlockedAt])!,
  };

  /// [userId]'s achievements added up: unlocked, total, games with any and games
  /// finished. Counted in the database and one small row, so it is fine to load
  /// with a profile. Empty (all zeros) when they have none.
  Future<AchievementTotals> fetchAchievementTotals(String userId) async {
    final data = await _client.rpc(
      Db.rpcAchievementTotals,
      params: {'target_user': userId},
    );
    final row = data is List ? (data.isEmpty ? null : data.first) : data;
    if (row is! Map) return const AchievementTotals();
    return AchievementTotals(
      unlocked: _int(row['unlocked']),
      total: _int(row['total']),
      games: _int(row['games']),
      completedGames: _int(row['completed_games']),
    );
  }

  /// Which of [userId]'s games have achievements, and how far they got in each.
  /// Counted in the database: no achievement rows are sent. Empty when they have
  /// none. Call it only when a viewer asks to see them.
  Future<List<GameAchievementSummary>> fetchAchievementSummary(
    String userId,
  ) async {
    final data = await _client.rpc(
      Db.rpcAchievementSummary,
      params: {'target_user': userId},
    );
    if (data is! List) return const [];
    return [
      for (final row in data)
        if (row is Map) _achievementSummaryFromRow(Map<String, dynamic>.from(row)),
    ];
  }

  /// [userId]'s achievements for one game, or null when they have none stored
  /// for it. Same meaning as [fetchGameAchievements], for another member.
  Future<List<Achievement>?> fetchPublicGameAchievements(
    String userId,
    String gameId,
  ) async {
    final data = await _client.rpc(
      Db.rpcGameAchievements,
      params: {'target_user': userId, 'target_game': gameId},
    );
    return Achievement.listFromJson(data);
  }

  /// [userId]'s achievements for [gameId] as Steam has them now, through the
  /// `sync-achievements` Edge Function: another member's (from the Steam account
  /// on their profile) or the signed-in member's. The function saves the list on
  /// their library row, and answers another member's from that row when it was
  /// fetched a few minutes ago. Throws [FunctionException] when it answers with an
  /// error; null when the answer has no list.
  Future<List<Achievement>?> fetchSteamGameAchievements(
    String userId,
    String gameId,
  ) async {
    final response = await _client.functions.invoke(
      'sync-achievements',
      body: {'game_id': gameId, 'user_id': userId, ..._language},
    );
    final data = response.data;
    return data is Map ? Achievement.listFromJson(data['achievements']) : null;
  }
}
