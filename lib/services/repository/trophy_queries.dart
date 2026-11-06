part of '../checkpoint_repository.dart';

/// PlayStation trophies: the list of a game the import stored, and a member's
/// (or another member's, when they share them).
mixin _TrophyQueries on _RepositoryBase {
  /// Stores [trophies] (the list of [gameId]) and/or [meta] (its set and counts by
  /// grade) on [userId]'s library row. False when the member has no such row on the
  /// server (the game is queued to be saved later), so nothing was kept. The row is
  /// only updated, never created: the game goes in through the library's own save
  /// first.
  Future<bool> saveGameTrophies(String userId, String gameId, {List<Trophy>? trophies, TrophyMeta? meta}) async {
    if (trophies == null && meta == null) return true;
    final rows = await _client
        .from(Db.userGames)
        .update({
          if (trophies != null) Db.trophies: Trophy.listToJson(trophies),
          if (meta != null) Db.trophyMeta: meta.toJson(),
        })
        .eq(Db.userId, userId)
        .eq(Db.gameId, gameId)
        .select(Db.gameId);
    return rows.isNotEmpty;
  }

  /// Which of [userId]'s games have trophies stored, and how far they got in each.
  /// Counted in the database: no trophy list is sent. Empty when there are none or
  /// the member keeps them to themselves (unless it is the signed-in member).
  Future<List<GameTrophySummary>> fetchTrophySummary(String userId) async {
    final data = await _client.rpc(Db.rpcTrophySummary, params: {'target_user': userId});
    if (data is! List) return const [];
    return [
      for (final row in data)
        if (row is Map) _trophySummaryFromRow(Map<String, dynamic>.from(row)),
    ];
  }

  /// The trophy set and counts the member's last PlayStation sync stored for their
  /// own [gameId]; null when none (the game never came from PlayStation).
  Future<TrophyMeta?> fetchTrophyMeta(String userId, String gameId) async {
    final row = await _client
        .from(Db.userGames)
        .select(Db.trophyMeta)
        .eq(Db.userId, userId)
        .eq(Db.gameId, gameId)
        .maybeSingle();
    return TrophyMeta.fromJson(row?[Db.trophyMeta]);
  }

  /// Whether [userId] shows the PlayStation icon on their profile (see
  /// [PublicProfile.psnSynced]); for the signed-in member's own profile, whether
  /// they have synced.
  Future<bool> fetchPsnSynced(String userId) async {
    final row = await _client.from(Db.publicProfiles).select(Db.psnSynced).eq(Db.id, userId).maybeSingle();
    return row?[Db.psnSynced] == true;
  }

  /// [userId]'s trophies for [gameId] (their own always; another member's when
  /// they share them), or null when none are stored.
  Future<List<Trophy>?> fetchGameTrophies(String userId, String gameId) async {
    final data = await _client.rpc(
      Db.rpcGameTrophies,
      params: {'target_user': userId, 'target_game': gameId},
    );
    return Trophy.listFromJson(data);
  }
}
