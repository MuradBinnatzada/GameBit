part of '../library_store.dart';

/// Importing from Steam: the library sync, and the achievements of a game.
extension LibrarySteamSync on LibraryStore {
  /// Syncs the signed-in user's Steam library. Returns null when everything was
  /// imported, otherwise a message that is safe to show: why nothing was synced,
  /// or what is still waiting when only part of it was. [syncStatus] says which.
  Future<String?> syncLibrary() async {
    final current = _user;
    if (current == null) return L10n.current.syncSignIn;
    if (_isSyncing) return L10n.current.syncAlreadyRunning;
    if (!_profile.steamConnected || _profile.steamId == null) {
      return L10n.current.syncConnectSteamFirst;
    }

    _isSyncing = true;
    _syncStatus = SyncStatus.idle;
    _syncFailure = null;
    _notify();

    try {
      final data = await _repository.syncSteamLibrary();
      debugPrint('Steam Sync Complete: $data');

      // Give the database a brief moment to settle broadcasts
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _refreshLibrary(current);

      // The function saves what it could and says what IGDB left for later.
      final delayed = SyncFailure.fromDelayed(data);
      _recordSync(current, delayed);
      if (_user?.id == current.id) _onSteamSynced?.call(current.id);
      // The games it imported have catalog rows IGDB has not filled in yet. They
      // are filled in once the re-read above has put them on screen, so what
      // comes back lands on them.
      if (_user?.id == current.id) _backfillAfterRefresh = true;
      return delayed?.message;
    } catch (e) {
      debugPrint('Error syncing Steam library: $e');
      final failure = SyncFailure.from(e);
      _recordSync(current, failure);
      return failure.message;
    } finally {
      _isSyncing = false;
      _notify();
    }
  }

  /// Remembers how a sync ended, unless the account changed while it ran.
  void _recordSync(User syncedFor, SyncFailure? failure) {
    if (_user?.id != syncedFor.id) return;
    _syncFailure = failure;
    _syncStatus = switch (failure) {
      null => SyncStatus.synced,
      SyncFailure(isDelayed: true) => SyncStatus.delayed,
      _ => SyncStatus.failed,
    };
  }

  /// Called when a game's detail page opens. Achievements aren't part of the
  /// library fetch, so if they aren't in memory yet this reads the stored copy
  /// of just that game's `achievements` column and puts it on the local [Game].
  ///
  /// Does nothing when they are already in memory, the game isn't in the
  /// library, or a lookup for it is already running. When the database has
  /// nothing stored (NULL) the game is left with `achievements == null`, which
  /// is the UI's cue to offer "Load Steam Achievements" ([syncGameAchievements]).
  /// Never throws; a failed lookup is logged and treated like "nothing stored".
  ///
  /// Does no notifying before its first `await`, so it is safe to call from
  /// `initState` or right after a frame.
  Future<void> ensureAchievementsLoaded(String gameId) async {
    final current = _user;
    if (current == null) return;
    final game = maybeGame(gameId);
    if (game == null || !game.inLibrary || game.achievements != null) return;
    if (!_achievementsLoading.add(gameId)) return;

    try {
      final stored = await _repository.fetchGameAchievements(current.id, gameId);
      if (stored == null || _user?.id != current.id) return;

      // Re-read the game: a Steam sync may have filled it in while we waited.
      final latest = maybeGame(gameId);
      if (latest == null || latest.achievements != null) return;
      _replaceGame(latest.copyWith(achievements: stored));
    } catch (e, st) {
      debugPrint('Achievements lookup failed for $gameId: $e\n$st');
    } finally {
      _achievementsLoading.remove(gameId);
    }
  }

  /// Puts a list of [gameId]'s achievements fetched elsewhere (opening the game
  /// on your profile) on the local game, so its screen shows the same.
  void adoptAchievements(String gameId, List<Achievement> achievements) {
    final game = maybeGame(gameId);
    if (game == null || !game.inLibrary) return;
    _replaceGame(game.copyWith(achievements: achievements));
  }

  /// Loads Steam achievements for a single game on demand (via the
  /// `sync-achievements` Edge Function) and caches them on the local [Game].
  ///
  /// Achievements cost one Steam round trip per game, so they are deliberately
  /// not part of [syncLibrary]. Returns `null` on success, or a message that is
  /// safe to show to the user.
  Future<String?> syncGameAchievements(String gameId) async {
    // Local check only, to avoid a pointless request. The Edge Function
    // re-checks against the profile row on the server.
    if (_user == null ||
        _profile.steamId == null ||
        !_profile.steamConnected) {
      return L10n.current.achievementsConnectSteam;
    }
    final game = maybeGame(gameId);
    if (game == null) return L10n.current.gameNotFound;

    try {
      final data = await _repository.syncGameAchievements(gameId);
      final achievements =
          data is Map ? Achievement.listFromJson(data['achievements']) : null;
      if (achievements == null) return L10n.current.steamUnexpectedResponse;

      // Re-read the game: it may have changed while the request was in flight.
      _replaceGame((maybeGame(gameId) ?? game).copyWith(achievements: achievements));
      return null;
    } on FunctionException catch (e) {
      debugPrint('Achievements sync failed (${e.status}): ${e.details}');
      final failure = SyncFailure.from(e);
      if (failure.code != SyncFailureCode.unknown) return failure.message;
      // No code: a function deployed before codes existed. Its text is still
      // actionable (e.g. private profile).
      final details = e.details;
      final message = details is Map ? details['error'] : null;
      return message is String && message.isNotEmpty
          ? message
          : L10n.current.achievementsLoadFailed;
    } catch (e) {
      debugPrint('Achievements sync failed: $e');
      return L10n.current.achievementsLoadFailed;
    }
  }
}
