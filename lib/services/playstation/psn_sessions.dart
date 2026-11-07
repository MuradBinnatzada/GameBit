import 'package:checkpoint/models/limits.dart';

/// Play sessions from PlayStation play time, by the same rules as Steam's
/// (`supabase/functions/_shared/steam_sessions.ts`). Sony only says how long a game
/// has been played in all and when it was last played. The phone keeps the play time
/// it saw for each game ([PsnDevice.storedPlaytime]); a later sync that sees more logs
/// the difference as one play session, dated when Sony says the game was last played.
///
/// The first time a game's play time is seen (a game just imported, or one from
/// before this existed) only the baseline is kept: that play time is the game's whole
/// history, not a session.
///
/// Pure, so the rules can be tested without Sony or a phone.

/// Less than this since the last session is kept for the next sync rather than
/// logged, so short plays add up to a session instead of being dropped.
const psnMinSessionMinutes = 5;

/// One play session to log.
class PsnSession {
  const PsnSession({required this.hours, required this.at});

  /// Rounded to hundredths of an hour.
  final double hours;

  /// When Sony says the game was last played; now when it does not say (or says
  /// the future).
  final DateTime at;
}

/// What a sync writes for one game: the play time to remember afterwards, and the
/// session to log, if any.
class PsnPlaytimeUpdate {
  const PsnPlaytimeUpdate({required this.baseline, this.session});

  /// The value to remember, in minutes.
  final int baseline;
  final PsnSession? session;
}

/// What to do with a game that now has [minutes] of play time, when the phone
/// remembers [before] (null: it has not seen the game yet).
///
/// A play time that went down (Sony corrected it) becomes the new baseline without a
/// session. A rise under [psnMinSessionMinutes] keeps the old baseline.
PsnPlaytimeUpdate psnPlaytimeUpdate({
  required int minutes,
  required int? before,
  required DateTime? lastPlayed,
  required DateTime now,
}) {
  final seen = minutes < 0 ? 0 : minutes;
  if (before == null || seen < before) return PsnPlaytimeUpdate(baseline: seen);
  final played = seen - before;
  if (played < psnMinSessionMinutes) return PsnPlaytimeUpdate(baseline: before);
  final hours = ((played / 60) * 100).round() / 100;
  final at = lastPlayed != null && !lastPlayed.isAfter(now) ? lastPlayed : now;
  return PsnPlaytimeUpdate(
    baseline: seen,
    session: PsnSession(hours: hours > maxTotalHours ? maxTotalHours : hours, at: at),
  );
}
