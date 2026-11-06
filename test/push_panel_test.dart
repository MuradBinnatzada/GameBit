import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/push.dart';
import 'package:checkpoint/screens/settings/notifications_section.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// Settings > Notifications: the push switches.
void main() {
  late FakeRepository repo;
  late FakePushService phone;
  late AppStores stores;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    phone = FakePushService();
  });

  Future<void> open(WidgetTester tester, {bool signedIn = true}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    stores = AppStores(
      repository: repo,
      authService: FakeAuthService(signedIn ? testUser('u1') : null),
      connectivity: FakeConnectivity(),
      apiService: FakeBrowseApi(),
      pushService: phone,
      releaseNotifier: FakeReleaseNotifier(),
    );
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: NotificationsSection())),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pumpAndSettle();
  }

  Finder master() => find.byType(SwitchListTile).first;

  Future<void> turnOn(WidgetTester tester) async {
    await tester.tap(master());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('a build that cannot receive push says so and its switch is off', (tester) async {
    phone.supported = false;
    await open(tester);

    expect(find.textContaining('built with a Firebase project'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(master()).onChanged, isNull);
  });

  testWidgets('with nobody signed in it asks to log in', (tester) async {
    await open(tester, signedIn: false);

    expect(find.textContaining('Log in to get notifications'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(master()).onChanged, isNull);
  });

  testWidgets('is off to begin with, with no kinds to choose from', (tester) async {
    await open(tester);

    expect(tester.widget<SwitchListTile>(master()).value, isFalse);
    expect(find.text('Price drops'), findsNothing);
    expect(find.text('Replies'), findsNothing);
    expect(phone.calls, isEmpty);
  });

  testWidgets('turning it on registers the phone and offers the two kinds, both on', (tester) async {
    await open(tester);

    await turnOn(tester);

    expect(tester.widget<SwitchListTile>(master()).value, isTrue);
    expect(repo.pushDevices.keys, ['token-1']);
    expect(find.text('Price drops'), findsOneWidget);
    expect(find.text('Replies'), findsOneWidget);
    // The master switch and the two kinds are on; the fourth is the release day reminders.
    final tiles = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
    expect(tiles, hasLength(4));
    expect([for (final t in tiles) t.value], [true, true, true, false]);
  });

  testWidgets('a kind is saved when it is turned off', (tester) async {
    await open(tester);
    await turnOn(tester);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Price drops'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(repo.notificationSettings, const NotificationSettings(priceDrops: false));
    expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Price drops')).value, isFalse);
    expect(find.textContaining("Couldn't change"), findsNothing);
  });

  testWidgets('a kind the server refuses goes back and says so', (tester) async {
    await open(tester);
    await turnOn(tester);
    repo.pushDown = true;

    await tester.tap(find.widgetWithText(SwitchListTile, 'Replies'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Replies')).value, isTrue);
    expect(find.textContaining("Couldn't change push notifications"), findsOneWidget);
  });

  testWidgets('a refused permission says where to give it, and the button opens the system settings', (tester) async {
    phone.grant = false;
    await open(tester);

    await turnOn(tester);

    expect(tester.widget<SwitchListTile>(master()).value, isFalse);
    expect(find.textContaining('turned off for Gamebit in your device settings'), findsOneWidget);
    expect(repo.pushDevices, isEmpty);

    await tester.tap(find.text('Open device settings'));
    await tester.pump();
    expect(phone.calls, contains('settings'));
  });

  testWidgets('a server that is down says so and leaves it off', (tester) async {
    repo.pushDown = true;
    await open(tester);

    await turnOn(tester);

    expect(tester.widget<SwitchListTile>(master()).value, isFalse);
    expect(find.textContaining("Couldn't change push notifications"), findsOneWidget);
  });

  testWidgets('turning it off takes the kinds away and the phone off the server', (tester) async {
    await open(tester);
    await turnOn(tester);

    await tester.tap(master());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(master()).value, isFalse);
    expect(find.text('Price drops'), findsNothing);
    expect(repo.pushDevices, isEmpty);
  });
}
