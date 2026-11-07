import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/models/discussion.dart';
import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/services/discussion_failure.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

DateTime ago(int minutes) =>
    DateTime.now().toUtc().subtract(Duration(minutes: minutes));

/// The Discussions tab, its boards, threads and replies, posting, the chat rules,
/// reporting and blocking, in the real app shell on fake data sources.
void main() {
  late FakeRepository repo;
  late FakeDiscussionApi api;
  late AppStores stores;
  final me = testMember('u1', name: 'Me');

  AppStores makeStores({bool signedIn = true}) => AppStores(
    repository: repo,
    authService: FakeAuthService(signedIn ? testUser('u1') : null),
    connectivity: FakeConnectivity(),
    apiService: FakeBrowseApi(),
    discussionApi: api,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository()
      ..library = [testGame('g1', title: 'Hades', cover: false, igdbId: 1)]
      ..discussionThreads.addAll([
        testThread(
          't1',
          title: 'Best soulslike?',
          text: 'Elden Ring or Sekiro?',
          author: 'a',
          authorName: 'Ann',
          replies: 2,
          at: ago(30),
        ),
        testThread(
          't2',
          title: 'Pinned rules',
          author: 'b',
          authorName: 'Bob',
          pinned: true,
          at: ago(900),
        ),
        testThread(
          't3',
          board: 'games',
          title: 'Hades builds',
          author: 'a',
          authorName: 'Ann',
          at: ago(5),
          game: const DiscussionGame(id: 'g1', title: 'Hades', igdbId: 1),
        ),
        testThread(
          't4',
          board: 'help',
          title: 'Closed topic',
          author: 'c',
          authorName: 'Cy',
          locked: true,
          at: ago(60),
        ),
      ])
      ..discussionPosts['t1'] = [
        testPost(
          'p1',
          't1',
          author: 'b',
          authorName: 'Bob',
          text: 'Elden Ring, no contest.',
          at: ago(60),
        ),
        testPost(
          'p2',
          't1',
          author: 'u1',
          authorName: 'Me',
          text: 'My own reply.',
          at: ago(30),
        ),
      ];
    api = FakeDiscussionApi(repo, me: me);
    stores = makeStores();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> start(
    WidgetTester tester, {
    Widget home = const AppShell(),
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(stores.initialize);
    await tester.pumpWidget(
      AppStoresScope(
        stores: stores,
        child: MaterialApp(theme: buildTheme(), home: home),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      stores.dispose();
    });
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openTab(WidgetTester tester) async {
    await start(tester);
    stores.nav.select(NavTab.discussions);
    await settle(tester);
  }

  Future<void> openThread(WidgetTester tester, String title) async {
    await openTab(tester);
    await tester.tap(find.text(title));
    await settle(tester);
  }

  testWidgets('Discussions is the fifth tab, in the middle', (tester) async {
    await start(tester);

    final labels = [
      for (final d in tester.widgetList<NavigationDestination>(
        find.byType(NavigationDestination),
      ))
        d.label,
    ];
    expect(labels, ['Home', 'Search', 'Discussions', 'My Library', 'Profile']);
    expect(NavTab.discussions, 2);
    // Nothing is asked until the tab is shown.
    expect(repo.threadReads, isEmpty);
  });

  testWidgets(
    'the tab lists the boards with their threads, and the latest discussions',
    (tester) async {
      await openTab(tester);

      for (final board in ['General', 'Game talk', 'Help & tips']) {
        expect(find.text(board), findsOneWidget, reason: board);
      }
      expect(find.text('2 threads'), findsOneWidget); // General
      expect(find.text('Latest discussions'.toUpperCase()), findsOneWidget);
      expect(find.text('Hades builds'), findsOneWidget);
      expect(find.text('Best soulslike?'), findsOneWidget);
      // The newest first.
      expect(
        tester.getTopLeft(find.text('Hades builds')).dy,
        lessThan(tester.getTopLeft(find.text('Best soulslike?')).dy),
      );
    },
  );

  testWidgets('signed out, the tab asks to log in and asks nothing', (
    tester,
  ) async {
    stores = makeStores(signedIn: false);
    await openTab(tester);

    expect(find.text('Log in to join the discussions'), findsOneWidget);
    expect(repo.threadReads, isEmpty);
  });

  testWidgets('a board lists its threads, the pinned one first', (
    tester,
  ) async {
    await openTab(tester);

    await tester.tap(find.text('General').first);
    await settle(tester);

    expect(find.text('Pinned rules'), findsOneWidget);
    expect(find.text('Best soulslike?'), findsOneWidget);
    expect(find.text('Hades builds'), findsNothing); // another board's
    expect(
      tester.getTopLeft(find.text('Pinned rules')).dy,
      lessThan(tester.getTopLeft(find.text('Best soulslike?')).dy),
    );
    expect(find.text('New discussion'), findsOneWidget);
  });

  testWidgets('a thread shows its text and its replies', (tester) async {
    await openThread(tester, 'Best soulslike?');

    expect(find.text('Elden Ring or Sekiro?'), findsOneWidget);
    expect(find.text('Elden Ring, no contest.'), findsOneWidget);
    expect(find.text('My own reply.'), findsOneWidget);
    expect(find.text('2 replies'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('You'), findsOneWidget); // my reply is marked
    expect(find.text('Write a reply'), findsOneWidget);
  });

  testWidgets('a game\'s thread names the game', (tester) async {
    await openThread(tester, 'Hades builds');

    expect(find.widgetWithText(ActionChip, 'Hades'), findsOneWidget);
  });

  group('replying', () {
    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'Write a reply'),
        text,
      );
      await tester.pump();
    }

    testWidgets('the chat rules come first, and are not asked again', (
      tester,
    ) async {
      await openThread(tester, 'Best soulslike?');

      await type(tester, 'Sekiro is better.');
      await tester.tap(find.byTooltip('Send reply'));
      await settle(tester);

      expect(find.text('Chat rules'), findsOneWidget);
      expect(find.text('No hate'), findsOneWidget);
      expect(api.replyCalls, isEmpty);

      await tester.tap(find.text('I agree'));
      await settle(tester);

      expect(api.replyCalls.single, (thread: 't1', text: 'Sekiro is better.', replyTo: null));
      expect(find.text('Sekiro is better.'), findsOneWidget);
      expect(find.text('3 replies'), findsOneWidget);

      // The second reply goes straight out.
      await type(tester, 'And more.');
      await tester.tap(find.byTooltip('Send reply'));
      await settle(tester);
      expect(find.text('Chat rules'), findsNothing);
      expect(api.replyCalls, hasLength(2));
    });

    group('to a post', () {
      setUp(() {
        SharedPreferences.setMockInitialValues({'chat_rules_accepted_u1': true});
        repo.discussionPosts['t1']!.add(
          testPost(
            'p3',
            't1',
            author: 'a',
            authorName: 'Ann',
            text: 'Sekiro has better combat.',
            at: ago(20),
            replyTo: const DiscussionQuote(postId: 'p1', authorName: 'Bob', excerpt: 'Elden Ring, no contest.'),
          ),
        );
      });

      Finder replyButtons() => find.widgetWithText(TextButton, 'Reply');

      testWidgets('every post has a Reply button, the opening one too', (tester) async {
        await openThread(tester, 'Best soulslike?');

        // The opening post and the three replies.
        expect(replyButtons(), findsNWidgets(4));
      });

      testWidgets('a reply says whom it answers, with how that post starts', (tester) async {
        await openThread(tester, 'Best soulslike?');

        expect(find.text('Replying to Bob'), findsOneWidget);
        // The quote and the post itself both hold the words; the quote is the shorter of the two.
        expect(find.text('Elden Ring, no contest.'), findsNWidgets(2));
        expect(find.text('Sekiro has better combat.'), findsOneWidget);
      });

      testWidgets('Reply names the member in the box, and the reply goes out answering that post', (tester) async {
        await openThread(tester, 'Best soulslike?');
        expect(find.text('Replying to Bob'), findsOneWidget); // the quote only

        await tester.ensureVisible(replyButtons().at(1));
        await tester.tap(replyButtons().at(1)); // Bob's post
        await settle(tester);
        expect(find.text('Replying to Bob'), findsNWidgets(2)); // the quote and the box

        await type(tester, 'Agreed.');
        await tester.tap(find.byTooltip('Send reply'));
        await settle(tester);

        expect(api.replyCalls.single, (thread: 't1', text: 'Agreed.', replyTo: 'p1'));
        // The new reply shows whom it answered; the box is back to the thread.
        expect(find.text('Replying to Bob'), findsNWidgets(2)); // p3's quote and the new reply's
        expect(find.byTooltip('Cancel reply'), findsNothing);
      });

      testWidgets('cancelling takes the name away, and the next reply answers the thread', (tester) async {
        await openThread(tester, 'Best soulslike?');
        await tester.ensureVisible(replyButtons().at(1));
        await tester.tap(replyButtons().at(1));
        await settle(tester);
        expect(find.byTooltip('Cancel reply'), findsOneWidget);

        await tester.tap(find.byTooltip('Cancel reply'));
        await settle(tester);
        expect(find.byTooltip('Cancel reply'), findsNothing);

        await type(tester, 'Just saying.');
        await tester.tap(find.byTooltip('Send reply'));
        await settle(tester);
        expect(api.replyCalls.single.replyTo, isNull);
      });

      testWidgets('Reply on the opening post answers the thread itself', (tester) async {
        await openThread(tester, 'Best soulslike?');
        await tester.ensureVisible(replyButtons().at(1));
        await tester.tap(replyButtons().at(1)); // a post first
        await settle(tester);
        expect(find.byTooltip('Cancel reply'), findsOneWidget);

        await tester.ensureVisible(replyButtons().first);
        await tester.tap(replyButtons().first); // the opening post
        await settle(tester);

        expect(find.byTooltip('Cancel reply'), findsNothing);
      });

      testWidgets('a locked thread has no Reply buttons', (tester) async {
        repo.discussionPosts['t4'] = [testPost('q1', 't4', author: 'c', authorName: 'Cy')];
        await openThread(tester, 'Closed topic');

        expect(replyButtons(), findsNothing);
      });
    });

    testWidgets('closing the rules without agreeing posts nothing', (
      tester,
    ) async {
      await openThread(tester, 'Best soulslike?');

      await type(tester, 'Sekiro is better.');
      await tester.tap(find.byTooltip('Send reply'));
      await settle(tester);
      await tester.tapAt(const Offset(10, 10)); // outside the sheet
      await settle(tester);

      expect(api.replyCalls, isEmpty);
      expect(
        find.text('Sekiro is better.'),
        findsOneWidget,
      ); // still in the box
    });

    testWidgets(
      'a post the chat rules refuse stays in the box, with a word about it',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'chat_rules_accepted_u1': true,
        });
        api.failWith = const DiscussionFailure(
          DiscussionFailureCode.contentNotAllowed,
        );
        await openThread(tester, 'Best soulslike?');

        await type(tester, 'A refused post.');
        await tester.tap(find.byTooltip('Send reply'));
        await settle(tester);

        expect(find.textContaining('breaks the chat rules'), findsOneWidget);
        expect(find.text('A refused post.'), findsOneWidget); // kept to change
        expect(find.text('2 replies'), findsOneWidget);
      },
    );

    testWidgets('posting too fast says when to try again', (tester) async {
      SharedPreferences.setMockInitialValues({'chat_rules_accepted_u1': true});
      api.failWith = const DiscussionFailure(
        DiscussionFailureCode.rateLimited,
        retryAfter: Duration(minutes: 4),
      );
      await openThread(tester, 'Best soulslike?');

      await type(tester, 'Another.');
      await tester.tap(find.byTooltip('Send reply'));
      await settle(tester);

      expect(
        find.text('You’re posting fast. Try again in 4 minutes.'),
        findsOneWidget,
      );
    });

    testWidgets('the send button waits for some text', (tester) async {
      await openThread(tester, 'Best soulslike?');

      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.send_rounded),
            )
            .onPressed,
        isNull,
      );
      await type(tester, '  ');
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.send_rounded),
            )
            .onPressed,
        isNull,
      );
      await type(tester, 'Hello');
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.send_rounded),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('a locked thread says so and has no box', (tester) async {
      await openThread(tester, 'Closed topic');

      expect(find.text('This discussion is locked.'), findsOneWidget);
      expect(find.text('Write a reply'), findsNothing);
    });
  });

  group('starting a thread', () {
    Future<void> fill(
      WidgetTester tester, {
      String title = 'Hello there',
      String text = 'First post.',
    }) async {
      await tester.enterText(find.widgetWithText(TextField, 'Title'), title);
      await tester.enterText(
        find.widgetWithText(TextField, 'What do you want to talk about?'),
        text,
      );
      await tester.pump();
    }

    Future<void> openForm(WidgetTester tester) async {
      await openTab(tester);
      await tester.tap(find.text('Help & tips').first);
      await settle(tester);
      await tester.tap(find.text('New discussion'));
      await settle(tester);
    }

    testWidgets('on a board: the form, the rules, then the thread', (
      tester,
    ) async {
      await openForm(tester);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
            .onPressed,
        isNull,
      );

      await fill(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Post'));
      await settle(tester);
      expect(find.text('Chat rules'), findsOneWidget);
      await tester.tap(find.text('I agree'));
      await settle(tester);

      expect(api.threadCalls.single, (
        board: 'help',
        title: 'Hello there',
        text: 'First post.',
        gameId: null,
      ));
      // The new thread is open.
      expect(find.text('Hello there'), findsOneWidget);
      expect(find.text('First post.'), findsOneWidget);
      expect(find.text('No replies yet'), findsOneWidget);
    });

    testWidgets('needs a title of three characters and some text', (
      tester,
    ) async {
      await openForm(tester);

      await fill(tester, title: 'ab');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
            .onPressed,
        isNull,
      );
      await fill(tester, text: '   ');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
            .onPressed,
        isNull,
      );
      await fill(tester);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('a refused thread stays in the form', (tester) async {
      SharedPreferences.setMockInitialValues({'chat_rules_accepted_u1': true});
      api.failWith = const DiscussionFailure(
        DiscussionFailureCode.contentNotAllowed,
      );
      await openForm(tester);

      await fill(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Post'));
      await settle(tester);

      expect(find.textContaining('breaks the chat rules'), findsOneWidget);
      expect(find.text('Hello there'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Post'), findsOneWidget);
    });

    testWidgets('from the tab\'s button, the board is picked', (tester) async {
      SharedPreferences.setMockInitialValues({'chat_rules_accepted_u1': true});
      await openTab(tester);
      await tester.tap(find.byTooltip('New discussion'));
      await settle(tester);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await settle(tester);
      await tester.tap(find.text('Game talk').last);
      await settle(tester);
      await fill(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Post'));
      await settle(tester);

      expect(api.threadCalls.single.board, 'games');
    });
  });

  group('what can be done with a post', () {
    Future<void> openMenu(WidgetTester tester, int index) async {
      await tester.tap(find.byIcon(Icons.more_horiz_rounded).at(index));
      await tester.pumpAndSettle();
    }

    testWidgets('report: pick why, and it is gone', (tester) async {
      await openThread(tester, 'Best soulslike?');

      await openMenu(tester, 1); // Bob's reply
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      expect(find.text('Spam or ads'), findsOneWidget);
      await tester.tap(find.text('Abusive or hateful'));
      await settle(tester);

      expect(repo.discussionReports.single, (
        threadId: null,
        postId: 'p1',
        reason: ReportReason.abuse,
      ));
      expect(find.text('Elden Ring, no contest.'), findsNothing);
      expect(find.textContaining('we’ll take a look'), findsOneWidget);
    });

    testWidgets('report a thread: it goes, and the screen closes', (
      tester,
    ) async {
      await openThread(tester, 'Best soulslike?');

      await openMenu(tester, 0); // the opening post, Ann's
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spam or ads'));
      await settle(tester);

      expect(repo.discussionReports.single.threadId, 't1');
      expect(
        find.text('Best soulslike?'),
        findsNothing,
      ); // back on the tab, where it is gone
    });

    testWidgets('block: asks first, then their replies are gone', (
      tester,
    ) async {
      await openThread(tester, 'Best soulslike?');

      await openMenu(tester, 1);
      await tester.tap(find.text('Block Bob'));
      await tester.pumpAndSettle();
      expect(find.text('Block Bob?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await settle(tester);

      expect(repo.blockedMembers.keys, ['b']);
      expect(find.text('Elden Ring, no contest.'), findsNothing);
      expect(find.text('My own reply.'), findsOneWidget);
    });

    testWidgets('block: cancelling blocks nobody', (tester) async {
      await openThread(tester, 'Best soulslike?');

      await openMenu(tester, 1);
      await tester.tap(find.text('Block Bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(repo.blockedMembers, isEmpty);
      expect(find.text('Elden Ring, no contest.'), findsOneWidget);
    });

    testWidgets(
      'your own reply has Delete, not Report, and is deleted after asking',
      (tester) async {
        await openThread(tester, 'Best soulslike?');

        await openMenu(tester, 2); // my reply
        expect(find.text('Report'), findsNothing);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(find.text('Delete this reply?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await settle(tester);

        expect(repo.deletedDiscussionPosts, ['p2']);
        expect(find.text('My own reply.'), findsNothing);
        expect(find.text('1 reply'), findsOneWidget);
      },
    );

    testWidgets(
      'your own thread is deleted after asking, and the screen closes',
      (tester) async {
        repo.discussionThreads.add(
          testThread(
            'mine',
            title: 'My thread',
            author: 'u1',
            authorName: 'Me',
            at: ago(1),
          ),
        );
        await openThread(tester, 'My thread');

        await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(find.text('Delete this discussion?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
        await settle(tester);

        expect(repo.deletedDiscussionThreads, ['mine']);
        expect(find.text('My thread'), findsNothing);
      },
    );
  });

  group('blocked members', () {
    testWidgets('are listed, and unblocking brings their threads back', (
      tester,
    ) async {
      repo.blockedMembers['b'] = testMember('b', name: 'Bob');
      await openTab(tester);
      expect(
        find.text('Pinned rules'),
        findsNothing,
      ); // Bob's thread is left out

      await tester.tap(find.byTooltip('Show menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blocked members'));
      await settle(tester);
      expect(find.text('Bob'), findsOneWidget);

      await tester.tap(find.text('Unblock'));
      await settle(tester);

      expect(repo.blockedMembers, isEmpty);
      expect(find.text('Nobody is blocked'), findsOneWidget);
    });
  });

  testWidgets('the chat rules can be read from the tab', (tester) async {
    await openTab(tester);

    await tester.tap(find.byTooltip('Show menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat rules'));
    await settle(tester);

    for (final rule in [
      'Be kind',
      'No hate',
      'No spam',
      'Mind spoilers',
      'Report, don’t feud',
    ]) {
      expect(find.text(rule), findsOneWidget, reason: rule);
    }
    // To read, not to agree to.
    expect(find.text('Got it'), findsOneWidget);
    expect(find.text('I agree'), findsNothing);
  });

  group('on a game\'s screen', () {
    testWidgets('the discussions about the game, and a way to start one', (
      tester,
    ) async {
      await start(tester, home: const GameDetailScreen(gameId: 'g1'));
      await settle(tester);

      expect(find.text('Game discussions'), findsOneWidget);
      expect(find.text('Hades builds'), findsOneWidget);
      expect(find.text('Closed topic'), findsNothing); // another game's
      expect(find.text('Start a discussion'), findsOneWidget);
      expect(repo.threadReads.last.game, 'g1');
    });

    testWidgets('a game nobody discussed says so', (tester) async {
      repo.discussionThreads.removeWhere((t) => t.id == 't3');
      await start(tester, home: const GameDetailScreen(gameId: 'g1'));
      await settle(tester);

      expect(
        find.text('Nobody has talked about this game yet.'),
        findsOneWidget,
      );
    });

    testWidgets('starting one is about the game, on the Game talk board', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'chat_rules_accepted_u1': true});
      await start(tester, home: const GameDetailScreen(gameId: 'g1'));
      await settle(tester);

      await tester.ensureVisible(find.text('Start a discussion'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start a discussion'));
      await settle(tester);
      expect(find.text('About Hades'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Best weapon?',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'What do you want to talk about?'),
        'Aspects?',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Post'));
      await settle(tester);

      expect(api.threadCalls.single, (
        board: 'games',
        title: 'Best weapon?',
        text: 'Aspects?',
        gameId: 'g1',
      ));
    });

    testWidgets('signed out, the panel is not there', (tester) async {
      stores = makeStores(signedIn: false);
      repo.popular = [testGame('g1', status: null, cover: false)];
      await start(tester, home: const GameDetailScreen(gameId: 'g1'));
      await settle(tester);

      expect(find.text('Game discussions'), findsNothing);
      expect(repo.threadReads, isEmpty);
    });
  });
}
