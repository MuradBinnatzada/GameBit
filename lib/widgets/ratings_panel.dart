import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/library_stats.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/panel.dart';
import 'package:checkpoint/widgets/star_rating.dart';

/// How a member rates their games: the average on the left and, on the right, one
/// bar per rating from one star to ten, as tall as the number of games given
/// that rating. The counts stay hidden until a bar is tapped; then it lights up
/// and a bubble over it shows the stars and how many games have them.
class RatingsPanel extends StatefulWidget {
  const RatingsPanel({super.key, required this.stats});

  final LibraryStats stats;

  static const double _barAreaHeight = 76;

  /// Room above the bars for the bubble.
  static const double _bubbleHeight = 26;

  /// The bars, lowest first: one for each star from one to ten, holding the half
  /// star under it too.
  static const List<int> bars = LibraryStats.ratingSteps;

  /// Games in [bar]: its star and the half star under it.
  static int countFor(LibraryStats stats, int bar) => stats.ratingCounts[bar] ?? 0;

  @override
  State<RatingsPanel> createState() => _RatingsPanelState();
}

class _RatingsPanelState extends State<RatingsPanel> {
  /// The bar that was tapped, if any.
  int? _selected;

  void _tap(int bar) {
    HapticFeedback.selectionClick();
    setState(() => _selected = _selected == bar ? null : bar);
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    if (stats.ratedCount == 0) {
      return Panel(
        title: context.l10n.ratings,
        child: Text(
          context.l10n.noRatedGamesYet,
          style: TextStyle(color: context.palette.muted, fontSize: 13),
        ),
      );
    }
    const bars = RatingsPanel.bars;
    final tallest = bars
        .map((r) => RatingsPanel.countFor(stats, r))
        .reduce((a, b) => a > b ? a : b);
    final selected = _selected;

    return Panel(
      title: context.l10n.ratings,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stats.averageRating.toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 34,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                StarRating(
                  rating: (stats.averageRating * 2).round() / 2,
                  size: 10,
                ),
                const SizedBox(height: 6),
                Text(
                  context.l10n.ratedCount(stats.ratedCount),
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  height:
                      RatingsPanel._bubbleHeight + RatingsPanel._barAreaHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final r in bars)
                              Expanded(
                                child: _Bar(
                                  rating: r,
                                  count: RatingsPanel.countFor(stats, r),
                                  tallest: tallest,
                                  selected: selected == r,
                                  onTap: () => _tap(r),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (selected != null)
                        PositionedDirectional(
                          top: 0,
                          start: 0,
                          end: 0,
                          height: RatingsPanel._bubbleHeight,
                          // Centered over its bar, but never out of the chart.
                          child: IgnorePointer(
                            child: Align(
                              alignment: Alignment(
                                2 *
                                        (bars.indexOf(selected) + 0.5) /
                                        bars.length -
                                    1,
                                0,
                              ),
                              child: _Bubble(
                                rating: selected,
                                count: RatingsPanel.countFor(stats, selected),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [_AxisLabel('1'), _AxisLabel('10')],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "1 ★" / "10 ★" under the ends of the chart. The star is an icon: the ★
/// character is missing from some fonts.
class _AxisLabel extends StatelessWidget {
  const _AxisLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: TextStyle(color: context.palette.muted, fontSize: 11)),
        const SizedBox(width: 1),
        Icon(Icons.star_rounded, size: 11, color: context.palette.muted),
      ],
    );
  }
}

/// What the tapped bar stands for: its stars and how many games have them.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.rating, required this.count});

  final int rating;
  final int count;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.palette.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.palette.text.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$rating',
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 1),
            Icon(Icons.star_rounded, size: 12, color: context.palette.star),
            const SizedBox(width: 6),
            Text(
              context.l10n.gamesCount(count),
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.rating,
    required this.count,
    required this.tallest,
    required this.selected,
    required this.onTap,
  });

  final int rating;
  final int count;
  final int tallest;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final height = count == 0
        ? 3.0
        : 6 + (RatingsPanel._barAreaHeight - 6) * count / tallest;
    final Color color;
    if (count == 0) {
      color = selected ? context.palette.faint : context.palette.track;
    } else if (selected) {
      color = context.palette.star;
    } else {
      color = context.palette.star.withValues(alpha: 0.35 + 0.65 * count / tallest);
    }
    final stars = context.l10n.starsCount(rating, '$rating');
    return Semantics(
      button: true,
      selected: selected,
      label: '$stars: ${context.l10n.gamesCount(count)}',
      excludeSemantics: true,
      onTap: onTap,
      // The whole column is the target, so a one-game bar is as easy to hit as a
      // tall one.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            height: height,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
