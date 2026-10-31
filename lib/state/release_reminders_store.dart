import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/release_reminders.dart';
import 'package:checkpoint/services/release_notifier.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';

/// How turning the reminders on or off went.
enum RemindersResult {
  on,
  off,

  /// The system's permission to show notifications was refused.
  denied,

  /// This device can't schedule notifications (the web, a computer).
  unsupported,
}

/// Release day reminders: when they are on, a notification is scheduled on the
/// device for each wishlist game with a release date to come, and kept in step
/// with the wishlist (see [releaseReminders]). Whether they are on is the
/// member's choice, kept on the device per account; the notifications are the
/// device's, so they are taken back when another account signs in or this one
/// signs out. Nothing here is sent to a server.
class ReleaseRemindersStore extends ChangeNotifier {
  ReleaseRemindersStore({
    required this._auth,
    required this._library,
    required this._notifier,
    required this._onOpenGame,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AuthStore _auth;
  final LibraryStore _library;
  final ReleaseNotifier _notifier;
  final void Function(int igdbId) _onOpenGame;
  final DateTime Function() _clock;

  String? _userId;
  bool _enabled = false;
  bool _busy = false;

  /// Reminders are scheduled on the device by this app run (or one it took over).
  bool _scheduled = false;

  /// What was scheduled last, so an unchanged wishlist schedules nothing.
  String? _signature;
  int _loadSeq = 0;

  static String _key(String userId) => 'release_reminders.v1.$userId';

  /// Whether this device can show reminders at all.
  bool get isSupported => _notifier.isSupported;

  /// Whether a member is signed in, which reminders are for.
  bool get isSignedIn => _userId != null;

  /// The signed-in member has reminders on.
  bool get isEnabled => _enabled;

  /// Turning them on or off is under way.
  bool get isBusy => _busy;

  /// How many reminders the wishlist has now: the releases still to come.
  int get count => releaseReminders(_library.libraryGames, now: _clock()).length;

  Future<void> initialize() async {
    _auth.addListener(_onAuth);
    _library.addListener(_onLibrary);
    await _load(_auth.user?.id);
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuth);
    _library.removeListener(_onLibrary);
    super.dispose();
  }

  void _onAuth() {
    final id = _auth.user?.id;
    if (id != _userId) unawaited(_load(id));
  }

  void _onLibrary() {
    if (_enabled) unawaited(_sync());
    notifyListeners();
  }

  Future<void> _load(String? userId) async {
    final seq = ++_loadSeq;
    // The reminders of the account that went are not for the one that came.
    if (_scheduled) await _withdraw();
    _userId = userId;
    _enabled = false;
    if (userId != null && _notifier.isSupported) {
      try {
        final prefs = await SharedPreferences.getInstance();
        _enabled = prefs.getBool(_key(userId)) ?? false;
      } catch (e) {
        debugPrint('Reading the reminders setting failed: $e');
      }
    }
    if (seq != _loadSeq) return;
    if (_enabled) {
      try {
        await _notifier.initialize(onOpenGame: _onOpenGame);
      } catch (e) {
        debugPrint('Starting reminders failed: $e');
      }
      await _sync();
    }
    notifyListeners();
  }

  /// Turns the reminders on, asking the system for its permission first, or off.
  Future<RemindersResult> setEnabled(bool on) async {
    final userId = _userId;
    if (_busy || userId == null || !_notifier.isSupported) return RemindersResult.unsupported;
    _busy = true;
    notifyListeners();
    try {
      if (on) {
        await _notifier.initialize(onOpenGame: _onOpenGame);
        if (!await _notifier.requestPermission()) return RemindersResult.denied;
        _enabled = true;
        await _save(userId, true);
        await _sync();
        return RemindersResult.on;
      }
      _enabled = false;
      await _save(userId, false);
      await _withdraw();
      return RemindersResult.off;
    } catch (e) {
      debugPrint('Changing reminders failed: $e');
      return on ? RemindersResult.denied : RemindersResult.off;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> openSystemSettings() => _notifier.openSystemSettings();

  /// The syncs one after the other: two changes of the wishlist in a row must
  /// not schedule at once.
  Future<void> _queue = Future.value();

  Future<void> _sync() => _queue = _queue.then((_) => _syncNow());

  /// Schedules what the wishlist calls for, unless it is what already is. Only
  /// from a library the server answered: while it loads, or from the copy saved
  /// on the device, what is scheduled stays.
  Future<void> _syncNow() async {
    if (!_enabled || !_library.isSettled) return;
    final plan = releaseReminders(_library.libraryGames, now: _clock());
    // The language is part of it: the notifications are written in it.
    final signature = '${L10n.languageCode}|${[for (final r in plan) '${r.game.id}@${r.at.toIso8601String()}'].join(',')}';
    if (signature == _signature) return;
    _signature = signature;
    try {
      await _notifier.schedule(plan);
      _scheduled = true;
    } catch (e) {
      _signature = null;
      debugPrint('Scheduling reminders failed: $e');
    }
  }

  Future<void> _withdraw() async {
    _signature = null;
    _scheduled = false;
    try {
      await _notifier.cancelAll();
    } catch (e) {
      debugPrint('Taking back reminders failed: $e');
    }
  }

  static Future<void> _save(String userId, bool on) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key(userId), on);
    } catch (e) {
      debugPrint('Saving the reminders setting failed: $e');
    }
  }
}
