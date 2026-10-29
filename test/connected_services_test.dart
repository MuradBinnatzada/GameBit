import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/services/pending_edits.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/profile_store.dart';

import 'support/fakes.dart';

/// The connected services and the account names behind PSN, Xbox and Discord are
/// kept on the device first and mirrored to the profile row
/// (`connected_services`, `psn_id`, `xbox_id`, `discord_id`), which is what other
/// members see and what the icons on their page open.
void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late FakeConnectivity network;
  late AuthStore auth;
  late ProfileStore profile;

  ProfileStore newProfile() => ProfileStore(
    repository: repo,
    auth: auth,
    cache: LocalCache(),
    connectivity: network,
  );

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  Future<void> start([Map<String, Object> saved = const {}]) async {
    SharedPreferences.setMockInitialValues(saved);
    await profile.initialize();
    await pumpEventQueue();
  }

  setUp(() async {
    debugPrint = (String? message, {int? wrapWidth}) {};
    repo = FakeRepository();
    authService = FakeAuthService(testUser('u1'));
    network = FakeConnectivity();
    auth = AuthStore(authService);
    await auth.initialize();
    profile = newProfile();
  });

  tearDown(() {
    debugPrint = debugPrintThrottled;
    profile.dispose();
    auth.dispose();
  });

  group('connecting and disconnecting', () {
    test('connecting PSN saves the name on the device and on the server', () async {
      await start();

      profile.setServiceId(ConnectedService.psn, 'ps_user');
      await pumpEventQueue();

      expect(profile.isConnected(ConnectedService.psn), isTrue);
      expect(repo.writes, ['services:psn']);
      expect(repo.connectedServices, {ConnectedService.psn});
      expect(repo.savedPsnId, 'ps_user');
      final saved = await prefs();
      expect(saved.getString('psn_id.u1'), 'ps_user');
      expect(saved.getStringList('connected_services.u1'), ['psn']);
      expect(saved.getBool('accounts_pending.u1'), isFalse);
      expect(profile.notice, isNull);
    });

    test(
      'Xbox, Discord and Nintendo are written the same way, in a stable order',
      () async {
        await start();

        profile.setServiceId(ConnectedService.xbox, 'gamer');
        await pumpEventQueue();
        profile.setServiceId(ConnectedService.discord, 'disc#1');
        await pumpEventQueue();
        profile.toggleService(
          ConnectedService.nintendo,
        ); // has no name to store
        await pumpEventQueue();

        expect(repo.writes, [
          'services:xbox',
          'services:discord,xbox',
          'services:discord,nintendo,xbox',
        ]);
        // The names go up with the list; Nintendo has none.
        expect(repo.savedXboxId, 'gamer');
        expect(repo.savedDiscordId, 'disc#1');
        expect(repo.savedPsnId, isNull);
      },
    );

    test('disconnecting writes the list without it', () async {
      await start();
      profile.setServiceId(ConnectedService.psn, 'ps_user');
      await pumpEventQueue();
      profile.setServiceId(ConnectedService.xbox, 'gamer');
      await pumpEventQueue();

      profile.toggleService(ConnectedService.psn);
      await pumpEventQueue();

      expect(profile.isConnected(ConnectedService.psn), isFalse);
      expect(repo.connectedServices, {ConnectedService.xbox});
      expect(repo.writes.last, 'services:xbox');
      // A disconnected service has no name on the server any more.
      expect(repo.savedPsnId, isNull);
      expect(repo.savedXboxId, 'gamer');

      profile.toggleService(ConnectedService.xbox);
      await pumpEventQueue();
      expect(repo.connectedServices, isEmpty);
      expect(repo.writes.last, 'services:');
    });

    test('changing the name of a service that is already connected sends the new name', () async {
      await start();
      profile.setServiceId(ConnectedService.psn, 'old');
      await pumpEventQueue();

      profile.setServiceId(ConnectedService.psn, 'new');
      await pumpEventQueue();

      expect(repo.writes, ['services:psn', 'services:psn']);
      expect(repo.savedPsnId, 'new');
      expect((await prefs()).getString('psn_id.u1'), 'new');
    });

    test('Steam is never written to the list', () async {
      repo.steamId = '76561198000000000';
      await start();
      expect(profile.isConnected(ConnectedService.steam), isTrue);

      profile.setServiceId(ConnectedService.psn, 'ps_user');
      await pumpEventQueue();

      expect(repo.connectedServices, {ConnectedService.psn});
      expect(profile.connectedServices, {
        ConnectedService.steam,
        ConnectedService.psn,
      });
    });
  });

  group('when the server cannot be reached', () {
    test('the change stands on this device, the user is told, and it is sent when the connection is back', () async {
      await start();
      repo.offline = true;

      profile.setServiceId(ConnectedService.psn, 'ps_user');
      await pumpEventQueue();

      expect(profile.isConnected(ConnectedService.psn), isTrue);
      expect(profile.notice, queuedNotice);
      expect(repo.writes, isEmpty);
      expect((await prefs()).getBool('accounts_pending.u1'), isTrue);
      profile.clearNotice();

      repo.offline = false;
      network.controller.add(true);
      await pumpEventQueue();

      expect(repo.writes, ['services:psn']);
      expect(profile.notice, isNull);
      expect((await prefs()).getBool('accounts_pending.u1'), isFalse);
    });

    test('a change made offline is sent when the app is opened again with the connection back', () async {
      await start();
      repo.offline = true;
      profile.setServiceId(ConnectedService.psn, 'ps_user');
      await pumpEventQueue();
      expect(repo.writes, isEmpty);

      // A new run of the app: the same device, a new store.
      profile.dispose();
      repo.offline = false;
      profile = newProfile();
      await profile.initialize();
      await pumpEventQueue();

      expect(profile.isConnected(ConnectedService.psn), isTrue);
      expect(repo.writes, ['services:psn']);
      expect((await prefs()).getBool('accounts_pending.u1'), isFalse);
    });

    test('a name the server refuses for its words says so', () async {
      await start();
      repo
        ..rejectWrites = true
        ..rejectCode = 'CP422';

      profile.toggleService(ConnectedService.nintendo);
      await pumpEventQueue();

      expect(profile.notice, startsWith('That text breaks the community rules'));
    });

    test('a refused write is reported, keeps the change on the device and is tried again on the next load', () async {
      await start();
      repo.rejectWrites = true;

      profile.toggleService(ConnectedService.nintendo);
      await pumpEventQueue();

      expect(profile.isConnected(ConnectedService.nintendo), isTrue);
      expect(
        profile.notice,
        'Could not update the accounts shown on your profile.',
      );
      expect((await prefs()).getBool('accounts_pending.u1'), isTrue);
      profile.clearNotice();

      repo.rejectWrites = false;
      await profile.refresh();
      await pumpEventQueue();

      expect(repo.writes, ['services:nintendo']);
      expect(profile.notice, isNull);
      expect((await prefs()).getBool('accounts_pending.u1'), isFalse);
    });

    test('a retry that nobody asked for does not nag: no notice when a background send fails', () async {
      repo.writesDown = true;
      await start({
        'connected_services.u1': ['psn'],
        'accounts_pending.u1': true,
      });
      await profile.refresh();
      await pumpEventQueue();

      expect(profile.notice, isNull);
      expect((await prefs()).getBool('accounts_pending.u1'), isTrue);
    });

    test(
      'with an expired session nothing is sent; restoring it sends the change',
      () async {
        authService = FakeAuthService()
          ..persistedId = 'u1'
          ..restoreWorks = true;
        auth.dispose();
        auth = AuthStore(authService);
        await auth.initialize();
        profile.dispose();
        profile = newProfile();
        await start();
        expect(auth.isSessionPending, isTrue);

        profile.setServiceId(ConnectedService.xbox, 'gamer');
        await pumpEventQueue();

        expect(profile.isConnected(ConnectedService.xbox), isTrue);
        expect(profile.notice, queuedNotice);
        expect(repo.writes, isEmpty);

        await auth.restoreSession();
        await pumpEventQueue();

        expect(repo.writes, ['services:xbox']);
      },
    );
  });

  group('reconciling with the server', () {
    test('a device that never connected anything shows what another device connected, names included', () async {
      repo.connectedServices = {ConnectedService.xbox};
      repo.savedXboxId = 'gamer';

      await start();

      expect(profile.isConnected(ConnectedService.xbox), isTrue);
      expect(profile.xboxId, 'gamer'); // the name came from the other device
      expect((await prefs()).getString('xbox_id.u1'), 'gamer');
      expect(repo.writes, isEmpty);
      final saved = await prefs();
      expect(saved.getStringList('connected_services.u1'), ['xbox']);
      expect(saved.getBool('accounts_pending.u1'), isFalse);
    });

    test('a service another device connected before it saved names has no name here', () async {
      repo.connectedServices = {ConnectedService.xbox};

      await start();

      expect(profile.isConnected(ConnectedService.xbox), isTrue);
      expect(profile.xboxId, isNull);
      expect(repo.writes, isEmpty);
    });

    test('a name this device has and the server lacks goes up, without changing the rest', () async {
      repo.connectedServices = {ConnectedService.psn};

      await start({
        'psn_id.u1': 'ps_user',
        'connected_services.u1': ['psn'],
        'accounts_pending.u1': false,
      });

      expect(profile.psnId, 'ps_user');
      expect(repo.writes, ['services:psn']);
      expect(repo.savedPsnId, 'ps_user');
    });

    test('a change made on top of the adopted list keeps the other device\'s services', () async {
      repo.connectedServices = {ConnectedService.xbox};
      await start();

      profile.setServiceId(ConnectedService.psn, 'ps_user');
      await pumpEventQueue();

      expect(repo.writes, ['services:psn,xbox']);
    });

    test('a list saved before the server kept one is sent on the first load, not overwritten', () async {
      await start({
        'psn_id.u1': 'ps_user',
        'connected_services.u1': ['psn'],
      });

      expect(profile.isConnected(ConnectedService.psn), isTrue);
      expect(repo.writes, ['services:psn']);
      expect(repo.savedPsnId, 'ps_user'); // the name goes up with it
      expect((await prefs()).getBool('accounts_pending.u1'), isFalse);
    });

    test('a list saved before the server kept one, but empty, adopts the server\'s', () async {
      repo.connectedServices = {ConnectedService.discord};

      await start({'connected_services.u1': <String>[]});

      expect(profile.isConnected(ConnectedService.discord), isTrue);
      expect(repo.writes, isEmpty);
    });

    test(
      'a change this device has not sent beats the server\'s list',
      () async {
        repo.connectedServices = {ConnectedService.xbox};

        await start({
          'connected_services.u1': ['psn'],
          'accounts_pending.u1': true,
        });

        expect(profile.connectedServices, {ConnectedService.psn});
        expect(repo.connectedServices, {ConnectedService.psn});
      },
    );

    test(
      'once sent, a service disconnected on another device disappears here too',
      () async {
        repo.connectedServices = {};

        await start({
          'psn_id.u1': 'ps_user',
          'connected_services.u1': ['psn'],
          'accounts_pending.u1': false,
        });

        expect(profile.isConnected(ConnectedService.psn), isFalse);
        expect(repo.writes, isEmpty);
      },
    );

    test('a change made while the profile was being read is not undone by the older answer', () async {
      await start();
      repo.profileLoadGate = Completer<void>();
      final reloading = profile.refresh(); // reads the list as it is now: empty

      profile.toggleService(ConnectedService.nintendo);
      await pumpEventQueue();
      expect(repo.connectedServices, {ConnectedService.nintendo});

      repo.profileLoadGate!.complete();
      await reloading;
      await pumpEventQueue();

      expect(profile.isConnected(ConnectedService.nintendo), isTrue);
      expect((await prefs()).getStringList('connected_services.u1'), [
        'nintendo',
      ]);
    });

    test(
      'a change made while the last one is on its way is sent after it',
      () async {
        await start();
        repo.servicesGate = Completer<void>();

        profile.setServiceId(ConnectedService.psn, 'ps_user');
        await pumpEventQueue();
        profile.setServiceId(ConnectedService.xbox, 'gamer');
        await pumpEventQueue();
        expect(repo.writes, isEmpty); // the first is still on its way

        repo.servicesGate!.complete();
        await pumpEventQueue();

        expect(repo.writes, ['services:psn', 'services:psn,xbox']);
        expect(repo.connectedServices, {
          ConnectedService.psn,
          ConnectedService.xbox,
        });
        expect((await prefs()).getBool('accounts_pending.u1'), isFalse);
      },
    );
  });

  group('Instagram and Twitch', () {
    test('connecting them saves the names on the device and on the server', () async {
      await start();

      profile.setServiceId(ConnectedService.instagram, 'ada.plays');
      profile.setServiceId(ConnectedService.twitch, 'ada_live');
      await pumpEventQueue();

      expect(profile.isConnected(ConnectedService.instagram), isTrue);
      expect(profile.instagramId, 'ada.plays');
      expect(profile.twitchId, 'ada_live');
      expect(profile.accountNames, {
        ConnectedService.instagram: 'ada.plays',
        ConnectedService.twitch: 'ada_live',
      });
      expect(repo.connectedServices, {ConnectedService.instagram, ConnectedService.twitch});
      expect(repo.savedInstagramId, 'ada.plays');
      expect(repo.savedTwitchId, 'ada_live');
      final saved = await prefs();
      expect(saved.getString('instagram_id.u1'), 'ada.plays');
      expect(saved.getString('twitch_id.u1'), 'ada_live');
    });

    test('disconnecting one clears its name on the server', () async {
      await start();
      profile.setServiceId(ConnectedService.twitch, 'ada_live');
      await pumpEventQueue();

      profile.toggleService(ConnectedService.twitch);
      await pumpEventQueue();

      expect(profile.isConnected(ConnectedService.twitch), isFalse);
      expect(profile.accountNames, isEmpty);
      expect(repo.connectedServices, isEmpty);
      expect(repo.savedTwitchId, isNull);
    });

    test('the names on the server are adopted on load, so a second device shows them', () async {
      repo.connectedServices = {ConnectedService.instagram};
      repo.savedInstagramId = 'from_server';
      await start();

      expect(profile.isConnected(ConnectedService.instagram), isTrue);
      expect(profile.instagramId, 'from_server');
      expect(profile.accountNames[ConnectedService.instagram], 'from_server');
      expect((await prefs()).getString('instagram_id.u1'), 'from_server');
    });
  });

  group('cleanAccountName', () {
    test('trims, and drops a leading @ for Instagram and Twitch', () {
      expect(cleanAccountName(ConnectedService.instagram, '  @ada.plays '), 'ada.plays');
      expect(cleanAccountName(ConnectedService.twitch, '@@ada_live'), 'ada_live');
      expect(cleanAccountName(ConnectedService.psn, ' ps_user '), 'ps_user');
      // Discord names may have anything in them, an @ included.
      expect(cleanAccountName(ConnectedService.discord, '@ada#1'), '@ada#1');
    });

    test('refuses nothing, too long, or a name the service does not allow', () {
      expect(cleanAccountName(ConnectedService.psn, '   '), isNull);
      expect(cleanAccountName(ConnectedService.psn, 'x' * (accountNameMaxLength + 1)), isNull);
      expect(cleanAccountName(ConnectedService.instagram, '../explore'), isNull);
      expect(cleanAccountName(ConnectedService.instagram, 'a' * 31), isNull);
      expect(cleanAccountName(ConnectedService.twitch, 'has space'), isNull);
      expect(cleanAccountName(ConnectedService.twitch, 'a' * 26), isNull);
    });
  });

  group('accounts', () {
    test(
      'another account on the device does not inherit the list, or send it',
      () async {
        await start();
        profile.setServiceId(ConnectedService.psn, 'ps_user');
        await pumpEventQueue();
        repo.writes.clear();

        repo.connectedServices = {}; // u2's row
        repo.savedPsnId = null;
        authService.emit(testUser('u2'));
        await pumpEventQueue();

        expect(profile.connectedServices, isEmpty);
        expect(profile.psnId, isNull);
        expect(repo.writes, isEmpty);
        // u1's own list is still on the device for when they sign in again.
        expect((await prefs()).getStringList('connected_services.u1'), ['psn']);
      },
    );

    test('signing out while a change is on its way does not write it back for the account that left', () async {
      await start();
      repo.servicesGate = Completer<void>();
      profile.toggleService(ConnectedService.nintendo);
      await pumpEventQueue();

      authService.emit(null);
      await pumpEventQueue();
      repo.servicesGate!.complete();
      await pumpEventQueue();

      // Still pending for u1: the send was not confirmed for them, so it will be repeated.
      expect((await prefs()).getBool('accounts_pending.u1'), isTrue);
    });
  });
}
