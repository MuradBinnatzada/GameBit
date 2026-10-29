import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, FunctionException;

import 'package:checkpoint/models/discussion.dart';
import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/services/discussion_failure.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/discussions_store.dart';
import 'package:checkpoint/state/load_status.dart';

import 'support/fakes.dart';

DateTime ago(int minutes) =>
    DateTime.now().toUtc().subtract(Duration(minutes: minutes));

void main() {
  group('DiscussionFailure', () {
    DiscussionFailure from(int status, [Object? details]) =>
        DiscussionFailure.from(
          FunctionException(status: status, details: details),
        );

    test('is named by the code the function sends', () {
      expect(
        from(422, {'code': 'CONTENT_NOT_ALLOWED'}).code,
        DiscussionFailureCode.contentNotAllowed,
      );
      expect(
        from(422, {'code': 'TOO_MANY_LINKS'}).code,
        DiscussionFailureCode.tooManyLinks,
      );
      expect(
        from(409, {'code': 'DUPLICATE'}).code,
        DiscussionFailureCode.duplicate,
      );
      expect(from(409, {'code': 'LOCKED'}).code, DiscussionFailureCode.locked);
      expect(
        from(404, {'code': 'NOT_FOUND'}).code,
        DiscussionFailureCode.notFound,
      );
      expect(
        from(403, {'code': 'MFA_REQUIRED'}).code,
        DiscussionFailureCode.mfaRequired,
      );
      expect(
        from(401, {'code': 'UNAUTHENTICATED'}).code,
        DiscussionFailureCode.unauthenticated,
      );
    });

    test('a rate limit says how long to wait, and is worded for it', () {
      final failure = from(429, {'code': 'RATE_LIMITED', 'retry_after': 150});
      expect(failure.code, DiscussionFailureCode.rateLimited);
      expect(failure.retryAfter, const Duration(seconds: 150));
      expect(failure.message, 'You’re posting fast. Try again in 3 minutes.');
      expect(
        from(429, {'code': 'RATE_LIMITED', 'retry_after': 20}).message,
        'You’re posting fast. Try again in a minute.',
      );
      expect(
        from(429, {'code': 'RATE_LIMITED'}).message,
        'You’re posting fast. Try again in a little while.',
      );
    });

    test('without a code it is told by the status, or is something else', () {
      expect(from(401).code, DiscussionFailureCode.unauthenticated);
      expect(from(0).code, DiscussionFailureCode.offline);
      expect(from(500).code, DiscussionFailureCode.other);
      expect(from(400, 'not a body').code, DiscussionFailureCode.other);
      // Anything that is not an answer of the server is taken as no connection,
      // as everywhere in the app (isConnectionFailure); a refused sign-in is not.
      expect(
        DiscussionFailure.from(Exception('x')).code,
        DiscussionFailureCode.offline,
      );
      expect(
        DiscussionFailure.from(const AuthException('x')).code,
        DiscussionFailureCode.other,
      );
      expect(
        DiscussionFailure.from(const SocketException('down')).code,
        DiscussionFailureCode.offline,
      );
      const own = DiscussionFailure(DiscussionFailureCode.locked);
      expect(DiscussionFailure.from(own), same(own));
    });

    test('every failure has words to show', () {
      for (final code in DiscussionFailureCode.values) {
        expect(DiscussionFailure(code).message, isNotEmpty, reason: code.name);
      }
      expect(
        const DiscussionFailure(DiscussionFailureCode.contentNotAllowed)
            .message,
        contains('chat rules'),
      );
    });
  });

  group('DiscussionBoard', () {
    test('the boards the app knows are in its words, the others as the database has them', () {
      const known = DiscussionBoard(
        id: 'recommendations',
        titleFallback: 'x',
        descriptionFallback: 'y',
      );
      expect(known.title, 'What should I play?');
      expect(known.description, 'Ask for a game, or suggest one.');
      const other = DiscussionBoard(
        id: 'speedruns',
        titleFallback: 'Speedruns',
        descriptionFallback: 'Fast.',
      );
      expect(other.title, 'Speedruns');
      expect(other.description, 'Fast.');
      expect(other.icon, Icons.chat_bubble_outline_rounded);
    });
  });

  group('DiscussionsStore', () {
    late FakeRepository repo;
    late FakeAuthService authService;
    late AuthStore auth;
    late FakeDiscussionApi api;
    late DiscussionsStore store;
    late DebugPrintCallback originalDebugPrint;
    final me = testMember('u1', name: 'Me');

    setUp(() {
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {};
      SharedPreferences.setMockInitialValues({});
      repo = FakeRepository();
      authService = FakeAuthService(testUser('u1'));
      auth = AuthStore(authService)..initialize();
      api = FakeDiscussionApi(repo, me: me);
      store = DiscussionsStore(repository: repo, auth: auth, api: api)
        ..initialize();
      repo.discussionThreads.addAll([
        testThread(
          't1',
          title: 'Best soulslike?',
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
          game: const DiscussionGame(id: 'g1', title: 'Hades'),
        ),
        testThread(
          't4',
          board: 'help',
          title: 'Stuck on a boss',
          author: 'c',
          authorName: 'Cy',
          at: ago(60),
        ),
      ]);
      repo.discussionPosts['t1'] = [
        testPost(
          'p1',
          't1',
          author: 'b',
          authorName: 'Bob',
          text: 'Elden Ring.',
          at: ago(60),
        ),
        testPost(
          'p2',
          't1',
          author: 'a',
          authorName: 'Ann',
          text: 'Agreed.',
          at: ago(30),
        ),
      ];
    });

    tearDown(() {
      debugPrint = originalDebugPrint;
      store.dispose();
      auth.dispose();
    });

    List<String> ids(ThreadList list) => [for (final t in list.threads) t.id];

    test('nothing is asked until a screen asks, or signed out', () async {
      expect(store.boardsStatus, LoadStatus.idle);
      expect(repo.threadReads, isEmpty);

      authService.emit(null);
      await pumpEventQueue();
      await store.loadBoards();
      await store.loadThreads(DiscussionScope.all);
      await store.loadThread('t1');

      expect(repo.threadReads, isEmpty);
      expect(repo.postReads, isEmpty);
      expect(store.boardsStatus, LoadStatus.idle);
    });

    group('boards', () {
      test('are loaded with how many threads each has', () async {
        await store.loadBoards();

        expect(store.boardsStatus, LoadStatus.ready);
        expect(
          [for (final b in store.boards) (b.id, b.threadCount)],
          [('general', 2), ('games', 1), ('help', 1)],
        );
        expect(store.boardById('help')!.title, 'Help & tips');
        expect(store.boardById('nope'), isNull);
      });

      test('what is fresh is not asked for again, unless forced', () async {
        await store.loadBoards();
        repo.discussionThreads.removeWhere((t) => t.id == 't4');

        await store.loadBoards();
        expect(store.boardById('help')!.threadCount, 1);

        await store.loadBoards(force: true);
        expect(store.boardById('help')!.threadCount, 0);
      });

      test(
        'a failed first read is failed; a failed refresh keeps the boards',
        () async {
          repo.failDiscussionReads = true;
          await store.loadBoards();
          expect(store.boardsStatus, LoadStatus.failed);

          repo.failDiscussionReads = false;
          await store.loadBoards();
          expect(store.boardsStatus, LoadStatus.ready);

          repo.failDiscussionReads = true;
          await store.loadBoards(force: true);
          expect(store.boardsStatus, LoadStatus.ready);
          expect(store.boards, isNotEmpty);
        },
      );
    });

    group('lists of threads', () {
      test('all boards: the ones written in last first', () async {
        await store.loadThreads(DiscussionScope.all);

        expect(ids(store.listOf(DiscussionScope.all)), [
          't3',
          't1',
          't4',
          't2',
        ]);
        expect(store.listOf(DiscussionScope.all).status, LoadStatus.ready);
      });

      test('a board: pinned first, then the last written in', () async {
        const general = DiscussionScope(boardId: 'general');
        await store.loadThreads(general);

        expect(ids(store.listOf(general)), ['t2', 't1']);
      });

      test('a game: the threads about it', () async {
        const hades = DiscussionScope(gameId: 'g1');
        await store.loadThreads(hades);

        expect(ids(store.listOf(hades)), ['t3']);
        expect(store.listOf(hades).threads.single.game!.title, 'Hades');
      });

      test('what is fresh is not asked for again, unless forced', () async {
        await store.loadThreads(DiscussionScope.all);
        await store.loadThreads(DiscussionScope.all);
        expect(repo.threadReads, hasLength(1));

        await store.loadThreads(DiscussionScope.all, force: true);
        expect(repo.threadReads, hasLength(2));
      });

      test('two screens asking at once share one request', () async {
        repo.discussionGate = Completer<void>();

        final first = store.loadThreads(DiscussionScope.all);
        final second = store.loadThreads(DiscussionScope.all);
        expect(store.listOf(DiscussionScope.all).status, LoadStatus.loading);
        repo.discussionGate!.complete();
        await Future.wait([first, second]);

        expect(repo.threadReads, hasLength(1));
      });

      test('pages: the next page is appended without repeats, and the last stops it', () async {
        repo.discussionThreads.addAll([
          for (var i = 0; i < 25; i++)
            testThread('many-$i', board: 'off-topic', at: ago(1000 + i)),
        ]);
        const board = DiscussionScope(boardId: 'off-topic');
        await store.loadThreads(board);
        expect(store.listOf(board).threads, hasLength(20));
        expect(store.listOf(board).hasMore, isTrue);

        await store.loadMoreThreads(board);

        expect(store.listOf(board).threads, hasLength(25));
        expect(store.listOf(board).hasMore, isFalse);
        expect(repo.threadReads.last.offset, 20);
        expect({
          for (final t in store.listOf(board).threads) t.id,
        }, hasLength(25));
      });

      test('a failed page can be tried again', () async {
        repo.discussionThreads.addAll([
          for (var i = 0; i < 25; i++)
            testThread('many-$i', board: 'off-topic', at: ago(1000 + i)),
        ]);
        const board = DiscussionScope(boardId: 'off-topic');
        await store.loadThreads(board);
        repo.failDiscussionReads = true;

        await store.loadMoreThreads(board);
        expect(store.listOf(board).loadMoreFailed, isTrue);
        expect(store.listOf(board).hasMore, isTrue);

        repo.failDiscussionReads = false;
        await store.loadMoreThreads(board);
        expect(store.listOf(board).loadMoreFailed, isFalse);
        expect(store.listOf(board).threads, hasLength(25));
      });

      test(
        'a failed first read is failed; a failed refresh keeps what was shown',
        () async {
          repo.failDiscussionReads = true;
          await store.loadThreads(DiscussionScope.all);
          expect(store.listOf(DiscussionScope.all).status, LoadStatus.failed);

          repo.failDiscussionReads = false;
          await store.loadThreads(DiscussionScope.all);
          repo.failDiscussionReads = true;
          await store.loadThreads(DiscussionScope.all, force: true);

          expect(store.listOf(DiscussionScope.all).status, LoadStatus.ready);
          expect(store.listOf(DiscussionScope.all).threads, hasLength(4));
        },
      );
    });

    group('one thread', () {
      test('is loaded with its replies, oldest first', () async {
        await store.loadThread('t1');

        final view = store.viewOf('t1');
        expect(view.status, LoadStatus.ready);
        expect(view.thread!.title, 'Best soulslike?');
        expect([for (final p in view.posts) p.id], ['p1', 'p2']);
        expect(view.hasMore, isFalse);
      });

      test('one that is gone is ready and empty', () async {
        await store.loadThread('missing');

        expect(store.viewOf('missing').status, LoadStatus.ready);
        expect(store.viewOf('missing').thread, isNull);
      });

      test('replies are paged', () async {
        repo.discussionPosts['t1'] = [
          for (var i = 0; i < 35; i++)
            testPost('r$i', 't1', author: 'b', at: ago(500 - i)),
        ];
        await store.loadThread('t1');
        expect(store.viewOf('t1').posts, hasLength(30));
        expect(store.viewOf('t1').hasMore, isTrue);

        await store.loadMorePosts('t1');

        expect(store.viewOf('t1').posts, hasLength(35));
        expect(store.viewOf('t1').hasMore, isFalse);
        expect(repo.postReads.last.offset, 30);
      });

      test(
        'a failed first read is failed; a failed refresh keeps what was shown',
        () async {
          repo.failDiscussionReads = true;
          await store.loadThread('t1');
          expect(store.viewOf('t1').status, LoadStatus.failed);

          repo.failDiscussionReads = false;
          await store.loadThread('t1');
          repo.failDiscussionReads = true;
          await store.loadThread('t1');

          expect(store.viewOf('t1').status, LoadStatus.ready);
          expect(store.viewOf('t1').posts, hasLength(2));
        },
      );
    });

    group('posting', () {
      test(
        'a new thread is made, and the lists it belongs on are read again',
        () async {
          const general = DiscussionScope(boardId: 'general');
          const help = DiscussionScope(boardId: 'help');
          await store.loadThreads(general);
          await store.loadThreads(help);
          await store.loadThreads(DiscussionScope.all);

          final id = await store.createThread(
            boardId: 'general',
            title: 'Hello there',
            text: 'First post.',
          );
          await pumpEventQueue();

          expect(api.threadCalls.single, (
            board: 'general',
            title: 'Hello there',
            text: 'First post.',
            gameId: null,
          ));
          expect(ids(store.listOf(general)), contains(id));
          expect(ids(store.listOf(DiscussionScope.all)), contains(id));
          expect(ids(store.listOf(help)), isNot(contains(id)));
        },
      );

      test('a thread about a game also goes on that game\'s list', () async {
        const hades = DiscussionScope(gameId: 'g1');
        await store.loadThreads(hades);

        final id = await store.createThread(
          boardId: 'games',
          title: 'Hades again',
          text: 'Text.',
          gameId: 'g1',
        );
        await pumpEventQueue();

        expect(ids(store.listOf(hades)), contains(id));
      });

      test('a refused thread is thrown, and nothing is made', () async {
        api.failWith = const DiscussionFailure(
          DiscussionFailureCode.contentNotAllowed,
        );

        await expectLater(
          store.createThread(boardId: 'general', title: 'Hello', text: 'x'),
          throwsA(
            isA<DiscussionFailure>().having(
              (f) => f.code,
              'code',
              DiscussionFailureCode.contentNotAllowed,
            ),
          ),
        );

        expect(repo.discussionThreads, hasLength(4));
      });

      test(
        'a reply is posted, and is there once the thread is read on',
        () async {
          await store.loadThread('t1');
          await store.loadThreads(const DiscussionScope(boardId: 'general'));

          await store.reply('t1', 'Sekiro too.');

          expect(api.replyCalls.single, (thread: 't1', text: 'Sekiro too.'));
          final view = store.viewOf('t1');
          expect(
            [for (final p in view.posts) p.text],
            ['Elden Ring.', 'Agreed.', 'Sekiro too.'],
          );
          expect(view.thread!.replyCount, 3);
          // The list that holds the thread has its new count.
          expect(
            store
                .listOf(const DiscussionScope(boardId: 'general'))
                .threads
                .firstWhere((t) => t.id == 't1')
                .replyCount,
            3,
          );
        },
      );

      test('a reply to a long thread reads on to its end', () async {
        repo.discussionPosts['t1'] = [
          for (var i = 0; i < 30; i++)
            testPost(
              'r$i',
              't1',
              author: 'b',
              text: 'Reply $i.',
              at: ago(500 - i),
            ),
        ];
        await store.loadThread('t1');
        expect(store.viewOf('t1').hasMore, isTrue);

        await store.reply('t1', 'The last one.');

        expect(store.viewOf('t1').posts.last.text, 'The last one.');
        expect(store.viewOf('t1').posts, hasLength(31));
      });

      test('a refused reply is thrown, and nothing is added', () async {
        await store.loadThread('t1');
        api.failWith = const DiscussionFailure(
          DiscussionFailureCode.rateLimited,
        );

        await expectLater(
          store.reply('t1', 'Too fast.'),
          throwsA(isA<DiscussionFailure>()),
        );

        expect(store.viewOf('t1').posts, hasLength(2));
      });
    });

    group('your own', () {
      test('thread is deleted, and goes off every list', () async {
        await store.loadThreads(DiscussionScope.all);
        await store.loadThread('t1');

        await store.deleteThread('t1');

        expect(repo.deletedDiscussionThreads, ['t1']);
        expect(ids(store.listOf(DiscussionScope.all)), isNot(contains('t1')));
        expect(store.viewOf('t1').thread, isNull);
      });

      test('reply is deleted, and the count goes down', () async {
        await store.loadThread('t1');

        await store.deletePost('t1', 'p2');

        expect(repo.deletedDiscussionPosts, ['p2']);
        expect([for (final p in store.viewOf('t1').posts) p.id], ['p1']);
        expect(store.viewOf('t1').thread!.replyCount, 1);
      });

      test('a failed delete throws and keeps it', () async {
        await store.loadThread('t1');
        repo.failDiscussionWrites = true;

        await expectLater(store.deletePost('t1', 'p2'), throwsException);

        expect(store.viewOf('t1').posts, hasLength(2));
      });
    });

    group('reporting', () {
      test('a thread goes off the lists', () async {
        await store.loadThreads(DiscussionScope.all);

        await store.reportThread('t4', ReportReason.spam);

        expect(repo.discussionReports.single, (
          threadId: 't4',
          postId: null,
          reason: ReportReason.spam,
        ));
        expect(ids(store.listOf(DiscussionScope.all)), isNot(contains('t4')));
      });

      test('a reply goes off its thread', () async {
        await store.loadThread('t1');

        await store.reportPost('t1', 'p1', ReportReason.abuse);

        expect(repo.discussionReports.single, (
          threadId: null,
          postId: 'p1',
          reason: ReportReason.abuse,
        ));
        expect([for (final p in store.viewOf('t1').posts) p.id], ['p2']);
      });

      test('a report that could not be sent throws and keeps it', () async {
        await store.loadThreads(DiscussionScope.all);
        repo.failDiscussionWrites = true;

        await expectLater(
          store.reportThread('t4', ReportReason.spam),
          throwsException,
        );

        expect(ids(store.listOf(DiscussionScope.all)), contains('t4'));
      });
    });

    group('a blocked member', () {
      // Blocking is app-wide (BlocksStore); the discussions are told to forget them.
      Future<void> block(String id) async {
        await repo.blockMember(id);
        store.forgetMember(id);
      }

      test(
        'has their threads and replies taken off everything held',
        () async {
          await store.loadThreads(DiscussionScope.all);
          await store.loadThread('t1');
          await store.loadThread('t3');

          await block('b');

          expect(ids(store.listOf(DiscussionScope.all)), [
            't3',
            't1',
            't4',
          ]); // Bob's t2 is gone
          expect(
            [for (final p in store.viewOf('t1').posts) p.id],
            ['p2'],
          ); // and his reply
        },
      );

      test('has a thread they wrote, when open, gone', () async {
        await store.loadThread('t4');

        await block('c');

        expect(store.viewOf('t4').thread, isNull);
        expect(store.viewOf('t4').status, LoadStatus.ready);
      });

      test('comes back when unblocked', () async {
        await block('b');
        await store.loadThreads(DiscussionScope.all);
        expect(ids(store.listOf(DiscussionScope.all)), isNot(contains('t2')));

        await repo.unblockMember('b');
        store.refreshAfterUnblock();
        await store.loadThreads(DiscussionScope.all);

        expect(ids(store.listOf(DiscussionScope.all)), contains('t2'));
      });
    });

    group('the chat rules', () {
      test('are agreed to once per account, on this device', () async {
        expect(await store.hasAcceptedRules(), isFalse);

        await store.acceptRules();
        expect(await store.hasAcceptedRules(), isTrue);

        authService.emit(testUser('u2'));
        await pumpEventQueue();
        expect(await store.hasAcceptedRules(), isFalse);

        authService.emit(testUser('u1'));
        await pumpEventQueue();
        expect(await store.hasAcceptedRules(), isTrue);
      });

      test('signed out, nothing is agreed to', () async {
        authService.emit(null);
        await pumpEventQueue();

        await store.acceptRules();

        expect(await store.hasAcceptedRules(), isFalse);
      });
    });

    test('another account drops everything', () async {
      await store.loadBoards();
      await store.loadThreads(DiscussionScope.all);
      await store.loadThread('t1');

      authService.emit(testUser('u2'));
      await pumpEventQueue();

      expect(store.boardsStatus, LoadStatus.idle);
      expect(store.boards, isEmpty);
      expect(store.listOf(DiscussionScope.all).status, LoadStatus.idle);
      expect(store.viewOf('t1').status, LoadStatus.idle);
    });
  });
}
