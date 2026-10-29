part of '../library_store.dart';

/// Logging, editing and deleting play sessions, which move the game's hours with them.
extension LibraryPlaySessions on LibraryStore {
  GameStatus _statusAfterLogging(GameStatus? s) =>
      s == GameStatus.completed ? GameStatus.completed : GameStatus.playing;

  /// Logs a play session of [hours] (more than 0, at most [maxSessionHours])
  /// and adds it to the game's total. [at] backdates it: a session played
  /// earlier, logged now. A time in the future is taken as now.
  Future<void> logSession({
    required String gameId,
    required double hours,
    GamePlatform? platform,
    String note = '',
    DateTime? at,
  }) => _logNewSession(
    gameId: gameId,
    hours: hours,
    maxHours: maxSessionHours,
    platform: platform,
    note: note,
    at: at,
  );

  /// Logs [session] again after [deleteSession] took it away (its Undo), as it
  /// was: same hours, platform, note and time.
  Future<void> restoreSession(LogEntry session) => _logNewSession(
    gameId: session.gameId,
    hours: session.hours,
    maxHours: maxTotalHours,
    platform: session.platform,
    note: session.note,
    at: session.timestamp,
  );

  Future<void> _logNewSession({
    required String gameId,
    required double hours,
    required double maxHours,
    GamePlatform? platform,
    String note = '',
    DateTime? at,
  }) async {
    if (hours <= 0 || hours > maxHours) return;
    final current = _user;
    if (current == null) return;
    final g = gameById(gameId);
    final p = platform ?? g.playedOn ?? (g.platforms.isNotEmpty ? g.platforms.first : GamePlatform.pc);
    final next = g.copyWith(
      hoursPlayed: (g.hoursPlayed + hours).clamp(0, maxTotalHours).toDouble(),
      playedOn: p,
      status: _statusAfterLogging(g.status),
      dateAdded: g.dateAdded ?? DateTime.now(),
    );
    _replaceGame(next);
    final now = DateTime.now();
    final when = at == null || at.isAfter(now) ? now : at;
    final cleanNote = _cleanNote(note);
    final logId = 'local-${now.microsecondsSinceEpoch}';
    _logs = _newestFirst([
      LogEntry(
        id: logId,
        gameId: gameId,
        timestamp: when,
        hours: hours,
        platform: p,
        note: cleanNote,
      ),
      ..._logs,
    ]);
    _notify();

    await _saveUserGame(next);
    final inserted = await _insertLog(
      userId: current.id,
      localId: logId,
      loggedAt: when,
      gameId: gameId,
      hours: hours,
      platform: p,
      note: cleanNote,
    );
    if (inserted) await _refreshLogs(current.id);
  }

  Future<void> updateTime({
    required String gameId,
    required double totalHours,
    GamePlatform? platform,
    String note = '',
  }) async {
    final current = _user;
    if (current == null) return;
    totalHours = totalHours.clamp(0, maxTotalHours).toDouble();
    final now = DateTime.now();
    final g = gameById(gameId);
    final delta = totalHours - g.hoursPlayed;
    final p = platform ?? g.playedOn ?? (g.platforms.isNotEmpty ? g.platforms.first : GamePlatform.pc);
    final next = g.copyWith(
      hoursPlayed: totalHours,
      playedOn: platform ?? g.playedOn,
      status: delta > 0.01
          ? _statusAfterLogging(g.status)
          : (g.status ?? GameStatus.playing),
      dateAdded: g.dateAdded ?? DateTime.now(),
    );
    _replaceGame(next);
    await _saveUserGame(next);

    if (delta > 0.01) {
      final inserted = await _insertLog(
        userId: current.id,
        localId: 'local-${now.microsecondsSinceEpoch}',
        loggedAt: now,
        gameId: gameId,
        hours: delta,
        platform: p,
        note: _cleanNote(note),
      );
      if (inserted) await _refreshLogs(current.id);
    }
  }

