import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/game.dart';

/// Numbers about a library, worked out from its games: how many are in each
/// status, the hours played in total and per platform, and how the ratings are
/// spread. The same code serves the signed-in member's library and another
/// member's, so the two profile pages always add up the same way.
@immutable
class LibraryStats {
  const LibraryStats({
    this.games = 0,
    this.byStatus = const {},
    this.totalHours = 0,
    this.hoursByPlatform = const {},
    this.ratingCounts = const {},
    this.ratedCount = 0,
    this.averageRating = 0,
  });

  /// The bars of the chart, lowest first: one to ten stars.
  static const List<int> ratingSteps = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

  factory LibraryStats.of(Iterable<Game> library) {
    final byStatus = <GameStatus, int>{};
    final ratingCounts = <int, int>{};
    var games = 0;
    var totalHours = 0.0;
    var ratingSum = 0.0;
    var ratedCount = 0;
    for (final g in library) {
      games++;
      final status = g.status;
      if (status != null) byStatus[status] = (byStatus[status] ?? 0) + 1;
      // A completed game still being played is under Playing as well, as in
      // the library's tabs.
      if (status == GameStatus.completed && g.isPlaying) {
        byStatus[GameStatus.playing] = (byStatus[GameStatus.playing] ?? 0) + 1;
      }
      totalHours += g.hoursPlayed;
      if (g.rating > 0) {
        ratedCount++;
        ratingSum += g.rating;
        // A bar holds the half star under it too (a 7.5 is in the 8 bar, as in
        // the community rating); a stray value still lands in a bar.
        final step = g.rating.ceil().clamp(1, 10);
        ratingCounts[step] = (ratingCounts[step] ?? 0) + 1;
      }
    }
    return LibraryStats(
      games: games,
      byStatus: Map.unmodifiable(byStatus),
      totalHours: totalHours,
      hoursByPlatform: hoursByPlatformOf(library),
      ratingCounts: Map.unmodifiable(ratingCounts),
      ratedCount: ratedCount,
      averageRating: ratedCount == 0 ? 0 : ratingSum / ratedCount,
    );
  }

  /// Total hours per platform, most played first, based on each game's total
  /// playtime (so hours imported by Steam sync count too, not just logged
  /// sessions). A game counts for the platform it was played on, else the first
  /// it was released on, else PC.
  static Map<GamePlatform, double> hoursByPlatformOf(Iterable<Game> library) {
    final m = <GamePlatform, double>{};
    for (final g in library) {
      if (g.hoursPlayed <= 0) continue;
      final platform =
          g.playedOn ??
          (g.platforms.isNotEmpty ? g.platforms.first : GamePlatform.pc);
      m[platform] = (m[platform] ?? 0) + g.hoursPlayed;
    }
    final entries = m.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map.fromEntries(entries);
  }

  /// Games in the library, whatever their status.
  final int games;

  /// Games listed under each status (see [Game.isListedUnder]), so a completed
  /// game still being played counts for Completed and Playing both.
  final Map<GameStatus, int> byStatus;
  final double totalHours;
  final Map<GamePlatform, double> hoursByPlatform;

  /// Games per bar of [ratingSteps]: a bar holds its star and the half star under
  /// it. Unrated games are not counted.
  final Map<int, int> ratingCounts;
  final int ratedCount;

  /// 0 when nothing is rated.
  final double averageRating;

  int count(GameStatus status) => byStatus[status] ?? 0;
}
