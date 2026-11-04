import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/screens/profile/edit_profile_screen.dart';
import 'package:checkpoint/screens/profile/profile_screen.dart';
import 'package:checkpoint/screens/settings/settings_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_state.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// An account icon, by the first line of its tooltip; the rest says whether the
/// account is verified.
Finder accountIcon(String name) => find.byWidgetPredicate(
  (w) => w is Tooltip && w.message?.split('\n').first == name,
);

/// The Profile tab: laid out like another member's page, with Edit Profile and
/// Settings under the counts, Sign out beside your name and your connected
/// accounts as icons above the bio.
void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late AppStores stores;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository()
      ..library = [
        testGame(
          'a',
          title: 'Alpha',
          favorite: true,
          status: GameStatus.completed,
        ),
        testGame('b', title: 'Bravo'),
      ]
      ..logs = [testLog('l1', 'a')];
    authService = FakeAuthService(testUser('u1'));
    stores = AppStores(
      repository: repo,
      authService: authService,
      connectivity: FakeConnectivity(),
    );
  });

  Future<void> open(WidgetTester tester, {double width = 800}) async {
    tester.view.physicalSize = Size(width, 4800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(
          theme: buildTheme(),
          home: const Scaffold(body: ProfileScreen()),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pumpAndSettle();
  }

  double top(WidgetTester tester, Finder finder) =>
      tester.getTopLeft(finder.first).dy;

  group('the page', () {
    testWidgets('is laid out like another member\'s, from your own library', (
      tester,
    ) async {
      repo.steamId = '76561198000000000';
      await open(tester);

      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('@ada'), findsOneWidget);
      expect(find.text('Member since Jan 2026'), findsOneWidget);

      final order = [
        top(tester, find.text('Favorite Games')),
        top(tester, find.text('Recent activity')),
        top(tester, find.textContaining('Total Playtime')),
        top(tester, find.text('Hours by platform')),
        top(tester, find.text('Ratings')),
        top(tester, find.text('Achievements')),
        top(tester, find.text('Wishlist')),
      ];
      expect(order, orderedEquals([...order]..sort()));

      expect(find.text('Total Playtime: 25 hours'), findsOneWidget); // 2 × 12.5
      expect(find.text('1.5 h · PC'), findsOneWidget); // the logged session
      expect(find.text('4.5'), findsOneWidget); // average rating
      expect(find.text('2 rated'), findsOneWidget);
    });

    testWidgets('has Sign out at the top right, level with the name', (
      tester,
    ) async {
      await open(tester);

      final signOut = find.byTooltip('Sign out');
      expect(signOut, findsOneWidget);
      expect(find.byIcon(Icons.logout_rounded), findsOneWidget);
      final name = tester.getRect(find.text('Ada'));
      final button = tester.getRect(signOut);
      expect(button.left, greaterThan(name.right));
      expect(button.center.dy, closeTo(name.center.dy, 8));
      // At the right edge of the page, where the Settings button ends.
      expect(
        button.right,
        closeTo(
          tester.getRect(find.widgetWithText(OutlinedButton, 'Settings')).right,
          12,
        ),
      );
      expect(find.text('Top rated'), findsOneWidget); // only the menu row
    });

    testWidgets('Sign out signs you out', (tester) async {
      await open(tester);

      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Sign out'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(stores.auth.isLoggedIn, isFalse);
    });

    testWidgets('Edit Profile and Settings sit side by side under the counts', (
      tester,
    ) async {
      await open(tester);

      final edit = find.widgetWithText(OutlinedButton, 'Edit Profile');
      final settings = find.widgetWithText(OutlinedButton, 'Settings');
      expect(edit, findsOneWidget);
      expect(settings, findsOneWidget);
      expect(top(tester, edit), top(tester, settings));
      expect(top(tester, find.text('Followers')), lessThan(top(tester, edit)));
      expect(
        top(tester, edit),
        lessThan(top(tester, find.text('Favorite Games'))),
      );
    });

    testWidgets('Settings opens the settings, Edit Profile the editor', (
      tester,
    ) async {
      await open(tester);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Edit Profile'));
      await tester.pumpAndSettle();
      expect(find.byType(EditProfileScreen), findsOneWidget);
    });

    testWidgets('the boxes and the menu open the Library tab', (tester) async {
      await open(tester);

      await tester.tap(find.text('Completed'));
      await tester.pumpAndSettle();
      expect(stores.nav.index, NavTab.library);
      expect(stores.libraryView.selectedStatus, GameStatus.completed);

      stores.nav.select(NavTab.profile);
      await tester.tap(find.text('Wishlist'));
      await tester.pumpAndSettle();
      expect(stores.libraryView.selectedStatus, GameStatus.wishlist);

      stores.nav.select(NavTab.profile);
      await tester.tap(find.text('Top rated'));
      await tester.pumpAndSettle();
      expect(stores.libraryView.selectedStatus, isNull);
      expect(stores.libraryView.sortField, SortField.rating);
      expect(stores.nav.index, NavTab.library);
    });
  });

  testWidgets('the header and the account icons fit a narrow phone', (
    tester,
  ) async {
    // No sessions: the test font is far wider than a real one, and the session
    // rows of the Recent activity panel (not part of this change) would not fit.
    repo
      ..logs = []
      ..steamId = '76561198000000000';
    await open(tester, width: 340);

    expect(tester.takeException(), isNull);
    expect(find.byType(FaIcon), findsNWidgets(ConnectedService.values.length));
    expect(find.byTooltip('Sign out'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Edit Profile'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Settings'), findsOneWidget);
  });

  group('connected accounts', () {
    testWidgets('nothing connected: no icons, and no box to connect them here', (
      tester,
    ) async {
      await open(tester);

      expect(find.byType(FaIcon), findsNothing);
      expect(find.text('Connected accounts'), findsNothing);
      expect(find.text('Connect accounts'), findsNothing);
      expect(find.text('Connect'), findsNothing);
      expect(find.text('Sync Library'), findsNothing);
    });

    testWidgets(
      'the connected account is a small icon above the bio and a link',
      (tester) async {
        repo.steamId = '76561198000000000';
        await open(tester);

        final icon = accountIcon('Open Steam profile');
        expect(icon, findsOneWidget);
        // Nothing else can be connected, so nothing else is shown.
        expect(find.byType(FaIcon), findsOneWidget);
        expect(accountIcon('Xbox'), findsNothing);
        expect(accountIcon('PSN'), findsNothing);
        expect(accountIcon('Nintendo'), findsNothing);

        // Under the name, above the counts.
        expect(top(tester, find.text('Ada')), lessThan(top(tester, icon)));
        expect(top(tester, icon), lessThan(top(tester, find.text('Followers'))));
        // The ID is in Settings, not on the page.
        expect(find.text('76561198000000000'), findsNothing);
        expect(find.text('Connect'), findsNothing);
      },
    );

    testWidgets('the icons sit above the bio', (tester) async {
      repo
        ..profileBio = 'Collector of platinum trophies.'
        ..steamId = '76561198000000000';
      await open(tester);

      expect(
        top(tester, accountIcon('Open Steam profile')),
        lessThan(top(tester, find.text('Collector of platinum trophies.'))),
      );
    });
  });
}
