import 'package:checkpoint/models/game.dart';

/// A wishlist game and the moment to remind the member it comes out: [at] is
/// [reminderHour] o'clock, on the device's clock, on the release day.
typedef ReleaseReminder = ({Game game, DateTime at});

/// The hour of the release day the reminder is shown at: after people are up,
/// before most are at play.
const reminderHour = 9;

/// The most reminders kept at once. iOS keeps 64 scheduled notifications per
/// app and drops the rest, so the nearest releases are the ones that count.
const maxReminders = 60;

/// The reminders to have scheduled for [library] at [now]: its wishlist games
/// that have a release date still to come, soonest first, at most [limit]. A
/// game whose reminder hour has gone by on its release day has none: the app
/// already tells the member about it (see [releaseAlerts]). A game is found
/// again from its IGDB id, so one without is left out.
List<ReleaseReminder> releaseReminders(
  List<Game> library, {
  required DateTime now,
  int limit = maxReminders,
}) {
  final reminders = <ReleaseReminder>[
    for (final g in library)
      if (g.status == GameStatus.wishlist && g.igdbId != null && g.releaseDate != null)
        (game: g, at: _at(g.releaseDate!)),
  ].where((r) => r.at.isAfter(now)).toList()
    ..sort((a, b) {
      final c = a.at.compareTo(b.at);
      return c != 0 ? c : a.game.title.compareTo(b.game.title);
    });
  return reminders.take(limit).toList();
}

/// The reminder hour on the calendar day [releaseDate] names. Its own year,
/// month and day are the day, as in [releaseAlerts].
DateTime _at(DateTime releaseDate) =>
    DateTime(releaseDate.year, releaseDate.month, releaseDate.day, reminderHour);
