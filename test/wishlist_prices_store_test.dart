import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/wishlist_prices_store.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRepository repo;
  late FakeAuthService authService;
  late FakePriceApi api;
  late AppStores stores;
  late DateTime now;

  Game wish(String id, {String? title}) =>
      testGame(id, title: title, cover: false, status: GameStatus.wishlist, igdbId: id.hashCode & 0xffff);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  AppStores newStores() => AppStores(
    repository: repo,
    authService: authService,
    connectivity: FakeConnectivity(),
    apiService: FakeBrowseApi(),
    priceApi: api,
  );

  /// A second store, with a clock the test moves; make it once the first is running
  /// (it learns who is signed in from the auth store, as in the app).
  WishlistPricesStore clocked() {
    final store = WishlistPricesStore(
      auth: stores.auth,
      library: stores.library,
      api: api,
      clock: () => now,
    )..initialize();
    addTearDown(store.dispose);
    return store;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 11, 7, 12);
    api = FakePriceApi();
    repo = FakeRepository()
      ..library = [wish('a', title: 'Alpha'), wish('b', title: 'Beta'), testGame('owned', cover: false)];
    authService = FakeAuthService(testUser('u1'));
    stores = newStores();
  });

  tearDown(() => stores.dispose());

  test('asks once the library has loaded, and only about the wishlist', () async {
    api.answers['a'] = testPrice(50);

    await stores.initialize();
    await settle();

    expect(api.calls, [
      ['a', 'b'],
    ]);
    expect(stores.wishlistPrices.priceFor('a')!.cut, 50);
    expect(stores.wishlistPrices.priceFor('b'), isNull);
    expect(stores.wishlistPrices.priceFor('owned'), isNull);
  });

  test('a game with no price is not asked about again', () async {
    await stores.initialize();
    await settle();
    expect(api.calls, hasLength(1));

    await stores.wishlistPrices.refresh();
    await stores.library.importGame(testGame('c', cover: false), status: GameStatus.playing);
    await settle();

    expect(api.calls, hasLength(1));
  });

  test('a game added to the wishlist is the only one asked about', () async {
    await stores.initialize();
    await settle();
    api.answers['c'] = testPrice(30);

    await stores.library.importGame(wish('c'), status: GameStatus.wishlist);
    await settle();

    expect(api.calls, [
      ['a', 'b'],
      ['c'],
    ]);
    expect(stores.wishlistPrices.priceFor('c')!.cut, 30);
  });

  test('the deals are the wishlist games on sale, and follow the wishlist', () async {
    api.answers
      ..['a'] = testPrice(20)
      ..['b'] = testPrice(0, amount: 40);
    await stores.initialize();
    await settle();

    expect([for (final d in stores.wishlistPrices.deals) d.game.id], ['a']);

    await stores.library.setStatus('a', GameStatus.playing);
    await settle();

    expect(stores.wishlistPrices.deals, isEmpty);
  });

  test('prices are asked again after three hours', () async {
    await stores.initialize();
    await settle();
    final store = clocked();
    await settle();
    final before = api.calls.length;

    now = now.add(WishlistPricesStore.freshFor - const Duration(minutes: 1));
    await store.refresh();
    expect(api.calls, hasLength(before));

    now = now.add(const Duration(minutes: 2));
    await store.refresh();
    expect(api.calls, hasLength(before + 1));
    expect(api.calls.last, ['a', 'b']);
  });

  test('a failed request shows nothing, and is not repeated for five minutes', () async {
    api.fail = true;
    await stores.initialize();
    await settle();
    final store = clocked();
    await settle();
    final failed = api.calls.length;
    expect(store.priceFor('a'), isNull);
    expect(store.deals, isEmpty);

    now = now.add(WishlistPricesStore.retryAfterFailure - const Duration(seconds: 1));
    await store.refresh();
    expect(api.calls, hasLength(failed));

    api.fail = false;
    api.answers['a'] = testPrice(40);
    now = now.add(const Duration(seconds: 2));
    await store.refresh();

    expect(api.calls, hasLength(failed + 1));
    expect(store.priceFor('a')!.cut, 40);
  });

  test('asks in batches of fifty', () async {
    repo.library = [for (var i = 0; i < 120; i++) wish('g$i')];

    await stores.initialize();
    await settle();

    expect([for (final c in api.calls) c.length], [50, 50, 20]);
  });

  test('a sign-out drops the prices, and nothing is asked with nobody signed in', () async {
    api.answers['a'] = testPrice(50);
    await stores.initialize();
    await settle();
    expect(stores.wishlistPrices.priceFor('a'), isNotNull);
    final asked = api.calls.length;

    await stores.auth.logOut();
    await settle();

    expect(stores.wishlistPrices.priceFor('a'), isNull);
    expect(stores.wishlistPrices.deals, isEmpty);
    await stores.wishlistPrices.refresh();
    expect(api.calls, hasLength(asked));
  });
}
