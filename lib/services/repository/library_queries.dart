part of '../checkpoint_repository.dart';

/// The catalog and the signed-in member's library: their games, play sessions and completion times, reads and writes.
mixin _LibraryQueries on _RepositoryBase {
  /// A small slice of the global catalog for the Home carousels: the newest
  /// [limit] rows of `games`. This replaces the old "download every game"
  /// fetch, so the payload stays the same size however big the catalog grows.
  /// Anything else (library games, search results) is loaded on demand.
  Future<List<Game>> fetchPopularGames({int limit = 20}) async {
    final rows = await _client
        .from(Db.games)
        .select()
        .order(Db.createdAt, ascending: false)
        .limit(limit);
    return rows.map<Game>(_gameFromCatalogRow).toList(growable: false);
  }

  /// The catalog's game with [igdbId], or null when it has none: a game opened
  /// from a shared link. Anyone may read the catalog, signed in or not.
  Future<Game?> fetchCatalogGame(int igdbId) async {
    final row = await _client
        .from(Db.games)
        .select()
        .eq(Db.igdbId, igdbId)
        .maybeSingle();
    return row == null ? null : _gameFromCatalogRow(row);
  }

  /// Columns of a library row: its own fields, the member's completion time for
  /// the game (`completion_times` belongs to the row, so it embeds as one object
  /// or null) and the catalog game it points at.
  /// Listed explicitly (rather than `select()`) so the heavy `achievements` JSONB
  /// column is never part of this payload; load it per game with
  /// [fetchGameAchievements] instead.
  static final String _userGameColumns = '''
          ${Db.id},
          ${Db.userId},
          ${Db.gameId},
          ${Db.status},
          ${Db.rating},
          ${Db.hoursPlayed},
          ${Db.playedOn},
          ${Db.purchasePrice},
          ${Db.dateAdded},
          ${Db.isFavorite},
          ${Db.customBackdropUrl},
          ${Db.completedAt},
          ${Db.review},
          ${Db.stillPlaying},
          ${Db.perfected},
          ${Db.completionTimes} (
            ${Db.category},
            ${Db.minutes}
          ),
          ${Db.games}!inner (
            ${Db.id},
            ${Db.igdbId},
            ${Db.steamAppId},
            ${Db.slug},
            ${Db.title},
            ${Db.publisher},
            ${Db.developer},
            ${Db.releaseYear},
            ${Db.platforms},
            ${Db.genres},
            ${Db.summary},
            ${Db.coverUrl},
            ${Db.releaseDate},
            ${Db.createdAt}
          )
        ''';

  /// The user's whole library, read [_pageSize] rows at a time so that no single
  /// request is large or runs into the API's row cap. Pages are keyed on
  /// `game_id` (unique per user, and the lead of an existing index), not on an
  /// offset, so rows added or removed while it runs can't shift later pages and
  /// skip or repeat a game. The pages are joined and returned together: the
  /// library the store shows is never a partial one.
  Future<List<Game>> fetchUserGames(String userId) async {
    final rows = await _readAllPages(Db.gameId, (after) {
      final query = _client
          .from(Db.userGames)
          .select(_userGameColumns)
          .eq(Db.userId, userId);
      return (after == null ? query : query.gt(Db.gameId, after))
          // Ascending, because the next page asks for `game_id > cursor`.
          .order(Db.gameId, ascending: true)
          .limit(_pageSize);
    });
    // Newest first, the order the old single ordered query returned.
    return rows.map<Game>(_gameFromUserGameRow).toList()..sort(_newestFirst);
  }

  /// The IGDB ids of the games in [userId]'s library whose catalog row was never
  /// filled in from IGDB (`games.igdb_synced_at` is NULL), for the background
  /// backfill (`CatalogBackfill`). A separate read rather than a column of
  /// [fetchUserGames], so the library payload and the copy saved on the device
  /// don't grow by a timestamp per game: this one answers only the games still
  /// to do, which is nothing once a library is filled in. It also reads the
  /// server's state as it is now, so rows filled in meanwhile (by another member,
  /// or by opening a game's screen) drop out without the library being read again.
  /// Paged like [fetchUserGames]: a library just imported from Steam can be long.
  /// Also the wishlist and To Play games not out yet whose row is due again (see
  /// [_fetchDueUpcoming]), each id once.
  Future<List<int>> fetchUnsyncedIgdbIds(String userId) async {
    final (never, upcoming) = await (
      _readAllPages(Db.gameId, (after) {
        final query = _client
            .from(Db.userGames)
            .select('${Db.gameId}, ${Db.games}!inner(${Db.igdbId})')
            .eq(Db.userId, userId)
            .isFilter('${Db.games}.${Db.igdbSyncedAt}', null)
            .not('${Db.games}.${Db.igdbId}', 'is', null);
        return (after == null ? query : query.gt(Db.gameId, after))
            .order(Db.gameId, ascending: true)
            .limit(_pageSize);
      }),
      _fetchDueUpcoming(userId),
    ).wait;
    return {
      for (final row in [...never, ...upcoming])
        if (row[Db.games] case final Map<dynamic, dynamic> game)
          if (_intOrNull(game[Db.igdbId]) case final int igdbId
              when igdbId > 0)
            igdbId,
    }.toList();
  }

  /// Wishlist and To Play games that aren't out yet (or have no date), whose
  /// catalog row was filled in a week ago or more: IGDB moves release dates, and
  /// the wishlist release alerts read them. `igdb-handler` answers a row filled
  /// in less than a week ago as it is, so asking for these costs nothing until
  /// they are due.
  Future<List<Map<String, dynamic>>> _fetchDueUpcoming(String userId) {
    final weekAgo = DateTime.now().toUtc().subtract(const Duration(days: 7)).toIso8601String();
    final today = _day(DateTime.now());
    return _readAllPages(Db.gameId, (after) {
      final query = _client
          .from(Db.userGames)
          .select('${Db.gameId}, ${Db.games}!inner(${Db.igdbId})')
          .eq(Db.userId, userId)
          .inFilter(Db.status, [
            gameStatusToDb(GameStatus.wishlist),
            gameStatusToDb(GameStatus.toPlay),
          ])
          .lt('${Db.games}.${Db.igdbSyncedAt}', weekAgo)
          .not('${Db.games}.${Db.igdbId}', 'is', null)
          .or('${Db.releaseDate}.is.null,${Db.releaseDate}.gte.$today', referencedTable: Db.games);
      return (after == null ? query : query.gt(Db.gameId, after))
          .order(Db.gameId, ascending: true)
          .limit(_pageSize);
    });
  }

  /// What IGDB says about the user's library games that the library filters work
  /// on (themes, game modes, perspectives, engines, developers, publishers), by
  /// game id. Only the games whose catalog row was filled in from IGDB are here
  /// (`games.igdb_synced_at` is set); a game missing from the answer has no
  /// details yet, which is not the same as a game IGDB has no values for (that one
  /// is here, with empty lists).
  ///
  /// A read of its own, made when the filter sheet opens, and not part of
  /// [fetchUserGames]: the lists would add a few hundred bytes to every game of
  /// every library load and of the copy saved on the device, for something most
  /// visits to the Library never use. Paged like [fetchUserGames].
  Future<Map<String, GameAttributes>> fetchLibraryAttributes(
    String userId,
  ) async {
    final rows = await _readAllPages(Db.gameId, (after) {
      final query = _client
          .from(Db.userGames)
          .select('''
            ${Db.gameId},
            ${Db.games}!inner (
              ${Db.themes},
              ${Db.gameModes},
              ${Db.playerPerspectives},
              ${Db.gameEngines},
              ${Db.developers},
              ${Db.publishers}
            )
          ''')
          .eq(Db.userId, userId)
          .not('${Db.games}.${Db.igdbSyncedAt}', 'is', null);
      return (after == null ? query : query.gt(Db.gameId, after))
          .order(Db.gameId, ascending: true)
          .limit(_pageSize);
    });
    return {
      for (final row in rows)
        if (row[Db.games] case final Map<dynamic, dynamic> game)
          '${row[Db.gameId]}': _attributesFromRow(
            Map<String, dynamic>.from(game),
          ),
    };
  }

  /// Every play session of the user, newest first. Read in pages like
  /// [fetchUserGames]: a long-time player passes the API's row cap.
  Future<List<LogEntry>> fetchLogEntries(String userId) async {
    final rows = await _readAllPages(Db.id, (after) {
      final query = _client
          .from(Db.logEntries)
          .select()
          .eq(Db.userId, userId);
      return (after == null ? query : query.gt(Db.id, after))
          .order(Db.id, ascending: true) // see fetchUserGames
          .limit(_pageSize);
    });
    return rows.map<LogEntry>(_logFromRow).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  /// How long the members took to finish [gameId], by category: the median and
  /// how many times it is the median of (see [CommunityTimes]). One request,
  /// counted in the database: no member's own time is sent. Empty when nobody
  /// reported one, and without a session.
  Future<CommunityTimes> fetchCommunityTimes(String gameId) async {
    final data = await _client.rpc(
      Db.rpcCompletionTimeStats,
      params: {'target_game': gameId},
    );
    if (data is! List) return const CommunityTimes();
    final byCategory = <CompletionCategory, CommunityTime>{};
    for (final raw in data) {
      if (raw is! Map) continue;
      final category = CompletionCategory.fromWire(raw[Db.category]);
      final median = _int(raw['median_minutes']);
      final count = _int(raw['submissions']);
      if (category == null || median <= 0 || count <= 0) continue;
      byCategory[category] = CommunityTime(
        median: Duration(minutes: median),
        count: count,
      );
    }
    return CommunityTimes(Map.unmodifiable(byCategory));
  }

  Future<void> upsertUserGame({
    required String userId,
    required String gameId,
    required GameStatus status,
    required double rating,
    required double hoursPlayed,
    required GamePlatform? playedOn,
    required double purchasePrice,
    required bool isFavorite,
    String? customBackdropUrl,
    DateTime? dateAdded,
    String review = '',
    bool stillPlaying = false,
    bool perfected = false,
  }) async {
    await _client.from(Db.userGames).upsert({
      Db.userId: userId,
      Db.gameId: gameId,
      Db.status: gameStatusToDb(status),
      Db.rating: rating,
      Db.hoursPlayed: hoursPlayed,
      Db.playedOn: playedOn == null ? null : gamePlatformToDb(playedOn),
      Db.purchasePrice: purchasePrice,
      Db.dateAdded: (dateAdded ?? DateTime.now()).toUtc().toIso8601String(),
      Db.isFavorite: isFavorite,
      Db.customBackdropUrl: customBackdropUrl,
      Db.review: review.trim(),
      // The trigger clears it for any status but completed.
      Db.stillPlaying: stillPlaying && status == GameStatus.completed,
      Db.perfected: perfected,
    }, onConflict: '${Db.userId},${Db.gameId}');
  }

  /// Saves how long [userId] took to finish [gameId], replacing the time they
  /// gave before (one per member and game). The game must be in their library
  /// on the server: the time belongs to its row there, and goes with it.
  Future<void> upsertCompletionTime({
    required String userId,
    required String gameId,
    required CompletionTime time,
  }) async {
    await _client.from(Db.completionTimes).upsert({
      Db.userId: userId,
      Db.gameId: gameId,
      Db.category: time.category.wire,
      Db.minutes: time.minutes,
    }, onConflict: '${Db.userId},${Db.gameId}');
  }

  /// Removes [userId]'s completion time for [gameId]. Removing one that isn't
  /// there does nothing.
  Future<void> deleteCompletionTime(String userId, String gameId) async {
    await _client
        .from(Db.completionTimes)
        .delete()
        .eq(Db.userId, userId)
        .eq(Db.gameId, gameId);
  }

  /// Inserts a play session. [loggedAt] is when it was logged, for a session
  /// that was kept on the device while the server was out of reach; without it
  /// the server stamps the time it arrives.
  Future<void> insertLogEntry({
    required String userId,
    required String gameId,
    required double hours,
    required GamePlatform platform,
    required String note,
    DateTime? loggedAt,
  }) async {
    await _client.from(Db.logEntries).insert({
      Db.userId: userId,
      Db.gameId: gameId,
      Db.hours: hours,
      Db.platform: gamePlatformToDb(platform),
      Db.note: note.trim(),
      if (loggedAt != null) Db.loggedAt: loggedAt.toUtc().toIso8601String(),
    });
  }

  /// Saves an edited play session: its hours, platform, note and when it was
  /// played (a session logged on the wrong day moves to the right one).
  Future<void> updateLogEntry({
    required String id,
    required double hours,
    required GamePlatform platform,
    required String note,
    required DateTime loggedAt,
  }) async {
    await _client
        .from(Db.logEntries)
        .update({
          Db.hours: hours,
          Db.platform: gamePlatformToDb(platform),
          Db.note: note.trim(),
          Db.loggedAt: loggedAt.toUtc().toIso8601String(),
        })
        .eq(Db.id, id);
  }

  /// Deletes one play session. The game's total is the store's to change.
  Future<void> deleteLogEntry(String id) async {
    await _client.from(Db.logEntries).delete().eq(Db.id, id);
  }

  /// Adds [game] to the global catalog if it isn't there yet, through the
  /// `igdb-handler` Edge Function (mode `add`).
  ///
  /// A game's identity is its IGDB id: `games.igdb_id` is unique and `games.id`
  /// must be [gameIdForIgdb] of it (database constraint), so the game added here
  /// from search and the same game imported by Steam sync are one row.
  ///
  /// Members can't write the catalog (20261019132900_security_hardening.sql), so
  /// only the IGDB id is sent: the function builds a missing row from IGDB's own
  /// answer, and a game that already exists (added earlier by another user, or by
  /// sync-steam) is left exactly as it is. Throws [StateError] when IGDB has no
  /// game by that id, and the [FunctionException] of a failed call.
  Future<void> addToCatalog(Game game) async {
    final igdbId = game.igdbId;
    if (igdbId == null) {
      // Only games read back from the database can lack an IGDB id (legacy
      // Steam-keyed rows), and those already exist, so they never get here.
      throw StateError('Cannot add "${game.title}" to the catalog without an IGDB id.');
    }
    assert(game.id == gameIdForIgdb(igdbId), 'games.id must be derived from igdb_id');
    final response = await _client.functions.invoke(
      'igdb-handler',
      body: {
        'mode': 'add',
        'igdb_ids': [igdbId],
      },
    );
    final data = response.data;
    bool lists(String key) => data is Map && data[key] is List && (data[key] as List).contains(igdbId);
    if (!lists('added') && !lists('existing')) {
      throw StateError('IGDB has no game "${game.title}" ($igdbId) to add to the catalog.');
    }
  }

  /// Takes [gameId] out of the library together with its play sessions, in one
  /// transaction (`remove_library_game`): both go, or neither does. The server
  /// works on the session's own rows, which are [userId]'s.
  Future<void> deleteUserGame(String userId, String gameId) async {
    await _client.rpc(Db.rpcRemoveLibraryGame, params: {'target_game': gameId});
  }

  /// Removes the user's whole library: every play session and every game (with
  /// its stored achievements), in one transaction (`clear_library`). The shared
  /// catalog is untouched.
  Future<void> clearLibrary(String userId) async {
    await _client.rpc(Db.rpcClearLibrary);
  }

  /// Emits an event whenever one of [userId]'s `user_games` rows changes.
  ///
  /// This deliberately isn't `.stream()`: that API has no column selection, so
  /// it would start with a `select *` of the whole library (achievements JSONB
  /// included). The store only uses this as a "refetch the library" trigger,
  /// so a plain change subscription with no initial snapshot is enough. Callers
  /// get the data from [fetchUserGames], which leaves `achievements` out.
  ///
  /// Like the stream it replaces, the user_id filter means DELETE events are
  /// not delivered (Realtime can't filter them); local deletes are applied
  /// optimistically by the store.
  Stream<void> watchUserGames(String userId) {
    late final StreamController<void> controller;
    RealtimeChannel? channel;
    controller = StreamController<void>(
      onListen: () {
        channel = _client
            .channel('user_games:$userId')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: Db.userGames,
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: Db.userId,
                value: userId,
              ),
              callback: (_) => controller.add(null),
            )
            .subscribe();
      },
      onCancel: () async {
        final c = channel;
        channel = null;
        if (c != null) await _client.removeChannel(c);
      },
    );
    return controller.stream;
  }

  Stream<List<Map<String, dynamic>>> watchLogEntries(String userId) => _client
      .from(Db.logEntries)
      .stream(primaryKey: [Db.id])
      .eq(Db.userId, userId);
}
