import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException, FunctionException;

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/screens/settings/account_section.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/services/pending_edits.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// Renders the real app shell (all four tabs) on top of fake data sources.
void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late AppStores stores;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    authService = FakeAuthService();
    stores = AppStores(
      repository: repo,
      authService: authService,
      connectivity: FakeConnectivity(),
      // Home asks IGDB for what is popular.
      apiService: FakeBrowseApi(),
    );
  });

  Future<void> start(WidgetTester tester) async {
    // As in the app: the stores start before the first frame.
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: buildTheme(), home: const AppShell()),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
  }

  testWidgets('shows the saved library with an offline banner when the server is down', (tester) async {
    await tester.runAsync(() async {
      final cache = LocalCache();
      await cache.writeLibrary('u1', [
        testGame('a', title: 'Saved Alpha', cover: false),
        testGame('b', title: 'Saved Bravo', cover: false),
      ]);
    });
    authService.user = testUser('u1');
    repo.offline = true;
    await start(tester);

    stores.nav.select(NavTab.library);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('SAVED ALPHA'), findsWidgets);
    expect(find.text('SAVED BRAVO'), findsWidgets);
    expect(find.textContaining('Can\'t reach Gamebit'), findsOneWidget);
    expect(find.text('Could not load library'), findsNothing);
  });

  testWidgets('shows a load error, not a banner, when there is nothing saved', (tester) async {
    authService.user = testUser('u1');
    repo.offline = true;
    await start(tester);

    stores.nav.select(NavTab.library);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Could not load library'), findsWidgets);
    expect(find.textContaining('Can\'t reach Gamebit'), findsNothing);
  });

  testWidgets('the banner goes away once Retry reaches the server', (tester) async {
    await tester.runAsync(() async {
      await LocalCache().writeLibrary('u1', [testGame('a', title: 'Saved Alpha', cover: false)]);
    });
    authService.user = testUser('u1');
    repo.offline = true;
    await start(tester);
    stores.nav.select(NavTab.library);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Can\'t reach Gamebit'), findsOneWidget);

    repo.offline = false;
    repo.library = [testGame('a', title: 'Fresh Alpha', cover: false)];
    await tester.tap(find.text('Retry').first);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('Can\'t reach Gamebit'), findsNothing);
    expect(find.text('FRESH ALPHA'), findsWidgets);
  });

  testWidgets('follows queued while offline count in the banner', (tester) async {
    await tester.runAsync(() async {
      await LocalCache().writeLibrary('u1', [testGame('a', title: 'Saved Alpha', cover: false)]);
    });
    authService.user = testUser('u1');
    repo.offline = true;
    await start(tester);
    stores.nav.select(NavTab.library);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('will sync'), findsNothing);

    await tester.runAsync(() => stores.profile.toggleFollow('x'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('1 change will sync when you\'re back online'), findsOneWidget);
    expect(find.text(queuedNotice), findsOneWidget); // the snack bar, from the profile store
  });

  testWidgets('a queued follow shows in the banner even if the library loaded fine', (tester) async {
    repo.library = [testGame('a', title: 'Fresh Alpha', cover: false)];
    authService.user = testUser('u1');
    await start(tester);
    stores.nav.select(NavTab.library);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Can\'t reach Gamebit'), findsNothing);

    repo.writesDown = true;
    await tester.runAsync(() => stores.profile.toggleFollow('x'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('1 change is waiting to sync'), findsOneWidget);
    expect(find.textContaining('Can\'t reach Gamebit'), findsNothing);
  });

  testWidgets('Settings shows "Sync Delayed" when Steam is rate limiting, and the next sync clears it', (tester) async {
    repo.steamId = '76561198000000000';
    repo.syncError = const FunctionException(
      status: 429,
      details: {'code': 'STEAM_RATE_LIMITED', 'retry_after': 300},
    );
    authService.user = testUser('u1');
    await start(tester);
    stores.nav.select(NavTab.profile);
    await tester.pump(const Duration(milliseconds: 400));
    // The sync lives with the Steam account, under Connect accounts in Settings.
    expect(find.text('Sync Library'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Settings'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sync Delayed'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Sync Library'),
      300,
      scrollable: find.descendant(
        of: find.byType(AccountSection),
        matching: find.byType(Scrollable),
      ),
    );
    // Built can still mean below the window: bring it fully on screen.
    await tester.ensureVisible(find.text('Sync Library'));
    await tester.pump();
    await tester.tap(find.text('Sync Library'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Sync Delayed'), findsOneWidget);
    expect(find.text('Retry Sync'), findsOneWidget);
    expect(find.text('Sync Library'), findsNothing);
    // The same words in the notice and in the snack bar.
    expect(find.textContaining('Steam is limiting requests right now. Try again in 5 minutes.'), findsWidgets);

    repo.syncError = null;
    await tester.tap(find.text('Retry Sync'));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Sync Delayed'), findsNothing);
    expect(find.text('Sync Library'), findsOneWidget);
    expect(find.text('Library synced successfully'), findsOneWidget);
  });

  testWidgets('every tab builds for a signed-out visitor', (tester) async {
    await start(tester);

    for (final tab in [NavTab.search, NavTab.library, NavTab.profile, NavTab.home]) {
      stores.nav.select(tab);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      // Library and Profile sit behind the log-in overlay.
      expect(
        find.text('Log in to track games'),
        tab == NavTab.library || tab == NavTab.profile ? findsOneWidget : findsNothing,
      );
    }
  });

  testWidgets('a Google sign-in that fails says why instead of doing nothing', (tester) async {
    authService.signInError = AuthException('Google sign-in was cancelled.');
    await start(tester);
    stores.nav.select(NavTab.library);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Continue with Google'));
    await tester.pump();

    expect(find.text('Google sign-in was cancelled.'), findsOneWidget);
    expect(stores.auth.isLoggedIn, isFalse);
  });

  testWidgets('a Google sign-in that works lifts the log-in overlay', (tester) async {
    await start(tester);
    stores.nav.select(NavTab.library);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Continue with Google'));
    // The stores load the account that signed in.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 400));

    expect(stores.auth.isLoggedIn, isTrue);
    expect(find.text('Log in to track games'), findsNothing);
  });
}
