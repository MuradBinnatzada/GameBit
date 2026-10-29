part of '../checkpoint_repository.dart';

/// A member's lists of games.
mixin _ListQueries on _RepositoryBase {
  /// A list with its games, in their order, each with the catalog columns.
  static final String _listColumns = '''
          ${Db.id},
          ${Db.userId},
          ${Db.title},
          ${Db.description},
          ${Db.isPublic},
          ${Db.updatedAt},
          ${Db.gameListItems} (
            ${Db.position},
            ${Db.games} (
              ${Db.id},
              ${[..._catalogColumns, Db.releaseDate].join(', ')}
            )
          )
        ''';

  /// [userId]'s lists, the last changed first. Another member's private lists
  /// are never returned (RLS), so for them this is their public lists.
  Future<List<GameList>> fetchLists(String userId) async {
    final rows = await _client
        .from(Db.gameLists)
        .select(_listColumns)
        .eq(Db.userId, userId)
        .order(Db.updatedAt, ascending: false)
        .order(Db.position, referencedTable: Db.gameListItems);
    return rows.map<GameList>(_listFromRow).toList(growable: false);
  }

  /// One list, or null when it doesn't exist or isn't the caller's to see (a
  /// private list of someone else): a list opened from a link.
  Future<GameList?> fetchList(String listId) async {
    final row = await _client
        .from(Db.gameLists)
        .select(_listColumns)
        .eq(Db.id, listId)
        .order(Db.position, referencedTable: Db.gameListItems)
        .maybeSingle();
    return row == null ? null : _listFromRow(row);
  }

  /// Makes a list for the signed-in member and returns it (empty).
  Future<GameList> createList({
    required String title,
    String description = '',
    bool isPublic = false,
  }) async {
    final row = await _client
        .from(Db.gameLists)
        .insert({
          Db.title: title.trim(),
          Db.description: description.trim(),
          Db.isPublic: isPublic,
        })
        .select(_listColumns)
        .single();
    return _listFromRow(row);
  }

  Future<void> updateList(
    String listId, {
    required String title,
    required String description,
    required bool isPublic,
  }) async {
    await _client
        .from(Db.gameLists)
        .update({
          Db.title: title.trim(),
          Db.description: description.trim(),
          Db.isPublic: isPublic,
        })
        .eq(Db.id, listId);
  }

  /// Deletes a list and its entries (the games stay in the catalog and library).
  Future<void> deleteList(String listId) async {
    await _client.from(Db.gameLists).delete().eq(Db.id, listId);
  }

  /// Puts [gameId] in the list at [position]. The game must be in the catalog.
  Future<void> addToList(String listId, String gameId, int position) async {
    await _client.from(Db.gameListItems).upsert({
      Db.listId: listId,
      Db.gameId: gameId,
      Db.position: position,
    }, onConflict: '${Db.listId},${Db.gameId}');
  }

  Future<void> removeFromList(String listId, String gameId) async {
    await _client
        .from(Db.gameListItems)
        .delete()
        .eq(Db.listId, listId)
        .eq(Db.gameId, gameId);
  }

  /// Saves the order of the list's games: [gameIds] first to last.
  Future<void> reorderList(String listId, List<String> gameIds) async {
    if (gameIds.isEmpty) return;
    await _client.from(Db.gameListItems).upsert([
      for (var i = 0; i < gameIds.length; i++)
        {Db.listId: listId, Db.gameId: gameIds[i], Db.position: i},
    ], onConflict: '${Db.listId},${Db.gameId}');
  }
}
