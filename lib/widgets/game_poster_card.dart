import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/cover_art.dart';
import 'package:checkpoint/widgets/star_rating.dart';

/// Poster + title + stars (+ optional caption). Used in horizontal carousels and
/// the browse grids.
class GamePosterCard extends StatelessWidget {
  const GamePosterCard({super.key, required this.game, required this.width, this.subtitle, this.subtitleIcon, this.caption, this.showUnrated = true});
  final Game game;
  final double width;
  final String? subtitle;
  final IconData? subtitleIcon;

  /// A second muted line under [subtitle] (Recent Activity: the exact time).
  final String? caption;

  /// Whether a game the user hasn't rated says "Not rated". Catalog lists turn it
  /// off: there it would sit under nearly every poster.
  final bool showUnrated;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => openGame(context, game.id),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          CoverArt(game: game),
          const SizedBox(height: 8),
          Text(game.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          if (game.rating > 0 || showUnrated) ...[
            const SizedBox(height: 4),
            game.rating > 0
                ? StarRating(rating: game.rating, size: 14)
                : Text(context.l10n.notRated, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: context.palette.muted)),
          ],
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Row(children: [
              if (subtitleIcon != null) ...[
                Icon(subtitleIcon, size: 12, color: context.palette.muted),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: context.palette.muted)),
              ),
            ]),
          ],
          if (caption != null) ...[
            const SizedBox(height: 2),
            Text(caption!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: context.palette.muted)),
          ],
        ]),
      ),
    );
  }
}
