import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/models/year_review.dart';
import 'package:checkpoint/sheets/year_review_share_sheet.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/utils/image_share.dart';
import 'package:checkpoint/widgets/year_review_card.dart';

import 'support/fakes.dart';

void main() {
  final year = DateTime.now().year;

  /// Six games played 10, 8, 6, 4, 3 and 2 hours, one session each, over six months.
  YearReview fullReview() {
    final names = ['Hades', 'Celeste', 'Hollow Knight', 'Outer Wilds', 'Disco Elysium', 'Tunic'];
    const hours = [10.0, 8.0, 6.0, 4.0, 3.0, 2.0];
    return YearReview.of(
      year: year,
      games: [
        for (var i = 0; i < names.length; i++)
          testGame('g$i', title: names[i], cover: false, genres: i.isEven ? const ['RPG'] : const ['Platform', 'Adventure']),
      ],
      sessions: [
        for (var i = 0; i < names.length; i++)
          LogEntry(id: 's$i', gameId: 'g$i', timestamp: DateTime(year, i + 1, 5, 20), hours: hours[i], platform: GamePlatform.pc),
      ],
    );
  }

  /// A year with a completion and no session: one card to share.
  YearReview completionsOnly() => YearReview.of(
    year: year,
    games: [testGame('g1', title: 'Celeste', cover: false, status: GameStatus.completed).withCompletedAt(DateTime(year, 3, 2))],
    sessions: const [],
  );

  Future<void> pumpCard(WidgetTester tester, Widget card) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: buildTheme(), home: Scaffold(body: Center(child: card))),
    );
  }

  group('the cards', () {
    testWidgets('the overview says the year in numbers', (tester) async {
      await pumpCard(tester, YearOverviewCard(review: fullReview()));

      expect(find.text('Gamebit'), findsOneWidget);
      expect(find.text('$year'), findsOneWidget);
      expect(find.text('33 h'), findsOneWidget);
      expect(find.textContaining('over 6 sessions of 6 games'), findsOneWidget);
      expect(find.text('Days played'), findsOneWidget);
      expect(find.text('Longest streak (days)'), findsOneWidget);
      expect(find.text('Games added'), findsOneWidget);
      expect(find.text('Games completed'), findsOneWidget);
      expect(tester.getSize(find.byType(YearOverviewCard)), yearCardSize);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the top games card lists five games and three genres', (tester) async {
      await pumpCard(tester, YearTopGamesCard(review: fullReview()));

      expect(find.text('Most played'), findsOneWidget);
      for (final title in ['Hades', 'Celeste', 'Hollow Knight', 'Outer Wilds', 'Disco Elysium']) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.text('Tunic'), findsNothing);
      expect(find.text('10 h'), findsOneWidget);
      expect(find.text('Top genres'), findsOneWidget);
      expect(tester.getSize(find.byType(YearTopGamesCard)), yearCardSize);
      expect(tester.takeException(), isNull);
    });

    testWidgets('they keep their size at the largest text size, with long titles', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final review = YearReview.of(
        year: year,
        games: [
          for (var i = 0; i < 5; i++)
            testGame('g$i', title: 'A very long game title that cannot fit on one line number $i', cover: false),
        ],
        sessions: [
          for (var i = 0; i < 5; i++)
            LogEntry(id: 's$i', gameId: 'g$i', timestamp: DateTime(year, 2, 1 + i, 20), hours: 1234.5 - i, platform: GamePlatform.pc),
        ],
      );

      await pumpCard(tester, YearTopGamesCard(review: review));
      expect(tester.takeException(), isNull);
      await pumpCard(tester, YearOverviewCard(review: review));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(YearOverviewCard)), yearCardSize);
    });

    testWidgets('they fit in Russian', (tester) async {
      await initializeDateFormatting('ru');
      L10n.use(const Locale('ru'));
      addTearDown(() => L10n.use(L10n.english));

      await pumpCard(tester, YearOverviewCard(review: fullReview()));
      expect(find.text('Gamebit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await pumpCard(tester, YearTopGamesCard(review: fullReview()));
      expect(find.text(L10n.current.mostPlayed), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('capturePng', () {
    testWidgets('draws a card as a 1080 x 1350 PNG', (tester) async {
      final key = GlobalKey();
      await pumpCard(tester, RepaintBoundary(key: key, child: YearOverviewCard(review: fullReview())));

      final bytes = await tester.runAsync(() => capturePng(key));

      expect(bytes, isNotNull);
      // The PNG signature, then IHDR: width and height as big-endian 32-bit numbers.
      expect(bytes!.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      final header = ByteData.sublistView(bytes, 16, 24);
      expect((header.getUint32(0), header.getUint32(4)), (1080, 1350));
    });

    testWidgets('gives nothing for a key that is not on screen', (tester) async {
      final bytes = await tester.runAsync(() => capturePng(GlobalKey()));
      expect(bytes, isNull);
    });
  });

  group('the share sheet', () {
    late List<({String name, Uint8List bytes, String text})> shared;
    late Completer<void> called;
    late Future<bool> Function() outcome;

    setUp(() {
      shared = [];
      called = Completer<void>();
      outcome = () async => true;
    });

    Future<bool> fakeSave(String name, Uint8List bytes, String text, Rect? origin) async {
      shared.add((name: name, bytes: bytes, text: text));
      called.complete();
      return outcome();
    }

    Future<void> openSheet(WidgetTester tester, YearReview review) async {
      tester.view.physicalSize = const Size(412, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: YearReviewShareSheet(review: review, saveImage: fakeSave)),
        ),
      );
    }

    /// Taps Share and waits for the picture to be drawn and handed to [fakeSave].
    Future<void> share(WidgetTester tester) async {
      await tester.tap(find.text('Share'));
      await tester.pump();
      await tester.runAsync(() => called.future.timeout(const Duration(seconds: 10)));
      await tester.pump();
    }

    testWidgets('shares the overview as a PNG with a caption', (tester) async {
      await openSheet(tester, fullReview());
      expect(find.text('Share your year'), findsOneWidget);

      await share(tester);

      expect(shared, hasLength(1));
      expect(shared.single.name, 'gamebit-$year-overview.png');
      expect(shared.single.bytes.sublist(1, 4), [0x50, 0x4E, 0x47]);
      expect(shared.single.text, 'My $year in games, on Gamebit');
      expect(find.text('Could not save the file.'), findsNothing);
    });

    testWidgets('shares the card that is on screen after a swipe', (tester) async {
      await openSheet(tester, fullReview());

      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1500);
      await tester.pumpAndSettle();
      await share(tester);

      expect(shared.single.name, 'gamebit-$year-most-played.png');
    });

    testWidgets('a year with nothing to rank has the one card', (tester) async {
      await openSheet(tester, completionsOnly());
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1500);
      await tester.pumpAndSettle();
      expect(find.text('Most played'), findsNothing);

      await share(tester);

      expect(shared.single.name, 'gamebit-$year-overview.png');
    });

    testWidgets('says so when the picture could not be handed on', (tester) async {
      outcome = () async => throw StateError('no share sheet');
      await openSheet(tester, fullReview());

      await share(tester);

      expect(find.text('Could not save the file.'), findsOneWidget);
      // The button is usable again.
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    });

    testWidgets('cancelling the share sheet is not an error', (tester) async {
      outcome = () async => false;
      await openSheet(tester, fullReview());

      await share(tester);

      expect(find.text('Could not save the file.'), findsNothing);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    });
  });
}
