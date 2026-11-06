import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/push.dart';
import 'package:checkpoint/models/share_link.dart';
import 'package:checkpoint/services/notification_taps.dart';
import 'package:checkpoint/services/push_service.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/push_store.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRepository repo;
  late FakeAuthService authService;
  late FakePushService phone;
  late AppStores stores;

  const threadId = '11111111-2222-4333-8444-555555555555';

  AppStores newStores() => AppStores(
    repository: repo,
    authService: authService,
    connectivity: FakeConnectivity(),
    apiService: FakeBrowseApi(),
    pushService: phone,
  );

  Future<bool?> savedSwitch(String userId) async => (await SharedPreferences.getInstance()).getBool('push.v1.$userId');
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Signs out and lets the stores finish letting go of the account, so tearing them
  /// down afterwards does not cut that short.
  Future<void> signOut() async {
    await stores.auth.logOut();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    authService = FakeAuthService(testUser('u1'));
    phone = FakePushService();
    stores = newStores();
  });

  tearDown(() => stores.dispose());

  group('turning it on', () {
    test('asks the system, registers the phone with its language and region, and is remembered', () async {
      await stores.initialize();
      expect(stores.push.isEnabled, isFalse);
      expect(phone.calls, isEmpty); // nothing is asked until the member does it

      final result = await stores.push.setEnabled(true);

      expect(result, PushResult.on);
      expect(stores.push.isEnabled, isTrue);
      expect(phone.calls, ['initialize', 'permission', 'token']);
      expect(repo.pushDevices.keys, ['token-1']);
      expect(repo.pushDevices['token-1']!.language, 'en');
      expect(repo.pushDevices['token-1']!.country, matches(RegExp('^[A-Z]{2}\$')));
      expect(repo.pushDevices['token-1']!.platform, 'android');
      expect(await savedSwitch('u1'), isTrue);
      expect(stores.push.isBusy, isFalse);
    });

    test('reads what the member wants from the server', () async {
      repo.notificationSettings = const NotificationSettings(priceDrops: false);
      await stores.initialize();
      await stores.push.setEnabled(true);
      expect(stores.push.settings, const NotificationSettings(priceDrops: false));
    });

    test('a refused permission leaves it off and registers nothing', () async {
      phone.grant = false;
      await stores.initialize();

      expect(await stores.push.setEnabled(true), PushResult.denied);

      expect(stores.push.isEnabled, isFalse);
      expect(repo.pushDevices, isEmpty);
      expect(await savedSwitch('u1'), isNull);
      expect(stores.push.isBusy, isFalse);
    });

    test('a phone with no token, or a server that is down, leaves it off', () async {
      phone.tokenValue = null;
      await stores.initialize();
      expect(await stores.push.setEnabled(true), PushResult.failed);
      expect(stores.push.isEnabled, isFalse);

      phone.tokenValue = 'token-1';
      repo.pushDown = true;
      expect(await stores.push.setEnabled(true), PushResult.failed);
      expect(stores.push.isEnabled, isFalse);
      expect(await savedSwitch('u1'), isNull);
      expect(stores.push.isBusy, isFalse);
    });

    test('a build that cannot receive push, or nobody signed in, cannot turn it on', () async {
      phone.supported = false;
      await stores.initialize();
      expect(stores.push.isSupported, isFalse);
      expect(await stores.push.setEnabled(true), PushResult.unsupported);
      expect(phone.calls, isEmpty);

      stores.dispose();
      phone = FakePushService();
      authService = FakeAuthService();
      stores = newStores();
      await stores.initialize();
      expect(stores.push.isSignedIn, isFalse);
      expect(await stores.push.setEnabled(true), PushResult.unsupported);
      expect(phone.calls, isEmpty);
    });
  });

  group('turning it off', () {
    test('takes the phone back from the server and throws its token away', () async {
      await stores.initialize();
      await stores.push.setEnabled(true);
      phone.calls.clear();

      expect(await stores.push.setEnabled(false), PushResult.off);

      expect(stores.push.isEnabled, isFalse);
      expect(repo.pushDevices, isEmpty);
      expect(phone.calls, contains('deleteToken'));
      expect(await savedSwitch('u1'), isFalse);
    });

    test('still turns off when the server cannot be reached', () async {
      await stores.initialize();
      await stores.push.setEnabled(true);
      repo.pushDown = true;

      expect(await stores.push.setEnabled(false), PushResult.off);
      expect(stores.push.isEnabled, isFalse);
      expect(await savedSwitch('u1'), isFalse);
    });
  });

  group('at the start of the app', () {
    test('a phone that was on registers again, so a renewed token or a new language reaches the server', () async {
      SharedPreferences.setMockInitialValues({'push.v1.u1': true});
      phone.permitted = true;
      repo.notificationSettings = const NotificationSettings(threadReplies: false);

      await stores.initialize();
      await settle();

      expect(stores.push.isEnabled, isTrue);
      expect(repo.pushDevices.keys, ['token-1']);
      expect(stores.push.settings, const NotificationSettings(threadReplies: false));
    });

    test('a member who took the permission back in the system settings is off, and it is remembered', () async {
      SharedPreferences.setMockInitialValues({'push.v1.u1': true});
      phone.permitted = false;

      await stores.initialize();
      await settle();

      expect(stores.push.isEnabled, isFalse);
      expect(repo.pushDevices, isEmpty);
      expect(await savedSwitch('u1'), isFalse);
    });

    test('it is per account: another member on this phone starts off', () async {
      SharedPreferences.setMockInitialValues({'push.v1.u1': true});
      phone.permitted = true;
      await stores.initialize();
      await settle();
      expect(stores.push.isEnabled, isTrue);

      authService.emit(testUser('u2'));
      await settle();

      expect(stores.push.isEnabled, isFalse);
    });

    test('a token Firebase renews is registered', () async {
      await stores.initialize();
      await stores.push.setEnabled(true);

      phone.refreshes.add('token-2');
      await settle();

      expect(repo.pushDevices.keys, containsAll(['token-1', 'token-2']));
    });
  });

  group('signing out', () {
    test('lets the phone go on the server first, so the next member does not get this one\'s notifications', () async {
      await stores.initialize();
      await stores.push.setEnabled(true);
      expect(repo.pushDevices, isNotEmpty);

      await signOut();

      expect(repo.pushDevices, isEmpty);
      expect(phone.calls, contains('deleteToken'));
    });

    test('does nothing for a phone that was not on', () async {
      await stores.initialize();
      await signOut();
      expect(phone.calls, isEmpty);
    });

    test('is not held up by a server that is down', () async {
      await stores.initialize();
      await stores.push.setEnabled(true);
      repo.pushDown = true;

      await signOut();

      expect(stores.auth.isLoggedIn, isFalse);
    });
  });

  group('what the member wants', () {
    test('is saved on the server, and a refusal puts the switch back', () async {
      await stores.initialize();
      await stores.push.setEnabled(true);

      expect(await stores.push.setPriceDrops(false), isTrue);
      expect(repo.notificationSettings, const NotificationSettings(priceDrops: false));
      expect(stores.push.settings.priceDrops, isFalse);

      repo.pushDown = true;
      expect(await stores.push.setThreadReplies(false), isFalse);
      expect(stores.push.settings.threadReplies, isTrue);
      expect(repo.notificationSettings.threadReplies, isTrue);
    });
  });

  group('a tapped notification', () {
    test('opens the game of a price drop and the thread of a reply', () async {
      await stores.initialize();
      await stores.push.setEnabled(true);

      phone.tap(const GameLink(1942));
      expect(stores.links.pending, const GameLink(1942));

      phone.tap(const ThreadLink(threadId));
      expect(stores.links.pending, const ThreadLink(threadId));
    });
  });

  group('what a notification carries', () {
    test('a price drop opens its game', () {
      expect(pushTarget({'kind': 'price_drop', 'igdb_id': '1942'}), const GameLink(1942));
      expect(pushTarget({'kind': 'price_drop', 'igdb_id': 1942}), const GameLink(1942));
    });

    test('a reply opens its thread', () {
      expect(pushTarget({'kind': 'thread_reply', 'thread_id': threadId}), const ThreadLink(threadId));
    });

    test('anything else opens nothing', () {
      expect(pushTarget({}), isNull);
      expect(pushTarget({'kind': 'price_drop'}), isNull);
      expect(pushTarget({'kind': 'price_drop', 'igdb_id': 'x'}), isNull);
      expect(pushTarget({'kind': 'price_drop', 'igdb_id': '0'}), isNull);
      expect(pushTarget({'kind': 'thread_reply', 'thread_id': 'not-an-id'}), isNull);
      expect(pushTarget({'kind': 'thread_reply'}), isNull);
      expect(pushTarget({'kind': 'follower', 'igdb_id': '5'}), isNull);
    });

    test('a notification the app shows itself carries what to open, and only its own payloads are read', () {
      expect(pushTargetOfPayload(pushPayload({'kind': 'price_drop', 'igdb_id': '1942'})), const GameLink(1942));
      expect(pushTargetOfPayload(pushPayload({'kind': 'thread_reply', 'thread_id': threadId})), const ThreadLink(threadId));
      // A release reminder's payload, a broken one and a notification of another kind open nothing here.
      expect(pushTargetOfPayload('game:1942'), isNull);
      expect(pushTargetOfPayload('push:{'), isNull);
      expect(pushTargetOfPayload('push:[1]'), isNull);
      expect(pushTargetOfPayload(pushPayload({'kind': 'follower'})), isNull);
      expect(pushTargetOfPayload(''), isNull);
    });

    test('a thread link reads back from its path', () {
      expect(LinkTarget.parse('/thread/$threadId'), const ThreadLink(threadId));
      expect(const ThreadLink(threadId).path, '/thread/$threadId');
      expect(LinkTarget.parse('/thread/nope'), isNull);
    });
  });

  group('the Firebase project of a build', () {
    FirebaseOptions? options(TargetPlatform p, {String project = 'demo', String key = 'k', String sender = '1', String android = 'a', String ios = 'i'}) =>
        FirebasePushService.optionsFor(p, projectId: project, apiKey: key, senderId: sender, androidAppId: android, iosAppId: ios);

    test('has each platform\'s app id', () {
      expect(options(TargetPlatform.android)!.appId, 'a');
      expect(options(TargetPlatform.android)!.projectId, 'demo');
      expect(options(TargetPlatform.android)!.messagingSenderId, '1');
      expect(options(TargetPlatform.iOS)!.appId, 'i');
      expect(options(TargetPlatform.iOS)!.iosBundleId, 'com.gamebit.mobileapp');
    });

    test('is none without the project, the key, the sender or the platform\'s app id', () {
      expect(options(TargetPlatform.android, project: ''), isNull);
      expect(options(TargetPlatform.android, key: ''), isNull);
      expect(options(TargetPlatform.android, sender: ''), isNull);
      expect(options(TargetPlatform.android, android: ''), isNull);
      expect(options(TargetPlatform.iOS, ios: ''), isNull);
      // Push is for the phones: nothing for a computer.
      expect(options(TargetPlatform.linux), isNull);
      expect(options(TargetPlatform.macOS), isNull);
    });

    test('a build with none has no push, so the app does not start Firebase', () {
      expect(
        FirebasePushService.optionsFor(TargetPlatform.android, projectId: '', apiKey: '', senderId: '', androidAppId: '', iosAppId: ''),
        isNull,
      );
    });

    test('the build has the Gamebit project by default, for the phones only', () {
      final android = FirebasePushService.optionsFor(TargetPlatform.android)!;
      expect(android.projectId, 'gamebit-9523b');
      expect(android.messagingSenderId, '46116590395');
      expect(android.appId, startsWith('1:46116590395:android:'));
      final ios = FirebasePushService.optionsFor(TargetPlatform.iOS)!;
      expect(ios.appId, startsWith('1:46116590395:ios:'));
      expect(ios.iosBundleId, 'com.gamebit.mobileapp');
      expect(FirebasePushService.optionsFor(TargetPlatform.linux), isNull);
    });
  });

  group('taps on the notifications the app shows', () {
    NotificationResponse tap(String? payload) =>
        NotificationResponse(notificationResponseType: NotificationResponseType.selectedNotification, payload: payload);

    tearDown(NotificationTaps.clear);

    test('reach every handler, each of which takes its own payloads', () {
      final reminders = <String>[];
      final pushes = <String>[];
      NotificationTaps.listen('reminders', reminders.add);
      NotificationTaps.listen('push', pushes.add);

      NotificationTaps.dispatch(tap('game:1942'));
      NotificationTaps.dispatch(tap(pushPayload({'kind': 'price_drop', 'igdb_id': '5'})));

      expect(reminders, ['game:1942', pushPayload({'kind': 'price_drop', 'igdb_id': '5'})]);
      expect(pushes, reminders);
    });

    test('a tap with no payload reaches nobody', () {
      final seen = <String>[];
      NotificationTaps.listen('a', seen.add);
      NotificationTaps.dispatch(tap(null));
      expect(seen, isEmpty);
    });

    test('an owner that listens again replaces its handler instead of adding one', () {
      final first = <String>[];
      final second = <String>[];
      NotificationTaps.listen('a', first.add);
      NotificationTaps.listen('a', second.add);
      NotificationTaps.dispatch(tap('x'));
      expect(first, isEmpty);
      expect(second, ['x']);
    });
  });
}
