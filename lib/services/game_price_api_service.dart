import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/models/game_price.dart';

/// Wishlist prices, from the `game-prices` Supabase Edge Function (which asks
/// IsThereAnyDeal). Only reachable by signed-in members. The function names the
/// games by their catalog id and looks them up itself; nothing about the member
/// goes with the request but the region, which picks the currency.
class GamePriceApiService {
  GamePriceApiService({this._country});

  /// Most games one request may name (what the function takes).
  static const int batchSize = 50;

  final String? _country;

  /// The two letters of the device's region ("DE"), "US" when it has none.
  String get country {
    final code = _country ?? PlatformDispatcher.instance.locale.countryCode;
    return code != null && RegExp(r'^[A-Za-z]{2}$').hasMatch(code)
        ? code.toUpperCase()
        : 'US';
  }

  /// The best price of each of [gameIds] (at most [batchSize]), null for a game
  /// with none; null when the request failed.
  Future<Map<String, GamePrice?>?> prices(List<String> gameIds) async {
    if (gameIds.isEmpty) return const {};
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'game-prices',
        body: {
          'game_ids': gameIds.take(batchSize).toList(),
          'country': country,
        },
      );
      final raw = res.data;
      return GamePrice.fromResponse(raw is String ? json.decode(raw) : raw);
    } catch (e) {
      debugPrint('game-prices request failed: $e');
      return null;
    }
  }
}
