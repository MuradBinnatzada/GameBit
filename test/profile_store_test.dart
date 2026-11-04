import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/user_profile.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/profile_store.dart';

import 'support/fakes.dart';

void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late LocalCache cache;
  late AuthStore auth;
  late ProfileStore profile;

  setUp(() {
    debugPrint = (String? message, {int? wrapWidth}) {};
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    authService = FakeAuthService(testUser('u1'));
    cache = LocalCache();
    auth = AuthStore(authService)..initialize();
    profile = ProfileStore(repository: repo, auth: auth, cache: cache);
  });

  tearDown(() {
    debugPrint = debugPrintThrottled;
    profile.dispose();
    auth.dispose();
  });

  test('loads the profile and follows', () async {
    await profile.initialize();

    expect(profile.profile.name, 'Ada');
    expect(profile.followingCount, 1);
    expect(profile.followersCount, 3);
  });

  test('keeps the saved profile and follows when the server cannot be reached', () async {
    await cache.writeProfile(
      'u1',
      UserProfile(
        name: 'Saved Ada',
        handle: '@saved',
        bio: '',
        joined: DateTime.utc(2026, 1, 1),
        followers: 0,
        following: 0,
      ),
    );
    await cache.writeSocial(
      'u1',
      const SocialSnapshot(followingIds: {'a', 'b'}, followersCount: 5),
    );
    repo.offline = true;

    await profile.initialize();

    expect(profile.profile.name, 'Saved Ada');
    expect(profile.followingCount, 2);
    expect(profile.followersCount, 5);
  });

  test('a second auth event during startup does not lose the saved data', () async {
    repo.offline = true;
    await cache.writeProfile(
      'u1',
      UserProfile(
        name: 'Saved Ada',
        handle: '@saved',
        bio: '',
        joined: DateTime.utc(2026, 1, 1),
        followers: 0,
        following: 0,
      ),
    );

    final loading = profile.initialize();
    authService.emit(testUser('u1')); // e.g. Supabase's own "signed in" event
    await loading;
    await pumpEventQueue();

    expect(profile.profile.name, 'Saved Ada');
  });

  test('signing out forgets the account and deletes its saved copy', () async {
    await profile.initialize();
    await pumpEventQueue();
    expect(await cache.readProfile('u1'), isNotNull);

    authService.emit(null);
    await pumpEventQueue();

    expect(profile.profile.handle, '@guest');
    expect(profile.steamConnected, isFalse);
    expect(profile.followingCount, 0);
    expect(await cache.readProfile('u1'), isNull);
    expect(await cache.readSocial('u1'), isNull);
  });

  test('one privacy save at a time; a failed one goes back to what the server has', () async {
    await profile.initialize();
    await pumpEventQueue();

    repo
      ..privacyGate = Completer<void>()
      ..writesDown = true;
    final first = profile.toggleSteamAchievementsPrivacy(false);
    expect(profile.showSteamAchievements, isFalse);
    expect(profile.savingSteamAchievementsPrivacy, isTrue);
    // Ignored while the first is on its way.
    expect(await profile.toggleSteamAchievementsPrivacy(true), isNull);
    expect(profile.showSteamAchievements, isFalse);

    repo.privacyGate!.complete();
    expect(await first, isNotNull);

    expect(profile.savingSteamAchievementsPrivacy, isFalse);
    expect(profile.showSteamAchievements, isTrue);
    expect(repo.showSteamAchievements, isTrue);
  });

  test('a saved privacy choice is kept in the saved copy of the profile', () async {
    await profile.initialize();
    await pumpEventQueue();

    expect(await profile.toggleSteamAchievementsPrivacy(false), isNull);
    await pumpEventQueue();

    expect(repo.showSteamAchievements, isFalse);
    expect((await cache.readProfile('u1'))!.value.showSteamAchievements, isFalse);
  });
}
