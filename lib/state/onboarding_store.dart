import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';

/// Whether to offer the first-run walk-through (OnboardingScreen) to the
/// signed-in member: once, to an account whose library the server answered empty,
/// and never again after it was finished or skipped. That is kept on the device
/// per account, so a new phone for an account with games doesn't ask, and the
/// app shell is told by [takeOffer] and calls [finish] when the screen closes.
class OnboardingStore extends ChangeNotifier {
  OnboardingStore({required this._auth, required this._library});

  final AuthStore _auth;
  final LibraryStore _library;

  String? _userId;

  /// Whether the walk-through was finished or skipped; null until the account's
  /// record has been read.
  bool? _done;

  /// It was offered since the app started (or this account signed in).
  bool _offered = false;
  int _loadSeq = 0;

  /// The key the record of [userId] is saved under in the device's preferences.
  @visibleForTesting
  static String prefsKey(String userId) => 'onboarding.v1.$userId';

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
    _done = null;
    _offered = false;
    if (userId == null) return;
    var done = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      done = prefs.getBool(prefsKey(userId)) ?? false;
    } catch (e) {
      debugPrint('Reading the onboarding record failed: $e');
      // Asking again at every launch is worse than not asking a new member.
      done = true;
    }
    if (seq != _loadSeq) return;
    _done = done;
    notifyListeners();
  }

  /// Whether the walk-through is due: the account's record says it wasn't done,
  /// and the library the server sent is empty. [takeOffer] is how to act on it.
  bool get isDue =>
      _userId != null && _done == false && !_offered && _library.isSettled && _library.libraryGames.isEmpty;

  /// The account to walk through, once: null when nothing is due, or it was
  /// offered already. The caller shows the walk-through, then calls [finish] with
  /// the account it got.
  String? takeOffer() {
    if (!isDue) return null;
    _offered = true;
    return _userId;
  }

  /// Records that [userId] has seen the walk-through, finished or skipped.
  Future<void> finish(String userId) async {
    if (userId == _userId) {
      _done = true;
      notifyListeners();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey(userId), true);
    } catch (e) {
      debugPrint('Saving the onboarding record failed: $e');
    }
  }
}
