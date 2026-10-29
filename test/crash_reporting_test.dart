import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/services/crash_reporting.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await CrashReporting.setEnabled(true);
  });

  group('canTestCrash', () {
    test('only a staging build that reports to Sentry has it', () {
      expect(CrashReporting.canTestCrash('https://k@o1.ingest.sentry.io/1', 'staging'), isTrue);
      expect(CrashReporting.canTestCrash('https://k@o1.ingest.sentry.io/1', 'production'), isFalse);
      expect(CrashReporting.canTestCrash('', 'staging'), isFalse);
    });
  });

  group('redact', () {
    test('leaves out email addresses, tokens and ids', () {
      const token =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      final text = CrashReporting.redact(
        'Failed for ada@example.com (user 0f8fad5b-d9cb-469f-a165-70867728950e) with $token',
      );

      expect(text, 'Failed for [email] (user [id]) with [token]');
    });

    test('leaves ordinary text alone', () {
      expect(CrashReporting.redact('Null check operator used on a null value'), 'Null check operator used on a null value');
    });
  });

  group('scrub', () {
    SentryEvent event() => SentryEvent(
      message: SentryMessage('Saved ada@example.com', params: ['ada@example.com']),
      exceptions: [SentryException(type: 'PostgrestException', value: 'row for 0f8fad5b-d9cb-469f-a165-70867728950e refused')],
      user: SentryUser(id: 'u1', email: 'ada@example.com'),
      request: SentryRequest(url: 'https://x.supabase.co/rest/v1/profiles?id=eq.1'),
      breadcrumbs: [Breadcrumb(message: 'tapped Library')],
      serverName: 'ada-laptop',
    );

    test('takes out who the member is, what they did and where they were', () {
      final scrubbed = CrashReporting.scrub(event())!;

      expect(scrubbed.user, isNull);
      expect(scrubbed.request, isNull);
      expect(scrubbed.breadcrumbs, isNull);
      expect(scrubbed.serverName, isNull);
    });

    test('redacts the words of the error', () {
      final scrubbed = CrashReporting.scrub(event())!;

      expect(scrubbed.message!.formatted, 'Saved [email]');
      expect(scrubbed.message!.params, isNull);
      expect(scrubbed.exceptions!.single.value, 'row for [id] refused');
    });

    test('drops a failed connection: that is not a bug of the app', () {
      expect(
        CrashReporting.scrub(SentryEvent(throwable: const SocketException('no route'))),
        isNull,
      );
      expect(CrashReporting.scrub(SentryEvent(throwable: TimeoutException('slow'))), isNull);
    });

    test('keeps a real error', () {
      expect(CrashReporting.scrub(SentryEvent(throwable: StateError('broken'))), isNotNull);
      expect(CrashReporting.scrub(SentryEvent(throwable: const FormatException('bad'))), isNotNull);
    });
  });

  group('the choice', () {
    test('is on until the member turns it off, and is kept on this device', () async {
      await CrashReporting.load();
      expect(CrashReporting.enabled, isTrue);

      await CrashReporting.setEnabled(false);
      expect(CrashReporting.enabled, isFalse);
      expect((await SharedPreferences.getInstance()).getBool('crash_reports_enabled'), isFalse);

      await CrashReporting.setEnabled(true);
      await CrashReporting.load();
      expect(CrashReporting.enabled, isTrue);
    });

    test('is read from the device', () async {
      SharedPreferences.setMockInitialValues({'crash_reports_enabled': false});

      await CrashReporting.load();

      expect(CrashReporting.enabled, isFalse);
    });

    test('a report is dropped while it is off', () async {
      await CrashReporting.setEnabled(false);

      expect(await CrashReporting.beforeSend(SentryEvent(throwable: StateError('x')), Hint()), isNull);

      await CrashReporting.setEnabled(true);
      expect(await CrashReporting.beforeSend(SentryEvent(throwable: StateError('x')), Hint()), isNotNull);
    });
  });

  test('a build without a DSN just runs the app, and reports nothing', () async {
    expect(CrashReporting.configured, isFalse);
    var ran = false;

    await CrashReporting.run(() => ran = true);

    expect(ran, isTrue);
  });
}
