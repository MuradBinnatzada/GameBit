part of '../library_store.dart';

/// Changing the library: adding and removing games, their status, rating, review and the rest of what a game holds, and saving it (or keeping it for later).
extension LibraryEditing on LibraryStore {
  Future<void> removeFromLibrary(String id) async {
    final current = _user;
    if (current == null) return;
    _editSeq++;

    // Remove from local library list
    _libraryGames = List.unmodifiable(_libraryGames.where((g) => g.id != id));
    // Its play sessions go with it, as on the server (deleteUserGame), which
    // Realtime doesn't announce. Left here, Home would look up a game that is
    // no longer in any list.
    _logs = List.unmodifiable(_logs.where((l) => l.gameId != id));

    // Rebuild the combined list from its sources (popular + library) so the
    // removed game's library state can't linger in it. The game stays in the
    // list as a plain catalog entry, so an open detail page doesn't flash
    // "Game not found" while it closes, and a later search shows it as not in
    // the library. (Game.copyWith can't clear a status, hence withoutUserState.)
    final removed = maybeGame(id);
    final catalogById = <String, Game>{
      for (final g in _mergeGames(_popularGames, _libraryGames)) g.id: g,
    };
    if (removed != null) catalogById.putIfAbsent(id, removed.withoutUserState);

    _games = List.unmodifiable(catalogById.values.toList()..sort((a, b) => a.title.compareTo(b.title)));
    _notify();

    try {
      _auth.requireSession();
      await _repository.deleteUserGame(current.id, id);
      _pending.removed.remove(id);
      final queuedLogs = _pending.logs.length + _pending.logEdits.length;
      _pending.logs.removeWhere((l) => l.gameId == id);
      _pending.logEdits.removeWhere((_, l) => l.gameId == id);
      // The server deleted the completion time with the row.
      final queuedTime = _pending.completionTimes.containsKey(id);
      _pending.completionTimes.remove(id);
      if (_pending.games.remove(id) != null ||
          queuedTime ||
          _pending.logs.length + _pending.logEdits.length != queuedLogs) {
        _savePending();
      }
      // Realtime doesn't announce deletes, so the saved copy is told directly.
      unawaited(_cache.removeGame(current.id, id));
    } catch (e) {
      debugPrint('Delete failed: $e');
      if (isConnectionFailure(e)) {
        _pending.markRemoved(id);
        _savePending();
        _queuedNotice();
      } else {
        // The server kept it: say so, and put back what it has.
        _setNotice(L10n.current.libraryRemoveFailed);
        unawaited(_refreshLibrary(current));
        unawaited(_refreshLogs(current.id));
      }
    }
  }

  /// Removes every game and play session from the signed-in user's library, on
  /// the server first and then here (the screen, the saved copy and the edits
  /// still waiting for the server). Connected accounts stay. Returns null on
  /// success, or a message that is safe to show; the library is untouched then.
  ///
  /// Needs the server: unlike a single game's delete this is not queued for
  /// later, because a queued "clear" would also wipe games added in between.
  Future<String?> clearLibrary() async {
    final current = _user;
    if (current == null) return L10n.current.libraryClearSignIn;
    if (_isSyncing) return L10n.current.libraryClearWaitForSync;

    try {
      _auth.requireSession();
      await _repository.clearLibrary(current.id);
    } catch (e, st) {
      debugPrint('Clearing the library failed: $e\n$st');
      return isConnectionFailure(e)
          ? L10n.current.libraryClearOffline
          : L10n.current.libraryClearFailed;
    }
    if (_user?.id != current.id) return null; // signed out or switched meanwhile

    _editSeq++;
    _refreshDebounce?.cancel();
    _backfill.stop();
    _backfillAfterRefresh = false;
    _libraryGames = const [];
    _logs = const [];
    _games = List.unmodifiable(_mergeGames(_popularGames, const []));
    _pending.games.clear();
    _pending.removed.clear();
    _pending.logs.clear();
    _pending.logEdits.clear();
    _pending.logDeletes.clear();
    _pending.completionTimes.clear();
    _savePending();
    _syncStatus = SyncStatus.idle;
    _syncFailure = null;
    _notify();
    // Deletes are not announced by Realtime, so the saved copy is told directly
    // (an empty library, not a missing one: offline it must open empty).
    unawaited(_cache.writeLibrary(current.id, const []));
    unawaited(_cache.writeLogs(current.id, const []));
    _onCleared?.call(current.id);
    return null;
  }

