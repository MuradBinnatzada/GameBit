import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/release_reminders.dart';

import 'support/fakes.dart';

void main() {
  // A Tuesday, a quarter to eight in the morning.
  final now = DateTime(2026, 11, 3, 7, 45);

  Game wish(String id, DateTime? release, {String? title, int? igdbId = 7, GameStatus? status = GameStatus.wishlist}) =>
      testGame(id, title: title, cover: false, status: status, igdbId: igdbId).copyWith(releaseDate: release);

  group('the reminders to schedule', () {
    test('are the wishlist games with a release to come, soonest first, at the reminder hour', () {
      final reminders = releaseReminders([
        wish('later', DateTime.utc(2026, 12, 25), title: 'Later'),
        wish('soon', DateTime.utc(2026, 11, 5), title: 'Soon'),
        wish('tonight', DateTime.utc(2026, 11, 3), title: 'Today'),
      ], now: now);

      expect([for (final r in reminders) r.game.id], ['tonight', 'soon', 'later']);
      expect(reminders.first.at, DateTime(2026, 11, 3, reminderHour));
      expect(reminders.last.at, DateTime(2026, 12, 25, reminderHour));
    });

    test('leave out what is out, what has no date, what is not on the wishlist, and what has no IGDB id', () {
      final reminders = releaseReminders([
        wish('out', DateTime.utc(2026, 10, 1)),
        wish('undated', null),
        wish('playing', DateTime.utc(2026, 12, 1), status: GameStatus.playing),
        wish('custom', DateTime.utc(2026, 12, 1), igdbId: null),
        wish('ok', DateTime.utc(2026, 12, 1)),
      ], now: now);

      expect([for (final r in reminders) r.game.id], ['ok']);
    });

    test('have none for a release day whose hour has gone by', () {
      final games = [wish('today', DateTime.utc(2026, 11, 3))];

      expect(releaseReminders(games, now: DateTime(2026, 11, 3, 8, 59)), hasLength(1));
      expect(releaseReminders(games, now: DateTime(2026, 11, 3, 9)), isEmpty);
      expect(releaseReminders(games, now: DateTime(2026, 11, 3, 15)), isEmpty);
    });

    test('are the nearest ones when there are more than can be kept; ties go by title', () {
      final games = [
        for (var i = 0; i < 70; i++) wish('g$i', DateTime.utc(2026, 11, 4).add(Duration(days: i)), title: 'Game ${69 - i}'),
        wish('b', DateTime.utc(2026, 11, 4), title: 'B'),
        wish('a', DateTime.utc(2026, 11, 4), title: 'A'),
      ];

      final reminders = releaseReminders(games, now: now);

      expect(reminders, hasLength(maxReminders));
      // The two released with g0 (Game 69) come in title order.
      expect([for (final r in reminders.take(3)) r.game.title], ['A', 'B', 'Game 69']);
      expect(releaseReminders(games, now: now, limit: 5), hasLength(5));
    });
  });

  test('a moment in local time keeps its instant when written in UTC, which is how it is scheduled', () {
    final local = DateTime(2026, 11, 5, reminderHour);

    final scheduled = tz.TZDateTime.from(local, tz.UTC);

    expect(scheduled.millisecondsSinceEpoch, local.millisecondsSinceEpoch);
  });
}
