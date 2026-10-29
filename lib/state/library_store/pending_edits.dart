part of '../library_store.dart';

/// Edits kept on the device while the server can't be reached, shown as if saved, and sent when it can.
extension LibraryPendingEdits on LibraryStore {
  void _queuedNotice() {
    _offline = true;
    _setNotice(queuedNotice);
  }

  void _savePending() {
    final userId = _pendingFor;
    if (userId != null) unawaited(_pendingStorage.write(userId, _pending));
  }

  /// [games] as the user last left them: the server's list with the edits that
  /// haven't reached it applied on top, so a refresh never undoes them.
  ///
  /// Completion times are sent and queued apart from the game: a queued game
  /// keeps the time the server has, and the queued times go on top.
  List<Game> _withPendingEdits(List<Game> games) {
    if (_pending.games.isEmpty &&
        _pending.removed.isEmpty &&
        _pending.completionTimes.isEmpty) {
      return games;
    }
    final byId = <String, Game>{
      for (final g in games)
        if (!_pending.removed.contains(g.id)) g.id: g,
    };
    for (final g in _pending.games.values) {
      byId[g.id] = g.withCompletionTime(byId[g.id]?.completionTime);
    }
    for (final MapEntry(key: id, value: time)
        in _pending.completionTimes.entries) {
      final g = byId[id];
      if (g != null) byId[id] = g.withCompletionTime(time);
    }
    return byId.values.toList();
  }

  /// [logs] as the user last left them: with the queued sessions, the queued
  /// changes to sessions applied, and without the sessions of games whose delete
  /// is queued (the delete takes them too, see [removeFromLibrary]). Newest first.
  List<LogEntry> _withPendingLogs(List<LogEntry> logs) {
    if (_pending.logs.isEmpty &&
        _pending.removed.isEmpty &&
        _pending.logEdits.isEmpty &&
        _pending.logDeletes.isEmpty) {
      return logs;
    }
    return _newestFirst([
      for (final l in _pending.logs) l.toEntry(),
      for (final l in logs)
        if (!_pending.removed.contains(l.gameId) &&
            !_pending.logDeletes.contains(l.id))
          _pending.logEdits[l.id]?.toEntry(fromSteam: l.fromSteam) ?? l,
    ]);
  }

  /// Sends the queued edits to the server, deletes first, then games and their
  /// completion times, then sessions (new ones, then changed and deleted ones).
  /// Stops at the first one the server can't be reached for (the rest stay
  /// queued); one it refuses is dropped, with a notice. Safe to call any
  /// time: it does nothing without a live session or while already running.
  Future<void> flushPending() async {
    final user = _user;
    if (user == null || _flushing || _pending.isEmpty || _auth.isSessionPending) {
      return;
    }
    _flushing = true;
    var sent = 0;
    var refused = 0;
    var unreachable = false;

    // Runs [send] for one queued item. Returns false when the loop must stop.
    Future<bool> attempt(Future<void> Function() send, void Function() done) async {
      if (_user?.id != user.id) return false;
      try {
        await send();
        sent++;
        done();
        return true;
      } catch (e, st) {
        debugPrint('Sending a queued edit failed: $e\n$st');
        if (isConnectionFailure(e)) {
          unreachable = true;
          return false;
        }
        refused++;
        done();
        return true;
      }
    }

    try {
      for (final id in [..._pending.removed]) {
        final ok = await attempt(
          () async {
            await _repository.deleteUserGame(user.id, id);
            unawaited(_cache.removeGame(user.id, id));
          },
          () => _pending.removed.remove(id),
        );
        if (!ok) return;
      }
      for (final game in [..._pending.games.values]) {
        final ok = await attempt(
          () => _persistGame(user.id, game),
          () => _pending.games.remove(game.id),
        );
        if (!ok) return;
      }
      // After the games: a time needs its library row on the server.
      for (final MapEntry(key: gameId, value: time) in [
        ..._pending.completionTimes.entries,
      ]) {
        final ok = await attempt(
          () => _sendCompletionTime(user.id, gameId, time),
          () {
            // A newer time queued while this one was sent is still to go.
            if (_pending.completionTimes[gameId] == time) {
              _pending.completionTimes.remove(gameId);
            }
          },
        );
        if (!ok) return;
      }
      for (final log in [..._pending.logs]) {
        final ok = await attempt(
          () => _repository.insertLogEntry(
            userId: user.id,
            gameId: log.gameId,
            hours: log.hours,
            platform: log.platform,
            note: log.note,
            // When it was played, not when the connection came back.
            loggedAt: log.timestamp,
          ),
          () => _pending.logs.remove(log),
        );
        if (!ok) return;
      }
      for (final log in [..._pending.logEdits.values]) {
        final ok = await attempt(
          () => _repository.updateLogEntry(
            id: log.localId,
            hours: log.hours,
            platform: log.platform,
            note: log.note,
            loggedAt: log.timestamp,
          ),
          () => _pending.logEdits.remove(log.localId),
        );
        if (!ok) return;
      }
      for (final id in [..._pending.logDeletes]) {
        final ok = await attempt(
          () => _repository.deleteLogEntry(id),
          () => _pending.logDeletes.remove(id),
        );
        if (!ok) return;
      }
    } finally {
      _flushing = false;
      _savePending();
      if (unreachable) _offline = true;
      if (refused > 0) {
        _setNotice(L10n.current.offlineChangesSaveFailed);
      } else {
        _notify();
      }
      // Pull in what the server has now, queued edits that remain applied on top.
      if (sent > 0 && _user?.id == user.id) {
        unawaited(_refreshLibrary(user));
        unawaited(_refreshLogs(user.id));
      }
    }
  }
}