  Future<void> toggleFavorite(String id) async {
    final game = gameById(id);
    final isCurrentlyFavorite = game.isFavorite;

    // Enforce Top 4 Limit
    final currentFavorites = _libraryGames.where((g) => g.isFavorite).length;
    if (!isCurrentlyFavorite && currentFavorites >= 4) {
      _setNotice(L10n.current.libraryFavoritesLimit(4));
      return;
    }

    // A game that is not in the library comes in with its heart, as it does with
    // a rating or a platform (setRating, setPlayedOn). Without a status there is
    // no row to save the favorite on.
    final next = game.copyWith(
      isFavorite: !isCurrentlyFavorite,
      status: game.status ?? GameStatus.playing,
      dateAdded: game.dateAdded ?? DateTime.now(),
    );
    _replaceGame(next);
    await _saveUserGame(next);
  }

  Future<void> addToLibrary(String id, GameStatus status) =>
      setStatus(id, status);

  /// [stillPlaying] is for a game made (or kept) Completed: whether it is
  /// still being played ([Game.stillPlaying]). Null keeps what it had, which is
  /// false for a game that wasn't completed. Any other status clears it.
  Future<void> setStatus(String id, GameStatus status, {bool? stillPlaying}) async {
    final game = gameById(id);
    final wasCompleted = game.status == GameStatus.completed;
    var next = game.copyWith(
      status: status,
      dateAdded: game.dateAdded ?? DateTime.now(),
      stillPlaying: status == GameStatus.completed
          ? stillPlaying ?? (wasCompleted && game.stillPlaying)
          : false,
    );
    // As the database keeps it (user_games_track_completion), so the Year in
    // Review counts it right away.
    if (status != GameStatus.completed) {
      next = next.withCompletedAt(null);
    } else if (game.status != GameStatus.completed) {
      next = next.withCompletedAt(DateTime.now());
    }
    _replaceGame(next);
    await _saveUserGame(next);
  }

  /// Keeps the completed game [id] under Playing too ([Game.stillPlaying]), or
  /// takes it off again. Does nothing for a game that isn't completed: it would
  /// be Playing, not still playing.
  Future<void> setStillPlaying(String id, bool value) async {
    final game = gameById(id);
    if (game.status != GameStatus.completed || game.stillPlaying == value) return;
    final next = game.copyWith(stillPlaying: value);
    _replaceGame(next);
    await _saveUserGame(next);
  }

  /// Marks the game [id] perfected ([Game.perfected]): the member got its
  /// Platinum trophy, every achievement or 100% out of it. Does nothing for a
  /// game that can't be ([Game.canBePerfected]).
  Future<void> setPerfected(String id, bool value) async {
    final game = gameById(id);
    if (!game.canBePerfected || game.perfected == value) return;
    final next = game.copyWith(perfected: value);
    _replaceGame(next);
    await _saveUserGame(next);
  }

  /// Puts [game] in the library as an imported file has it: [status], and the
  /// [rating], [hours], [playedOn] and [review] the file gives (what it leaves
  /// out keeps what the library has; hours never go down). No session is logged:
  /// imported hours are the game's history, not something played now.
  Future<void> importGame(
    Game game, {
    required GameStatus status,
    double? rating,
    double? hours,
    GamePlatform? playedOn,
    String? review,
  }) async {
    final existing = maybeGame(game.id) ?? game;
    final importedHours = hours?.clamp(0, maxTotalHours).toDouble();
    var next = existing.copyWith(
      status: status,
      rating: rating?.clamp(0, 5).toDouble(),
      hoursPlayed: importedHours != null && importedHours > existing.hoursPlayed ? importedHours : null,
      playedOn: playedOn,
      review: review == null || review.length <= Db.reviewMaxLength ? review : review.substring(0, Db.reviewMaxLength),
      dateAdded: existing.dateAdded ?? DateTime.now(),
      stillPlaying: status == GameStatus.completed && existing.stillPlaying,
    );
    if (status != GameStatus.completed) {
      next = next.withCompletedAt(null);
    } else if (existing.status != GameStatus.completed) {
      next = next.withCompletedAt(DateTime.now());
    }
    _replaceGame(next);
    await _saveUserGame(next);
  }

