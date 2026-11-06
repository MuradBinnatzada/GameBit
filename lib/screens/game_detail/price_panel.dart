import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_price.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/state/wishlist_prices_store.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/panel.dart';

/// IsThereAnyDeal, which the prices come from and which its terms ask us to link.
final Uri _itadHome = Uri.parse('https://isthereanydeal.com/');

/// The best current price of a wishlist game, with its lowest price ever and a
/// link to the store. Nothing (and no space) for a game that is not on the
/// wishlist or has no price.
class PricePanel extends StatelessWidget {
  const PricePanel({super.key, required this.game});

  final Game game;

  @override
  Widget build(BuildContext context) {
    if (game.status != GameStatus.wishlist) return const SizedBox.shrink();
    final price = context.watch<WishlistPricesStore>().priceFor(game.id);
    if (price == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _PriceCard(price: price),
    );
  }
}

class _PriceCard extends StatelessWidget {
  const _PriceCard({required this.price});

  final GamePrice price;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final low = price.historyLow;
    final expiry = price.expiry;
    final saleEnds = expiry != null && expiry.isAfter(DateTime.now());
    return Panel(
      title: l10n.priceTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 4,
            children: [
              Text(
                price.price.format(),
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
              ),
              if (price.isOnSale) ...[
                Text(
                  price.regular.format(),
                  style: TextStyle(
                    color: palette.muted,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: palette.success,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '−${price.cut}%',
                    style: TextStyle(
                      // Dark on the light green of the dark theme, light on the
                      // dark green of the light one.
                      color: ThemeData.estimateBrightnessForColor(palette.success) == Brightness.dark
                          ? Colors.white
                          : Colors.black,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.priceAtStore(price.shop),
            style: TextStyle(color: palette.muted, fontSize: 13),
          ),
          if (price.isLowestEver) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.trending_down_rounded, size: 18, color: palette.success),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.priceLowestEver,
                    style: TextStyle(
                      color: palette.success,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (low != null) ...[
            const SizedBox(height: 8),
            Text(
              l10n.priceLowestEverWas(low.format()),
              style: TextStyle(color: palette.muted, fontSize: 13),
            ),
          ],
          if (price.isOnSale && saleEnds) ...[
            const SizedBox(height: 4),
            Text(
              l10n.priceSaleEnds(fmtMonthDay(expiry.toLocal())),
              style: TextStyle(color: palette.muted, fontSize: 13),
            ),
          ],
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => unawaited(_open(context, price.url)),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(l10n.priceViewDeal(price.shop)),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => unawaited(_open(context, _itadHome)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                l10n.pricesByItad,
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, Uri url) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = context.l10n.priceOpenFailed;
    var opened = false;
    try {
      opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Falls through to the message.
    }
    if (!opened) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
