import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_list.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/models/user_profile.dart';

/// How far the signed-in member is towards each milestone, worked out on the
/// device from what it holds: their library, sessions, lists and profile. It is
/// for the progress bars, and for telling when a milestone was probably just
/// reached; the server decides (`award_milestones`), so the rules here follow
/// its SQL (20261020120100_milestones.sql and
/// 20261020140337_milestones_without_steam.sql).
///
/// What the device doesn't know is left out, and its milestones get no bar: the
/// lists until they are loaded, and anything passed as null. Perfect games are
/// the ones the member marked: the server also counts every Steam achievement
/// unlocked, which isn't part of the library, so it may count more.
@immutable
class MilestoneProgress {
  const MilestoneProgress(this.values);

  factory MilestoneProgress.of({
    required List<Game> library,
    required List<LogEntry> sessions,
    List<GameList>? lists,
    int? following,
    int? followers,
    UserProfile? profile,
    bool? gameAccount,
    bool? twoFactor,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final logged = [
      for (final s in sessions)
        if (!s.isSynced) s,
    ];
    final played = [
      for (final g in library)
        if (g.status == GameStatus.playing ||
            g.status == GameStatus.completed ||
            g.status == GameStatus.dropped ||
            g.hoursPlayed > 0)
          g,
    ];
    int countWhere(bool Function(Game g) test) => library.where(test).length;

    return MilestoneProgress({
      MilestoneMetric.libraryGames: library.length,
      MilestoneMetric.sessions: logged.length,
      MilestoneMetric.hours: library.fold<double>(
        0,
        (sum, g) => sum + g.hoursPlayed,
      ),
      MilestoneMetric.gameHours: library.fold<double>(
        0,
        (most, g) => math.max(most, g.hoursPlayed),
      ),
      MilestoneMetric.completed: countWhere(
        (g) => g.status == GameStatus.completed,
      ),
      MilestoneMetric.completionTimes: countWhere(
        (g) => g.completionTime != null,
      ),
      MilestoneMetric.streakDays: longestStreak(logged),
      MilestoneMetric.nightSessions: logged
          .where((s) => s.timestamp.hour < 4)
          .length,
      MilestoneMetric.rated: countWhere((g) => g.rating > 0),
      MilestoneMetric.reviews: countWhere((g) => g.review.trim().isNotEmpty),
      if (lists != null) ...{
        MilestoneMetric.lists: lists.length,
        MilestoneMetric.publicLists: lists.where((l) => l.isPublic).length,
        MilestoneMetric.listSize: lists.fold<int>(
          0,
          (most, l) => math.max(most, l.games.length),
        ),
      },
      MilestoneMetric.platforms: {
        for (final g in library)
          if (g.playedOn case final p?) gamePlatformToDb(p),
        for (final s in logged) gamePlatformToDb(s.platform),
      }.length,
      MilestoneMetric.genres: {for (final g in played) ...g.genres}.length,
      MilestoneMetric.retroGames: played
          .where((g) => g.hasReleaseYear && g.releaseYear < 1995)
          .length,
      MilestoneMetric.decades: {
        for (final g in played)
          if (g.hasReleaseYear) g.releaseYear ~/ 10,
      }.length,
      MilestoneMetric.following: ?following,
      MilestoneMetric.followers: ?followers,
      if (profile != null) ...{
        MilestoneMetric.memberMonths: monthsBetween(profile.joined, at),
        MilestoneMetric.foundingMember: profile.joined.isBefore(foundingCutoff)
            ? 1
            : 0,
        MilestoneMetric.profileComplete:
            (profile.avatarUrl?.trim().isNotEmpty ?? false) &&
                (profile.bio?.trim().isNotEmpty ?? false)
            ? 1
            : 0,
      },
      MilestoneMetric.favorites: countWhere((g) => g.isFavorite),
      MilestoneMetric.wishlist: countWhere(
        (g) => g.status == GameStatus.wishlist,
      ),
      MilestoneMetric.dropped: countWhere(
        (g) => g.status == GameStatus.dropped,
      ),
      MilestoneMetric.perfectGames: countWhere((g) => g.isPerfected),
      if (gameAccount != null) MilestoneMetric.gameAccount: gameAccount ? 1 : 0,
      if (twoFactor != null) MilestoneMetric.twoFactor: twoFactor ? 1 : 0,
    });
  }

  /// Members who joined before this are founding members.
  static final foundingCutoff = DateTime.utc(2027);

  /// What is known of each metric; a metric that is missing is not known.
  final Map<MilestoneMetric, num> values;

  num? valueOf(MilestoneMetric metric) => values[metric];

  /// How far towards [m], 0 to 1; null when not known.
  double? fractionOf(Milestone m) {
    final value = values[m.metric];
    if (value == null) return null;
    return (value / m.threshold).clamp(0, 1).toDouble();
  }

  /// Whether this says [m] is reached.
  bool reached(Milestone m) {
    final value = values[m.metric];
    return value != null && value >= m.threshold;
  }

  /// The most days in a row with a session, by the device's calendar.
  static int longestStreak(Iterable<LogEntry> sessions) {
    final days = {
      for (final s in sessions)
        DateTime.utc(s.timestamp.year, s.timestamp.month, s.timestamp.day),
    }.toList()..sort();
    var best = 0;
    var run = 0;
    DateTime? previous;
    for (final day in days) {
      run = previous != null && day.difference(previous).inDays == 1
          ? run + 1
          : 1;
      best = math.max(best, run);
      previous = day;
    }
    return best;
  }

  /// Whole calendar months from [from] to [to]: a month after the 31st of
  /// January is the end of February, as in Postgres.
  static int monthsBetween(DateTime from, DateTime to) {
    final a = from.toUtc();
    final b = to.toUtc();
    var months = (b.year - a.year) * 12 + b.month - a.month;
    if (months > 0 && _addMonths(a, months).isAfter(b)) months--;
    return math.max(0, months);
  }

  // Postgres keeps the day when it can and otherwise takes the month's last.
  static DateTime _addMonths(DateTime d, int months) {
    final firstOfTarget = DateTime.utc(d.year, d.month + months);
    final lastDay = DateTime.utc(
      firstOfTarget.year,
      firstOfTarget.month + 1,
      0,
    ).day;
    return DateTime.utc(
      firstOfTarget.year,
      firstOfTarget.month,
      math.min(d.day, lastDay),
      d.hour,
      d.minute,
      d.second,
      d.millisecond,
    );
  }
}
