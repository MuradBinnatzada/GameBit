import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/models/milestone_progress.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/lists_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/profile_store.dart';

/// Milestones the server just recorded for the signed-in member, for the app
/// shell to announce ([MilestonesStore.takeAnnouncement]). Never empty.
@immutable
class MilestoneUnlock {
  const MilestoneUnlock(this.milestones, {required this.fromHistory});

  /// The most recently earned first.
  final List<Milestone> milestones;

  /// Mostly earned some time ago: what the member had done before milestones
  /// existed, or on another device. Summed up in one line rather than
  /// celebrated one by one.
  final bool fromHistory;
}

/// The signed-in member's own milestones: those they earned
/// ([CheckpointRepository.fetchMilestones], saved on the device too), how far
/// they are towards the others ([progress], worked out from the library, lists
/// and profile), and the calls that have the server award new ones.
///
/// The server decides what is earned (`award_milestones`). It is asked once a
/// session, as soon as there is a library (that is also when everything done
/// before milestones existed is credited), and again whenever [progress] says a
/// milestone was reached that isn't earned yet. That second ask waits for the
/// edit behind it to reach the server: the library's saves, and a session the
/// server hasn't given an id yet. What the server awards is kept for the app
/// shell to announce ([takeAnnouncement]), however early it arrives.
///
/// It runs on the changes of the stores it follows, never on a timer.
class MilestonesStore extends AccountScopedStore {
  MilestonesStore({
    required this._repository,
    required AuthStore auth,
    required this._library,
    required this._profile,
    required this._lists,
    required this._cache,
    DateTime Function()? now,
    int Function()? utcOffsetMinutes,
  }) : _auth = auth,
       _now = now ?? DateTime.now,
       _utcOffset =
           utcOffsetMinutes ?? (() => DateTime.now().timeZoneOffset.inMinutes),
       super(auth);

  final CheckpointRepository _repository;
  final AuthStore _auth;
  final LibraryStore _library;
  final ProfileStore _profile;
  final ListsStore _lists;
  final LocalCache _cache;
  final DateTime Function() _now;
  final int Function() _utcOffset;

  /// A milestone the server didn't award when asked (it counts a little
  /// differently, or a follow was still on its way) is asked about again on a
  /// change after this, or sooner once there is more of what it counts.
  static const askAgainAfter = Duration(seconds: 30);

  /// Earned this long before the call that found them, milestones are history.
  static const historyAfter = Duration(hours: 1);

  /// More than this many at once are summed up.
  static const announceOneByOne = 3;

  EarnedMilestones _earned = const EarnedMilestones();
  LoadStatus _status = LoadStatus.idle;
  MilestoneProgress? _progress;

  /// This device has shown the member's milestones before (they are in its
  /// cache), so what it has already announced is known.
  bool _seenOnDevice = false;

  /// The once-a-session read and award are done.
  bool _synced = false;

  /// When each milestone was last asked for, and how much of it there was.
  final Map<String, (DateTime, num)> _asked = {};
  bool _checkScheduled = false;
  bool _running = false;
  bool _disposed = false;
  bool _again = false;
  MilestoneUnlock? _announcement;

  /// The milestones the signed-in member has earned.
  EarnedMilestones get earned => _earned;

  /// Idle until the account's milestones are known: from the device, then from
  /// the server.
  LoadStatus get status => _status;

  /// What the server awarded since this was last asked, once: null when
  /// nothing. Listen to the store to hear of it.
  MilestoneUnlock? takeAnnouncement() {
    final out = _announcement;
    _announcement = null;
    return out;
  }

  /// How far the member is towards each milestone, as far as the device knows.
  MilestoneProgress get progress => _progress ??= MilestoneProgress.of(
    library: _library.libraryGames,
    sessions: _library.sessions,
    lists: _lists.status == LoadStatus.ready ? _lists.lists : null,
    following: _profile.followingCount,
    followers: _profile.followersCount,
    profile: accountId == null ? null : _profile.profile,
    gameAccount: _profile.steamConnected,
    twoFactor: _auth.hasTwoFactor,
    now: _now(),
  );

  @override
  void initialize() {
    super.initialize();
    _library.addListener(_onInputs);
    _profile.addListener(_onInputs);
    _lists.addListener(_onInputs);
    _auth.addListener(_onInputs);
    unawaited(_startAccount());
  }

  @override
  void resetForAccount() {
    _earned = const EarnedMilestones();
    _status = LoadStatus.idle;
    _progress = null;
    _seenOnDevice = false;
    _synced = false;
    _asked.clear();
    _again = false;
    _announcement = null;
    unawaited(_startAccount());
  }

