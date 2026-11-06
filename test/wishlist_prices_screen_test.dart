import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/screens/home/home_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// Prices on the screens: Home's Wishlist Deals row and a wishlist game's Price
/// panel.
void main() {
  late FakeRepository repo;
  late FakePriceApi priceApi;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    priceApi = FakePriceApi();
  });

  Game wish(String id, String title) =>
      testGame(id, title: title, cover: false, status: GameStatus.wishlist, igdbId: id.hashCode & 0xffff);

  Future<void> start(WidgetTester tester, Widget home) async {
    // Tall enough to have the whole page built.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final stores = AppStores(
      repository: repo,
      authService: FakeAuthService(testUser('u1')),
      connectivity: FakeConnectivity(),
      apiService: FakeBrowseApi()
        ..answer = (mode, offset) => ResultsPage([testEntry('hot-1', title: 'Hot Game', score: 91.6)], hasMore: false),
      priceApi: priceApi,
    );
    await tester.runAsync(() async {
      await stores.initialize();
      // The prices are asked for once the library is in.
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: buildTheme(), home: Scaffold(body: home)),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pumpAndSettle();
  }

  group('Home', () {
    testWidgets('lists the wishlist games on sale, with the cut and the price', (tester) async {
      repo.library = [wish('a', 'Alpha'), wish('b', 'Beta'), wish('c', 'Gamma')];
      priceApi.answers
        ..['a'] = testPrice(50)
        ..['b'] = testPrice(0, amount: 40);

      await start(tester, const HomeScreen());

      expect(find.text('Wishlist Deals'), findsOneWidget);
      expect(find.text('−50% · €20.00'), findsOneWidget);
      expect(find.text('Alpha'), findsWidgets);
      // Beta is not on sale and Gamma has no price: neither is in the row.
      expect(find.textContaining('€40.00'), findsNothing);
    });

    testWidgets('has no row when nothing on the wishlist is on sale', (tester) async {
      repo.library = [wish('a', 'Alpha')];
      priceApi.answers['a'] = testPrice(0, amount: 40);

      await start(tester, const HomeScreen());

      expect(find.text('Wishlist Deals'), findsNothing);
    });

    testWidgets('has no row when the prices could not be had', (tester) async {
      repo.library = [wish('a', 'Alpha')];
      priceApi.fail = true;

      await start(tester, const HomeScreen());

      expect(find.text('Wishlist Deals'), findsNothing);
    });
  });

  group('a game\'s screen', () {
    testWidgets('shows the price, the cut, the store and a link to it', (tester) async {
      repo.library = [wish('a', 'Alpha')];
      priceApi.answers['a'] = testPrice(50, low: 12.5);

      await start(tester, const GameDetailScreen(gameId: 'a'));

      expect(find.text('Price'), findsOneWidget);
      expect(find.text('€20.00'), findsOneWidget);
      expect(find.text('€40.00'), findsOneWidget);
      expect(find.text('−50%'), findsOneWidget);
      expect(find.text('at Steam'), findsOneWidget);
      expect(find.text('Lowest ever: €12.50'), findsOneWidget);
      expect(find.text('Lowest price ever'), findsNothing);
      expect(find.text('See it at Steam'), findsOneWidget);
      expect(find.text('Prices from IsThereAnyDeal'), findsOneWidget);
    });

    testWidgets('says so when the price is the lowest the game has had', (tester) async {
      repo.library = [wish('a', 'Alpha')];
      priceApi.answers['a'] = testPrice(50, low: 20);

      await start(tester, const GameDetailScreen(gameId: 'a'));

      expect(find.text('Lowest price ever'), findsOneWidget);
      expect(find.textContaining('Lowest ever:'), findsNothing);
    });

    testWidgets('says when the sale ends, if it still runs', (tester) async {
      repo.library = [wish('a', 'Alpha'), wish('b', 'Beta')];
      priceApi.answers
        ..['a'] = testPrice(50, expiry: DateTime.now().add(const Duration(days: 3)))
        ..['b'] = testPrice(50, expiry: DateTime.now().subtract(const Duration(days: 1)));

      await start(tester, const GameDetailScreen(gameId: 'a'));
      expect(find.textContaining('Sale ends'), findsOneWidget);
    });

    testWidgets('a sale that has ended is not announced', (tester) async {
      repo.library = [wish('b', 'Beta')];
      priceApi.answers['b'] = testPrice(50, expiry: DateTime.now().subtract(const Duration(days: 1)));

      await start(tester, const GameDetailScreen(gameId: 'b'));

      expect(find.text('Price'), findsOneWidget);
      expect(find.textContaining('Sale ends'), findsNothing);
    });

    testWidgets('a game at its regular price shows the price without a cut', (tester) async {
      repo.library = [wish('a', 'Alpha')];
      priceApi.answers['a'] = testPrice(0, amount: 40);

      await start(tester, const GameDetailScreen(gameId: 'a'));

      expect(find.text('€40.00'), findsOneWidget);
      expect(find.textContaining('−'), findsNothing);
    });

    testWidgets('has no panel for a game with no price', (tester) async {
      repo.library = [wish('a', 'Alpha')];

      await start(tester, const GameDetailScreen(gameId: 'a'));

      expect(find.text('Price'), findsNothing);
      expect(find.text('Prices from IsThereAnyDeal'), findsNothing);
    });

    testWidgets('has no panel for a game that is not on the wishlist', (tester) async {
      repo.library = [testGame('a', title: 'Alpha', cover: false)];
      priceApi.answers['a'] = testPrice(50);

      await start(tester, const GameDetailScreen(gameId: 'a'));

      expect(find.text('Price'), findsNothing);
      // Nobody asked about it either.
      expect(priceApi.calls, isEmpty);
    });
  });
}
