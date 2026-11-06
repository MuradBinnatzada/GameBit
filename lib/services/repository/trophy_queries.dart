part of '../checkpoint_repository.dart';

/// PlayStation trophies: the list of a game the import stored, and a member's
/// (or another member's, when they share them).
mixin _TrophyQueries on _RepositoryBase {
  /// Stores [trophies] as the list of [gameId] on [userId]'s library row. False
  /// when the member has no such row on the server (the game is queued to be
  /// saved later), so the list was not kept. The row is only updated, never
  /// created: the game goes in through the library's own save first.
  Future<bool> saveGameTrophies(String userId, String gameId, List<Trophy> trophies) async {
    final rows = await _client
        .from(Db.userGames)
        .update({Db.trophies: Trophy.listToJson(trophies)})
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
