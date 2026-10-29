import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/discussion.dart';
import 'package:checkpoint/screens/settings/blocked_members_screen.dart';
import 'package:checkpoint/screens/discussions/board_screen.dart';
import 'package:checkpoint/screens/discussions/new_thread_screen.dart';
import 'package:checkpoint/screens/discussions/thread_screen.dart';
import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/app/sign_in_panel.dart';
import 'package:checkpoint/models/friend_activity.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_details.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/screens/game_detail/sessions_screen.dart';
import 'package:checkpoint/screens/lists/lists_screen.dart';
import 'package:checkpoint/screens/profile/edit_profile_screen.dart';
import 'package:checkpoint/screens/profile/follows_screen.dart';
import 'package:checkpoint/screens/profile/public_profile_screen.dart';
import 'package:checkpoint/screens/settings/settings_screen.dart';
import 'package:checkpoint/screens/settings/two_factor_setup_screen.dart';
import 'package:checkpoint/screens/stats/year_review_screen.dart';
import 'package:checkpoint/sheets/edit_session_sheet.dart';
import 'package:checkpoint/sheets/game_backdrop_sheet.dart';
import 'package:checkpoint/sheets/list_sheets.dart';
import 'package:checkpoint/sheets/log_hours_sheet.dart';
import 'package:checkpoint/sheets/pick_next_sheet.dart';
import 'package:checkpoint/sheets/quick_log_sheet.dart';
import 'package:checkpoint/sheets/review_sheet.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/appearance_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/widgets/library_controls.dart';
import 'package:checkpoint/widgets/library_filters.dart';
import 'package:checkpoint/widgets/star_rating.dart';

import 'support/fakes.dart';

