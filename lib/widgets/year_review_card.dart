import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/models/year_review.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/cover_art.dart';

/// The size a share card is laid out at, 4:5 like a portrait post. Captured at
/// 3x it is 1080 x 1350 pixels.
const yearCardSize = Size(360, 450);

// A card is a picture that leaves the app, so it keeps one look whatever theme
// the member picked: the dark palette on a deep purple to blue ground.
const _ink = Palette.dark;
const _groundTop = Color(0xFF241447);
const _groundBottom = Color(0xFF0F1A2E);

/// The year in one picture: hours played, a bar a month, and the four counts.
class YearOverviewCard extends StatelessWidget {
  const YearOverviewCard({super.key, required this.review});
  final YearReview review;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final r = review;
    return _CardFrame(
      year: r.year,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            l10n.hoursShort(fmtHours(r.hours)),
            style: const TextStyle(fontSize: 64, height: 1.05, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.yearPlayedSummary(r.year, l10n.sessionCount(r.sessionCount), l10n.ofGamesCount(r.gamesPlayed)),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: _ink.muted, fontSize: 14, height: 1.3),
        ),
        const Spacer(),
        if (r.sessionCount > 0) _MonthBars(hours: r.hoursByMonth),
        const Spacer(),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _Stat(value: '${r.daysPlayed}', label: l10n.daysPlayed(r.daysPlayed))),
          const SizedBox(width: 12),
          Expanded(child: _Stat(value: '${r.longestStreak}', label: l10n.longestStreakDays)),
        ]),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _Stat(value: '${r.completed.length}', label: l10n.gamesCompleted)),
          const SizedBox(width: 12),
          Expanded(child: _Stat(value: '${r.addedCount}', label: l10n.gamesAdded)),
        ]),
      ]),
    );
  }
}

/// The most played games with their covers and hours, and the top genres.
/// Only for a review with a game to list ([YearReview.topGames]).
class YearTopGamesCard extends StatelessWidget {
  const YearTopGamesCard({super.key, required this.review});
  final YearReview review;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final r = review;
    final most = r.topGames.isEmpty ? 1.0 : r.topGames.first.hours;
    return _CardFrame(
      year: r.year,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(l10n.mostPlayed, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < r.topGames.length; i++)
          _GameRow(
            rank: i + 1,
            game: r.topGames[i],
            share: most <= 0 ? 0 : r.topGames[i].hours / most,
          ),
        const Spacer(),
        if (r.topGenres.isNotEmpty) ...[
          Text(l10n.topGenres, style: TextStyle(color: _ink.muted, fontSize: 12)),
          const SizedBox(height: 2),
          Text(
            [for (final g in r.topGenres.take(3)) tagName(g.genre)].join(', '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ],
      ]),
    );
  }
}

/// The ground, the wordmark and the year, around a card's [child].
class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.year, required this.child});
  final int year;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The same pixels whatever the text size of the device that makes the card.
    return MediaQuery.withNoTextScaling(
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: SizedBox.fromSize(
          size: yearCardSize,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_groundTop, _groundBottom],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(
                    'Gamebit',
                    style: TextStyle(color: _ink.accent, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 0.4),
                  ),
                  const Spacer(),
                  Text('$year', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 18),
                Expanded(child: child),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: const TextStyle(fontSize: 28, height: 1.1, fontWeight: FontWeight.w800)),
      Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: _ink.muted, fontSize: 12)),
    ]);
  }
}

/// Hours by month, a bar each with the month's initial under it. The busiest
/// month is the blue one.
class _MonthBars extends StatelessWidget {
  const _MonthBars({required this.hours});
  final List<double> hours;

  static const double _barsHeight = 64;

  @override
  Widget build(BuildContext context) {
    final tallest = hours.reduce((a, b) => a > b ? a : b);
    final busiest = hours.indexOf(tallest);
    return Column(children: [
      SizedBox(
        height: _barsHeight,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var m = 0; m < 12; m++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: hours[m] <= 0 || tallest <= 0
                    ? const SizedBox.shrink()
                    : FractionallySizedBox(
                        heightFactor: (hours[m] / tallest).clamp(0.0, 1.0),
                        child: ConstrainedBox(
                          // A month with a little play still shows.
                          constraints: const BoxConstraints(minHeight: 3),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: m == busiest ? _ink.electric : _ink.accent,
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
        ]),
      ),
      Container(height: 1, color: Colors.white24),
      const SizedBox(height: 4),
      Row(children: [
        for (var m = 0; m < 12; m++)
          Expanded(
            child: Text(fmtMonthLetter(m), textAlign: TextAlign.center, style: TextStyle(color: _ink.muted, fontSize: 11)),
          ),
      ]),
    ]);
  }
}

class _GameRow extends StatelessWidget {
  const _GameRow({required this.rank, required this.game, required this.share});
  final int rank;
  final GameHours game;

  /// This game's hours out of the most played game's, 0 to 1.
  final double share;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 20,
          child: Text('$rank', style: TextStyle(color: _ink.muted, fontSize: 14, fontWeight: FontWeight.w800)),
        ),
        SizedBox(width: 28, child: CoverArt(game: game.game, radius: 5, showTitle: false)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(game.game.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: share.clamp(0.0, 1.0), minHeight: 5, color: _ink.accent, backgroundColor: Colors.white12),
            ),
          ]),
        ),
        const SizedBox(width: 10),
        // One width for every row, so the bars end in one line.
        SizedBox(
          width: 54,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerEnd,
            child: Text(context.l10n.hoursShort(fmtHours(game.hours)), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }
}
