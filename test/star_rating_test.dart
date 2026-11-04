import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/widgets/star_rating.dart';

/// The ten stars: what a tap or a drag gives (half a star on the left of a star,
/// the whole star on the right), and how they fit a narrow place.
void main() {
  Future<void> show(
    WidgetTester tester, {
    double rating = 0,
    double size = 30,
    double? width,
    ValueChanged<double>? onChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: StarRating(rating: rating, size: size, onChanged: onChanged),
            ),
          ),
        ),
      ),
    );
  }

  int count(WidgetTester tester, IconData icon) => find.byIcon(icon).evaluate().length;

  testWidgets('shows ten stars: the rating filled, the rest outlined', (tester) async {
    await show(tester, rating: 7);

    expect(count(tester, Icons.star_rounded), 7);
    expect(count(tester, Icons.star_outline_rounded), 3);
    expect(count(tester, Icons.star_half_rounded), 0);
  });

  testWidgets('a half rating, or an average, ends on a half star', (tester) async {
    await show(tester, rating: 7.5);

    expect(count(tester, Icons.star_rounded), 7);
    expect(count(tester, Icons.star_half_rounded), 1);
    expect(count(tester, Icons.star_outline_rounded), 2);
  });

  testWidgets('a tap gives the star under the finger: the left half is half a star', (tester) async {
    final given = <double>[];
    await show(tester, size: 30, onChanged: given.add);
    final origin = tester.getTopLeft(find.byType(StarRating));
    // 30 px stars, centred in the 48 px high target.
    final y = origin.dy + 24;

    await tester.tapAt(Offset(origin.dx + 5, y)); // the left of the first star
    await tester.tapAt(Offset(origin.dx + 20, y)); // its right
    await tester.tapAt(Offset(origin.dx + 40, y)); // the left of the second
    await tester.tapAt(Offset(origin.dx + 299, y)); // the right of the last
    await tester.pump();

    expect(given, [0.5, 1, 1.5, 10]);
  });

  testWidgets('dragging across the stars follows the finger', (tester) async {
    final given = <double>[];
    await show(tester, size: 30, onChanged: given.add);
    final origin = tester.getTopLeft(find.byType(StarRating));
    final y = origin.dy + 24;

    final gesture = await tester.startGesture(Offset(origin.dx + 5, y));
    await gesture.moveTo(Offset(origin.dx + 95, y));
    await gesture.moveTo(Offset(origin.dx + 185, y));
    await gesture.up();

    expect(given.last, 6.5); // 185 px of 30 px stars: the left of the seventh
    expect(given.every((v) => v * 2 == (v * 2).roundToDouble() && v >= 0.5 && v <= 10), isTrue);
  });

  testWidgets('ten stars too wide for the room shrink, and a tap still lands on the right one', (tester) async {
    final given = <double>[];
    await show(tester, size: 44, width: 250, onChanged: given.add); // 440 wanted
    final box = tester.getRect(find.byType(StarRating));

    expect(box.width, lessThanOrEqualTo(250));
    expect(tester.takeException(), isNull);

    await tester.tapAt(Offset(box.left + box.width - 2, box.top + 24));
    await tester.tapAt(Offset(box.left + 2, box.top + 24));
    expect(given, [10, 0.5]);
  });

  testWidgets('a read-only row narrower than ten stars shrinks instead of overflowing', (tester) async {
    await show(tester, rating: 4, size: 14, width: 100); // 140 wanted

    expect(tester.getSize(find.byType(StarRating)).width, lessThanOrEqualTo(100));
    expect(tester.takeException(), isNull);
  });
}
