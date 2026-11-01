import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/limits.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/sheets/edit_session_sheet.dart';
import 'package:checkpoint/sheets/log_hours_sheet.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// The hours a member can type in (Log Hours, Edit session) stop at
/// [maxManualHours]; the store and the database still hold up to [maxTotalHours],
/// which a Steam sync can reach.
void main() {
  late AppStores stores;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final repo = FakeRepository()
      ..library = [
        testGame('small', title: 'Hades', cover: false, hours: 86),
        testGame('steam', title: 'Counter-Strike 2', cover: false, hours: 30000),
      ]
      ..logs = [
        testLog('l1', 'small'),
        LogEntry(
          id: 'l2',
          gameId: 'steam',
          timestamp: DateTime.utc(2026, 2, 3),
          hours: 25000,
          platform: testLog('x', 'steam').platform,
          note: '',
        ),
      ];
    stores = AppStores(
      repository: repo,
      authService: FakeAuthService(testUser('u1')),
      connectivity: FakeConnectivity(),
      apiService: FakeDetailsApi(),
    );
    await stores.initialize();
  });
  tearDown(() => stores.dispose());

  Future<void> show(WidgetTester tester, Widget sheet) async {
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: lightTheme, home: Scaffold(body: sheet)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null;

  test('what is typed is held lower than what is stored', () {
    expect(maxManualHours, lessThan(maxTotalHours));
    expect(maxManualHours, 20000);
  });

  group('Log Hours', () {
    testWidgets('takes a total up to the limit', (tester) async {
      await show(tester, const LogHoursSheet(gameId: 'small'));

      await type(tester, '20000');

      expect(saveEnabled(tester), isTrue);
      expect(find.textContaining('at most'), findsNothing);
    });

    testWidgets('refuses a total over the limit and says what it is', (tester) async {
      await show(tester, const LogHoursSheet(gameId: 'small'));

      await type(tester, '20001');

      expect(saveEnabled(tester), isFalse);
      expect(find.text('The total can be at most 20,000 hours.'), findsOneWidget);
    });

    testWidgets('refuses the extra zero a slip adds', (tester) async {
      await show(tester, const LogHoursSheet(gameId: 'small'));

      await type(tester, '860000');

      expect(saveEnabled(tester), isFalse);
    });

    testWidgets('a Steam total past the limit can be kept or lowered, not raised', (tester) async {
      await show(tester, const LogHoursSheet(gameId: 'steam'));

      // The sheet opens on the game's 30 000 hours.
      expect(saveEnabled(tester), isTrue);
      await type(tester, '29000');
      expect(saveEnabled(tester), isTrue);
      await type(tester, '30001');
      expect(saveEnabled(tester), isFalse);
    });
  });

  group('Edit session', () {
    testWidgets('refuses hours over the limit with a message about the limit', (tester) async {
      await show(tester, EditSessionSheet(session: stores.library.sessionById('l1')!));

      await type(tester, '20001');

      expect(saveEnabled(tester), isFalse);
      expect(find.text('A session can be at most 20,000 hours.'), findsOneWidget);
      expect(find.text('Enter more than 0 hours.'), findsNothing);
    });

    testWidgets('still says to enter more than 0 for nothing', (tester) async {
      await show(tester, EditSessionSheet(session: stores.library.sessionById('l1')!));

      await type(tester, '0');

      expect(saveEnabled(tester), isFalse);
      expect(find.text('Enter more than 0 hours.'), findsOneWidget);
    });

    testWidgets('a session logged past the limit can still be edited down', (tester) async {
      await show(tester, EditSessionSheet(session: stores.library.sessionById('l2')!));

      expect(saveEnabled(tester), isTrue);
      await type(tester, '24000');
      expect(saveEnabled(tester), isTrue);
      await type(tester, '25001');
      expect(saveEnabled(tester), isFalse);
    });
  });

  group('the store', () {
    test('still holds a total up to the database range', () async {
      await stores.library.updateTime(gameId: 'small', totalHours: 50000);
      expect(stores.library.gameById('small').hoursPlayed, 50000);
    });

    test('a session logged on a Steam game keeps its hours', () async {
      await stores.library.logSession(gameId: 'steam', hours: 2);
      expect(stores.library.gameById('steam').hoursPlayed, 30002);
    });
  });
}
