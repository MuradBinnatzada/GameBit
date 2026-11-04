import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/profile_store.dart';

import 'support/fakes.dart';

/// Steam is the only connected service, because it is the only one whose owner
/// the app can prove: it is connected exactly when the profile has the Steam ID
/// the server saved after Steam's own sign-in. A name the member could type in
/// (PSN, Xbox, Discord, Instagram, Twitch, Nintendo) is not kept anywhere.
void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late AuthStore auth;
  late ProfileStore profile;

  Future<void> start([Map<String, Object> saved = const {}]) async {
    SharedPreferences.setMockInitialValues(saved);
    await profile.initialize();
    await pumpEventQueue();
  }

  setUp(() async {
    debugPrint = (String? message, {int? wrapWidth}) {};
    repo = FakeRepository();
    authService = FakeAuthService(testUser('u1'));
    auth = AuthStore(authService);
    await auth.initialize();
    profile = ProfileStore(repository: repo, auth: auth, cache: LocalCache());
  });

  tearDown(() {
    debugPrint = debugPrintThrottled;
    profile.dispose();
    auth.dispose();
  });

  group('Steam', () {
    test('is not connected until the profile has a Steam ID', () async {
      await start();

      expect(profile.steamConnected, isFalse);
      expect(profile.connectedServices, isEmpty);
      expect(profile.accountNames, isEmpty);
    });

    test('is connected, with its ID, once the profile has one', () async {
      repo.steamId = '76561198000000000';
      await start();

      expect(profile.steamConnected, isTrue);
      expect(profile.connectedServices, {ConnectedService.steam});
      expect(profile.accountNames, {
        ConnectedService.steam: '76561198000000000',
      });
    });

    test('a blank Steam ID is not a connection', () async {
      repo.steamId = '   ';
      await start();

      expect(profile.steamConnected, isFalse);
      expect(profile.connectedServices, isEmpty);
      expect(profile.accountNames, isEmpty);
    });

    test('is not connected for the guest placeholder after signing out', () async {
      repo.steamId = '76561198000000000';
      await start();
      expect(profile.steamConnected, isTrue);

      authService.emit(null);
      await pumpEventQueue();

      expect(profile.steamConnected, isFalse);
      expect(profile.connectedServices, isEmpty);
    });
  });

  group('names that were only typed in', () {
    test('what earlier builds saved on the device is deleted, and nothing else', () async {
      await start({
        // Per account, from the build that mirrored them to the server.
        'psn_id.u1': 'ps_user',
        'xbox_id.u1': 'gamer',
        'discord_id.u2': 'disc#1',
        'instagram_id.u1': 'ada.plays',
        'twitch_id.u1': 'ada_live',
        'connected_services.u1': ['psn', 'xbox'],
        'accounts_pending.u1': true,
        // For the whole device, from the build before that.
        'psn_id': 'old',
        'connected_services': ['nintendo'],
        // Not theirs.
        'onboarding_seen.u1': true,
        'psn_idea.u1': 'kept', // a different key that only starts the same
      });

      final keys = (await SharedPreferences.getInstance()).getKeys();
      expect(keys, containsAll(['onboarding_seen.u1', 'psn_idea.u1']));
      for (final key in keys) {
        expect(
          key,
          isNot(matches(r'^(psn_id|xbox_id|discord_id|instagram_id|twitch_id|connected_services|accounts_pending)(\.|$)')),
        );
      }
    });

    test('are not offered as connected services', () {
      expect(ConnectedService.values, [ConnectedService.steam]);
    });
  });
}
