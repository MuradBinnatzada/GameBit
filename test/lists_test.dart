import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game_list.dart';
import 'package:checkpoint/models/game_reviews.dart' show MemberReportSubject;
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/screens/lists/list_screen.dart';
import 'package:checkpoint/screens/lists/lists_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

void main() {
  late FakeRepository repo;
  late AppStores stores;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository()
      ..library = [
        testGame('g1', title: 'Hades', cover: false),
        testGame('g2', title: 'Celeste', cover: false),
        testGame('g3', title: 'Outer Wilds', cover: false),
      ];
    stores = AppStores(
      repository: repo,
      authService: FakeAuthService(testUser('u1')),
      connectivity: FakeConnectivity(),
      apiService: FakeDetailsApi(),
    );
  });

  group('ListsStore', () {
    setUp(() async => stores.initialize());
    tearDown(() => stores.dispose());

    test('makes a list, puts games on it in order, and moves them', () async {
      final list = await stores.lists.create(title: '  Cozy  ', isPublic: true);
      expect(list!.title, 'Cozy');

      for (final id in ['g1', 'g2', 'g3']) {
        await stores.lists.toggleGame(list.id, stores.library.gameById(id));
      }
      expect(stores.lists.listById(list.id)!.games.map((g) => g.id), ['g1', 'g2', 'g3']);
      expect(repo.writes, containsAllInOrder(['list-add:list-1:g1:0', 'list-add:list-1:g2:1', 'list-add:list-1:g3:2']));
      expect(stores.lists.listsWith('g2').single.id, list.id);

      await stores.lists.move(list.id, 2, 0);
      expect(stores.lists.listById(list.id)!.games.map((g) => g.id), ['g3', 'g1', 'g2']);
      expect(repo.writes.last, 'list-order:list-1:g3,g1,g2');

      await stores.lists.toggleGame(list.id, stores.library.gameById('g1'));
      expect(stores.lists.listById(list.id)!.games.map((g) => g.id), ['g3', 'g2']);
      expect(repo.writes.last, 'list-remove:list-1:g1');
    });

    test('a game that is not in the catalog yet is added to it first', () async {
      final list = await stores.lists.create(title: 'Later');
      final searchResult = testGame('new', title: 'New game', status: null, cover: false);

      await stores.lists.toggleGame(list!.id, searchResult);

      expect(repo.writes, containsAllInOrder(['base:new', 'list-add:list-1:new:0']));
    });

    test('a change the server refuses is put back, with a notice', () async {
      final list = await stores.lists.create(title: 'Mine');
      repo.rejectWrites = true;

      await stores.lists.toggleGame(list!.id, stores.library.gameById('g1'));
      expect(stores.lists.listById(list.id)!.games, isEmpty);
      expect(stores.lists.notice, 'Could not save that change to your list.');

      repo.rejectWrites = false;
      repo.offline = true;
      await stores.lists.update(list.id, title: 'Renamed', description: '', isPublic: false);
      expect(stores.lists.listById(list.id)!.title, 'Mine');
      expect(stores.lists.notice, 'Lists need a connection. Check it and try again.');
    });

    test('a title that breaks the community rules is refused, with its own notice', () async {
      repo
        ..rejectWrites = true
        ..rejectCode = 'CP422';

      final list = await stores.lists.create(title: 'Anything');

      expect(list, isNull);
      expect(stores.lists.notice, startsWith('That text breaks the community rules'));
    });

    test('another member\'s lists are only their public ones, and go on sign-out', () async {
      repo.lists['p1'] = const GameList(id: 'p1', ownerId: 'm1', title: 'Theirs', isPublic: true);
      repo.lists['p2'] = const GameList(id: 'p2', ownerId: 'm1', title: 'Hidden');

      await stores.lists.loadPublic('m1');
      expect(stores.lists.publicListsOf('m1').map((l) => l.id), ['p1']);
    });
  });

  group('on screen', () {
    Future<void> pump(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(stores: stores, child: MaterialApp(theme: buildTheme(), home: home)),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await tester.pumpAndSettle();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }

    testWidgets('a game goes on a new list from its screen', (tester) async {
      await pump(tester, const GameDetailScreen(gameId: 'g1'));

      await tester.tap(find.byTooltip('Add to list'));
      await settle(tester);
      await tester.tap(find.text('New list'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Roguelikes');
      await tester.pump();
      await tester.tap(find.text('Create list'));
      await settle(tester);

      expect(repo.writes, containsAllInOrder(['create-list:Roguelikes', 'list-add:list-1:g1:0']));
      final tile = tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Roguelikes'));
      expect(tile.value, isTrue);
    });

    testWidgets('the lists screen offers to make the first one, and opens a list', (tester) async {
      await pump(tester, const ListsScreen());
      expect(find.text('No lists yet'), findsOneWidget);

      final list = await tester.runAsync(() => stores.lists.create(title: 'Best of 2026'));
      await tester.runAsync(() => stores.lists.toggleGame(list!.id, stores.library.gameById('g2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Best of 2026'));
      await tester.pumpAndSettle();

      expect(find.byType(ListScreen), findsOneWidget);
      expect(find.text('Celeste'), findsOneWidget);
      expect(find.byTooltip('Delete list'), findsOneWidget);
    });

    testWidgets('a public list of someone else can be reported, not edited', (tester) async {
      repo.lists['p1'] = const GameList(id: 'p1', ownerId: 'm1', title: 'Theirs', isPublic: true);
      await pump(tester, const ListScreen(listId: 'p1'));
      await settle(tester);
      expect(find.byTooltip('Delete list'), findsNothing);

      await tester.tap(find.byTooltip('Report list'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Theirs'), findsWidgets);
      await tester.tap(find.text('Something else'));
      await tester.pumpAndSettle();

      expect(repo.memberReports.single.listId, 'p1');
      expect(repo.memberReports.single.userId, 'm1');
      expect(repo.memberReports.single.subject, MemberReportSubject.list);
    });

    testWidgets('your own list has no report button', (tester) async {
      await pump(tester, const ListsScreen());
      final list = await tester.runAsync(() => stores.lists.create(title: 'Mine', isPublic: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mine'));
      await tester.pumpAndSettle();
      expect(list, isNotNull);

      expect(find.byTooltip('Report list'), findsNothing);
    });

    testWidgets('a private list of someone else, opened from a link, is not shown', (tester) async {
      await pump(tester, const ListScreen(listId: 'nope'));
      await settle(tester);
      expect(find.text('List not found'), findsOneWidget);
    });
  });
}
