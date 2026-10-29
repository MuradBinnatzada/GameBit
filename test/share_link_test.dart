import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/sign_in_panel.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/share_link.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/screens/lists/list_screen.dart';
import 'package:checkpoint/screens/profile/public_profile_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

void main() {
  const member = '11111111-2222-3333-4444-555555555555';

  test('reads the links it makes, and nothing else', () {
    expect(LinkTarget.parse('/game/1942'), const GameLink(1942));
    expect(LinkTarget.parse('/u/$member'), const MemberLink(member));
    expect(LinkTarget.parse('/list/$member/'), const ListLink(member));
    for (final bad in ['', '/', '/game/abc', '/game/0', '/u/not-an-id', '/list', '/other/1', '/game/1/extra']) {
      expect(LinkTarget.parse(bad), isNull, reason: bad);
    }
  });

  test('a link is the web app address with the target after #', () {
    expect(shareUrl(const GameLink(7), base: 'https://checkpoint.example'), 'https://checkpoint.example/#/game/7');
    expect(LinkTarget.parse(Uri.parse(shareUrl(const ListLink(member), base: 'https://x.y/app')!).fragment), const ListLink(member));
  });

  test('the address is the configured one, or on the web the one the app was opened at', () {
    expect(webAppUrl(isWeb: false, configured: 'https://a.b/'), 'https://a.b');
    expect(webAppUrl(isWeb: false, configured: ''), isNull);
    expect(webAppUrl(isWeb: true, configured: '', base: Uri.parse('https://a.b/app/#/game/1')), 'https://a.b/app');
  });

  group('opening a link', () {
    late FakeRepository repo;
    late FakeAuthService authService;

    Future<AppStores> start(WidgetTester tester, LinkTarget link) async {
      SharedPreferences.setMockInitialValues({});
      final stores = AppStores(
        repository: repo,
        authService: authService,
        connectivity: FakeConnectivity(),
        apiService: FakeDetailsApi(),
        initialLink: link,
      );
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: buildTheme(), home: const AppShell()),
      ));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      return stores;
    }

    setUp(() {
      repo = FakeRepository();
      authService = FakeAuthService();
    });

    testWidgets('a game link opens the game from the catalog, signed in or not', (tester) async {
      repo.catalog[1942] = testGame(gameIdForIgdb(1942), title: 'Shared game', status: null, igdbId: 1942, cover: false);
      final stores = await start(tester, const GameLink(1942));

      expect(find.byType(GameDetailScreen), findsOneWidget);
      expect(find.text('Shared game'), findsWidgets);
      expect(stores.links.pending, isNull);
    });

    testWidgets('a game the catalog does not have says so', (tester) async {
      await start(tester, const GameLink(5));
      expect(find.text("That game isn't in Gamebit yet."), findsOneWidget);
    });

    testWidgets('a profile link asks to sign in first, then opens the profile', (tester) async {
      final stores = await start(tester, const MemberLink(member));
      expect(find.byType(SignInScreen), findsOneWidget);
      expect(stores.links.pending, const MemberLink(member));

      authService.emit(testUser('u1'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.byType(PublicProfileScreen), findsOneWidget);
      expect(stores.links.pending, isNull);
    });

    testWidgets('a list link opens the list for a signed-in member', (tester) async {
      authService = FakeAuthService(testUser('u1'));
      await start(tester, const ListLink(member));
      expect(find.byType(ListScreen), findsOneWidget);
      expect(find.text('List not found'), findsOneWidget);
    });
  });
}
