import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'package:checkpoint/models/game.dart';

/// An amount in a currency (an ISO 4217 code such as `EUR`), as IsThereAnyDeal
/// gives it. Kept exactly: nothing here rounds a price.
@immutable
class Money {
  const Money(this.amount, this.currency);

  final double amount;
  final String currency;

  static Money? fromJson(Object? json) {
    if (json is! Map) return null;
    final amount = json['amount'];
    final currency = json['currency'];
    if (amount is! num || !amount.isFinite || amount < 0) return null;
    if (currency is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      return null;
    }
    return Money(amount.toDouble(), currency);
  }

  Map<String, Object> toJson() => {'amount': amount, 'currency': currency};

  /// "$12.50", "12,50 €": written the way the app's language writes [currency].
  String format() =>
      NumberFormat.simpleCurrency(name: currency).format(amount);

  @override
  bool operator ==(Object other) =>
      other is Money && other.amount == amount && other.currency == currency;

  @override
  int get hashCode => Object.hash(amount, currency);
}

/// The best current price of a game in the main PC stores, from the
/// `game-prices` Edge Function (IsThereAnyDeal).
@immutable
class GamePrice {
  const GamePrice({
    required this.shop,
    required this.price,
    required this.regular,
    required this.cut,
    required this.url,
    this.expiry,
    this.historyLow,
  });

  /// The store that has the price.
  final String shop;
  final Money price;

  /// The price without the sale.
  final Money regular;

  /// Percent off the regular price; 0 when the game is not on sale.
  final int cut;

  /// The store's page for the game, exactly as IsThereAnyDeal gave it (its
  /// terms forbid changing a link).
  final Uri url;

  /// When the sale ends, when the store says.
  final DateTime? expiry;

  /// The lowest price the game has ever had, when known.
  final Money? historyLow;

  bool get isOnSale => cut > 0;

  /// The price is the lowest the game has ever had.
  bool get isLowestEver {
    final low = historyLow;
    return low != null &&
        low.currency == price.currency &&
        price.amount <= low.amount + 0.005;
  }

  static GamePrice? fromJson(Object? json) {
    if (json is! Map) return null;
    final shop = json['shop'];
    final name = shop is Map ? shop['name'] : null;
    final price = Money.fromJson(json['price']);
    final regular = Money.fromJson(json['regular']);
    final text = json['url'];
    final url = text is String ? Uri.tryParse(text) : null;
    if (name is! String || name.isEmpty || price == null || regular == null) {
      return null;
    }
    // Only a web page is opened from here.
    if (url == null || url.scheme != 'https' || url.host.isEmpty) return null;
    final cut = json['cut'];
    final expiry = json['expiry'];
    return GamePrice(
      shop: name,
      price: price,
      regular: regular,
      cut: cut is num ? cut.round().clamp(0, 100) : 0,
      url: url,
      expiry: expiry is String ? DateTime.tryParse(expiry) : null,
      historyLow: Money.fromJson(json['history_low']),
    );
  }

  /// The answer of `game-prices`: game id -> price, null for a game with none.
  /// Null when the answer is not one (an `{ "error": ... }`, say). A price that
  /// can't be read is a game with none.
  static Map<String, GamePrice?>? fromResponse(Object? response) {
    if (response is! Map) return null;
    final prices = response['prices'];
    if (prices is! Map) return null;
    return {
      for (final e in prices.entries)
        if (e.key is String) e.key as String: GamePrice.fromJson(e.value),
    };
  }
}

/// A wishlist game that is on sale.
typedef WishlistDeal = ({Game game, GamePrice price});

/// The wishlist games of [prices] that are on sale, the ones at their lowest
/// price ever first, then the biggest cut first, then by title.
List<WishlistDeal> wishlistDeals(
  Iterable<Game> library,
  GamePrice? Function(String gameId) prices,
) {
  final deals = <WishlistDeal>[
    for (final g in library)
      if (g.status == GameStatus.wishlist)
        if (prices(g.id) case final p? when p.isOnSale) (game: g, price: p),
  ];
  deals.sort((a, b) {
    final lowest =
        (b.price.isLowestEver ? 1 : 0) - (a.price.isLowestEver ? 1 : 0);
    if (lowest != 0) return lowest;
    final cut = b.price.cut.compareTo(a.price.cut);
    return cut != 0 ? cut : a.game.title.compareTo(b.game.title);
  });
  return deals;
}
