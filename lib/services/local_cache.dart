import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/models/user_profile.dart';

/// A value read back from [LocalCache], with when it was saved.
class Cached<T> {
  const Cached(this.value, this.savedAt);

  final T value;
  final DateTime savedAt;
}

/// The signed-in user's follow state as last fetched.
class SocialSnapshot {
  const SocialSnapshot({required this.followingIds, required this.followersCount});

  final Set<String> followingIds;
  final int followersCount;
}

/// Copies of what the server last returned, kept on the device so the app can
/// show the library without a network connection.
///
/// This is a read-through cache, not a store of record: the stores write to it
/// only with data they just fetched (never with a local edit the server hasn't
/// accepted), show it while the network request is still running, and fall back
/// to it when that request fails. It is kept per account, so another account
/// signing in on the same device never sees it, and a store drops an account's
/// copy when that account signs out ([clearAccount]).
///
/// It sits on `shared_preferences`, which loads every value into memory at
/// startup. That is fine for a library of a few thousand games, but this class is
/// the only thing that knows where the data lives, so a database can replace it
/// if libraries outgrow that.
///
/// Nothing here throws: a missing, unreadable or outdated entry reads as `null`,
/// and a failed write is logged and skipped. A broken cache must never break
/// the app.
///
/// The library entry is the one that grows with the user, so reads and writes of
/// it are timed. Nothing is printed unless one takes [slowAfter] or longer, and
/// then the line says how long, where the time went (storage or JSON) and how big
/// the entry is: the numbers to look at before deciding that `shared_preferences`
/// is too slow for big libraries.
class LocalCache {
  LocalCache({this.slowAfter = slowThreshold});

  /// When a library read or write is slow enough to be logged.
  static const slowThreshold = Duration(milliseconds: 50);

  final Duration slowAfter;

  /// Bump when the JSON written below changes shape. Entries with another version
  /// read as missing and are deleted.
  static const _version = 1;
  static const _prefix = 'cache.v$_version';

  static String _libraryKey(String userId) => '$_prefix.library.$userId';
  static String _logsKey(String userId) => '$_prefix.logs.$userId';
  static String _profileKey(String userId) => '$_prefix.profile.$userId';
  static String _socialKey(String userId) => '$_prefix.social.$userId';
  static String _milestonesKey(String userId) => '$_prefix.milestones.$userId';
  static const _popularKey = '$_prefix.popular';

  Future<Cached<List<Game>>?> readLibrary(String userId) =>
      _readList(_libraryKey(userId), Game.fromJson, timedAs: 'library');

  Future<void> writeLibrary(String userId, List<Game> games) => _write(
    _libraryKey(userId),
    () => [for (final g in games) g.toJson()],
    timedAs: 'library',
  );

  Future<Cached<List<LogEntry>>?> readLogs(String userId) =>
      _readList(_logsKey(userId), LogEntry.fromJson);

  Future<void> writeLogs(String userId, List<LogEntry> logs) =>
      _write(_logsKey(userId), () => [for (final l in logs) l.toJson()]);

  Future<Cached<UserProfile>?> readProfile(String userId) =>
      _read(_profileKey(userId), (data) => UserProfile.fromJson(_asMap(data)));

  Future<void> writeProfile(String userId, UserProfile profile) =>
      _write(_profileKey(userId), profile.toJson);

  Future<Cached<SocialSnapshot>?> readSocial(String userId) =>
      _read(_socialKey(userId), (data) {
        final map = _asMap(data);
        return SocialSnapshot(
          followingIds: {for (final id in map['following'] as List) '$id'},
          followersCount: (map['followers'] as num).toInt(),
        );
      });

  Future<void> writeSocial(String userId, SocialSnapshot social) =>
      _write(_socialKey(userId), () => {
        'following': social.followingIds.toList(),
        'followers': social.followersCount,
      });

  /// The milestones [userId] has earned, as last read from the server.
  Future<Cached<EarnedMilestones>?> readMilestones(String userId) =>
      _read(_milestonesKey(userId), EarnedMilestones.fromJson);

  Future<void> writeMilestones(String userId, EarnedMilestones earned) =>
      _write(_milestonesKey(userId), earned.toJson);

  /// The Home carousels' games. Not tied to an account: the catalog is the same
  /// for everyone, including a signed-out visitor.
  Future<Cached<List<Game>>?> readPopular() =>
      _readList(_popularKey, Game.fromJson);