  Future<void> _startAccount() async {
    final userId = accountId;
    if (userId == null) return;
    final epoch = this.epoch;
    final cached = await _cache.readMilestones(userId);
    if (isStale(epoch)) return;
    if (cached != null) {
      _earned = cached.value.plus(_earned.unlockedAt);
      _seenOnDevice = true;
      _status = LoadStatus.ready;
      notifyIfAlive();
    }
    _onInputs();
  }

  // The stores this one follows notify from the middle of their own work, often
  // several times in a row: it looks once they are done.
  void _onInputs() {
    _progress = null;
    if (_checkScheduled) return;
    _checkScheduled = true;
    scheduleMicrotask(() {
      _checkScheduled = false;
      notifyIfAlive();
      unawaited(_check());
    });
  }

  /// Reads the member's milestones from the server again (pull to refresh).
  Future<void> refresh() {
    _synced = false;
    return _check();
  }

  Future<void> _check() async {
    if (_disposed || accountId == null) return;
    // No library yet, neither saved on the device nor from the server.
    if (_library.lastSyncedAt == null) return;
    // One call at a time; the one running looks again when it is done.
    if (_running) {
      _again = true;
      return;
    }

    final ask = _toAskFor();
    if (_synced && ask.isEmpty) return;

    _running = true;
    try {
      if (_synced) {
        // The server can only count what reached it.
        final epoch = this.epoch;
        await _library.whenSaved();
        if (isStale(epoch)) return;
        if (_library.sessions.any(_notOnServer)) return;
      }
      final now = _now();
      final asking = _toAskFor();
      if (_synced && asking.isEmpty) return;
      for (final m in asking) {
        _asked[m.id] = (now, progress.valueOf(m.metric) ?? 0);
      }
      await _sync(readAll: !_synced);
    } finally {
      _running = false;
    }
    if (_again) {
      _again = false;
      await _check();
    }
  }

  /// A session logged on the device that the server hasn't taken yet (its id is
  /// the device's own until it has).
  static bool _notOnServer(LogEntry session) => session.id.startsWith('local-');

  /// The milestones [progress] says are reached but aren't earned, leaving out
  /// those asked for lately with no more to show for them since.
  List<Milestone> _toAskFor() {
    final now = _now();
    return [
      for (final m in milestones)
        if (!_earned.has(m.id) && progress.reached(m) && !_askedLately(m, now))
          m,
    ];
  }

  bool _askedLately(Milestone m, DateTime now) {
    final asked = _asked[m.id];
    if (asked == null) return false;
    final (at, value) = asked;
    final more = (progress.valueOf(m.metric) ?? 0) > value;
    return !more && now.difference(at) < askAgainAfter;
  }

  Future<void> _sync({required bool readAll}) async {
    final userId = accountId!;
    final epoch = this.epoch;
    final startedAt = _now();
    if (_status == LoadStatus.idle) {
      _status = LoadStatus.loading;
      notifyIfAlive();
    }
    try {
      final awarded = await _repository.awardMilestones(_utcOffset());
      final all = readAll ? await _repository.fetchMilestones(userId) : null;
      if (isStale(epoch)) return;

      final before = _earned;
      _earned = _earned.plus({...?all, ...awarded});
      _synced = _synced || readAll;
      _status = LoadStatus.ready;
      _announce(before, startedAt);
      _seenOnDevice = true;
      notifyIfAlive();
      await _cache.writeMilestones(userId, _earned);
    } catch (e, st) {
      debugPrint('Awarding milestones failed: $e\n$st');
      if (isStale(epoch)) return;
      // Asked again on the next change.
      _asked.clear();
      if (_status == LoadStatus.loading) {
        _status = _seenOnDevice ? LoadStatus.ready : LoadStatus.failed;
        notifyIfAlive();
      }
    }
  }

  /// Keeps for announcing what [_earned] has that [before] didn't, with what
  /// is still waiting. On a device that has never shown this member's
  /// milestones, everything is new to it.
  void _announce(EarnedMilestones before, DateTime startedAt) {
    final waiting = _announcement?.milestones ?? const <Milestone>[];
    final fresh = [
      for (final m in _earned.list)
        if (!_seenOnDevice || !before.has(m.id) || waiting.contains(m)) m,
    ];
    if (fresh.isEmpty) return;
    final historyBefore = startedAt.subtract(historyAfter);
    final fromHistory =
        (_announcement?.fromHistory ?? false) ||
        fresh.length > announceOneByOne ||
        fresh.any((m) => _earned.unlockedAt[m.id]!.isBefore(historyBefore));
    _announcement = MilestoneUnlock(fresh, fromHistory: fromHistory);
  }

  @override
  void dispose() {
    _disposed = true;
    _library.removeListener(_onInputs);
    _profile.removeListener(_onInputs);
    _lists.removeListener(_onInputs);
    _auth.removeListener(_onInputs);
    super.dispose();
  }
}