  /// Saves the member's review of [id] next to their rating (at most
  /// [Db.reviewMaxLength] characters; empty removes it). Like a rating, a game
  /// that is not in the library comes in with it.
  Future<void> setReview(String id, String review) async {
    final game = gameById(id);
    var text = review.trim();
    if (text.length > Db.reviewMaxLength) text = text.substring(0, Db.reviewMaxLength);
    if (text == game.review && game.inLibrary) return;
    final next = game.copyWith(
      status: game.status ?? GameStatus.playing,
      review: text,
      dateAdded: game.dateAdded ?? DateTime.now(),
    );
    _replaceGame(next);
    await _saveUserGame(next);
    _onReviewSaved?.call(id);
  }

  Future<void> setRating(String id, double rating) async {
    final game = gameById(id);
    final next = game.copyWith(
      status: game.status ?? GameStatus.playing,
      rating: rating.clamp(0, 5).toDouble(),
      dateAdded: game.dateAdded ?? DateTime.now(),
    );
    _replaceGame(next);
    await _saveUserGame(next);
    _onReviewSaved?.call(id);
  }

  Future<void> setPlayedOn(String id, GamePlatform platform) async {
    final game = gameById(id);
    final next = game.copyWith(
      status: game.status ?? GameStatus.playing,
      playedOn: platform,
      dateAdded: game.dateAdded ?? DateTime.now(),
    );
    _replaceGame(next);
    await _saveUserGame(next);
  }

  /// Sets the member's own backdrop for a game in their library (null: the
  /// blurred cover). [url] is an IGDB image URL from the game's artworks or
  /// screenshots (see `showGameBackdropSheet`).
  Future<void> setBackdrop(String id, String? url) async {
    final game = gameById(id);
    if (!game.inLibrary || game.customBackdropUrl == url) return;
    final next = game.withBackdrop(url);
    _replaceGame(next);
    await _saveUserGame(next);
  }

  /// Saves how long the member took to finish [gameId] (null: removes it). Only
  /// for a game in the library: the time belongs to its library row, so it goes
  /// when the game is removed, and it stays when the game moves away from
  /// Completed. Shown at once; kept on the device and sent later when the server
  /// can't be reached, and put back as the server has it when it is refused.
  Future<void> setCompletionTime(String gameId, CompletionTime? time) async {
    final current = _user;
    final game = maybeGame(gameId);
    if (current == null || game == null || !game.inLibrary) return;
    if (game.completionTime == time) return;
    _replaceGame(game.withCompletionTime(time));

    _editSeq++;
    _pendingSaves++;
    try {
      // The time needs the library row on the server: one being sent (the game
      // was just marked completed) goes first, and behind one that is queued
      // for later, the time waits in the same queue.
      await _gameSaves[gameId];
      if (_user?.id != current.id) return; // signed out or switched meanwhile
      if (_pending.games.containsKey(gameId)) {
        _queueCompletionTime(gameId, time);
        return;
      }
      await _sendCompletionTime(current.id, gameId, time);
      // This is newer than anything queued for the same game.
      if (_pending.completionTimes.containsKey(gameId)) {
        _pending.completionTimes.remove(gameId);
        _savePending();
      }
    } catch (e, st) {
      debugPrint('Completion time save failed: $e\n$st');
      if (isConnectionFailure(e)) {
        _queueCompletionTime(gameId, time);
      } else {
        _setNotice(L10n.current.completionTimeSaveFailed);
        _refreshQueued = true; // Revert to server truth once writes settle
      }
    } finally {
      _saveDone();
      if (_pendingSaves == 0 && _refreshQueued) {
        _refreshQueued = false;
        await _refreshLibrary(current);
      }
    }
  }

