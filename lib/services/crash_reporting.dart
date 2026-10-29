import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/app/app_config.dart';

/// Crash reports (Sentry), so a failure in production is seen by the developer
/// and not first in a store review.
///
/// What is sent is kept small and is listed in the privacy policy
/// (docs/privacy.html): the error and where in the code it happened, the app
/// version and the device's OS and model. Not who the member is (no account id,
/// no email, no IP address), not what they typed, not the screens they visited,
/// not the requests the app made, no screenshots. [scrub] is the last pass over
/// every event before it leaves the device.
///
/// Nothing is sent when the build has no `SENTRY_DSN` ([AppConfig.sentryDsn]),
/// which includes every test and debug run, or when the member turned
/// Settings > Privacy > Send crash reports off on this device ([enabled]).
abstract final class CrashReporting {
  static const _enabledKey = 'crash_reports_enabled';

  static final ValueNotifier<bool> _enabled = ValueNotifier(true);

  /// Whether a crash is reported: the device's choice, on until it is turned off.
  static ValueListenable<bool> get enabledListenable => _enabled;
  static bool get enabled => _enabled.value;

  /// Whether this build has anywhere to send reports to, i.e. whether the
  /// Settings switch has anything to switch.
  static bool get configured => AppConfig.sentryDsn.isNotEmpty;

  /// Reads the device's choice. Never throws: a choice that can't be read is
  /// the default, on.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled.value = prefs.getBool(_enabledKey) ?? true;
    } catch (e) {
      debugPrint('Reading the crash report choice failed: $e');
    }
  }

  static Future<void> setEnabled(bool value) async {
    if (value == _enabled.value) return;
    _enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, value);
    } catch (e) {
      debugPrint('Saving the crash report choice failed: $e');
    }
  }

  /// Runs [appRunner] with crash reporting on when the build is set up for it,
  /// and plainly otherwise. The Flutter and platform error hooks are Sentry's.
  static Future<void> run(FutureOr<void> Function() appRunner) async {
    if (!configured) {
      await appRunner();
      return;
    }
    await load();
    await SentryFlutter.init((options) {
      options
        ..dsn = AppConfig.sentryDsn
        ..environment = AppConfig.environment
        ..sendDefaultPii = false
        // Errors only: no performance traces, no sessions, no screenshots.
        ..tracesSampleRate = null
        ..enableAutoSessionTracking = false
        ..attachScreenshot = false
        ..attachViewHierarchy = false
        // The trail before a crash would name the screens, the taps and the
        // requests (whose addresses carry member ids and search terms).
        ..maxBreadcrumbs = 0
        ..enableUserInteractionBreadcrumbs = false
        ..enableAutoNativeBreadcrumbs = false
        ..recordHttpBreadcrumbs = false
        ..captureFailedRequests = false
        ..beforeSend = beforeSend;
    }, appRunner: appRunner);
  }

  /// Every event goes through here before it leaves the device.
  @visibleForTesting
  static FutureOr<SentryEvent?> beforeSend(SentryEvent event, Hint hint) {
    if (!enabled) return null;
    return scrub(event);
  }

  /// [event] without what must not leave the device, or null when it is not
  /// worth reporting: a failed connection is not a bug of the app.
  @visibleForTesting
  static SentryEvent? scrub(SentryEvent event) {
    final throwable = event.throwable;
    if (_isNoConnection(throwable)) return null;

    final message = event.message;
    if (message != null) {
      message.formatted = redact(message.formatted);
      final template = message.template;
      if (template != null) message.template = redact(template);
      message.params = null;
    }
    for (final exception in event.exceptions ?? const <SentryException>[]) {
      final value = exception.value;
      if (value != null) exception.value = redact(value);
    }
    event
      ..user = null
      ..request = null
      ..breadcrumbs = null
      ..serverName = null;
    return event;
  }

  /// The kinds of failure that mean "no network" on any platform (dart:io is
  /// not there on the web, so they are told by name).
  static const _connectionFailures = {
    'SocketException',
    'HandshakeException',
    'TlsException',
    'ClientException',
    'TimeoutException',
    'WebSocketChannelException',
    'AuthRetryableFetchException',
  };

  static bool _isNoConnection(Object? error) =>
      error != null && _connectionFailures.contains(error.runtimeType.toString());

  static final _email = RegExp(r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+');
  // A JWT (the session and the anon key), as three dot-separated base64url parts.
  static final _token = RegExp(r'eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]*');
  static final _uuid = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
    caseSensitive: false,
  );

  /// [text] without email addresses, tokens and ids. An exception message from
  /// the server can quote the row it refused.
  @visibleForTesting
  static String redact(String text) => text
      .replaceAll(_token, '[token]')
      .replaceAll(_email, '[email]')
      .replaceAll(_uuid, '[id]');
}
