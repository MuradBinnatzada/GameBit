import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/share_link.dart';
import 'package:checkpoint/screens/settings/notifications_section.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/release_reminders_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRepository repo;
  late FakeAuthService authService;
  late FakeReleaseNotifier device;
  late AppStores stores;

  DateTime inDays(int days) => DateTime.now().add(Duration(days: days));

  Game wish(String id, int days, {String? title}) =>
      testGame(id, title: title, cover: false, status: GameStatus.wishlist, igdbId: id.hashCode & 0xffff)
          .copyWith(releaseDate: inDays(days));

  AppStores newStores() => AppStores(
    repository: repo,
    authService: authService,
    connectivity: FakeConnectivity(),
    apiService: FakeBrowseApi(),
    releaseNotifier: device,
  );

  Future<String?> savedSetting(String userId) async =>
      (await SharedPreferences.getInstance()).getBool('release_reminders.v1.$userId')?.toString();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository()..library = [wish('soon', 10), wish('later', 40), testGame('owned', cover: false)];
    authService = FakeAuthService(testUser('u1'));
    device = FakeReleaseNotifier();
    stores = newStores();
  });

  tearDown(() => stores.dispose());

  group('the store', () {
    test('is off until the member turns it on, and the device is not touched', () async {
      await stores.initialize();

      expect(stores.releaseReminders.isEnabled, isFalse);
      expect(device.calls, isEmpty);
      expect(device.scheduled, isEmpty);
    });

    test('turning it on asks the system, schedules the releases to come, and is remembered', () async {
      await stores.initialize();

      final result = await stores.releaseReminders.setEnabled(true);

      expect(result, RemindersResult.on);
      expect(stores.releaseReminders.isEnabled, isTrue);
      expect(device.calls, ['initialize', 'permission']);
      expect(device.scheduled, [
        ['soon', 'later'],
      ]);
      expect(stores.releaseReminders.count, 2);
      expect(await savedSetting('u1'), 'true');
    });

    test('a refusal leaves it off, and nothing is scheduled', () async {
      device.allow = false;
      await stores.initialize();

      final result = await stores.releaseReminders.setEnabled(true);

      expect(result, RemindersResult.denied);
      expect(stores.releaseReminders.isEnabled, isFalse);
      expect(device.scheduled, isEmpty);
      expect(await savedSetting('u1'), isNull);
      expect(stores.releaseReminders.isBusy, isFalse);
    });

    test('a device that cannot show reminders, or no member, cannot turn it on', () async {
      device.isSupported = false;
      await stores.initialize();
      expect(await stores.releaseReminders.setEnabled(true), RemindersResult.unsupported);
      expect(stores.releaseReminders.isSupported, isFalse);

      stores.dispose();
      device = FakeReleaseNotifier();
      authService = FakeAuthService();
      stores = newStores();
      await stores.initialize();
      expect(stores.releaseReminders.isSignedIn, isFalse);
      expect(await stores.releaseReminders.setEnabled(true), RemindersResult.unsupported);
      expect(device.calls, isEmpty);
    });

    test('follows the wishlist: a new release is added, and what did not change schedules nothing', () async {
      await stores.initialize();
      await stores.releaseReminders.setEnabled(true);
      expect(device.scheduled, hasLength(1));

      // A game that is out already, then one to come.
      await stores.library.importGame(wish('out', -3), status: GameStatus.wishlist);
      await pumpEventQueue();
      expect(device.scheduled, hasLength(1));
      await stores.library.importGame(wish('soonest', 2), status: GameStatus.wishlist);
      await pumpEventQueue();
      expect(device.scheduled.last, ['soonest', 'soon', 'later']);

      // Something that is not about the wishlist.
      await stores.library.setRating('owned', 4);
      await pumpEventQueue();
      expect(device.scheduled, hasLength(2));

      // Starting a wishlist game takes its reminder back.
      await stores.library.setStatus('soonest', GameStatus.playing);
      await pumpEventQueue();
      expect(device.scheduled.last, ['soon', 'later']);
    });

    test('turning it off takes the reminders back, and the wishlist schedules nothing after', () async {
      await stores.initialize();
      await stores.releaseReminders.setEnabled(true);

      final result = await stores.releaseReminders.setEnabled(false);
      await stores.library.importGame(wish('new', 5), status: GameStatus.wishlist);
      await pumpEventQueue();

      expect(result, RemindersResult.off);
      expect(device.calls, contains('cancelAll'));
      expect(device.scheduled, hasLength(1));
      expect(await savedSetting('u1'), 'false');
    });

    test('is on at the next start when it was on, and schedules once the library is the server\'s', () async {
      SharedPreferences.setMockInitialValues({'release_reminders.v1.u1': true});

      await stores.initialize();

      expect(stores.releaseReminders.isEnabled, isTrue);
      expect(device.calls, ['initialize']);
      expect(device.scheduled, [
        ['soon', 'later'],
      ]);
    });

    test('leaves what is scheduled alone while only the copy saved on the device is known', () async {
      SharedPreferences.setMockInitialValues({'release_reminders.v1.u1': true});
      repo.offline = true;

      await stores.initialize();

      expect(stores.releaseReminders.isEnabled, isTrue);
      expect(device.scheduled, isEmpty);
      expect(device.calls, isNot(contains('cancelAll')));
    });

    test('is the account\'s: its reminders are taken back when another signs in or it signs out', () async {
      SharedPreferences.setMockInitialValues({'release_reminders.v1.u1': true});
      await stores.initialize();
      expect(device.scheduled, hasLength(1));

      authService.emit(testUser('u2'));
      await pumpEventQueue();

      expect(stores.releaseReminders.isEnabled, isFalse);
      expect(device.calls, contains('cancelAll'));
      expect(device.scheduled, hasLength(1));

      device.calls.clear();
      authService.emit(null);
      await pumpEventQueue();
      expect(stores.releaseReminders.isSignedIn, isFalse);
      // Nothing was scheduled for u2, so there is nothing to take back.
      expect(device.calls, isEmpty);
    });

    test('a reminder tapped opens its game like a link', () async {
      SharedPreferences.setMockInitialValues({'release_reminders.v1.u1': true});
      await stores.initialize();

      device.open!(1942);

      expect(stores.links.pending, const GameLink(1942));
    });
  });

  group('the Notifications section', () {
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: NotificationsSection())),
        ),
      );
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      await tester.pump();
    }

    /// The reminders' switch: the section has the push notifications' above it.
    final reminders = find.descendant(
      of: find.widgetWithText(SwitchListTile, 'Release day reminders'),
      matching: find.byType(Switch),
    );

    Future<void> flip(WidgetTester tester) async {
      await tester.tap(reminders);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }

    testWidgets('a switch turns the reminders on and says how many are set', (tester) async {
      await open(tester);
      expect(tester.widget<Switch>(reminders).value, isFalse);
      expect(find.textContaining('reminders set'), findsNothing);

      await flip(tester);

      expect(tester.widget<Switch>(reminders).value, isTrue);
      expect(find.text('2 reminders set'), findsOneWidget);
      expect(device.scheduled, hasLength(1));
    });

    testWidgets('a refusal says where to turn notifications on, and goes there', (tester) async {
      device.allow = false;
      await open(tester);

      await flip(tester);

      expect(tester.widget<Switch>(reminders).value, isFalse);
      expect(find.textContaining('turned off for Gamebit'), findsOneWidget);
      await tester.tap(find.text('Open device settings'));
      await tester.pump();
      expect(device.calls, contains('settings'));
    });

    testWidgets('a device that cannot show reminders says so, and the switch waits', (tester) async {
      device.isSupported = false;
      await open(tester);

      expect(find.text('Reminders are available in the Android and iOS apps.'), findsOneWidget);
      expect(tester.widget<Switch>(reminders).onChanged, isNull);
    });

    testWidgets('signed out, it asks to log in first', (tester) async {
      authService = FakeAuthService();
      stores.dispose();
      stores = newStores();
      await open(tester);

      expect(find.text('Log in to set reminders for the games on your wishlist.'), findsOneWidget);
      expect(tester.widget<Switch>(reminders).onChanged, isNull);
    });
  });
}