  /// Sends [gameId]'s completion time, or deletes it when [time] is null, and
  /// tells [_onCompletionTimeSaved]. Throws when that fails.
  Future<void> _sendCompletionTime(
    String userId,
    String gameId,
    CompletionTime? time,
  ) async {
    _auth.requireSession();
    if (time == null) {
      await _repository.deleteCompletionTime(userId, gameId);
    } else {
      await _repository.upsertCompletionTime(
        userId: userId,
        gameId: gameId,
        time: time,
      );
    }
    _onCompletionTimeSaved?.call(gameId);
  }

  /// Keeps [time] on the device to send with the other queued edits.
  void _queueCompletionTime(String gameId, CompletionTime? time) {
    _pending.putCompletionTime(gameId, time);
    _savePending();
    _queuedNotice();
  }

  void _replaceGame(Game next) {
    // Unconditionally update or add to the library list
    final libraryById = <String, Game>{
      for (final game in _libraryGames) game.id: game,
    };
    libraryById[next.id] = next;
    _libraryGames = List.unmodifiable(
      libraryById.values.toList()..sort((a, b) => a.title.compareTo(b.title)),
    );

    // Unconditionally update the main catalog list
    final catalogById = <String, Game>{
      for (final game in _games) game.id: game,
    };
    catalogById[next.id] = next;
    _games = List.unmodifiable(
      catalogById.values.toList()..sort((a, b) => a.title.compareTo(b.title)),
    );

    _notify();
  }

  /// Makes sure [game] has its row in the shared catalog (a search result put
  /// on a list). Throws when that can't be done.
  Future<void> ensureInCatalog(Game game) async {
    if (_gamesInDb.contains(game.id)) return;
    _auth.requireSession();
    await _repository.addToCatalog(game);
    _gamesInDb.add(game.id);
  }

  /// Writes [game] to the server: its catalog row first if needed, then the
  /// user's row for it. Throws when that fails.
  Future<void> _persistGame(String userId, Game game) async {
    _auth.requireSession();
    // Only touch the global catalog for a game the server hasn't confirmed yet
    // (typically a fresh search result). The server adds it from IGDB unless it
    // is there already, so if another user added it first this is a no-op.
    if (!_gamesInDb.contains(game.id)) {
      await _repository.addToCatalog(game);
      _gamesInDb.add(game.id);
    }

    await _repository.upsertUserGame(
      userId: userId,
      gameId: game.id,
      status: game.status!,
      rating: game.rating,
      hoursPlayed: game.hoursPlayed,
      playedOn: game.playedOn,
      purchasePrice: game.purchasePrice,
      dateAdded: game.dateAdded,
      isFavorite: game.isFavorite,
      customBackdropUrl: game.customBackdropUrl,
      review: game.review,
      stillPlaying: game.stillPlaying,
      perfected: game.perfected,
    );
  }

  /// Done once no library row is on its way to the server: at once when none
  /// is. Never fails. (A save the server refused, or that was kept for later,
  /// is done too.)
  Future<void> whenSaved() {
    if (_pendingSaves == 0) return Future.value();
    return (_saved ??= Completer<void>()).future;
  }

  void _saveDone() {
    _pendingSaves--;
    if (_pendingSaves == 0) {
      _saved?.complete();
      _saved = null;
    }
  }

  Future<void> _saveUserGame(Game game) async {
    final current = _user;
    if (current == null || game.status == null) return;

    _editSeq++;
    _pendingSaves++;
    final sent = Completer<void>();
    _gameSaves[game.id] = sent.future;

    try {
      await _persistGame(current.id, game);
      // This is newer than anything queued for the same game.
      if (_pending.games.remove(game.id) != null) _savePending();
    } catch (e, st) {
      debugPrint('User game save failed: $e\n$st');
      if (isConnectionFailure(e)) {
        // Keep the edit on screen and on the device; it is sent later.
        _pending.putGame(game);
        _savePending();
        _queuedNotice();
      } else {
        _setNotice(
          isContentRefusal(e)
              ? L10n.current.contentRefused
              : L10n.current.gameUpdateSaveFailed,
        );
        _refreshQueued = true; // Revert to server truth once writes settle
      }
    } finally {
      if (identical(_gameSaves[game.id], sent.future)) {
        _gameSaves.remove(game.id);
      }
      sent.complete();
      _saveDone();
      if (_pendingSaves == 0 && _refreshQueued) {
        _refreshQueued = false;
        await _refreshLibrary(current);
      }
    }
  }
}
