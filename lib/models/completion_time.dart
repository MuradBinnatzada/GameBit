import 'package:flutter/foundation.dart';

import 'package:checkpoint/l10n/l10n.dart';

/// Which run of a game a completion time is for: HowLongToBeat's three.
enum CompletionCategory {
  mainStory('main'),
  mainExtras('main_extra'),
  completionist('completionist');

  const CompletionCategory(this.wire);

  /// `completion_times.category`.
  final String wire;

  String get label => switch (this) {
    mainStory => L10n.current.completionMainStory,
    mainExtras => L10n.current.completionMainExtras,
    completionist => L10n.current.completionCompletionist,
  };

  /// The category stored as [wire], or null when it is not one this build knows.
  static CompletionCategory? fromWire(Object? wire) {
    for (final category in values) {
      if (category.wire == wire) return category;
    }
    return null;
  }
}

/// How long the member took to finish a game they completed, in one
/// [category] (`completion_times`, at most one per game). Whole minutes, as
/// stored.
@immutable
class CompletionTime {
  const CompletionTime(this.category, this.minutes);

  final CompletionCategory category;
  final int minutes;

  /// From [toJson]'s output or a `completion_times` row; null when it isn't one.
  static CompletionTime? fromJson(Object? json) {
    if (json is! Map) return null;
    final category = CompletionCategory.fromWire(json['category']);
    final raw = json['minutes'];
    final minutes = raw is num ? raw : num.tryParse('$raw');
    if (category == null ||
        minutes == null ||
        !minutes.isFinite ||
        minutes < 1) {
      return null;
    }
    return CompletionTime(category, minutes.round());
  }

  Map<String, dynamic> toJson() => {
    'category': category.wire,
    'minutes': minutes,
  };

  @override
  bool operator ==(Object other) =>
      other is CompletionTime &&
      other.category == category &&
      other.minutes == minutes;

  @override
  int get hashCode => Object.hash(category, minutes);

  @override
  String toString() => 'CompletionTime(${category.wire}, $minutes min)';
}

/// Fewer times than this in a category and a game's screen shows IGDB's figure
/// for it instead of Gamebit's.
const minCommunityTimes = 5;

/// What Gamebit's members reported for one category of a game: the median
/// and how many times it is the median of (`completion_time_stats`, which
/// leaves out times under 10 minutes and over 1 000 hours).
@immutable
class CommunityTime {
  const CommunityTime({required this.median, required this.count});

  final Duration median;
  final int count;
}

/// [CommunityTime]s of one game, by category. A category nobody reported a
/// time for is missing.
@immutable
class CommunityTimes {
  const CommunityTimes([this.byCategory = const {}]);

  final Map<CompletionCategory, CommunityTime> byCategory;

  /// [category]'s figure when at least [minCommunityTimes] members reported
  /// one, or null: too few to go by.
  CommunityTime? shown(CompletionCategory category) {
    final time = byCategory[category];
    return time != null && time.count >= minCommunityTimes ? time : null;
  }

  /// Whether any category has enough times to be shown.
  bool get hasShown => CompletionCategory.values.any((c) => shown(c) != null);
}
