import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/push.dart';
import 'package:checkpoint/models/share_link.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/services/push_service.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/utils/region.dart';

/// How turning push notifications on or off went.
enum PushResult {
  on,
  off,

  /// The system's permission to show notifications was refused.
  denied,

  /// This build or device can't receive push notifications, or nobody is signed in.
  unsupported,

  /// The phone's token or the server could not be reached.
  failed,
}

/// Push notifications (price drops of the wishlist, replies to the member's threads):
/// whether this phone gets them, and which kinds. Turning them on asks the system for
/// its permission, takes the phone's token and registers it with the server for the
/// signed-in member; turning them off (or signing out) takes it back, so a phone never
/// gets a member's notifications once they are gone from it. Whether this phone is
/// registered is kept on the device per account; which kinds the member wants is on
/// the server (`notification_settings`) and follows the member to any phone.
class PushStore extends ChangeNotifier {
  PushStore({
    required this._repository,
    required this._auth,
    required this._service,
    required this._onOpen,
    String Function()? language,
    String Function()? country,
    this._platform,
  }) : _language = language ?? (() => L10n.languageCode),
       _country = country ?? deviceCountry;

  final CheckpointRepository _repository;
  final AuthStore _auth;
  final PushService _service;
  final void Function(LinkTarget target) _onOpen;
  final String Function() _language;
  final String Function() _country;
  final String? _platform;

  String? _userId;
  bool _enabled = false;
  bool _busy = false;
  NotificationSettings _settings = const NotificationSettings();
  String? _token;
  StreamSubscription<String>? _refreshes;
  int _loadSeq = 0;

  static String _key(String userId) => 'push.v1.$userId';

  /// Whether this build and device can receive push notifications.
  bool get isSupported => _service.isSupported;

  bool get isSignedIn => _userId != null;

  /// This phone gets the signed-in member's notifications.
  bool get isEnabled => _enabled;

  /// Turning them on or off is under way.
  bool get isBusy => _busy;

  /// The kinds the member wants (meaningful while [isEnabled]).
  NotificationSettings get settings => _settings;

  String get _platformName => _platform ?? (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');

  Future<void> initialize() async {
    _auth.addListener(_onAuth);
    await _load(_auth.user?.id);
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuth);
    unawaited(_refreshes?.cancel());
    super.dispose();
  }

  void _onAuth() {
    final id = _auth.user?.id;
    if (id != _userId) unawaited(_load(id));
  }

  Future<void> _load(String? userId) async {
    final seq = ++_loadSeq;
    await _refreshes?.cancel();
    _refreshes = null;
    _userId = userId;
    _enabled = false;
    _token = null;
    _settings = const NotificationSettings();
    notifyListeners();
    if (userId == null || !_service.isSupported) return;

    var wasOn = false;
    try {
      wasOn = (await SharedPreferences.getInstance()).getBool(_key(userId)) ?? false;
    } catch (e) {
      debugPrint('Reading the push setting failed: $e');
    }
    if (!wasOn || seq != _loadSeq) return;

    await _service.initialize(onOpen: _onOpen);
    if (seq != _loadSeq) return;
    if (!await _service.isPermitted()) {
      // The member took the permission back in the system's settings.
      await _save(userId, false);
      return;
    }
    _enabled = true;
    notifyListeners();
    // A token that was renewed since, or a language or region that changed, reaches the server.
    await _register();
    await _readSettings(seq);
    if (seq != _loadSeq) return;
    _refreshes = _service.tokenRefreshed.listen((token) => unawaited(_registerToken(token)));
    notifyListeners();
  }

  /// Turns push on for this phone and the signed-in member (asking the system for its
  /// permission first), or off.
  Future<PushResult> setEnabled(bool on) async {
    final userId = _userId;
    if (_busy || userId == null || !_service.isSupported) return PushResult.unsupported;
    _busy = true;
    notifyListeners();
    final seq = _loadSeq;
    try {
      if (on) {
        await _service.initialize(onOpen: _onOpen);
        if (await _service.requestPermission() != PushPermission.granted) return PushResult.denied;
        final token = await _service.token();
        if (token == null) return PushResult.failed;
        await _registerToken(token, throwing: true);
        _enabled = true;
        await _save(userId, true);
        await _readSettings(seq);
        await _refreshes?.cancel();
        _refreshes = _service.tokenRefreshed.listen((t) => unawaited(_registerToken(t)));
        return PushResult.on;
      }
      await _unregister();
      _enabled = false;
      await _save(userId, false);
      await _refreshes?.cancel();
      _refreshes = null;
      return PushResult.off;
    } catch (e) {
      debugPrint('Changing push notifications failed: $e');
      return PushResult.failed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Wants (or not) to hear about wishlist games going on sale. False when the server
  /// refused and the switch went back.
  Future<bool> setPriceDrops(bool on) => _change(_settings.copyWith(priceDrops: on));

  /// Wants (or not) to hear of replies to the member's threads.
  Future<bool> setThreadReplies(bool on) => _change(_settings.copyWith(threadReplies: on));

  Future<bool> _change(NotificationSettings next) async {
    if (_userId == null) return false;
    final before = _settings;
    _settings = next;
    notifyListeners();
    try {
      await _repository.saveNotificationSettings(next);
      return true;
    } catch (e) {
      debugPrint('Saving the notification settings failed: $e');
      _settings = before;
      notifyListeners();
      return false;
    }
  }

  Future<void> openSystemSettings() => _service.openSystemSettings();

  /// Lets this phone go before [userId] signs out, while the session still works: the
  /// server stops sending their notifications here. What it could not do is made up
  /// for by the server, which moves a token to whoever registers it next.
  Future<void> unregisterForLogOut(String userId) async {
    if (!_service.isSupported || _userId != userId || !_enabled) return;
    await _unregister();
    await _service.deleteToken();
  }

  Future<void> _register() async {
    final token = await _service.token();
    if (token != null) await _registerToken(token);
  }

  Future<void> _registerToken(String token, {bool throwing = false}) async {
    _token = token;
    try {
      await _repository.registerPushDevice(
        token: token,
        platform: _platformName,
        language: _language(),
        country: _country(),
      );
    } catch (e) {
      debugPrint('Registering the push token failed: $e');
      if (throwing) rethrow;
    }
  }

  Future<void> _unregister() async {
    final token = _token ?? await _service.token();
    if (token != null) {
      try {
        await _repository.unregisterPushDevice(token);
      } catch (e) {
        debugPrint('Unregistering the push token failed: $e');
      }
    }
    await _service.deleteToken();
    _token = null;
  }

  Future<void> _readSettings(int seq) async {
    try {
      final settings = await _repository.fetchNotificationSettings();
      if (seq == _loadSeq) _settings = settings;
    } catch (e) {
      debugPrint('Reading the notification settings failed: $e');
    }
  }

  static Future<void> _save(String userId, bool on) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key(userId), on);
    } catch (e) {
      debugPrint('Saving the push setting failed: $e');
    }
  }
}
