import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException;

import 'package:checkpoint/models/admin_moderation.dart';
import 'package:checkpoint/models/game_reviews.dart' show ReportReason;
import 'package:checkpoint/models/public_profile.dart';
import 'package:checkpoint/screens/profile/public_profile_screen.dart';
import 'package:checkpoint/screens/settings/settings_screen.dart';
import 'package:checkpoint/services/admin_failure.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// Moderating from the app: what the admin function sends and how the app reads
/// it, the store behind the Admin screens, and the screens themselves (the
/// queue, suspending, reinstating, the profile menu) on a fake function.
void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late FakeAdminApi api;
  late AppStores stores;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    authService = FakeAuthService(testUser('u1'));
    api = FakeAdminApi()
      ..reportList = [
        testReport('m1', overdue: true, hoursOpen: 30),
        testReport(
          'm2',
          name: 'Spammer',
          handle: 'spam4u',
          source: ReportSource.thread,
          reason: ReportReason.spam,
          content: 'Buy cheap keys',
          hoursOpen: 0.4,
        ),
      ];
    stores = AppStores(
      repository: repo,
      authService: authService,
      connectivity: FakeConnectivity(),
      adminApi: api,
    );
  });

  group('what the function sends', () {
    test('a report is read with its member, age and reason', () {
      final report = AdminReport.fromJson({
        'source': 'reply',
        'reported_at': '2026-11-01T10:00:00Z',
        'hours_open': 26.5,
        'overdue': true,
        'reason': 'spam',
        'member': {
          'id': 'm1',
          'handle': 'rude',
          'name': 'Rude Player',
          'suspended': true,
        },
        'content': 'Buy cheap keys',
        'reference': 'post-1',
      });

      expect(report.source, ReportSource.reply);
      expect(report.reason, ReportReason.spam);
      expect(report.member.id, 'm1');
      expect(report.member.displayName, 'Rude Player');
      expect(report.member.atHandle, '@rude');
      expect(report.member.suspended, isTrue);
      expect(report.hoursOpen, 26.5);
      expect(report.overdue, isTrue);
      expect(report.reportedAt, DateTime.utc(2026, 11, 1, 10));
      expect(report.content, 'Buy cheap keys');
      expect(report.reference, 'post-1');
    });

    test('a report with nothing in it is still a report', () {
      final report = AdminReport.fromJson({});

      expect(report.source, ReportSource.other);
      expect(report.reason, ReportReason.other);
      expect(report.member.id, '');
      expect(report.member.displayName, 'Player');
      expect(report.member.atHandle, '');
      expect(report.hoursOpen, 0);
      expect(report.overdue, isFalse);
      expect(report.reportedAt, isNull);
      expect(report.reference, isNull);
    });

    test('a member with no name is shown by their handle', () {
      const member = ModeratedMember(id: 'm1', handle: 'rude', name: '');

      expect(member.displayName, 'rude');
    });

    test('a suspension is read with its end, or without one', () {
      final timed = SuspendedMember.fromJson({
        'id': 'm1',
        'handle': 'rude',
        'name': 'Rude Player',
        'reason': 'Spam',
        'suspended_at': '2026-11-01T10:00:00Z',
        'until': '2026-11-08T10:00:00Z',
      });
      final forGood = SuspendedMember.fromJson({'id': 'm2', 'until': null});

      expect(timed.member.suspended, isTrue);
      expect(timed.reason, 'Spam');
      expect(timed.until, DateTime.utc(2026, 11, 8, 10));
      expect(timed.forGood, isFalse);
      expect(forGood.forGood, isTrue);
    });
  });

  group('what went wrong', () {
    AdminFailure failureOf(int status, [Object? details]) =>
        AdminFailure.from(FunctionException(status: status, details: details));

    test('is named by the code the function sends', () {
      expect(
        failureOf(403, {'code': 'FORBIDDEN'}).code,
        AdminFailureCode.forbidden,
      );
      expect(
        failureOf(403, {'code': 'MFA_REQUIRED'}).code,
        AdminFailureCode.mfaRequired,
      );
      expect(
        failureOf(429, {'code': 'RATE_LIMITED'}).code,
        AdminFailureCode.rateLimited,
      );
      expect(
        failureOf(404, {'code': 'NOT_FOUND'}).code,
        AdminFailureCode.notFound,
      );
      expect(
        failureOf(409, {'code': 'MEMBER_IS_ADMIN'}).code,
        AdminFailureCode.memberIsAdmin,
      );
    });

    test('falls back on the status when there is no code', () {
      expect(failureOf(401).code, AdminFailureCode.unauthenticated);
      expect(failureOf(0).code, AdminFailureCode.offline);
      expect(failureOf(500, 'oops').code, AdminFailureCode.other);
      // Anything else that is not the server answering, like everywhere in the app.
      expect(AdminFailure.from(Exception('x')).code, AdminFailureCode.offline);
    });

    test('is told to the moderator in words of the app\'s', () {
      expect(
        failureOf(403, {'code': 'FORBIDDEN'}).message,
        'This account isn’t an admin.',
      );
      expect(
        failureOf(409, {'code': 'MEMBER_IS_ADMIN'}).message,
        'Admins can’t be suspended from the app.',
      );
      expect(failureOf(500).message, 'Couldn’t do that. Try again.');
      final all = {
        for (final code in AdminFailureCode.values) AdminFailure(code).message,
      };
      expect(all.length, AdminFailureCode.values.length);
    });
  });

  group('the store', () {
    Future<void> signedIn() async {
      await stores.auth.initialize();
      stores.admin.initialize();
      await pumpEventQueue();
    }

    late DebugPrintCallback originalDebugPrint;
    setUp(() {
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {};
    });

    tearDown(() {
      debugPrint = originalDebugPrint;
      stores.dispose();
    });

    test('asks once the account is known whether it is an admin', () async {
      await signedIn();

      expect(api.calls, ['isAdmin']);
      expect(stores.admin.isAdmin, isTrue);
    });

    test(
      'a member who is not an admin is shown nothing and asked nothing',
      () async {
        api.admin = false;
        await signedIn();

        await stores.admin.loadReports();
        await stores.admin.loadSuspended();

        expect(stores.admin.isAdmin, isFalse);
        expect(stores.admin.reportsStatus, LoadStatus.idle);
        expect(stores.admin.suspendedStatus, LoadStatus.idle);
        expect(api.calls, ['isAdmin']);
      },
    );

    test('nobody signed in is not asked at all', () async {
      final signedOut = AppStores(
        repository: repo,
        authService: FakeAuthService(null),
        connectivity: FakeConnectivity(),
        adminApi: api,
      );
      addTearDown(signedOut.dispose);
      await signedOut.auth.initialize();
      signedOut.admin.initialize();
      await pumpEventQueue();

      await signedOut.admin.loadReports();

      expect(api.calls, isEmpty);
      expect(signedOut.admin.isAdmin, isFalse);
    });

    test('the queue is read, oldest first as sent', () async {
      await signedIn();

      await stores.admin.loadReports();

      expect(stores.admin.reportsStatus, LoadStatus.ready);
      expect(stores.admin.reports.map((r) => r.member.id), ['m1', 'm2']);
    });

    test(
      'a failed read is failed, and a refresh that fails keeps the queue',
      () async {
        await signedIn();
        api.failWith = const AdminFailure(AdminFailureCode.rateLimited);
        await stores.admin.loadReports();
        expect(stores.admin.reportsStatus, LoadStatus.failed);
        expect(stores.admin.reportsFailure?.code, AdminFailureCode.rateLimited);

        api.failWith = null;
        await stores.admin.loadReports();
        expect(stores.admin.reportsStatus, LoadStatus.ready);
        expect(stores.admin.reportsFailure, isNull);

        api.failWith = const AdminFailure(AdminFailureCode.offline);
        await stores.admin.loadReports();
        expect(stores.admin.reportsStatus, LoadStatus.ready);
        expect(stores.admin.reports, hasLength(2));
        expect(stores.admin.reportsFailure?.code, AdminFailureCode.offline);
      },
    );

    test('suspending sends the reason and the days, and moves the member to the list', () async {
      await signedIn();
      await stores.admin.loadReports();
      await stores.admin.loadSuspended();

      await stores.admin.suspend(memberId: 'm1', reason: 'Harassment', days: 7);
      await pumpEventQueue();

      expect(api.calls.last, 'suspended'); // the list was asked again
      expect(api.calls, contains('suspend:m1:Harassment:7'));
      expect(stores.admin.reports.map((r) => r.member.id), ['m2']);
      expect(stores.admin.suspended.map((s) => s.member.id), ['m1']);
    });

    test('a suspension for good sends no days', () async {
      await signedIn();

      await stores.admin.suspend(memberId: 'm9', reason: 'Spam');

      expect(api.calls, contains('suspend:m9:Spam:until reinstated'));
    });

    test(
      'a suspension that fails throws and leaves the queue as it was',
      () async {
        await signedIn();
        await stores.admin.loadReports();
        api.failWith = const AdminFailure(AdminFailureCode.memberIsAdmin);

        await expectLater(
          stores.admin.suspend(memberId: 'm1', reason: 'Spam'),
          throwsA(
            isA<AdminFailure>().having(
              (f) => f.code,
              'code',
              AdminFailureCode.memberIsAdmin,
            ),
          ),
        );

        expect(stores.admin.reports, hasLength(2));
      },
    );

    test(
      'reinstating takes the member off the list and asks the queue again',
      () async {
        await signedIn();
        api.suspendedList = [
          const SuspendedMember(
            member: ModeratedMember(
              id: 'm3',
              handle: 'gone',
              name: 'Gone',
              suspended: true,
            ),
            reason: 'Spam',
          ),
        ];
        await stores.admin.loadReports();
        await stores.admin.loadSuspended();
        expect(stores.admin.suspended, hasLength(1));
        api.calls.clear();

        await stores.admin.reinstate('m3');
        await pumpEventQueue();

        expect(api.calls, ['reinstate:m3', 'reports']);
        expect(stores.admin.suspended, isEmpty);
      },
    );

    test(
      'closing the reports about a member takes them off the queue',
      () async {
        await signedIn();
        await stores.admin.loadReports();

        await stores.admin.closeReports('m2', dismissed: true);

        expect(api.calls.last, 'close:m2:dismissed');
        expect(stores.admin.reports.map((r) => r.member.id), ['m1']);

        await stores.admin.closeReports('m1', dismissed: false);
        expect(api.calls.last, 'close:m1:actioned');
        expect(stores.admin.reports, isEmpty);
      },
    );

    test(
      'another account is asked again, and nothing of the last one stays',
      () async {
        await signedIn();
        await stores.admin.loadReports();
        expect(stores.admin.reports, isNotEmpty);

        api.admin = false;
        authService.emit(testUser('u2'));
        await pumpEventQueue();

        expect(stores.admin.isAdmin, isFalse);
        expect(stores.admin.reports, isEmpty);
        expect(stores.admin.reportsStatus, LoadStatus.idle);
      },
    );

    test(
      'an answer that arrives after the account changed is dropped',
      () async {
        await signedIn();
        final gate = api.gate = Completer<void>();
        final loading = stores.admin.loadReports();
        await pumpEventQueue();

        authService.emit(testUser('u2'));
        await pumpEventQueue();
        gate.complete();
        await loading;

        expect(stores.admin.reports, isEmpty);
        expect(stores.admin.reportsStatus, LoadStatus.idle);
      },
    );
  });

  group('the screens', () {
    Future<void> open(
      WidgetTester tester,
      Widget home, {
      Size size = const Size(800, 1200),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(theme: buildTheme(), home: home),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await tester.pumpAndSettle();
    }

    Future<void> openAdmin(
      WidgetTester tester, {
      Size size = const Size(800, 1200),
    }) => open(
      tester,
      const SettingsScreen(initialSection: SettingsSection.admin),
      size: size,
    );

    Finder text(String s) => find.textContaining(s, findRichText: true);

    group('Settings', () {
      testWidgets('lists Admin for an admin, in the sidebar', (tester) async {
        await open(tester, const SettingsScreen());
        expect(find.text('Admin'), findsOneWidget);
      });

      testWidgets('on a phone Admin is one of the chips', (tester) async {
        await open(tester, const SettingsScreen(), size: const Size(400, 900));
        expect(find.text('Admin'), findsOneWidget);
      });

      testWidgets('does not list it for anybody else', (tester) async {
        api.admin = false;
        await open(tester, const SettingsScreen());
        expect(find.text('Admin'), findsNothing);
        expect(find.text('Account'), findsWidgets);
      });

      testWidgets('does not open on it for anybody else', (tester) async {
        api.admin = false;
        await openAdmin(tester);
        expect(find.textContaining('Reports'), findsNothing);
        expect(api.calls, isNot(contains('reports')));
      });
    });

    group('the queue', () {
      testWidgets('lists the open reports with their age', (tester) async {
        await openAdmin(tester);

        expect(find.text('Reports (2)'), findsOneWidget);
        expect(text('Rude Player'), findsOneWidget);
        expect(text('@rude'), findsOneWidget);
        expect(find.text('A rude review'), findsOneWidget);
        expect(find.text('Overdue · 30 h'), findsOneWidget);
        expect(find.text('Reported as: Abusive or hateful'), findsOneWidget);
        expect(text('Spammer'), findsOneWidget);
        expect(find.text('Discussion thread'), findsOneWidget);
        expect(find.text('Open under 1 h'), findsOneWidget);
        expect(find.text('Reported as: Spam or ads'), findsOneWidget);
      });

      testWidgets('says so when nothing is waiting', (tester) async {
        api.reportList = [];
        await openAdmin(tester);

        expect(find.text('No open reports'), findsOneWidget);
        expect(find.text('Reports (0)'), findsOneWidget);
      });

      testWidgets('says so, and can try again, when it could not be read', (
        tester,
      ) async {
        api.failWith = const AdminFailure(AdminFailureCode.rateLimited);
        await openAdmin(tester);
        expect(find.text('Couldn’t load this'), findsOneWidget);
        expect(
          find.text('Too many requests. Try again in a minute.'),
          findsOneWidget,
        );

        api.failWith = null;
        await tester.tap(find.text('Try again'));
        await tester.pumpAndSettle();
        expect(find.text('Couldn’t load this'), findsNothing);
        expect(text('Rude Player'), findsOneWidget);
      });

      testWidgets('a report offers to suspend, dismiss or mark handled', (
        tester,
      ) async {
        await openAdmin(tester);

        await tester.tap(text('Rude Player'));
        await tester.pumpAndSettle();

        expect(find.text('Reports about Rude Player'), findsOneWidget);
        expect(find.text('Suspend…'), findsOneWidget);
        expect(find.text('Dismiss reports'), findsOneWidget);
        expect(find.text('Mark as handled'), findsOneWidget);
      });

      testWidgets('dismissing closes the reports about that member', (
        tester,
      ) async {
        await openAdmin(tester);

        await tester.tap(text('Rude Player'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Dismiss reports'));
        await tester.pumpAndSettle();

        expect(api.calls, contains('close:m1:dismissed'));
        expect(find.text('Reports closed'), findsOneWidget);
        expect(text('Rude Player'), findsNothing);
        expect(find.text('Reports (1)'), findsOneWidget);
      });

      testWidgets('marking handled closes them as actioned', (tester) async {
        await openAdmin(tester);

        await tester.tap(text('Spammer'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Mark as handled'));
        await tester.pumpAndSettle();

        expect(api.calls, contains('close:m2:actioned'));
      });

      testWidgets(
        'a member who is suspended already cannot be suspended again',
        (tester) async {
          api.reportList = [testReport('m1', suspended: true)];
          await openAdmin(tester);

          expect(text('Suspended'), findsWidgets);
          await tester.tap(text('Rude Player'));
          await tester.pumpAndSettle();

          expect(find.text('Already suspended'), findsOneWidget);
          await tester.tap(find.text('Suspend…'));
          await tester.pumpAndSettle();
          expect(find.text('Suspend Rude Player?'), findsNothing);
        },
      );
    });

    group('suspending', () {
      Future<void> startSuspending(WidgetTester tester, String who) async {
        await tester.tap(text(who));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Suspend…'));
        await tester.pumpAndSettle();
      }

      testWidgets('needs a reason, and a length that defaults to a week', (
        tester,
      ) async {
        await openAdmin(tester);

        await startSuspending(tester, 'Rude Player');

        expect(find.text('Suspend Rude Player?'), findsOneWidget);
        final button = find.widgetWithText(FilledButton, 'Suspend');
        expect(tester.widget<FilledButton>(button).onPressed, isNull);

        await tester.enterText(find.byType(TextField), '   ');
        await tester.pump();
        expect(tester.widget<FilledButton>(button).onPressed, isNull);

        await tester.enterText(find.byType(TextField), ' Harassing members ');
        await tester.pump();
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        await tester.tap(button);
        await tester.pumpAndSettle();

        expect(api.calls, contains('suspend:m1:Harassing members:7'));
      });

      testWidgets(
        'does it with the length chosen, tells the moderator and lists them',
        (tester) async {
          await openAdmin(tester);

          await startSuspending(tester, 'Spammer');
          await tester.enterText(find.byType(TextField), 'Ads');
          await tester.tap(find.text('Until reinstated'));
          await tester.pump();
          await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
          await tester.pumpAndSettle();

          expect(api.calls, contains('suspend:m2:Ads:until reinstated'));
          expect(find.text('Spammer is suspended'), findsOneWidget);
          expect(text('Spammer'), findsOneWidget); // only in the snackbar
          expect(find.text('Reports (1)'), findsOneWidget);
          expect(find.text('Suspended (1)'), findsOneWidget);
        },
      );

      testWidgets('cancelling suspends nobody', (tester) async {
        await openAdmin(tester);

        await startSuspending(tester, 'Rude Player');
        await tester.enterText(find.byType(TextField), 'Nope');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(api.calls.where((c) => c.startsWith('suspend:')), isEmpty);
        expect(find.text('Reports (2)'), findsOneWidget);
      });

      testWidgets('a refusal is told and the report stays', (tester) async {
        await openAdmin(tester);
        await startSuspending(tester, 'Rude Player');
        await tester.enterText(find.byType(TextField), 'Spam');
        await tester.pump();
        api.failWith = const AdminFailure(AdminFailureCode.memberIsAdmin);

        await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
        await tester.pumpAndSettle();

        expect(
          find.text('Admins can’t be suspended from the app.'),
          findsOneWidget,
        );
        expect(find.text('Reports (2)'), findsOneWidget);
      });
    });

    group('the suspended', () {
      setUp(() {
        api.suspendedList = [
          SuspendedMember(
            member: const ModeratedMember(
              id: 'm3',
              handle: 'gone',
              name: 'Gone Troll',
              suspended: true,
            ),
            reason: 'Slurs in a thread',
            until: DateTime.now().add(const Duration(days: 3)),
          ),
          const SuspendedMember(
            member: ModeratedMember(
              id: 'm4',
              handle: 'forever',
              name: 'Forever',
              suspended: true,
            ),
            reason: 'Spam',
          ),
        ];
      });

      Future<void> openSuspended(WidgetTester tester) async {
        await openAdmin(tester);
        await tester.tap(find.text('Suspended (2)'));
        await tester.pumpAndSettle();
      }

      testWidgets('lists them with the reason and when it ends', (
        tester,
      ) async {
        await openSuspended(tester);

        expect(text('Gone Troll'), findsOneWidget);
        expect(find.text('Slurs in a thread'), findsOneWidget);
        expect(text('Suspended until'), findsNWidgets(2));
        expect(text('Forever'), findsOneWidget);
        expect(find.text('Suspended until you reinstate them'), findsOneWidget);
      });

      testWidgets('says so when nobody is', (tester) async {
        api.suspendedList = [];
        await openAdmin(tester);
        await tester.tap(find.text('Suspended (0)'));
        await tester.pumpAndSettle();

        expect(find.text('Nobody is suspended'), findsOneWidget);
      });

      testWidgets(
        'reinstating asks first, and then they are gone from the list',
        (tester) async {
          await openSuspended(tester);

          await tester.tap(
            find.widgetWithText(OutlinedButton, 'Reinstate').first,
          );
          await tester.pumpAndSettle();
          expect(find.text('Reinstate Gone Troll?'), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(api.calls.where((c) => c.startsWith('reinstate')), isEmpty);

          await tester.tap(
            find.widgetWithText(OutlinedButton, 'Reinstate').first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Reinstate'));
          await tester.pumpAndSettle();

          expect(api.calls, contains('reinstate:m3'));
          expect(find.text('Gone Troll is reinstated'), findsOneWidget);
          expect(find.text('Suspended (1)'), findsOneWidget);
          expect(find.text('Slurs in a thread'), findsNothing);
        },
      );
    });

    group('a member\'s profile', () {
      setUp(() {
        repo.members['m1'] = const PublicProfile(
          id: 'm1',
          name: 'Member One',
          handle: '@member_one',
        );
      });

      Future<void> openMenu(WidgetTester tester) async {
        await open(tester, const PublicProfileScreen(userId: 'm1'));
        await tester.tap(find.byTooltip('More options'));
        await tester.pumpAndSettle();
      }

      testWidgets('offers an admin to suspend them', (tester) async {
        await openMenu(tester);

        expect(find.text('Suspend Member One (admin)'), findsOneWidget);
        expect(find.text('Block Member One'), findsOneWidget);
      });

      testWidgets('offers nobody else that', (tester) async {
        api.admin = false;
        await openMenu(tester);

        expect(find.text('Block Member One'), findsOneWidget);
        expect(find.textContaining('(admin)'), findsNothing);
      });

      testWidgets('suspends them after asking why', (tester) async {
        await openMenu(tester);

        await tester.tap(find.text('Suspend Member One (admin)'));
        await tester.pumpAndSettle();
        expect(find.text('Suspend Member One?'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Harassment');
        await tester.tap(find.text('30 days'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Suspend'));
        await tester.pumpAndSettle();

        expect(api.calls, contains('suspend:m1:Harassment:30'));
      });
    });
  });
}
