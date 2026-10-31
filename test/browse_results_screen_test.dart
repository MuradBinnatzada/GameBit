import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/models/browse.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/screens/search/browse_results_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// Discover's "Browse by" rows opening their lists, on top of a fake IGDB.
void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late FakeBrowseApi api;
  late AppStores stores;

  setUp(() {
    SharedPreferences.setMockInitialValues(onboardingSeenPrefs);
    repo = FakeRepository();
    authService = FakeAuthService(testUser('u1'));
    api = FakeBrowseApi();
    stores = AppStores(
      repository: repo,
      authService: authService,
      connectivity: FakeConnectivity(),
      apiService: api,
    );
  });

  /// The app shell on the Discover tab.
  Future<void> start(WidgetTester tester) async {
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
    stores.nav.select(NavTab.search);
    await tester.pumpAndSettle();
  }

  Future<void> openList(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'each Browse by row opens its list as a grid of poster cards, not a snack bar',
    (tester) async {
      await start(tester);

      for (final mode in BrowseMode.values) {
        await openList(tester, mode.label);

        expect(
          find.byType(BrowseResultsScreen),
          findsOneWidget,
          reason: mode.label,
        );
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text(mode.label),
          ),
          findsOneWidget,
        );
        expect(
          find.text('Game ${mode.name}-1'),
          findsOneWidget,
          reason: mode.label,
        );
        expect(
          find.text('Game ${mode.name}-2'),
          findsOneWidget,
          reason: mode.label,
        );
        expect(find.byType(SnackBar), findsNothing);

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(BrowseResultsScreen), findsNothing);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a poster says what its list is about', (tester) async {
    api.answer = (mode, offset) => ResultsPage([
      testEntry('g1', score: 91.6, released: DateTime.utc(2026, 10, 14)),
    ], hasMore: false);
    await start(tester);

    await openList(tester, 'Highest rated');
    expect(find.text('92 / 100'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await openList(tester, 'New releases');
    expect(find.text('Oct 14'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await openList(tester, 'Most popular');
    expect(find.text('RPG'), findsOneWidget); // the first genre
    expect(find.text('Not rated'), findsNothing);
  });

  testWidgets(
    'a list is fetched once: opening it again, or switching tabs and back, reuses it',
    (tester) async {
      await start(tester);

      await openList(tester, 'Most popular');
      await tester.pageBack();
      await tester.pumpAndSettle();
      stores.nav.select(NavTab.library);
      await tester.pumpAndSettle();
      stores.nav.select(NavTab.search);
      await tester.pumpAndSettle();
      await openList(tester, 'Most popular');

      expect(find.text('Game popular-1'), findsOneWidget);
      expect(api.callsFor(BrowseMode.popular), 1);
    },
  );

  testWidgets('shows a spinner while the first page loads', (tester) async {
    // Held from the start: Home asks for the popular list as soon as it builds,
    // and the list screen shows that same request.
    api.gate = Completer<void>();
    await start(tester);

    await tester.tap(find.text('Most popular'));
    await tester.pump(); // push
    await tester.pump(
      const Duration(milliseconds: 400),
    ); // route transition + load starts

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Game popular-1'), findsNothing);

    api.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Game popular-1'), findsOneWidget);
  });

  testWidgets('a failed load offers Try again, which loads the list', (
    tester,
  ) async {
    api.answer = (mode, offset) => null;
    await start(tester);

    await openList(tester, 'Highest rated');
    expect(find.text('Couldn’t load games'), findsOneWidget);

    api.answer = (mode, offset) =>
        ResultsPage([testEntry('g1')], hasMore: false);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('Couldn’t load games'), findsNothing);
    expect(find.text('Game g1'), findsOneWidget);
  });

  testWidgets('a guest is asked to log in, not to retry', (tester) async {
    authService.user = null;
    api.answer = (mode, offset) => null;
    await start(tester);

    await openList(tester, 'Most popular');

    expect(find.text('Log in to browse games'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('scrolling to the end loads the next page', (tester) async {
    api.answer = (mode, offset) => offset == 0
        ? ResultsPage([
            for (var i = 0; i < 30; i++) testEntry('p$i'),
          ], hasMore: true)
        : ResultsPage([testEntry('last')], hasMore: false);
    await start(tester);
    await openList(tester, 'Most popular');
    expect(find.text('Game last', skipOffstage: false), findsNothing);

    await tester.dragUntilVisible(
      find.text('Game last'),
      find.byType(CustomScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    expect(find.text('Game last'), findsOneWidget);
    expect(api.calls, [(BrowseMode.popular, 0), (BrowseMode.popular, 30)]);
  });

  testWidgets(
    'tapping a poster opens the game, though it is neither in the library nor a search result',
    (tester) async {
      await start(tester);
      await openList(tester, 'Most popular');

      await tester.tap(find.text('Game popular-1'));
      await tester.pumpAndSettle();

      expect(find.byType(GameDetailScreen), findsOneWidget);
      expect(find.text('Game not found'), findsNothing);
      expect(find.text('Game popular-1'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lays out three posters to a row on a phone, even at the largest text size',
    (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(() {
        tester.view.reset();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      const longTitle =
          'A Very Long Game Title That Cannot Possibly Fit On One Line';
      api.answer = (mode, offset) => ResultsPage([
        testEntry('g1', title: longTitle, released: DateTime.utc(2026, 10, 14)),
        testEntry('g2', released: DateTime.utc(2026, 10, 3)),
        testEntry('g3', released: DateTime.utc(2026, 9, 28)),
        testEntry('g4', released: DateTime.utc(2026, 9, 27)),
      ], hasMore: false);
      await start(tester);

      await openList(tester, 'New releases');

      // A layout overflow would be reported as an exception.
      expect(tester.takeException(), isNull);
      double top(String title) => tester.getTopLeft(find.text(title)).dy;
      expect(top('Game g2'), top(longTitle));
      expect(top('Game g3'), top(longTitle));
      expect(top('Game g4'), greaterThan(top(longTitle)));
    },
  );
}
