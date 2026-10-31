import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/release_alerts.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';

/// Wishlist release alerts: the wishlist games coming out soon or just out
/// ([alerts], on Home), and the ones that came out since the member was last
/// told ([announce], said once by the app shell). Which releases were announced
/// is kept on the device per account, so a release is announced once.
class ReleaseAlertsStore extends ChangeNotifier {
  ReleaseAlertsStore({required this._auth, required this._library, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AuthStore _auth;
  final LibraryStore _library;
  final DateTime Function() _clock;

  String? _userId;
  Set<String>? _announced;
  int _loadSeq = 0;

  static String _key(String userId) => 'release_alerts.v1.$userId';

  /// Wishlist games out within 60 days or out in the last 14, just out first.
  List<ReleaseAlert> get alerts => releaseAlerts(_library.listedGames, today: _clock());

  Future<void> initialize() async {
    _auth.addListener(_onAuth);
    _library.addListener(notifyListeners);
    await _load(_auth.user?.id);
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuth);
    _library.removeListener(notifyListeners);
    super.dispose();
  }

  void _onAuth() {
    final id = _auth.user?.id;
    if (id != _userId) unawaited(_load(id));
  }

  Future<void> _load(String? userId) async {
    final seq = ++_loadSeq;
    _userId = userId;
    _announced = null;
    if (userId == null) return;
    Set<String> announced = {};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(userId));
      if (raw != null) announced = {for (final id in jsonDecode(raw) as List) '$id'};
    } catch (e) {
      debugPrint('Reading release alerts failed: $e');
    }
    if (seq != _loadSeq) return;
    _announced = announced;
    notifyListeners();
  }

  /// The wishlist games that are out (in the last 14 days) and were not
  /// announced yet, marked announced now. Empty until the account's record has
  /// been read.
  List<ReleaseAlert> announce() {
    final userId = _userId;
    final announced = _announced;
    if (userId == null || announced == null) return const [];
    final fresh = [
      for (final a in alerts)
        if (a.daysAway <= 0 && !announced.contains(_id(a))) a,
    ];
    if (fresh.isEmpty) return const [];
    announced.addAll(fresh.map(_id));
    // A release that left the window can't come up again: forget it.
    final current = {for (final a in alerts) _id(a)};
    announced.retainWhere(current.contains);
    unawaited(_save(userId, announced));
    return fresh;
  }

  /// A release is the game on that day: a moved date is a new release.
  static String _id(ReleaseAlert a) =>
      '${a.game.id}@${a.game.releaseDate!.toIso8601String().substring(0, 10)}';

  static Future<void> _save(String userId, Set<String> announced) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(userId), jsonEncode(announced.toList()));
    } catch (e) {
      debugPrint('Saving release alerts failed: $e');
    }
  }
}
