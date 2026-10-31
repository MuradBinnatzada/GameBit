import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/release_reminders.dart';

/// Shows the release day reminders on the device (see [ReleaseRemindersStore]).
/// Everything stays on the device: nothing here talks to a server.
abstract class ReleaseNotifier {
  /// Whether this device can show scheduled notifications: the Android and iOS
  /// apps.
  bool get isSupported;

  /// Starts it. [onOpenGame] is told the IGDB id of the game of a reminder the
  /// member tapped, including the one that opened the app.
  Future<void> initialize({required void Function(int igdbId) onOpenGame});

  /// Asks the system for the right to show notifications, if it isn't given.
  /// Whether it is.
  Future<bool> requestPermission();

  /// Replaces every reminder not shown yet with [reminders].
  Future<void> schedule(List<ReleaseReminder> reminders);

  /// Takes back every reminder not shown yet.
  Future<void> cancelAll();

  /// Opens the system's notification settings of the app, where a refused
  /// permission is given.
  Future<void> openSystemSettings();
}

/// [ReleaseNotifier] on `flutter_local_notifications`.
class LocalReleaseNotifier implements ReleaseNotifier {
  LocalReleaseNotifier({FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  void Function(int igdbId)? _onOpenGame;
  bool _ready = false;

  static const _channelId = 'release_day';
  static const _payloadPrefix = 'game:';

  @override
  bool get isSupported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Future<void> initialize({required void Function(int igdbId) onOpenGame}) async {
    _onOpenGame = onOpenGame;
    if (!isSupported || _ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Asked for when the member turns reminders on, not when the app starts.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) => _open(response.payload),
    );
    _ready = true;
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) _open(launch?.notificationResponse?.payload);
  }

  void _open(String? payload) {
    final id = payload != null && payload.startsWith(_payloadPrefix)
        ? int.tryParse(payload.substring(_payloadPrefix.length))
        : null;
    if (id != null) _onOpenGame?.call(id);
  }

  @override
  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    final granted = switch (defaultTargetPlatform) {
      TargetPlatform.android => await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission(),
      TargetPlatform.iOS => await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true),
      _ => false,
    };
    return granted ?? false;
  }

  @override
  Future<void> schedule(List<ReleaseReminder> reminders) async {
    if (!isSupported) return;
    // Those already on the screen stay; only what is still to come is redone.
    await _plugin.cancelAllPendingNotifications();
    final l10n = L10n.current;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        l10n.releaseChannelName,
        channelDescription: l10n.releaseChannelDescription,
      ),
      iOS: const DarwinNotificationDetails(),
    );
    for (var i = 0; i < reminders.length; i++) {
      final reminder = reminders[i];
      await _plugin.zonedSchedule(
        id: i,
        // The moment, written in UTC: a one-off reminder needs no time zone
        // database, only the instant, and the device's clock gave it.
        scheduledDate: tz.TZDateTime.from(reminder.at, tz.UTC),
        notificationDetails: details,
        // Not exact: that needs a permission people are asked for in settings,
        // and a reminder a few minutes late is as good as one on the dot.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: l10n.releaseNotificationTitle(reminder.game.title),
        body: l10n.releaseNotificationBody,
        payload: '$_payloadPrefix${reminder.game.igdbId}',
      );
    }
  }

  @override
  Future<void> cancelAll() async {
    if (!isSupported || !_ready) return;
    await _plugin.cancelAllPendingNotifications();
  }

  @override
  Future<void> openSystemSettings() async {
    if (!isSupported) return;
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.openAppNotificationSettings();
    await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.openAppNotificationSettings();
  }
}
