import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/next_game_picker.dart';
import 'package:checkpoint/screens/home/home_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

void main() {
  final library = [
    testGame('a', status: GameStatus.toPlay, platforms: const [GamePlatform.pc]),
    testGame('b', status: GameStatus.playing, platforms: const [GamePlatform.nswitch], playedOn: GamePlatform.nswitch),
    testGame('c', status: GameStatus.completed),
    testGame('d', status: GameStatus.wishlist, platforms: const [GamePlatform.ps5]),
    testGame('e', status: GameStatus.toPlay, platforms: const [GamePlatform.ps5, GamePlatform.pc]),
  ];

  test('picks from the backlog by default: To Play and Playing', () {
    final picker = NextGamePicker(library: library, random: math.Random(1));
    expect(picker.candidates.map((g) => g.id), ['a', 'b', 'e']);
  });

  test('every candidate comes up once before any comes up again, never twice in a row', () {
    final picker = NextGamePicker(library: library, random: math.Random(7));
    final picks = [for (var i = 0; i < 30; i++) picker.next()!.id];
    for (var round = 0; round < 10; round++) {
      expect(picks.sublist(round * 3, round * 3 + 3).toSet(), {'a', 'b', 'e'});
    }
    for (var i = 1; i < picks.length; i++) {
      expect(picks[i], isNot(picks[i - 1]));
    }
  });

  test('the platform filter keeps games played on it or released for it', () {
    final pc = NextGamePicker(library: library, platform: GamePlatform.pc);
    expect(pc.candidates.map((g) => g.id), ['a', 'e']);
    final ps5 = NextGamePicker(library: library, statuses: {GameStatus.wishlist, GameStatus.toPlay}, platform: GamePlatform.ps5);
    expect(ps5.candidates.map((g) => g.id), ['d', 'e']);
  });

  test('nothing to pick from is null', () {
    expect(NextGamePicker(library: library, statuses: {GameStatus.dropped}).next(), isNull);
  });

  test('the platform filter offers the platforms of the chosen statuses', () {
    expect(
      NextGamePicker.platformsOf(library, NextGamePicker.defaultStatuses),
      [GamePlatform.pc, GamePlatform.ps5, GamePlatform.nswitch],
    );
  });

  testWidgets('Home opens the picker; Play it starts the game and its timer', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = FakeRepository()
      ..library = [
        testGame('a', title: 'Alpha', status: GameStatus.toPlay, cover: false),
        testGame('b', title: 'Beta', status: GameStatus.toPlay, cover: false),
      ];
    final stores = AppStores(
      repository: repo,
      authService: FakeAuthService(testUser('u1')),
      connectivity: FakeConnectivity(),
      apiService: FakeBrowseApi(),
    );
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(AppStoresScope(
      stores: stores,
      child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: HomeScreen())),
    ));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text("Can't decide? Pick my next game"));
    await tester.pumpAndSettle();
    expect(find.text('What should I play?'), findsOneWidget);
    String picked() => ['Alpha', 'Beta'].firstWhere((t) => find.descendant(of: find.byType(BottomSheet), matching: find.text(t)).evaluate().isNotEmpty);
    final first = picked();

    await tester.tap(find.text('Pick another'));
    await tester.pumpAndSettle();
    final second = picked();
    expect(second, isNot(first));

    await tester.tap(find.text('Play it'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    final id = second == 'Alpha' ? 'a' : 'b';
    expect(stores.library.gameById(id).status, GameStatus.playing);
  });
}
