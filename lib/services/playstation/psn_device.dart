import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/services/playstation/psn_client.dart';

/// What this phone remembers about a member's PlayStation import, per Gamebit
/// account (so another account on the same phone starts clean):
///
///  * the sign-in: Sony's refresh token, in the phone's encrypted storage (Android
///    Keystore, iOS Keychain), so the next sync needs no password. Never sent to
///    Gamebit's servers, never in a backup. [forget] removes it.
///  * when the last sync was, for the once-a-day limit;
///  * which trophy lists were already stored and how far the member was in each
///    (so a sync only asks Sony again about the games that changed);
///  * how long each game had been played at the last sync (so a later sync can log
///    the rise as a play session, see `psn_sessions.dart`).
///
/// Everything fails soft: storage that cannot be read counts as empty, which
/// means signing in again, never a crash.
class PsnDevice {
  PsnDevice({FlutterSecureStorage? secure, DateTime Function()? now})
    : _secure = secure ?? _defaultSecure,
      _now = now ?? DateTime.now;

  static const _defaultSecure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  final FlutterSecureStorage _secure;
  final DateTime Function() _now;

  static String _signInKey(String userId) => 'psn_sign_in_$userId';
  static String _syncKey(String userId) => 'psn_last_sync_$userId';
  static String _listsKey(String userId) => 'psn_trophy_lists_$userId';
  static String _playtimeKey(String userId) => 'psn_playtime_$userId';

  /// The refresh token of the sign-in this phone kept for [userId], or null when
  /// there is none or Sony has let it lapse.
  Future<String?> savedSignIn(String userId) async {
    try {
      final raw = await _secure.read(key: _signInKey(userId));
      if (raw == null) return null;
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final token = json['token'];
      final until = json['until'] is String ? DateTime.tryParse(json['until'] as String) : null;
      if (token is! String || token.isEmpty) return null;
      if (until != null && until.isBefore(_now())) return null;
      return token;
    } catch (e) {
      debugPrint('Reading the saved PlayStation sign-in failed: ${e.runtimeType}');
      return null;
    }
  }

  /// Keeps the sign-in [tokens] ended with. Nothing is kept when Sony gave no
  /// refresh token.
  Future<void> saveSignIn(String userId, PsnTokens tokens) async {
    final token = tokens.refreshToken;
    if (token == null) return;
    try {
      await _secure.write(
        key: _signInKey(userId),
        value: jsonEncode({'token': token, 'until': tokens.refreshExpiresAt?.toUtc().toIso8601String()}),
      );
    } catch (e) {
      debugPrint('Saving the PlayStation sign-in failed: ${e.runtimeType}');
    }
  }

  /// Forgets the saved sign-in (the member signs in on Sony's page next time) and
  /// which trophy lists were stored, so the next sync reads them all again. The
  /// time of the last sync stays: signing out is no way round the daily limit.
  Future<void> forget(String userId) async {
    try {
      await _secure.delete(key: _signInKey(userId));
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_listsKey(userId));
    } catch (e) {
      debugPrint('Forgetting the PlayStation sign-in failed: ${e.runtimeType}');
    }
  }

  /// Removes everything kept for [userId]: the sign-in, the lists, the play times
  /// and the time of the last sync. For when the account itself goes.
  Future<void> forgetAll(String userId) async {
    await forget(userId);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_syncKey(userId));
      await prefs.remove(_playtimeKey(userId));
    } catch (e) {
      debugPrint('Forgetting the PlayStation sync time failed: ${e.runtimeType}');
    }
  }

  /// When [userId] last synced, or null.
  Future<DateTime?> lastSync(String userId) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_syncKey(userId));
      return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
    } catch (_) {
      return null;
    }
  }

  Future<void> markSynced(String userId) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_syncKey(userId), _now().toUtc().toIso8601String());
    } catch (e) {
      debugPrint('Saving the PlayStation sync time failed: ${e.runtimeType}');
    }
  }

  /// How long [userId] has to wait before the next sync given [limit] between
  /// them; null when they may sync now.
  Future<Duration?> waitFor(String userId, Duration limit) async {
    if (limit <= Duration.zero) return null;
    final last = await lastSync(userId);
    if (last == null) return null;
    final left = last.add(limit).difference(_now());
    return left > Duration.zero ? left : null;
  }

  /// The trophy lists already stored for [userId]: Sony's id of each set and the
  /// progress it was stored at (see [listMark]).
  Future<Map<String, String>> storedLists(String userId) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_listsKey(userId));
      final json = raw == null ? null : jsonDecode(raw);
      return json is Map ? {for (final e in json.entries) if (e.value is String) '${e.key}': e.value as String} : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _writes = Future.value();

  /// Notes that the list of [setId] was stored when the member had [mark]. One
  /// write at a time: an import notes a game after game without waiting.
  Future<void> rememberList(String userId, String setId, String mark) =>
      _writes = _writes.then((_) => _rememberList(userId, setId, mark));

  Future<void> _rememberList(String userId, String setId, String mark) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lists = await storedLists(userId);
      lists[setId] = mark;
      await prefs.setString(_listsKey(userId), jsonEncode(lists));
    } catch (e) {
      debugPrint('Saving the stored trophy lists failed: ${e.runtimeType}');
    }
  }

  /// How long each game had been played, in minutes, when [userId] last synced it:
  /// by [psnTitleKey] of the game's name. A game missing here was not seen yet, so
  /// its play time is history, not a session.
  Future<Map<String, int>> storedPlaytime(String userId) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_playtimeKey(userId));
      final json = raw == null ? null : jsonDecode(raw);
      return json is Map ? {for (final e in json.entries) if (e.value is int) '${e.key}': e.value as int} : {};
    } catch (_) {
      return {};
    }
  }

  /// Notes that [key] had [minutes] of play time at this sync. Same queue as
  /// [rememberList]. Kept when the sign-in is forgotten: the sessions it measures
  /// against are real, and logging a rise twice is worse than not logging one.
  Future<void> rememberPlaytime(String userId, String key, int minutes) =>
      _writes = _writes.then((_) => _rememberPlaytime(userId, key, minutes));

  Future<void> _rememberPlaytime(String userId, String key, int minutes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final times = await storedPlaytime(userId);
      times[key] = minutes;
      await prefs.setString(_playtimeKey(userId), jsonEncode(times));
    } catch (e) {
      debugPrint('Saving the PlayStation play times failed: ${e.runtimeType}');
    }
  }

  /// What a stored list stands for: how many trophies were earned out of how many,
  /// so a changed count means the list is out of date.
  static String listMark(int earned, int total) => '$earned/$total';
}
