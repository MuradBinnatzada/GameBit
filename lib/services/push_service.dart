import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:checkpoint/app/app_config.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/push.dart';
import 'package:checkpoint/models/share_link.dart';
import 'package:checkpoint/services/notification_taps.dart';

/// Whether the system lets the app show push notifications.
enum PushPermission { granted, denied }

/// This phone's side of push notifications (Firebase Cloud Messaging): the system's
/// permission, the phone's token, and what a tapped notification opens. The server
/// sends them (`supabase/functions/send-notifications`); nothing here is shown by the
/// app itself, the system shows them.
abstract class PushService {
  /// Whether this build and device can receive push notifications: the Android and
  /// iOS apps, built with a Firebase project (see `AppConfig.firebaseProjectId`).
  bool get isSupported;

  /// Starts it. [onOpen] is told what a tapped notification points at, including
  /// the one that opened the app.
  Future<void> initialize({required void Function(LinkTarget target) onOpen});

  /// Asks the system for the right to show notifications, if it isn't given.
  Future<PushPermission> requestPermission();

  /// Whether the system lets the app show them now, without asking.
  Future<bool> isPermitted();

  /// The phone's token, or null when there is none now (offline, no Google
  /// services).
  Future<String?> token();

  /// The tokens that replace the phone's one: Firebase renews it now and then.
  Stream<String> get tokenRefreshed;

  /// Throws the phone's token away, so a notification sent to it goes nowhere.
  Future<void> deleteToken();

  /// Opens the system's notification settings of the app, where a refused
  /// permission is given.
  Future<void> openSystemSettings();
}

