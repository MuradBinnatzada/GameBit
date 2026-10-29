import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/screens/stats/year_review_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/widgets/year_review_card.dart';

import 'support/fakes.dart';

void main() {
  late FakeRepository repo;
  late AppStores stores;
  final year = DateTime.now().year;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository()
      ..library = [
        testGame('g1', title: 'Hades', cover: false),
        testGame('g2', title: 'Celeste', cover: false, status: GameStatus.completed)
            .withCompletedAt(DateTime(year, 1, 20)),
      ]
      ..logs = [
        LogEntry(id: 's1', gameId: 'g1', timestamp: DateTime(year, 1, 10, 20), hours: 3, platform: GamePlatform.pc),
        LogEntry(id: 's2', gameId: 'g2', timestamp: DateTime(year, 1, 11, 20), hours: 1.5, platform: GamePlatform.nswitch),
        LogEntry(id: 's3', gameId: 'g1', timestamp: DateTime(year - 1, 6, 1, 20), hours: 8, platform: GamePlatform.pc),
      ];
    stores = AppStores(
      repository: repo,
      authService: FakeAuthService(testUser('u1')),
      connectivity: FakeConnectivity(),
      apiService: FakeBrowseApi(),
    );
  });

  Future<void> open(WidgetTester tester, {double width = 800}) async {
    tester.view.physicalSize = Size(width, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: buildTheme(), home: const YearReviewScreen()),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pumpAndSettle();
  }

  testWidgets('sums up the year, and another year from its chip', (tester) async {
    await open(tester);

    expect(find.text('4.5 h'), findsWidgets);
    expect(find.textContaining('over 2 sessions of 2 games'), findsOneWidget);
    expect(find.text('Hours by month'), findsOneWidget);
    expect(find.text('Most played'), findsOneWidget);
    expect(find.text('Completed in $year'), findsOneWidget);
    expect(find.text('Hours by platform'), findsOneWidget);

    await tester.tap(find.text('${year - 1}'));
    await tester.pumpAndSettle();
    expect(find.text('8 h'), findsWidgets);
    expect(find.textContaining('over 1 session of 1 game'), findsOneWidget);
    expect(find.text('Completed in ${year - 1}'), findsNothing);
  });

  testWidgets('the stat tiles fit a phone at the largest text size', (tester) async {
    // A Pixel 8a is 412 wide; the app lets text grow to 1.3 (CheckpointApp).
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, width: 412);

    expect(find.text('Longest streak (days)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the months chart can be read as a table', (tester) async {
    await open(tester);

    await tester.tap(find.text('Table'));
    await tester.pumpAndSettle();
    expect(find.text('January'), findsOneWidget);
    expect(find.text('December'), findsOneWidget);
    expect(find.text('Chart'), findsOneWidget);
  });

  testWidgets('Share opens the cards of the year', (tester) async {
    await open(tester);

    await tester.tap(find.byTooltip('Share your year'));
    await tester.pumpAndSettle();

    expect(find.text('Share your year'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.byType(YearOverviewCard), findsOneWidget);
  });

  testWidgets('a year with nothing logged says so', (tester) async {
    repo.logs = [];
    repo.library = [testGame('g1', cover: false, status: null)];
    await open(tester);

    expect(find.text('Nothing logged in $year'), findsOneWidget);
    expect(find.byTooltip('Share your year'), findsNothing);
  });
}
