import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/star_rating.dart';

/// How the members rated a game: the average and how many rated it on the left,
/// one bar per star from ten down to one on the right, as long as the
/// share of the ratings that gave it. Nothing for a game nobody rated.
class CommunityRatingSummary extends StatelessWidget {
  const CommunityRatingSummary({super.key, required this.ratings});

  final CommunityRatings ratings;

  @override
  Widget build(BuildContext context) {
    if (ratings.ratings == 0) return const SizedBox.shrink();
    final counts = [
      for (var stars = maxRating; stars >= 1; stars--) ratings.countForStars(stars),
    ];
    final most = counts.fold(0, (a, b) => a > b ? a : b);
    final l10n = context.l10n;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Semantics(
          label:
              '${l10n.outOf10Stars(fmtHours(double.parse(ratings.average.toStringAsFixed(1))))}, '
              '${l10n.ratingsCount(ratings.ratings)}',
          excludeSemantics: true,
          child: SizedBox(
            width: 120,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ratings.average.toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 4),
                StarRating(rating: ratings.average, size: 12),
                const SizedBox(height: 4),
                Text(
                  l10n.ratingsCount(ratings.ratings),
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: ExcludeSemantics(
            child: Column(
              children: [
                for (var i = 0; i < counts.length; i++)
                  _Bar(stars: maxRating - i, count: counts[i], most: most),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One row: the stars it is for, a bar, and how many gave them.
class _Bar extends StatelessWidget {
  const _Bar({required this.stars, required this.count, required this.most});

  final int stars;
  final int count;
  final int most;

  @override
  Widget build(BuildContext context) {
    final share = most == 0 ? 0.0 : count / most;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              '$stars',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                children: [
                  Container(
                    height: 6,
                    color: context.palette.text.withValues(alpha: 0.08),
                  ),
                  FractionallySizedBox(
                    widthFactor: count == 0 ? 0 : share.clamp(0.04, 1.0),
                    child: Container(height: 6, color: context.palette.star),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 30,
            child: Text(
              fmtCount(count),
              textAlign: TextAlign.end,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
