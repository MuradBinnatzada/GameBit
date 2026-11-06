import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Where a tap on a notification the app showed itself arrives: the release day
/// reminders and the push notifications that came while the app was open. The
/// notifications plugin has one callback, and whichever service starts it last would
/// take it from the other, so both hand it [dispatch] and register what they do with
/// a payload here. Each takes the payloads it knows and ignores the rest.
class NotificationTaps {
  NotificationTaps._();

  static final Map<Object, void Function(String payload)> _handlers = {};

  /// Does [handler] with the payload of every tap, in place of what [owner] gave before.
  static void listen(Object owner, void Function(String payload) handler) => _handlers[owner] = handler;

  /// The callback to give the plugin (`onDidReceiveNotificationResponse`).
  static void dispatch(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;
    for (final handler in List.of(_handlers.values)) {
      handler(payload);
    }
  }

  /// Forgets every handler (for tests).
  static void clear() => _handlers.clear();
}
