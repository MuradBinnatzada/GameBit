import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:checkpoint/models/library_stats.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/widgets/ratings_panel.dart';
import 'package:checkpoint/widgets/star_rating.dart';

/// The ratings chart of a profile: bars that stay quiet until tapped.
void main() {
  // Three games at one star, two at nine and three at ten.
  final stats = LibraryStats(
    ratingCounts: {1: 3, 9: 2, 10: 3},
    ratedCount: 8,
    averageRating: 6.8,
  );

  Future<void> show(WidgetTester tester, LibraryStats stats) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: RatingsPanel(stats: stats)),
      ),
    );
  }

  // The bars are the only tappable things in the panel (the star row of the
  // average is read-only), lowest rating first.
  Finder bar(int i) => find
      .descendant(
        of: find.byType(RatingsPanel),
        matching: find.byType(GestureDetector),
      )
      .at(i);

  testWidgets('counts how the ratings spread: 10 bars from 1 star to 10', (
    tester,
  ) async {
    await show(tester, stats);

    expect(
      find.descendant(
        of: find.byType(RatingsPanel),
        matching: find.byType(GestureDetector),
      ),
      findsNWidgets(10),
    );
    expect(RatingsPanel.bars.first, 1);
    expect(RatingsPanel.bars.last, 10);
    expect(RatingsPanel.countFor(stats, 1), 3);
    expect(RatingsPanel.countFor(stats, 9), 2);
    expect(RatingsPanel.countFor(stats, 3), 0);
  });

  testWidgets('the axis reads 1 to 10, and the "8 rated" total stays', (
    tester,
  ) async {
    await show(tester, stats);

    expect(find.text('1'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text('8 rated'), findsOneWidget);
  });

  testWidgets('no count is shown until a bar is tapped', (tester) async {
    await show(tester, stats);

    expect(find.textContaining('game'), findsNothing);
    // No numbers over the bars.
    expect(find.text('3'), findsNothing);
    expect(find.text('2'), findsNothing);
    // Only the average's stars.
    expect(find.byType(StarRating), findsOneWidget);
  });

  testWidgets('tapping a bar shows its stars and the number of games', (
    tester,
  ) async {
    await show(tester, stats);

    await tester.tap(bar(9)); // 10 stars
    await tester.pump();

    expect(find.text('3 games'), findsOneWidget);
    // The bubble is the number and one star, not another row of ten.
    expect(find.byType(StarRating), findsOneWidget);
    expect(find.text('10'), findsNWidgets(2)); // the axis and the bubble
  });

  testWidgets('one game is "1 game"', (tester) async {
    await show(
      tester,
      LibraryStats(ratingCounts: {7: 1}, ratedCount: 1, averageRating: 7),
    );

    await tester.tap(bar(6)); // 7 stars
    await tester.pump();

    expect(find.text('1 game'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('a bar nobody picked says 0 games', (tester) async {
    await show(tester, stats);

    await tester.tap(bar(2)); // 3 stars
    await tester.pump();

    expect(find.text('0 games'), findsOneWidget);
  });

  testWidgets(
    'tapping another bar moves the bubble; tapping it again hides it',
    (tester) async {
      await show(tester, stats);

      await tester.tap(bar(9));
      await tester.pump();
      await tester.tap(bar(8)); // 9 stars
      await tester.pump();
      expect(find.text('3 games'), findsNothing);
      expect(find.text('2 games'), findsOneWidget);

      await tester.tap(bar(8));
      await tester.pump();
      expect(find.textContaining('game'), findsNothing);
    },
  );

  testWidgets('the first bar is the games with one star', (tester) async {
    await show(tester, stats);

    await tester.tap(bar(0));
    await tester.pump();

    expect(find.text('3 games'), findsOneWidget);
    expect(find.text('≤'), findsNothing);
  });

  testWidgets('a member who rated nothing sees no chart', (tester) async {
    await show(tester, const LibraryStats());

    expect(find.text('No rated games yet.'), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);
  });

  testWidgets('the bubble stays inside the chart for the bars at either edge', (
    tester,
  ) async {
    // A narrow phone: the chart is about 180 px wide, the bubble a good part of it.
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await show(tester, stats);
    final chart = tester.getRect(find.byType(RatingsPanel));

    for (final i in [0, 9]) {
      await tester.tap(bar(i));
      await tester.pump();
      final bubble = tester.getRect(find.byType(DecoratedBox).last);
      expect(bubble.left, greaterThanOrEqualTo(chart.left));
      expect(bubble.right, lessThanOrEqualTo(chart.right));
      expect(tester.takeException(), isNull);
      await tester.tap(bar(i)); // off again
      await tester.pump();
    }
  });
}
