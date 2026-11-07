import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/game.dart';

/// One play session.
@immutable
class LogEntry {
  const LogEntry({
    required this.id,
    required this.gameId,
    required this.timestamp,
    required this.hours,
    required this.platform,
    this.note = '',
    this.fromSteam = false,
    this.fromPlayStation = false,
  });

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
        id: json['id'] as String,
        gameId: json['gameId'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String).toLocal(),
        hours: (json['hours'] as num).toDouble(),
        platform: gamePlatformFromDb(json['platform']) ?? GamePlatform.pc,
        note: json['note'] as String? ?? '',
        fromSteam: json['source'] == 'steam',
        fromPlayStation: json['source'] == 'playstation',
      );

  final String id;
  final String gameId;
  final DateTime timestamp;
  final double hours;
  final GamePlatform platform;
  final String note;

  /// Logged by the Steam sync from a rise in the game's Steam playtime, not by
  /// the member (`log_entries.source`).
  final bool fromSteam;

  /// Logged by the PlayStation sync, from a rise in the game's PlayStation play
  /// time (`log_entries.source`).
  final bool fromPlayStation;

  /// Logged by a sync (Steam's or PlayStation's), not by the member.
  bool get isSynced => fromSteam || fromPlayStation;

  /// What the offline cache keeps of this session; read back by [LogEntry.fromJson].
  Map<String, dynamic> toJson() => {
        'id': id,
        'gameId': gameId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'hours': hours,
        'platform': gamePlatformToDb(platform),
        'note': note,
        if (fromSteam) 'source': 'steam',
        if (fromPlayStation) 'source': 'playstation',
      };
}