/// [PushService] on `firebase_messaging`. The Firebase project comes from
/// `AppConfig` (no `google-services.json` is needed in the build).
class FirebasePushService implements PushService {
  FirebasePushService({FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;
  bool _broken = false;

  /// The channels of Android, by the id the server names in a message.
  static const _priceChannel = 'price_drops';
  static const _replyChannel = 'thread_replies';

  /// The options of Firebase for [platform], or null when the build has none.
  @visibleForTesting
  static FirebaseOptions? optionsFor(
    TargetPlatform platform, {
    String projectId = AppConfig.firebaseProjectId,
    String apiKey = AppConfig.firebaseApiKey,
    String senderId = AppConfig.firebaseSenderId,
    String androidAppId = AppConfig.firebaseAndroidAppId,
    String iosAppId = AppConfig.firebaseIosAppId,
  }) {
    if (projectId.isEmpty || apiKey.isEmpty || senderId.isEmpty) return null;
    return switch (platform) {
      TargetPlatform.android when androidAppId.isNotEmpty => FirebaseOptions(
        apiKey: apiKey,
        appId: androidAppId,
        messagingSenderId: senderId,
        projectId: projectId,
      ),
      TargetPlatform.iOS when iosAppId.isNotEmpty => FirebaseOptions(
        apiKey: apiKey,
        appId: iosAppId,
        messagingSenderId: senderId,
        projectId: projectId,
        iosBundleId: 'com.gamebit.mobileapp',
      ),
      _ => null,
    };
  }

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  @override
  bool get isSupported => !kIsWeb && !_broken && optionsFor(defaultTargetPlatform) != null;

  @override
  Future<void> initialize({required void Function(LinkTarget target) onOpen}) async {
    if (!isSupported || _ready) return;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: optionsFor(defaultTargetPlatform));
      await _createChannels();
      void open(RemoteMessage message) {
        final target = pushTarget(message.data);
        if (target != null) onOpen(target);
      }

      FirebaseMessaging.onMessageOpenedApp.listen(open);
      // While the app is open the system shows nothing by itself on Android: the app
      // does, and a tap on that arrives through [NotificationTaps]. iPhones show it
      // themselves once told to.
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: NotificationTaps.dispatch,
      );
      NotificationTaps.listen(this, (payload) {
        final target = pushTargetOfPayload(payload);
        if (target != null) onOpen(target);
      });
      FirebaseMessaging.onMessage.listen((message) => unawaited(_showWhileOpen(message)));
      await _messaging.setForegroundNotificationPresentationOptions(alert: true, sound: true);
      final first = await _messaging.getInitialMessage();
      if (first != null) open(first);
      _ready = true;
    } catch (e) {
      // A Firebase project that is not what the build says it is: no push, and the
      // app carries on.
      debugPrint('Starting push notifications failed: $e');
      _broken = true;
    }
  }

  /// Shows a push notification that arrived while the app is open (Android; on an
  /// iPhone the system does it). It is the same notification the system would have
  /// shown in the background, in the same channel.
  Future<void> _showWhileOpen(RemoteMessage message) async {
    final notification = message.notification;
    if (defaultTargetPlatform != TargetPlatform.android || notification == null) return;
    final l10n = L10n.current;
    final replies = message.data['kind'] == 'thread_reply';
    try {
      await _plugin.show(
        id: message.hashCode & 0x7fffffff,
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            replies ? _replyChannel : _priceChannel,
            replies ? l10n.pushChannelReplies : l10n.pushChannelPriceDrops,
            channelDescription: replies ? l10n.pushChannelRepliesDescription : l10n.pushChannelPriceDropsDescription,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: pushPayload(message.data),
      );
    } catch (e) {
      debugPrint('Showing a push notification failed: $e');
    }
  }

  /// The Android channels the server's messages name, written in the app's language
  /// (the system lists them in the app's notification settings).
  Future<void> _createChannels() async {
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    final l10n = L10n.current;
    await android.createNotificationChannel(
      AndroidNotificationChannel(
        _priceChannel,
        l10n.pushChannelPriceDrops,
        description: l10n.pushChannelPriceDropsDescription,
        importance: Importance.high,
      ),
    );
    await android.createNotificationChannel(
      AndroidNotificationChannel(
        _replyChannel,
        l10n.pushChannelReplies,
        description: l10n.pushChannelRepliesDescription,
        importance: Importance.high,
      ),
    );
  }

  @override
  Future<PushPermission> requestPermission() async {
    if (!_ready) return PushPermission.denied;
    try {
      final settings = await _messaging.requestPermission(alert: true, sound: true, badge: false);
      return _granted(settings.authorizationStatus) ? PushPermission.granted : PushPermission.denied;
    } catch (e) {
      debugPrint('Asking for the notification permission failed: $e');
      return PushPermission.denied;
    }
  }

  @override
  Future<bool> isPermitted() async {
    if (!_ready) return false;
    try {
      return _granted((await _messaging.getNotificationSettings()).authorizationStatus);
    } catch (_) {
      return false;
    }
  }

  static bool _granted(AuthorizationStatus status) =>
      status == AuthorizationStatus.authorized || status == AuthorizationStatus.provisional;

  @override
  Future<String?> token() async {
    if (!_ready) return null;
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // The token of Apple's push service comes first, a moment after the permission.
        for (var i = 0; i < 10 && await _messaging.getAPNSToken() == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      // The classic FCM token, which the server's FCM v1 `token` field takes. The newer
      // register() / onRegistered give a Firebase installation id instead, which this
      // has not been checked to work as a `token`.
      // ignore: deprecated_member_use
      return await _messaging.getToken();
    } catch (e) {
      debugPrint('Getting the push token failed: $e');
      return null;
    }
  }

  @override
  // ignore: deprecated_member_use
  Stream<String> get tokenRefreshed => _ready ? _messaging.onTokenRefresh : const Stream.empty();

  @override
  Future<void> deleteToken() async {
    if (!_ready) return;
    try {
      // ignore: deprecated_member_use
      await _messaging.deleteToken();
    } catch (e) {
      debugPrint('Deleting the push token failed: $e');
    }
  }

  @override
  Future<void> openSystemSettings() async {
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.openAppNotificationSettings();
    await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.openAppNotificationSettings();
  }
}