  /// The session [id], or null.
  LogEntry? sessionById(String id) {
    for (final l in _logs) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// Changes the play session [id]: its [hours] (more than 0, at most
  /// [maxTotalHours]), [platform], [note] and when it was played ([at]; a time
  /// in the future is taken as now). The game's total moves by the difference in
  /// hours. Kept on the device when the server can't be reached, like any edit;
  /// when the server refuses it, the session and the total are put back.
  Future<void> editSession(
    String id, {
    required double hours,
    required GamePlatform platform,
    required DateTime at,
    String note = '',
  }) async {
    final current = _user;
    final old = sessionById(id);
    if (current == null || old == null || hours <= 0 || hours > maxTotalHours) {
      return;
    }
    if (_isUnconfirmed(id)) return;
    final now = DateTime.now();
    final edited = LogEntry(
      id: id,
      gameId: old.gameId,
      timestamp: at.isAfter(now) ? now : at,
      hours: hours,
      platform: platform,
      note: _cleanNote(note),
      fromSteam: old.fromSteam,
    );
    _logs = _newestFirst([for (final l in _logs) l.id == id ? edited : l]);
    final gameBefore = maybeGame(old.gameId);
    final gameAfter = _withHoursMoved(gameBefore, hours - old.hours);
    if (gameAfter != null) _replaceGame(gameAfter);
    _notify();

    final saved = await _sendSessionChange(
      current,
      PendingLog(
        localId: id,
        gameId: edited.gameId,
        hours: edited.hours,
        platform: edited.platform,
        note: edited.note,
        timestamp: edited.timestamp,
      ),
    );
    if (!saved) {
      if (gameBefore != null && gameAfter != null) _replaceGame(gameBefore);
      return;
    }
    if (gameAfter != null) await _saveUserGame(gameAfter);
  }

  /// Deletes the play session [id] and takes its hours off the game's total.
  /// Returns the session, for an Undo ([restoreSession]), or null when there was
  /// nothing to delete.
  Future<LogEntry?> deleteSession(String id) async {
    final current = _user;
    final old = sessionById(id);
    if (current == null || old == null) return null;
    if (_isUnconfirmed(id)) return null;
    _logs = List.unmodifiable(_logs.where((l) => l.id != id));
    final gameBefore = maybeGame(old.gameId);
    final gameAfter = _withHoursMoved(gameBefore, -old.hours);
    if (gameAfter != null) _replaceGame(gameAfter);
    _notify();

    final saved = await _sendSessionChange(current, null, deletedId: id);
    if (!saved) {
      if (gameBefore != null && gameAfter != null) _replaceGame(gameBefore);
      return null;
    }
    if (gameAfter != null) await _saveUserGame(gameAfter);
    return old;
  }

  /// A session logged here that reached the server but whose server id hasn't
  /// come back yet: it can't be found there to change. Says so.
  bool _isUnconfirmed(String id) {
    if (!id.startsWith('local-') || _pending.logs.any((l) => l.localId == id)) {
      return false;
    }
    _setNotice(L10n.current.sessionStillSaving);
    return true;
  }

  /// [game] with [delta] hours added to its total (never below 0), or null when
  /// it isn't in the library.
  Game? _withHoursMoved(Game? game, double delta) {
    if (game == null || !game.inLibrary || delta.abs() < 0.001) return null;
    return game.copyWith(
      hoursPlayed: (game.hoursPlayed + delta).clamp(0, maxTotalHours).toDouble(),
    );
  }

  /// Sends an edited session ([edited]) or a deleted one ([deletedId]), or
  /// queues it when the server can't be reached. Returns false when the server
  /// refused it: the sessions are read again then, with a notice.
  Future<bool> _sendSessionChange(
    User current,
    PendingLog? edited, {
    String? deletedId,
  }) async {
    final id = edited?.localId ?? deletedId!;
    if (_pending.logs.any((l) => l.localId == id)) {
      // Not inserted yet: the insert that is queued is changed instead.
      if (edited != null) {
        _pending.editLog(edited);
      } else {
        _pending.removeLog(id);
      }
      _savePending();
      return true;
    }
    try {
      _auth.requireSession();
      if (edited != null) {
        await _repository.updateLogEntry(
          id: id,
          hours: edited.hours,
          platform: edited.platform,
          note: edited.note,
          loggedAt: edited.timestamp,
        );
        if (_pending.logEdits.remove(id) != null) _savePending();
      } else {
        await _repository.deleteLogEntry(id);
        if (_pending.logEdits.remove(id) != null) _savePending();
      }
      return true;
    } catch (e, st) {
      debugPrint('Saving a session change failed: $e\n$st');
      if (isConnectionFailure(e)) {
        if (edited != null) {
          _pending.editLog(edited);
        } else {
          _pending.removeLog(id);
        }
        _savePending();
        _queuedNotice();
        return true;
      }
      _setNotice(L10n.current.sessionChangeSaveFailed);
      unawaited(_refreshLogs(current.id));
      return false;
    }
  }

  /// Inserts a play session. When the server can't be reached it is queued
  /// instead (and shown now), keeping [loggedAt] as its time; returns whether
  /// it reached the server.
  Future<bool> _insertLog({
    required String userId,
    required String localId,
    required DateTime loggedAt,
    required String gameId,
    required double hours,
    required GamePlatform platform,
    required String note,
  }) async {
    try {
      _auth.requireSession();
      await _repository.insertLogEntry(
        userId: userId,
        gameId: gameId,
        hours: hours,
        platform: platform,
        note: note,
        // The time on screen, which is not now for a backdated session.
        loggedAt: loggedAt,
      );
      return true;
    } catch (e, st) {
      debugPrint('Logging a session failed: $e\n$st');
      if (isConnectionFailure(e)) {
        final log = PendingLog(
          localId: localId,
          gameId: gameId,
          hours: hours,
          platform: platform,
          note: note.trim(),
          timestamp: loggedAt,
        );
        _pending.logs.add(log);
        _savePending();
        if (!_logs.any((l) => l.id == localId)) {
          _logs = _newestFirst([log.toEntry(), ..._logs]);
        }
        _queuedNotice();
      } else {
        _setNotice(L10n.current.sessionSaveFailed);
      }
      return false;
    }
  }
}