  Future<void> writePopular(List<Game> games) =>
      _write(_popularKey, () => [for (final g in games) g.toJson()]);

  /// Drops [gameId] and its play sessions from [userId]'s saved library. Used
  /// after a delete the server accepted: deletes are not announced by Realtime, so
  /// without this the saved copy would bring the game back the next time the
  /// library is opened offline.
  Future<void> removeGame(String userId, String gameId) async {
    final library = await readLibrary(userId);
    if (library != null) {
      await writeLibrary(userId, [
        for (final g in library.value)
          if (g.id != gameId) g,
      ]);
    }
    final logs = await readLogs(userId);
    if (logs != null) {
      await writeLogs(userId, [
        for (final l in logs.value)
          if (l.gameId != gameId) l,
      ]);
    }
  }

  /// Deletes everything saved for [userId]. Call it when that account signs out.
  Future<void> clearAccount(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        _libraryKey(userId),
        _logsKey(userId),
        _profileKey(userId),
        _socialKey(userId),
        _milestonesKey(userId),
      ]) {
        await prefs.remove(key);
      }
    } catch (e, st) {
      debugPrint('Clearing the cache failed: $e\n$st');
    }
  }

  /// Deletes everything this device holds for [userId], for an account that no
  /// longer exists: the saved copy ([clearAccount]) and also what a sign-out
  /// leaves behind on purpose (follows and library edits still waiting for the
  /// server).
  ///
  /// Every per-account key on the device ends in `.<user id>` (ids are UUIDs, so
  /// the suffix can't match another account), which keeps this working for keys
  /// that other classes own.
  Future<void> eraseAccount(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (key.endsWith('.$userId')) await prefs.remove(key);
      }
    } catch (e, st) {
      debugPrint('Erasing the account from the device failed: $e\n$st');
    }
  }

  static Map<String, dynamic> _asMap(Object? data) =>
      Map<String, dynamic>.from(data as Map);

  Future<Cached<List<T>>?> _readList<T>(
    String key,
    T Function(Map<String, dynamic>) decode, {
    String? timedAs,
  }) => _read(
    key,
    (data) => [for (final item in data as List) decode(_asMap(item))],
    timedAs: timedAs,
  );

  /// With [timedAs], a slow read is logged under that name (see [slowAfter]).
  Future<Cached<T>?> _read<T>(
    String key,
    T Function(Object? data) decode, {
    String? timedAs,
  }) async {
    try {
      final watch = Stopwatch()..start();
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final storage = watch.elapsed;
      try {
        final envelope = _asMap(jsonDecode(raw));
        if (envelope['v'] != _version) throw const FormatException('version');
        final cached = Cached(
          decode(envelope['data']),
          DateTime.parse(envelope['savedAt'] as String).toLocal(),
        );
        _logIfSlow(timedAs, 'read', watch.elapsed, storage, raw.length);
        return cached;
      } catch (e) {
        // Unreadable (cut short, older shape): worse than nothing, so delete it.
        debugPrint('Dropping unreadable cache entry $key: $e');
        await prefs.remove(key);
        return null;
      }
    } catch (e, st) {
      debugPrint('Reading the cache failed ($key): $e\n$st');
      return null;
    }
  }

  /// [build] makes the JSON-ready value, inside the timed and guarded part. With
  /// [timedAs], a slow write is logged under that name (see [slowAfter]).
  Future<void> _write(
    String key,
    Object Function() build, {
    String? timedAs,
  }) async {
    try {
      final watch = Stopwatch()..start();
      final raw = jsonEncode({
        'v': _version,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'data': build(),
      });
      final encoding = watch.elapsed;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, raw);
      final total = watch.elapsed;
      _logIfSlow(timedAs, 'write', total, total - encoding, raw.length);
    } catch (e, st) {
      debugPrint('Writing the cache failed ($key): $e\n$st');
    }
  }

  /// [storage] is the time spent in `shared_preferences`; the rest of [total] was
  /// turning the entry into or from JSON and [Game]s. [chars] is the entry's
  /// length as stored, close enough to bytes (the JSON is almost all ASCII).
  void _logIfSlow(
    String? name,
    String what,
    Duration total,
    Duration storage,
    int chars,
  ) {
    if (name == null || total < slowAfter) return;
    debugPrint(
      'LocalCache: $what of $name took ${total.inMilliseconds} ms '
      '(storage ${storage.inMilliseconds} ms, JSON ${(total - storage).inMilliseconds} ms) '
      'for ${(chars / 1024).round()} KB',
    );
  }
}
