import 'package:flutter_test/flutter_test.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_price.dart';

import 'support/fakes.dart';

Map<String, Object?> priceJson({
  double price = 24.99,
  double regular = 59.99,
  int cut = 58,
  String shop = 'GOG',
  String url = 'https://itad.link/abc?aff=gamebit',
  Object? expiry,
  Object? historyLow,
}) => {
  'shop': {'id': 35, 'name': shop},
  'price': {'amount': price, 'currency': 'EUR'},
  'regular': {'amount': regular, 'currency': 'EUR'},
  'cut': cut,
  'url': url,
  'expiry': expiry,
  'history_low': historyLow,
};

GamePrice price({int cut = 58, double amount = 24.99, double? low}) => GamePrice(
  shop: 'GOG',
  price: Money(amount, 'EUR'),
  regular: const Money(59.99, 'EUR'),
  cut: cut,
  url: Uri.parse('https://itad.link/abc'),
  historyLow: low == null ? null : Money(low, 'EUR'),
);

void main() {
  group('Money', () {
    test('reads an amount and a three-letter currency', () {
      expect(Money.fromJson({'amount': 12.5, 'currency': 'USD'}), const Money(12.5, 'USD'));
      expect(Money.fromJson({'amount': 0, 'currency': 'EUR'}), const Money(0, 'EUR'));
      expect(Money.fromJson({'amount': 12, 'currency': 'EUR'})!.amount, 12.0);
    });

    test('refuses anything else', () {
      expect(Money.fromJson(null), isNull);
      expect(Money.fromJson('12'), isNull);
      expect(Money.fromJson({'amount': -1, 'currency': 'USD'}), isNull);
      expect(Money.fromJson({'amount': double.nan, 'currency': 'USD'}), isNull);
      expect(Money.fromJson({'amount': '5', 'currency': 'USD'}), isNull);
      expect(Money.fromJson({'amount': 5, 'currency': 'usd'}), isNull);
      expect(Money.fromJson({'amount': 5, 'currency': 'EURO'}), isNull);
      expect(Money.fromJson({'amount': 5}), isNull);
    });

    test('is written with the currency\'s own symbol', () {
      expect(const Money(12.5, 'USD').format(), r'$12.50');
      expect(const Money(12.5, 'EUR').format(), contains('€'));
      expect(const Money(12.5, 'EUR').format(), contains('12.50'));
    });
  });

  group('GamePrice', () {
    test('reads the answer of game-prices', () {
      final p = GamePrice.fromJson(
        priceJson(expiry: '2026-11-20T10:00:00+01:00', historyLow: {'amount': 9.99, 'currency': 'EUR'}),
      )!;

      expect(p.shop, 'GOG');
      expect(p.price, const Money(24.99, 'EUR'));
      expect(p.regular, const Money(59.99, 'EUR'));
      expect(p.cut, 58);
      expect(p.isOnSale, isTrue);
      expect(p.url, Uri.parse('https://itad.link/abc?aff=gamebit'));
      expect(p.expiry, DateTime.parse('2026-11-20T10:00:00+01:00'));
      expect(p.historyLow, const Money(9.99, 'EUR'));
    });

    test('keeps the link as it came, with its query', () {
      final p = GamePrice.fromJson(priceJson(url: 'https://itad.link/abc?aff=xyz&x=%20y#frag'))!;
      expect(p.url.toString(), 'https://itad.link/abc?aff=xyz&x=%20y#frag');
    });

    test('a game at its regular price is not on sale', () {
      final p = GamePrice.fromJson(priceJson(price: 59.99, cut: 0))!;
      expect(p.isOnSale, isFalse);
    });

    test('a cut is kept between 0 and 100, and a missing one is 0', () {
      expect(GamePrice.fromJson(priceJson(cut: 150))!.cut, 100);
      expect(GamePrice.fromJson(priceJson(cut: -4))!.cut, 0);
      expect(GamePrice.fromJson(priceJson())!.cut, 58);
      expect(GamePrice.fromJson({...priceJson(), 'cut': null})!.cut, 0);
    });

    test('an expiry or a lowest price that cannot be read is left out', () {
      final p = GamePrice.fromJson(priceJson(expiry: 'soon', historyLow: 'cheap'))!;
      expect(p.expiry, isNull);
      expect(p.historyLow, isNull);
    });

    test('a price with no store, no price or no https page is not one', () {
      expect(GamePrice.fromJson(null), isNull);
      expect(GamePrice.fromJson('x'), isNull);
      expect(GamePrice.fromJson(priceJson(url: 'http://shop.example/g')), isNull);
      expect(GamePrice.fromJson(priceJson(url: 'javascript:alert(1)')), isNull);
      expect(GamePrice.fromJson(priceJson(url: 'https://')), isNull);
      expect(GamePrice.fromJson(priceJson(url: '')), isNull);
      expect(GamePrice.fromJson({...priceJson(), 'shop': null}), isNull);
      expect(GamePrice.fromJson({...priceJson(), 'shop': {'name': ''}}), isNull);
      expect(GamePrice.fromJson({...priceJson(), 'price': null}), isNull);
      expect(GamePrice.fromJson({...priceJson(), 'regular': {'amount': 1}}), isNull);
    });

    test('is at its lowest ever when it is not above the lowest price, in the same currency', () {
      expect(price(low: 24.99).isLowestEver, isTrue);
      expect(price(low: 30).isLowestEver, isTrue);
      expect(price(low: 9.99).isLowestEver, isFalse);
      expect(price().isLowestEver, isFalse);
      final otherCurrency = GamePrice(
        shop: 'GOG',
        price: const Money(24.99, 'EUR'),
        regular: const Money(59.99, 'EUR'),
        cut: 58,
        url: Uri.parse('https://itad.link/abc'),
        historyLow: const Money(30, 'USD'),
      );
      expect(otherCurrency.isLowestEver, isFalse);
    });

    test('the response is game id -> price, a game with none being null', () {
      final prices = GamePrice.fromResponse({
        'prices': {'a': priceJson(), 'b': null, 'c': priceJson(url: 'http://nope.example')},
      })!;

      expect(prices.keys, ['a', 'b', 'c']);
      expect(prices['a']!.shop, 'GOG');
      expect(prices['b'], isNull);
      expect(prices['c'], isNull);
    });

    test('an answer that is an error is not a response', () {
      expect(GamePrice.fromResponse({'error': 'x', 'code': 'RATE_LIMITED'}), isNull);
      expect(GamePrice.fromResponse(null), isNull);
      expect(GamePrice.fromResponse({'prices': []}), isNull);
      expect(GamePrice.fromResponse({'prices': <String, Object?>{}}), isEmpty);
    });
  });

  group('wishlistDeals', () {
    final wish = [
      testGame('a', title: 'Alpha', status: GameStatus.wishlist),
      testGame('b', title: 'Beta', status: GameStatus.wishlist),
      testGame('c', title: 'Gamma', status: GameStatus.wishlist),
      testGame('d', title: 'Delta', status: GameStatus.wishlist),
      testGame('e', title: 'Epsilon', status: GameStatus.wishlist),
      testGame('owned', title: 'Owned', status: GameStatus.playing),
    ];

    List<String> ids(Map<String, GamePrice?> prices) =>
        [for (final d in wishlistDeals(wish, (id) => prices[id])) d.game.id];

    test('lists the wishlist games that are on sale, the biggest cut first, then by title', () {
      expect(
        ids({
          'a': price(cut: 20),
          'b': price(cut: 75),
          'c': price(cut: 20),
          'd': price(cut: 0),
          'owned': price(cut: 90),
        }),
        ['b', 'a', 'c'],
      );
    });

    test('puts the games at their lowest price ever first', () {
      expect(
        ids({
          'a': price(cut: 80),
          'b': price(cut: 30, low: 24.99),
          'c': price(cut: 50),
        }),
        ['b', 'a', 'c'],
      );
    });

    test('a game with no price is not a deal', () {
      expect(ids({'a': null, 'b': price(cut: 10)}), ['b']);
      expect(ids({}), isEmpty);
    });
  });
}
