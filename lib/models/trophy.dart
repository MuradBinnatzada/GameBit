import 'package:flutter/foundation.dart';

/// The four kinds of PlayStation trophy, by value: the Platinum is earned by
/// getting every other one of a game.
enum TrophyGrade {
  bronze,
  silver,
  gold,
  platinum;

  /// One letter, what a stored list calls the grade.
  String get code => name[0];

  static TrophyGrade? fromCode(Object? code) {
    for (final grade in values) {
      if (grade.code == code || grade.name == code) return grade;
    }
    return null;
  }
}

/// One trophy of a game, as the member's last PlayStation import read it: what it
/// is called and asks for, and whether and when they earned it. A game's list is
/// stored whole on `user_games.trophies` (like the Steam achievements of
/// [Achievement]), in the language the member's app was in at the time.
@immutable
class Trophy {
  const Trophy({
    required this.id,
    required this.grade,
    required this.name,
    this.detail = '',
    this.iconUrl,
    this.earned = false,
    this.earnedAt,
    this.rarity,
    this.earnedRate,
    this.hidden = false,
  });

  /// Sony's number for the trophy within its game (0 is the Platinum, if any).
  final int id;
  final TrophyGrade grade;
  final String name;

  /// What it asks for ("Finish the game on Hard").
  final String detail;
  final String? iconUrl;
  final bool earned;
  final DateTime? earnedAt;

  /// How rare Sony calls it: 0 ultra rare, 1 very rare, 2 rare, 3 common. Null: unknown.
  final int? rarity;

  /// The share of players who earned it, 0 to 100. Null: unknown.
  final double? earnedRate;

  /// A secret trophy: what it asks for stays unknown until it is earned.
  final bool hidden;

  /// The trophy as stored in the list (short keys: a game has dozens).
  Map<String, Object?> toJson() => {
    'i': id,
    'g': grade.code,
    'n': name,
    if (detail.isNotEmpty) 'd': detail,
    if (iconUrl != null) 'u': iconUrl,
    if (earned) 'e': 1,
    if (earnedAt != null) 'a': earnedAt!.toUtc().toIso8601String(),
    if (rarity != null) 'r': rarity,
    if (earnedRate != null) 'p': earnedRate,
    if (hidden) 'h': 1,
  };

  /// A trophy from [toJson]'s output; null when [json] is not one.
  static Trophy? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['i'];
    final grade = TrophyGrade.fromCode(json['g']);
    final name = json['n'];
    if (id is! num || grade == null || name is! String) return null;
    final at = json['a'];
    final url = json['u'];
    final rarity = json['r'];
    final rate = json['p'];
    return Trophy(
      id: id.toInt(),
      grade: grade,
      name: name,
      detail: json['d'] is String ? json['d'] as String : '',
      iconUrl: url is String && url.startsWith('https://') ? url : null,
      earned: json['e'] == 1 || json['e'] == true,
      earnedAt: at is String ? DateTime.tryParse(at)?.toLocal() : null,
      rarity: rarity is num ? rarity.toInt() : null,
      earnedRate: rate is num ? rate.toDouble() : null,
      hidden: json['h'] == 1 || json['h'] == true,
    );
  }

  /// A stored list: null when [json] is not a list (never loaded), the trophies
  /// it holds otherwise, in Sony's order. Anything in it that is not a trophy is
  /// dropped.
  static List<Trophy>? listFromJson(Object? json) {
    if (json is! List) return null;
    return [
      for (final item in json) ?fromJson(item),
    ];
  }

  static Object listToJson(List<Trophy> trophies) => [for (final t in trophies) t.toJson()];
}

/// How many trophies of each grade, earned out of all.
@immutable
class TrophyCounts {
  const TrophyCounts({this.bronze = 0, this.silver = 0, this.gold = 0, this.platinum = 0});

  final int bronze;
  final int silver;
  final int gold;
  final int platinum;

  int get total => bronze + silver + gold + platinum;

  int of(TrophyGrade grade) => switch (grade) {
    TrophyGrade.bronze => bronze,
    TrophyGrade.silver => silver,
    TrophyGrade.gold => gold,
    TrophyGrade.platinum => platinum,
  };

  /// The earned trophies of [trophies], by grade.
  factory TrophyCounts.earnedIn(Iterable<Trophy> trophies) {
    final n = {for (final g in TrophyGrade.values) g: 0};
    for (final t in trophies) {
      if (t.earned) n[t.grade] = n[t.grade]! + 1;
    }
    return TrophyCounts(
      bronze: n[TrophyGrade.bronze]!,
      silver: n[TrophyGrade.silver]!,
      gold: n[TrophyGrade.gold]!,
      platinum: n[TrophyGrade.platinum]!,
    );
  }

  TrophyCounts operator +(TrophyCounts other) => TrophyCounts(
    bronze: bronze + other.bronze,
    silver: silver + other.silver,
    gold: gold + other.gold,
    platinum: platinum + other.platinum,
  );
}

/// One game's trophy progress for a member: what `public_trophy_summary` returns.
/// The trophies themselves are fetched per game, when it is opened.
@immutable
class GameTrophySummary {
  const GameTrophySummary({
    required this.gameId,
    required this.title,
    required this.earned,
    required this.total,
    this.coverUrl,
    this.counts = const TrophyCounts(),
  });

  final String gameId;
  final String title;
  final String? coverUrl;

  /// Trophies earned out of the game's, all grades together.
  final int earned;
  final int total;

  /// The earned ones by grade.
  final TrophyCounts counts;

  double get progress => total == 0 ? 0 : earned / total;
  bool get complete => total > 0 && earned >= total;
  bool get hasPlatinum => counts.platinum > 0;
}

/// A member's trophies added up over every game that has a list stored.
@immutable
class TrophyTotals {
  const TrophyTotals({this.counts = const TrophyCounts(), this.earned = 0, this.total = 0, this.games = 0, this.completedGames = 0});

  final TrophyCounts counts;
  final int earned;
  final int total;
  final int games;
  final int completedGames;

  bool get isEmpty => games == 0;
  double get progress => total == 0 ? 0 : earned / total;

  factory TrophyTotals.of(Iterable<GameTrophySummary> games) {
    var counts = const TrophyCounts();
    var earned = 0;
    var total = 0;
    var n = 0;
    var done = 0;
    for (final g in games) {
      counts += g.counts;
      earned += g.earned;
      total += g.total;
      n++;
      if (g.complete) done++;
    }
    return TrophyTotals(counts: counts, earned: earned, total: total, games: n, completedGames: done);
  }
}
