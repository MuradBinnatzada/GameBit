import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/models/company.dart';
import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/models/studio_filters.dart';
import 'package:checkpoint/services/game_api_service.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/utils/countries.dart';

import 'support/fakes.dart';

/// Answers every studio search with one studio, and notes what was asked.
class _StudioApi extends GameApiService {
  final List<({String query, StudioFilters filters})> searches = [];

  @override
  Future<ResultsPage<CompanySummary>?> searchCompanies(
    String query, {
    StudioFilters filters = StudioFilters.none,
    int offset = 0,
    int limit = GameApiService.searchPageSize,
  }) async {
    searches.add((query: query, filters: filters));
    return ResultsPage([
      const CompanySummary(
        id: 70,
        name: 'Nintendo',
        country: 392,
        foundedYear: 1889,
        developedCount: 120,
      ),
    ], hasMore: false);
  }
}

void main() {
  group('StudioFilters', () {
    test('nothing picked is empty, in the default order', () {
      expect(StudioFilters.none.isEmpty, isTrue);
      expect(StudioFilters.none.count, 0);
      expect(StudioFilters.none.toWire(), isEmpty);
      expect(StudioFilters.none.sort, StudioSort.popular);
    });

    test('counts the role, every country and the years', () {
      final filters = StudioFilters(
        role: CompanyRole.publisher,
        countries: [840, 392],
        founded: const YearRange(from: 2000),
      );

      expect(filters.isEmpty, isFalse);
      expect(filters.count, 4);
    });

    test('the order alone is no filter', () {
      final sorted = StudioFilters(sort: StudioSort.newest);

      expect(sorted.isEmpty, isTrue);
      expect(sorted.count, 0);
      expect(sorted.toWire(), isEmpty);
    });

    test('toggles a country, and clears everything but the order', () {
      var filters = StudioFilters(sort: StudioSort.name).toggleCountry(392);
      expect(filters.countries, {392});
      filters = filters.toggleCountry(840).toggleCountry(392);
      expect(filters.countries, {840});

      final cleared = filters.withRole(CompanyRole.developer).cleared();
      expect(cleared.isEmpty, isTrue);
      expect(cleared.sort, StudioSort.name);
    });

    test('is sent as only what is picked', () {
      final filters = StudioFilters(
        role: CompanyRole.developer,
        countries: [392],
        founded: const YearRange(from: 1990, to: 1999),
      );

      expect(filters.toWire(), {
        'role': 'developer',
        'countries': [392],
        'founded': {'from': 1990, 'to': 1999},
      });
      expect(StudioFilters(founded: const YearRange(to: 1999)).toWire(), {
        'founded': {'to': 1999},
      });
    });

    test(
      'equal filters are equal, whatever order the countries were picked in',
      () {
        expect(
          StudioFilters(countries: [392, 840]),
          StudioFilters(countries: [840, 392]),
        );
        expect(
          StudioFilters(countries: [392]),
          isNot(StudioFilters(countries: [840])),
        );
        expect(StudioFilters(sort: StudioSort.name), isNot(StudioFilters.none));
      },
    );
  });

  group('countryCodes', () {
    test('lists every country with a name once, the common ones first', () {
      final codes = countryCodes();

      expect(codes.take(3), [840, 392, 826]);
      expect(codes.toSet(), hasLength(codes.length));
      expect([for (final c in codes) countryName(c)], everyElement(isNotNull));
      expect(codes, contains(752));
    });
  });

  group('the Studios tab filters', () {
    late _StudioApi api;
    late AppStores stores;

    setUp(() {
      SharedPreferences.setMockInitialValues(onboardingSeenPrefs);
      api = _StudioApi();
      stores = AppStores(
        repository: FakeRepository(),
        authService: FakeAuthService(testUser('u1')),
        connectivity: FakeConnectivity(),
        apiService: api,
      );
    });

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> openStudios(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
      await tester.pump(const Duration(milliseconds: 400));
      stores.nav.select(NavTab.search);
      await settle(tester);
      await tester.tap(find.text('Studios'));
      await settle(tester);
    }

    testWidgets(
      'browse studios by country, role and years with no name typed',
      (tester) async {
        await openStudios(tester);
        expect(find.text('Find a studio'), findsOneWidget);

        await tester.tap(find.byTooltip('Filter'));
        await settle(tester);
        for (final title in ['Sort by', 'Role', 'Country', 'Founded']) {
          expect(find.text(title), findsOneWidget, reason: title);
        }
        await tester.tap(find.text('Japan'));
        await tester.tap(find.text('Developers'));
        await tester.pump();
        expect(find.text('2 filters picked'), findsOneWidget);
        expect(api.searches, isEmpty);

        await tester.tap(find.text('Show results'));
        await settle(tester);

        final expected = StudioFilters(
          role: CompanyRole.developer,
          countries: [392],
        );
        expect(api.searches.single, (query: '', filters: expected));
        expect(stores.search.studioFilters, expected);
        expect(find.text('Nintendo'), findsOneWidget);
        expect(find.text('Japan · Founded 1889'), findsOneWidget);
        expect(find.text('Find a studio'), findsNothing);
      },
    );

    testWidgets(
      'a chip lets go of its filter, and the studios are fetched again',
      (tester) async {
        await openStudios(tester);
        stores.search.filterStudios(StudioFilters(countries: [392, 840]), '');
        await settle(tester);
        expect(api.searches, hasLength(1));

        await tester.tap(find.byTooltip('Remove Japan'));
        await settle(tester);

        expect(api.searches.last.filters.countries, {840});
        expect(find.byTooltip('Remove Japan'), findsNothing);
      },
    );

    testWidgets(
      'clearing the last filter with an empty box goes back to the prompt',
      (tester) async {
        await openStudios(tester);
        stores.search.filterStudios(StudioFilters(countries: [392]), '');
        await settle(tester);
        expect(find.text('Nintendo'), findsOneWidget);

        await tester.tap(find.byTooltip('Remove Japan'));
        await settle(tester);

        expect(find.text('Find a studio'), findsOneWidget);
        expect(api.searches, hasLength(1));
      },
    );

    testWidgets('the filter button counts what is picked', (tester) async {
      await openStudios(tester);
      stores.search.filterStudios(
        StudioFilters(countries: [392], role: CompanyRole.publisher),
        '',
      );
      await settle(tester);

      expect(
        find.descendant(of: find.byType(Badge), matching: find.text('2')),
        findsOneWidget,
      );
    });
  });
}
