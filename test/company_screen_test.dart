import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/models/company.dart';
import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/screens/company/company_screen.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// A publisher's or developer's page, opened from a game's screen or from the
/// Studios search, on top of a fake IGDB.
void main() {
  late FakeRepository repo;
  late FakeCompanyApi api;
  late AppStores stores;
  const bethesda = 1;

  setUp(() {
    SharedPreferences.setMockInitialValues(onboardingSeenPrefs);
    repo = FakeRepository();
    api = FakeCompanyApi()
      ..answer = ((id) =>
          testDetails(igdbId: id, companyIds: {'Bethesda Softworks': bethesda}))
      ..company = ((id) => Company(
        id: id,
        name: 'Bethesda Softworks',
        country: 840,
        foundedYear: 1986,
        description: 'Publisher of The Elder Scrolls.',
        publishedCount: 120,
        developedCount: 0,
      ));
    stores = AppStores(
      repository: repo,
      authService: FakeAuthService(testUser('u1')),
      connectivity: FakeConnectivity(),
      apiService: api,
    );
  });

  Future<void> start(WidgetTester tester, Widget home) async {
    // Tall enough to have the whole page on screen.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: buildTheme(), home: home),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pumpAndSettle();
  }

  testWidgets("a game's publisher opens its page, with its info and games", (
    tester,
  ) async {
    repo.library = [testGame('g1', title: 'Skyrim', igdbId: 472, cover: false)];
    await start(tester, const GameDetailScreen(gameId: 'g1'));
    await tester.pumpAndSettle();

    // Only a company IGDB gave an id for opens a page.
    expect(
      find.widgetWithText(ActionChip, 'Bethesda Softworks'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(ActionChip, 'Bethesda Game Studios'),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(ActionChip, 'Bethesda Softworks'));
    await tester.pumpAndSettle();

    expect(find.byType(CompanyScreen), findsOneWidget);
    expect(api.companyCalls, [bethesda]);
    expect(find.text('Founded 1986 · United States'), findsOneWidget);
    expect(find.text('Publisher of The Elder Scrolls.'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
    expect(find.text('Game 1-any-1'), findsWidgets);
    expect(find.text('Game 1-any-2'), findsWidgets);
    // It developed nothing, so that list is not offered.
    expect(
      find.widgetWithText(SegmentedButton<CompanyRole>, 'Developed'),
      findsNothing,
    );

    await tester.tap(
      find.widgetWithText(SegmentedButton<CompanyRole>, 'Published'),
    );
    await tester.pumpAndSettle();

    expect(api.gameCalls.last, (
      (bethesda, CompanyRole.publisher, DiscoverSort.popular),
      0,
    ));
    expect(find.text('Game 1-publisher-1'), findsWidgets);
  });

  testWidgets('the Studios search finds a studio and opens its page', (
    tester,
  ) async {
    api.company = (id) =>
        Company(id: id, name: 'Valve', publishedCount: 30, developedCount: 25);
    await start(tester, const AppShell());
    stores.nav.select(NavTab.search);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Studios'));
    await tester.pumpAndSettle();
    expect(find.text('Find a studio'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'valve');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Studio valve'), findsOneWidget);
    await tester.tap(find.text('Studio valve'));
    await tester.pumpAndSettle();

    expect(find.byType(CompanyScreen), findsOneWidget);
    expect(find.text('Valve'), findsWidgets);
  });
}
