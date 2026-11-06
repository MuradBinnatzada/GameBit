import 'dart:async';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_price.dart';
import 'package:checkpoint/services/game_price_api_service.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';

/// The best current price of each game on the member's wishlist (a game's screen
/// and Home's Wishlist Deals read it). It asks the `game-prices` function for the
/// wishlist games it has no price for yet, or only an old one, once the library
/// has loaded and again when the wishlist changes. Prices are live questions kept
/// in memory only: [freshFor] long, then asked again the next time the wishlist
/// or the app is looked at, and dropped when the account changes. A request that
/// fails is not repeated for [retryAfterFailure]; nothing is shown for a game
/// without a price.
class WishlistPricesStore extends AccountScopedStore {
  WishlistPricesStore({
    required AuthStore auth,
    required this._library,
    GamePriceApiService? api,
    DateTime Function()? clock,
  }) : _api = api ?? GamePriceApiService(),
       _clock = clock ?? DateTime.now,
       super(auth);

  /// How long a price is shown without asking again.
  static const Duration freshFor = Duration(hours: 3);

  /// How long to wait after a failed request before asking again.
  static const Duration retryAfterFailure = Duration(minutes: 5);

  /// Most wishlist games asked about in one go (a few requests); the rest are
  /// asked about next time.
  static const int maxPerRefresh = 200;

  final LibraryStore _library;
  final GamePriceApiService _api;
  final DateTime Function() _clock;

  final Map<String, ({GamePrice? price, DateTime at})> _prices = {};
  DateTime? _failedAt;
  bool _asking = false;
  bool _askAgain = false;

  @override
  void initialize() {
    super.initialize();
    _library.addListener(_onLibrary);
    _onLibrary();
  }

  @override
  void dispose() {
    _library.removeListener(_onLibrary);
    super.dispose();
  }

  @override
  void resetForAccount() {
    _prices.clear();
    _failedAt = null;
  }

  /// The best price of the game [gameId], or null: none known, or none asked yet.
  GamePrice? priceFor(String gameId) => _prices[gameId]?.price;

  /// The wishlist games that are on sale now.
  List<WishlistDeal> get deals => wishlistDeals(_library.listedGames, priceFor);

  Iterable<Game> get _wishlist => [
    for (final g in _library.listedGames)
      if (g.status == GameStatus.wishlist) g,
  ];

  void _onLibrary() {
    // The wishlist changed (a game left it, say), and so do the deals.
    notifyIfAlive();
    if (accountId == null || !_library.isSettled) return;
    unawaited(refresh());
  }

  /// Asks for the prices of the wishlist games that have none or an old one.
  /// Does nothing while a request is on its way (the wishlist is looked at again
  /// when it ends) or after a failure that is too recent.
  Future<void> refresh() async {
    if (accountId == null) return;
    if (_asking) {
      _askAgain = true;
      return;
    }
    final failed = _failedAt;
    if (failed != null && _clock().difference(failed) < retryAfterFailure) {
      return;
    }
    final epoch = this.epoch;
    _asking = true;
    try {
      do {
        _askAgain = false;
        final now = _clock();
        final due = [
          for (final g in _wishlist)
            if (_isDue(g.id, now)) g.id,
        ].take(maxPerRefresh).toList();
        if (due.isEmpty) break;
        final ok = await _ask(due, epoch);
        if (!ok || isStale(epoch)) break;
      } while (_askAgain);
    } finally {
      _asking = false;
    }
  }

  bool _isDue(String gameId, DateTime now) {
    final held = _prices[gameId];
    return held == null || now.difference(held.at) >= freshFor;
  }

  /// Asks about [ids], [GamePriceApiService.batchSize] at a time. False when a
  /// request failed.
  Future<bool> _ask(List<String> ids, int epoch) async {
    for (var i = 0; i < ids.length; i += GamePriceApiService.batchSize) {
      final batch = ids.skip(i).take(GamePriceApiService.batchSize).toList();
      final answer = await _api.prices(batch);
      if (isStale(epoch)) return false;
      if (answer == null) {
        _failedAt = _clock();
        return false;
      }
      _failedAt = null;
      final now = _clock();
      // A game the answer leaves out is a game with no price.
      for (final id in batch) {
        _prices[id] = (price: answer[id], at: now);
      }
      notifyIfAlive();
    }
    return true;
  }
}