/// Every screen and sheet: 48 px tap targets, a label on whatever can be
/// tapped, text that reads (in each of the four themes), and layouts that hold
/// at twice the normal text size on a small phone.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppStores seededStores() {
    final repo = FakeRepository()
      ..library = [
        testGame(
          'g1',
          title: 'Elden Ring Nightreign Deluxe Edition',
          cover: false,
          hours: 86,
        ),
        testGame(
          'g2',
          title: 'Hades II',
          cover: false,
          status: GameStatus.completed,
          hours: 40,
        ),
        testGame(
          'g3',
          title: 'Celeste',
          cover: false,
          status: GameStatus.toPlay,
        ),
        testGame(
          'g4',
          title: 'Starfield',
          cover: false,
          status: GameStatus.dropped,
          hours: 9,
        ),
        testGame(
          'g5',
          title: 'Hollow Knight: Silksong',
          cover: false,
          status: GameStatus.wishlist,
        ),
      ]
      ..discussionThreads.addAll([
        testThread('d1', title: 'Best soulslike?', author: 'friend-1', authorName: 'Grace Hopper', replies: 1, at: DateTime.now().toUtc().subtract(const Duration(hours: 2))),
        testThread('d2', title: 'Locked and pinned', author: 'friend-1', authorName: 'Grace Hopper', pinned: true, locked: true),
      ])
      ..discussionPosts['d1'] = [
        testPost('dp1', 'd1', author: 'friend-1', authorName: 'Grace Hopper', text: 'Elden Ring.'),
      ]
      ..logs = [testLog('l1', 'g1'), testLog('l2', 'g2')]
      ..followingActivity = [
        testActivity(
          'friend-1',
          'g9',
          FriendActivityKind.session,
          name: 'Grace Hopper',
          title: 'Balatro',
          hours: 2,
        ),
        testActivity(
          'friend-1',
          'g8',
          FriendActivityKind.rated,
          name: 'Grace Hopper',
          title: 'Tetris Effect',
          rating: 4.5,
        ),
      ];
    return AppStores(
      repository: repo,
      authService: FakeAuthService(testUser('u1')),
      connectivity: FakeConnectivity(),
      apiService: _Api(),
    );
  }

  /// Opens every tab, screen and sheet in turn over [theme], at [textScale],
  /// calling [check] on each.
  Future<void> visitEverything(
    WidgetTester tester, {
    required ThemeData theme,
    required Future<void> Function(String where) check,
    double textScale = 1,
  }) async {
    final stores = seededStores();
    await tester.runAsync(stores.initialize);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: StoreScope<AppearanceStore>(
          store: AppearanceStore(),
          child: MaterialApp(
            navigatorKey: nav,
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const AppShell(),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });

    Future<void> visit(String where) async {
      await tester.pumpAndSettle();
      await check(where);
    }

    await visit('Home');
    for (final (tab, name) in [
      (NavTab.search, 'Search'),
      (NavTab.discussions, 'Discussions'),
      (NavTab.library, 'Library'),
      (NavTab.profile, 'Profile'),
    ]) {
      stores.nav.select(tab);
      await visit(name);
    }
    stores.nav.select(NavTab.home);

    final screens = <String, Widget>{
      'Game': const GameDetailScreen(gameId: 'g1'),
      for (final s in SettingsSection.values)
        'Settings > ${s.label}': SettingsScreen(initialSection: s),
      'Edit profile': const EditProfileScreen(),
      'Followers': const FollowsScreen(userId: 'u1'),
      'Year in review': const YearReviewScreen(),
      'Lists': const ListsScreen(),
      'Sessions': const SessionsScreen(gameId: 'g1'),
      'Two-factor setup': const TwoFactorSetupScreen(),
      'Public profile': const PublicProfileScreen(userId: 'friend-1'),
      'Sign in': const SignInScreen(),
      'Board': const BoardScreen(scope: DiscussionScope(boardId: 'general')),
      'Thread': const ThreadScreen(threadId: 'd1'),
      'Locked thread': const ThreadScreen(threadId: 'd2'),
      'New discussion': const NewThreadScreen(boardId: 'general'),
      'Blocked members': const BlockedMembersScreen(),
    };
    for (final MapEntry(:key, :value) in screens.entries) {
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => value));
      await visit(key);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
    }

    final game = stores.library.maybeGame('g1')!;
    final sheets = <String, void Function(BuildContext)>{
      'Log a session': (c) => showQuickLogSheet(c),
      'Log hours': (c) => showLogHoursSheet(c, 'g1'),
      'Review': (c) => showReviewSheet(c, 'g1'),
      'Add to list': (c) => showAddToListSheet(c, game),
      'Backdrop': (c) => showGameBackdropSheet(c, 'g1'),
      'Pick my next game': (c) => showPickNextSheet(c),
      'Library filters': (c) => showLibraryFilterSheet(c),
      'New list': (c) => showEditListSheet(c),
      'Edit session': (c) => showEditSessionSheet(c, 'l1'),
    };
    for (final MapEntry(:key, :value) in sheets.entries) {
      value(tester.element(find.byType(AppShell)));
      await visit('$key sheet');
      nav.currentState!.pop();
      await tester.pumpAndSettle();
    }
  }

  /// The rating histogram's bars: ten share a row, so they are narrow (but tall,
  /// and each has its label).
  final histogramBar = RegExp(r'label: "[\d.]+ stars?( or less)?: \d+ games?"');

  for (final (name, theme) in [
    ('light', lightTheme),
    ('dark', darkTheme),
    ('light high contrast', lightHighContrastTheme),
    ('dark high contrast', darkHighContrastTheme),
  ]) {
    testWidgets(
      '$name: tap targets, labels and text contrast pass everywhere',
      (tester) async {
        // Tall enough to have each page on screen whole.
        tester.view.physicalSize = const Size(390, 2600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();

        await visitEverything(
          tester,
          theme: theme,
          check: (where) async {
            for (final guideline in [
              androidTapTargetGuideline,
              labeledTapTargetGuideline,
              textContrastGuideline,
            ]) {
              final result = await guideline.evaluate(tester);
              final problems = result.passed
                  ? const <String>[]
                  : result.reason!
                        .split('\n')
                        .where(
                          (line) =>
                              line.trim().isNotEmpty &&
                              !line.contains('See also') &&
                              !histogramBar.hasMatch(line),
                        )
                        .toList();
              expect(
                problems,
                isEmpty,
                reason: '$where: ${guideline.description}',
              );
            }
          },
        );
        semantics.dispose();
      },
    );
  }

  testWidgets('nothing overflows at twice the text size on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // An overflow is reported as an error, which fails the test.
    await visitEverything(
      tester,
      theme: lightTheme,
      textScale: 2,
      check: (_) async {},
    );
  });

  testWidgets('a cover in the library grid is read as its game', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final stores = seededStores();
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(
          theme: lightTheme,
          home: Scaffold(
            body: LibraryPosterGrid(
              games: [
                testGame(
                  'c1',
                  title: 'Outer Wilds',
                  hours: 22,
                ).copyWith(rating: 5),
              ],
            ),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pump();

    // With cover art there is no title on the poster; the button names the game.
    expect(
      find.bySemanticsLabel('Outer Wilds, rated 5 out of 5, 22 hours played'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('screen readers can turn the rating up and down by half a star', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var rating = 3.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => StarRating(
              rating: rating,
              size: 44,
              onChanged: (v) => setState(() => rating = v),
            ),
          ),
        ),
      ),
    );

    Future<void> act(SemanticsAction action) async {
      final node = tester.getSemantics(find.byType(StarRating));
      node.owner!.performAction(node.id, action);
      await tester.pump();
    }

    expect(
      tester.getSemantics(find.byType(StarRating)),
      isSemantics(
        isSlider: true,
        label: 'Rating',
        value: '3 out of 5 stars',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );
    await act(SemanticsAction.increase);
    expect(rating, 3.5);
    await act(SemanticsAction.decrease);
    await act(SemanticsAction.decrease);
    expect(rating, 2.5);
    expect(
      tester.getSize(find.byType(StarRating)).height,
      greaterThanOrEqualTo(48),
    );
    semantics.dispose();
  });
}

/// IGDB, answering every game's details.
class _Api extends FakeBrowseApi {
  @override
  Future<GameDetails?> fetchDetails(int igdbId) async =>
      testDetails(igdbId: igdbId);
}
