import 'package:flutter/foundation.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/social_user.dart';

/// The order of the reviews of a game. [wireName] is the `sort_by` the
/// `game_reviews` function takes.
enum ReviewSort {
  friends('friends'),
  newest('newest'),
  highest('highest'),
  lowest('lowest');

  const ReviewSort(this.wireName);
  final String wireName;

  String get label => switch (this) {
    friends => L10n.current.reviewSortFriends,
    newest => L10n.current.reviewSortNewest,
    highest => L10n.current.reviewSortHighest,
    lowest => L10n.current.reviewSortLowest,
  };
}

/// What the reviews of a game are narrowed to and ordered by.
@immutable
class ReviewFilter {
  const ReviewFilter({
    this.sort = ReviewSort.friends,
    this.onlyFollowing = false,
  });

  /// Friends first, then the newest, from everyone: what the game's screen shows.
  static const standard = ReviewFilter();

  final ReviewSort sort;

  /// Only the members the signed-in one follows.
  final bool onlyFollowing;

  ReviewFilter withSort(ReviewSort sort) =>
      ReviewFilter(sort: sort, onlyFollowing: onlyFollowing);

  ReviewFilter withOnlyFollowing(bool onlyFollowing) =>
      ReviewFilter(sort: sort, onlyFollowing: onlyFollowing);

  @override
  bool operator ==(Object other) =>
      other is ReviewFilter &&
      other.sort == sort &&
      other.onlyFollowing == onlyFollowing;

  @override
  int get hashCode => Object.hash(sort, onlyFollowing);
}

/// One member's review of a game, with what they had done with the game when
/// they wrote it (their status, rating and hours: what makes a review worth
/// weighing).
@immutable
class GameReview {
  const GameReview({
    required this.member,
    required this.text,
    this.status,
    this.rating = 0,
    this.hours = 0,
    this.writtenAt,
    this.isFollowing = false,
  });

  final SocialUser member;
  final String text;
  final GameStatus? status;

  /// Out of 5, in halves; 0 when they did not rate the game.
  final double rating;
  final double hours;

  /// When the review was written or last changed.
  final DateTime? writtenAt;

  /// Whether the signed-in member follows the author.
  final bool isFollowing;
}

/// Why a review, a discussion post, a profile or a list is reported. [wireName]
/// is the `reason` of `review_reports`, `discussion_reports` and `user_reports`.
enum ReportReason {
  spam('spam'),
  abuse('abuse'),
  other('other');

  const ReportReason(this.wireName);
  final String wireName;

  String get label => switch (this) {
    spam => L10n.current.reportReasonSpam,
    abuse => L10n.current.reportReasonAbuse,
    other => L10n.current.reportReasonOther,
  };
}

/// What of a member is reported (the `subject` of `user_reports`).
enum MemberReportSubject {
  profile('profile'),
  avatar('avatar'),
  list('list');

  const MemberReportSubject(this.wireName);
  final String wireName;
}

/// How the members rated a game: how many did, the average, how many wrote a
/// review, and how many gave each half star (the `game_review_stats` function).
@immutable
class CommunityRatings {
  const CommunityRatings({
    this.ratings = 0,
    this.average = 0,
    this.reviews = 0,
    this.halfStars = const [],
  });

  /// Members who rated the game.
  final int ratings;

  /// Their average rating out of 5; 0 when nobody rated it.
  final double average;

  /// Members who wrote a review.
  final int reviews;

  /// How many gave 0.5, 1, 1.5 ... 5 stars: ten entries, or none.
  final List<int> halfStars;

  bool get isEmpty => ratings == 0 && reviews == 0;

  /// How many gave [stars] (1 to 5): a rating in the half star under it counts
  /// too, so 4 holds 3.5 and 4, and 1 holds 0.5 and 1.
  int countForStars(int stars) {
    final high = stars * 2 - 1;
    final low = high - 1;
    return [low, high].fold(
      0,
      (sum, i) => i >= 0 && i < halfStars.length ? sum + halfStars[i] : sum,
    );
  }

  /// What the `game_review_stats` function answered (one row), or null when it
  /// is not such a row.
  static CommunityRatings? fromRow(Object? row) {
    if (row is! Map) return null;
    int whole(Object? v) => v is num && v.isFinite && v > 0 ? v.toInt() : 0;
    final stars = row['half_stars'];
    final average = row['average'];
    return CommunityRatings(
      ratings: whole(row['ratings']),
      average: average is num && average.isFinite
          ? average.toDouble().clamp(0, 5).toDouble()
          : 0,
      reviews: whole(row['reviews']),
      halfStars: [
        if (stars is List)
          for (final n in stars) whole(n),
      ],
    );
  }
}
