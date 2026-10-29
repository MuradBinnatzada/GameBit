import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthApiException, AuthException, User;

import 'package:checkpoint/app/new_password_screen.dart';
import 'package:checkpoint/models/achievement_summary.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/screens/profile/edit_profile_screen.dart';
import 'package:checkpoint/screens/settings/privacy_section.dart';
import 'package:checkpoint/screens/settings/settings_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// Settings: Account, Security and Privacy, as a sidebar on a wide window and a
/// row of chips on a phone; Account holds the accounts to connect and, at the
/// bottom, the account deletion.
void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late FakeSteamLink steam;
  late AppStores stores;

  User googleUser() => User(
    id: 'u1',
    appMetadata: const {'provider': 'google'},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
    email: 'ada@example.com',
  );

  User emailUser() => User(
    id: 'u1',
    appMetadata: const {'provider': 'email'},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-01-01T00:00:00Z',
    email: 'ada@example.com',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    authService = FakeAuthService(googleUser());
    steam = FakeSteamLink(repo);
    stores = AppStores(
      repository: repo,
      authService: authService,
      connectivity: FakeConnectivity(),
      steamLink: steam,
    );
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(400, 900),
    SettingsSection section = SettingsSection.account,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(
          theme: buildTheme(),
          // Opened over a first screen, the way the Profile tab opens it.
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(initialSection: section),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, Finder finder) =>
      tester.getTopLeft(finder.first).dy;

  /// A phone tall enough to have the whole Connect accounts box on screen.
  const tall = Size(400, 1800);

  /// Lets what the stores do after a tap (saving to the device and the server)
  /// finish: that runs outside the test's fake clock.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  /// The row of the Connect accounts box that lists [label].
  Finder rowOf(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(Row)).first;

  Finder connectButton(String label) => find.descendant(
    of: rowOf(label),
    matching: find.widgetWithText(TextButton, 'Connect'),
  );

  /// Scrolls the Privacy section down to [text]; a phone doesn't fit all of it.
  Future<void> scrollPrivacyTo(WidgetTester tester, String text) =>
      tester.scrollUntilVisible(
        find.text(text),
        200,
        scrollable: find
            .descendant(
              of: find.byType(PrivacySection),
              matching: find.byType(Scrollable),
            )
            .first,
      );

  group('the sections', () {
    testWidgets('are chips across the head of a phone screen', (tester) async {
      await open(tester);

      for (final label in ['Account', 'Security', 'Privacy']) {
        expect(
          find.widgetWithText(ChoiceChip, label),
          findsOneWidget,
          reason: label,
        );
      }
      expect(find.byType(ListTile), findsNothing);
      // Account is first.
      expect(find.text('Signed in as'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Security'));
      await tester.pumpAndSettle();
      expect(find.text('Signed in as'), findsNothing);
      expect(find.text('Sign-in'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Privacy'));
      await tester.pumpAndSettle();
      expect(find.text('Visible to other signed-in members'), findsOneWidget);
      await scrollPrivacyTo(tester, 'Private to you');
      expect(find.text('Private to you'), findsOneWidget);
    });

    testWidgets('are a sidebar on a wide window', (tester) async {
      await open(tester, size: const Size(1100, 800));

      expect(find.byType(ChoiceChip), findsNothing);
      for (final label in ['Account', 'Security', 'Privacy']) {
        expect(
          find.widgetWithText(ListTile, label),
          findsOneWidget,
          reason: label,
        );
      }
      // The sidebar is to the left of what it shows.
      expect(
        tester.getTopLeft(find.widgetWithText(ListTile, 'Account')).dx,
        lessThan(tester.getTopLeft(find.text('Signed in as')).dx),
      );

      await tester.tap(find.widgetWithText(ListTile, 'Privacy'));
      await tester.pumpAndSettle();
      expect(find.text('Visible to other signed-in members'), findsOneWidget);
      expect(find.text('Signed in as'), findsNothing);
    });

    testWidgets('can be opened on a given section', (tester) async {
      await open(tester, section: SettingsSection.security);

      expect(find.text('Sign-in'), findsOneWidget);
      expect(find.text('Signed in as'), findsNothing);
    });
  });

  group('Account', () {
    testWidgets('says who is signed in', (tester) async {
      await open(tester);

      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('@ada'), findsOneWidget);
      expect(find.text('ada@example.com'), findsOneWidget);
    });

    testWidgets('has the account deletion at the very bottom', (tester) async {
      await open(tester, size: tall);

      final delete = find.widgetWithText(OutlinedButton, 'Delete account');
      await tester.ensureVisible(delete);
      expect(delete, findsOneWidget);
      for (final above in [
        find.text('Edit profile'),
        find.text('Connect accounts'),
        find.widgetWithText(OutlinedButton, 'Sign out'),
      ]) {
        expect(top(tester, above), lessThan(top(tester, delete)));
      }
    });

    testWidgets('has Clear library just above the account deletion', (tester) async {
      await open(tester, size: tall);

      final clear = find.widgetWithText(OutlinedButton, 'Clear library');
      final delete = find.widgetWithText(OutlinedButton, 'Delete account');
      await tester.ensureVisible(delete);
      expect(clear, findsOneWidget);
      expect(top(tester, find.widgetWithText(OutlinedButton, 'Sign out')), lessThan(top(tester, clear)));
      expect(top(tester, clear), lessThan(top(tester, delete)));
    });

    testWidgets('Clear library asks first, and empties the library when confirmed', (tester) async {
      repo.library = [testGame('a'), testGame('b')];
      await open(tester, size: tall);
      expect(stores.library.libraryGames, hasLength(2));

      final clear = find.widgetWithText(OutlinedButton, 'Clear library');
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.text('Clear your library?'), findsOneWidget);

      // Cancel: nothing happens.
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(repo.writes, isNot(contains('clear-library')));
      expect(stores.library.libraryGames, hasLength(2));

      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, 'Clear library'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(repo.writes, contains('clear-library'));
      expect(stores.library.libraryGames, isEmpty);
      expect(find.text('Your library was cleared'), findsOneWidget);
    });

    testWidgets('Clear library waits for a running sync without spinning itself', (tester) async {
      repo.steamId = '76561198000000000';
      await open(tester, size: tall);

      final clear = find.widgetWithText(OutlinedButton, 'Clear library');
      await tester.ensureVisible(clear);

      final sync = stores.library.syncLibrary();
      await tester.pump();

      expect(stores.library.isSyncing, isTrue);
      expect(tester.widget<OutlinedButton>(clear).onPressed, isNull);
      expect(
        find.descendant(of: clear, matching: find.byType(CircularProgressIndicator)),
        findsNothing,
      );

      await tester.pump(const Duration(seconds: 1));
      await sync;
      await tester.pumpAndSettle();

      expect(stores.library.isSyncing, isFalse);
      expect(tester.widget<OutlinedButton>(clear).onPressed, isNotNull);
    });

    testWidgets('Clear library also clears the achievements on your profile', (tester) async {
      repo.library = [testGame('a')];
      repo.achievementSummaries['u1'] = [
        const GameAchievementSummary(gameId: 'a', title: 'A', unlocked: 3, total: 10),
      ];
      await open(tester, size: tall);
      await tester.runAsync(() => stores.publicAchievements.loadTotals('u1'));
      expect(stores.publicAchievements.totalsOf('u1').totals.unlocked, 3);

      final clear = find.widgetWithText(OutlinedButton, 'Clear library');
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, 'Clear library'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      final totals = stores.publicAchievements.totalsOf('u1');
      expect(totals.status, LoadStatus.ready);
      expect(totals.totals.isEmpty, isTrue);
    });

    testWidgets(
      'Edit profile opens the editor, which no longer deletes accounts',
      (tester) async {
        await open(tester);

        await tester.tap(find.text('Edit profile'));
        await tester.pumpAndSettle();

        expect(find.byType(EditProfileScreen), findsOneWidget);
        expect(find.text('Delete account'), findsNothing);
        expect(find.byIcon(Icons.delete_forever_rounded), findsNothing);
      },
    );

    testWidgets('Sign out signs out and leaves Settings', (tester) async {
      await open(tester, size: tall);

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(OutlinedButton, 'Sign out'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(stores.auth.isLoggedIn, isFalse);
      expect(find.byType(SettingsScreen), findsNothing);
    });
  });

  group('Connect accounts', () {
    testWidgets(
      'lists every service under Game profiles and Social media, with Connect on each',
      (tester) async {
        await open(tester, size: tall);

        expect(find.text('GAME PROFILES'), findsOneWidget);
        expect(find.text('SOCIAL MEDIA'), findsOneWidget);
        for (final s in ConnectedService.values) {
          expect(find.text(s.label), findsOneWidget, reason: s.label);
          expect(connectButton(s.label), findsOneWidget, reason: s.label);
        }
        expect(
          find.text('Not connected'),
          findsNWidgets(ConnectedService.values.length),
        );
        // Nothing to sync without a Steam account.
        expect(find.text('Sync Library'), findsNothing);
      },
    );

    testWidgets('connecting Instagram asks for the username and saves it', (
      tester,
    ) async {
      await open(tester, size: tall);

      await tester.tap(connectButton('Instagram'));
      await tester.pumpAndSettle();
      expect(find.text('Connect Instagram'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '@ada.plays');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      await settle(tester);

      expect(stores.profile.isConnected(ConnectedService.instagram), isTrue);
      expect(stores.profile.instagramId, 'ada.plays');
      expect(repo.savedInstagramId, 'ada.plays');
      expect(find.text('@ada.plays'), findsOneWidget);
      expect(find.byTooltip('Open Instagram profile'), findsOneWidget);
    });

    testWidgets(
      'a username the service does not allow is refused in the dialog',
      (tester) async {
        await open(tester, size: tall);

        await tester.tap(connectButton('Twitch'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'not a name');
        await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
        await tester.pumpAndSettle();

        expect(find.text("That isn't a valid Twitch username"), findsOneWidget);
        expect(stores.profile.isConnected(ConnectedService.twitch), isFalse);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(stores.profile.isConnected(ConnectedService.twitch), isFalse);
      },
    );

    testWidgets(
      'a connected service can be renamed and disconnected from its menu',
      (tester) async {
        // On the server already, as if connected on this or another device.
        repo
          ..connectedServices = {ConnectedService.psn}
          ..savedPsnId = 'ps_user';
        await open(tester, size: tall);
        expect(find.text('ps_user'), findsOneWidget);

        await tester.tap(
          find.descendant(
            of: rowOf('PSN'),
            matching: find.byIcon(Icons.more_vert_rounded),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Change username'));
        await tester.pumpAndSettle();
        expect(find.text('Change PSN username'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'new_name');
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        await settle(tester);
        expect(stores.profile.psnId, 'new_name');
        expect(repo.savedPsnId, 'new_name');

        await tester.tap(
          find.descendant(
            of: rowOf('PSN'),
            matching: find.byIcon(Icons.more_vert_rounded),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Disconnect'));
        await tester.pumpAndSettle();
        expect(find.text('Disconnect PSN?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
        await tester.pumpAndSettle();
        await settle(tester);

        expect(stores.profile.isConnected(ConnectedService.psn), isFalse);
        expect(repo.connectedServices, isEmpty);
        expect(connectButton('PSN'), findsOneWidget);
      },
    );

    testWidgets('cancelling the disconnect keeps the account', (tester) async {
      repo.steamId = '76561198000000000';
      await open(tester, size: tall);

      await tester.tap(
        find.descendant(
          of: rowOf('Steam'),
          matching: find.byIcon(Icons.more_vert_rounded),
        ),
      );
      await tester.pumpAndSettle();
      // A Steam ID is proved by signing in, never typed: nothing to change.
      expect(find.text('Change Steam ID'), findsNothing);
      expect(find.text('Change username'), findsNothing);
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(stores.profile.steamConnected, isTrue);
      expect(repo.steamId, '76561198000000000');
    });

    testWidgets(
      'connecting Steam signs in through Steam and brings the sync button',
      (tester) async {
        await open(tester, size: tall);
        expect(find.text('Sync Library'), findsNothing);
        steam.gate = Completer<void>();

        await tester.tap(connectButton('Steam'));
        await tester.pump();
        // Steam's page is open; the app waits for it, and asks for no ID.
        expect(find.text('Connect Steam'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(steam.opened.single.host, 'steamcommunity.com');

        steam.gate!.complete();
        await tester.pumpAndSettle();
        await settle(tester);

        expect(find.text('Connect Steam'), findsNothing);
        expect(find.text('Steam connected.'), findsOneWidget);
        expect(stores.profile.steamConnected, isTrue);
        // The server saved it; the app wrote no Steam ID.
        expect(repo.writes.where((w) => w.startsWith('steam:')), isEmpty);
        expect(find.text('Sync Library'), findsOneWidget);
      // The sync button belongs to the game profiles, above Social media.
        expect(
          top(tester, find.text('Sync Library')),
          lessThan(top(tester, find.text('SOCIAL MEDIA'))),
        );
      },
    );

    testWidgets('cancelling the Steam sign-in stops waiting and connects nothing', (
      tester,
    ) async {
      await open(tester, size: tall);
      steam.gate = Completer<void>();

      await tester.tap(connectButton('Steam'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Connect Steam'), findsNothing);
      expect(steam.cancels, 1);
      expect(stores.profile.linkingSteam, isFalse);

      // Steam's page comes back after all: the app was no longer waiting.
      steam.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Steam connected.'), findsNothing);
    });
  });

  group('Security', () {
    testWidgets(
      'shows how the account signs in and where its password is managed',
      (tester) async {
        await open(tester, section: SettingsSection.security);

        expect(find.text('Google'), findsOneWidget);
        expect(find.text('ada@example.com'), findsOneWidget);
        expect(find.text('Manage your Google Account'), findsOneWidget);
        // Google keeps the password.
        expect(find.text('Change password'), findsNothing);
      },
    );

    Future<void> savePassword(WidgetTester tester, String password) async {
      await tester.tap(find.text('Change password'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'New password'),
        password,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm new password'),
        password,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Save password'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
    }

    testWidgets('an email account can change its password', (tester) async {
      authService.user = emailUser();
      await open(tester, section: SettingsSection.security);

      expect(find.text('Email and password'), findsOneWidget);
      expect(find.text('Manage your Google Account'), findsNothing);

      await savePassword(tester, 'correct horse');

      expect(authService.passwordUpdates, ['correct horse']);
      expect(find.byType(NewPasswordScreen), findsNothing);
      expect(find.text('Password changed'), findsOneWidget);
      expect(stores.auth.isLoggedIn, isTrue);
    });

    testWidgets('says why a new password was refused', (tester) async {
      authService.user = emailUser();
      authService.passwordError = const AuthApiException(
        'New password should be different from the old password.',
        statusCode: '422',
        code: 'same_password',
      );
      await open(tester, section: SettingsSection.security);

      await savePassword(tester, 'hunter22');

      expect(
        find.text('That is your current password. Choose a different one.'),
        findsOneWidget,
      );
      expect(find.byType(NewPasswordScreen), findsOneWidget);
    });

    testWidgets('signs out the other devices and keeps this one', (
      tester,
    ) async {
      await open(tester, section: SettingsSection.security);

      // Below the two-factor switch.
      await tester.ensureVisible(find.text('Sign out other devices'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Sign out other devices'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(authService.signOutOthersCalls, 1);
      expect(stores.auth.isLoggedIn, isTrue);
      expect(find.text('Signed out of your other devices'), findsOneWidget);
    });

    testWidgets('says so when that fails', (tester) async {
      authService.signOutOthersError = AuthException('Session expired');
      await open(tester, section: SettingsSection.security);

      // Below the two-factor switch.
      await tester.ensureVisible(find.text('Sign out other devices'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Sign out other devices'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(find.text('Session expired'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Sign out other devices'),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('Privacy', () {
    testWidgets('lists what other members see and what stays private', (
      tester,
    ) async {
      await open(tester, section: SettingsSection.privacy);

      for (final text in [
        'Profile',
        'Library',
        'Recent activity',
        'Connected accounts',
        'Email address',
        'Purchase prices',
        'Session notes',
      ]) {
        await scrollPrivacyTo(tester, text);
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.textContaining('Instagram and Twitch'), findsOneWidget);
    });

    SwitchListTile achievementsSwitch(WidgetTester tester) => tester.widget(
      find.widgetWithText(SwitchListTile, 'Show Steam Achievements'),
    );

    Future<void> tapSwitch(WidgetTester tester) async {
      await tester.tap(find.text('Show Steam Achievements'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pumpAndSettle();
    }

    testWidgets('Show Steam Achievements is on until turned off, and is saved', (
      tester,
    ) async {
      await open(tester, section: SettingsSection.privacy);

      expect(
        find.text(
          'Allow other players to view your Steam achievements on your public profile.',
        ),
        findsOneWidget,
      );
      expect(achievementsSwitch(tester).value, isTrue);

      await tapSwitch(tester);

      expect(achievementsSwitch(tester).value, isFalse);
      expect(stores.profile.showSteamAchievements, isFalse);
      expect(repo.showSteamAchievements, isFalse);
      expect(repo.writes, ['show-achievements:false']);

      await tapSwitch(tester);

      expect(achievementsSwitch(tester).value, isTrue);
      expect(repo.showSteamAchievements, isTrue);
    });

    testWidgets('lists the blocked members, and opens the policy, the terms and a way to write to us', (
      tester,
    ) async {
      repo.blockedMembers['b'] = testMember('b', name: 'Bob');
      await open(tester, size: const Size(400, 2600), section: SettingsSection.privacy);

      expect(find.text('Terms of Use'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('Contact us'), findsOneWidget);
      // There is nowhere to send crash reports in a build without a DSN, so no switch.
      expect(find.text('Send crash reports'), findsNothing);

      await tester.tap(find.byIcon(Icons.person_off_outlined).first);
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Unblock'), findsOneWidget);
    });

    testWidgets('shows the saved choice', (tester) async {
      repo.showSteamAchievements = false;
      await open(tester, section: SettingsSection.privacy);

      expect(achievementsSwitch(tester).value, isFalse);
    });

    testWidgets('moves at once, and goes back with a message when the save fails', (
      tester,
    ) async {
      await open(tester, section: SettingsSection.privacy);
      repo
        ..privacyGate = Completer<void>()
        ..rejectWrites = true;

      await tester.tap(find.text('Show Steam Achievements'));
      await tester.pump();
      // Before the server answers: moved, and waiting for the save.
      expect(achievementsSwitch(tester).value, isFalse);
      expect(achievementsSwitch(tester).onChanged, isNull);

      repo.privacyGate!.complete();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pumpAndSettle();

      expect(achievementsSwitch(tester).value, isTrue);
      expect(repo.showSteamAchievements, isTrue);
      expect(
        find.text('Could not save your privacy setting. Please try again.'),
        findsOneWidget,
      );
    });

    testWidgets('is not kept for later when the server cannot be reached', (
      tester,
    ) async {
      await open(tester, section: SettingsSection.privacy);
      repo.writesDown = true;

      await tapSwitch(tester);

      expect(achievementsSwitch(tester).value, isTrue);
      expect(find.textContaining('was not changed'), findsOneWidget);
    });
  });
}
