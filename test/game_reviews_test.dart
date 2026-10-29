import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/screens/game_detail/game_detail_screen.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/game_reviews_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';

import 'support/fakes.dart';

/// [count] reviews by members "r0", "r1"..., newest first (r0 is the newest).
List<GameReview> reviewsOf(int count, {bool Function(int i)? following}) => [
  for (var i = 0; i < count; i++)
    testReview(
      'r$i',
      name: 'Reviewer $i',
      text: 'Review number $i.',
      rating: (i % 5) + 1.0,
      at: DateTime(2026, 10, 20).subtract(Duration(days: i)),
      following: following?.call(i) ?? false,
    ),
];

void main() {
  group('CommunityRatings', () {
    test('a whole star holds the half star under it too', () {
      // 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5
      const ratings = CommunityRatings(
        ratings: 55,
        average: 3.2,
        halfStars: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
      );

      expect(ratings.countForStars(1), 3);
      expect(ratings.countForStars(2), 7);
      expect(ratings.countForStars(3), 11);
      expect(ratings.countForStars(4), 15);
      expect(ratings.countForStars(5), 19);
    });

    test('a game nobody rated has no stars to count', () {
      expect(const CommunityRatings().isEmpty, isTrue);
      expect(const CommunityRatings().countForStars(5), 0);
      expect(const CommunityRatings(reviews: 1).isEmpty, isFalse);
    });

    test('reads what game_review_stats answers, and nothing odd', () {
      final ratings = CommunityRatings.fromRow({
        'ratings': 12,
        'average': 4.25,
        'reviews': 3,
        'half_stars': [0, 0, 0, 0, 0, 0, 0, 3, 4, 5],
      })!;

      expect(ratings.ratings, 12);
      expect(ratings.average, 4.25);
      expect(ratings.reviews, 3);
      expect(ratings.countForStars(5), 9);

      final odd = CommunityRatings.fromRow({
        'ratings': -1,
        'average': 9,
        'reviews': 'many',
        'half_stars': 'no',
      })!;
      expect(odd.ratings, 0);
      expect(odd.average, 5);
      expect(odd.reviews, 0);
      expect(odd.halfStars, isEmpty);
      expect(CommunityRatings.fromRow('nope'), isNull);
    });
  });

  group('GameReviewsStore', () {
    late FakeRepository repo;
    late FakeAuthService authService;
    late AuthStore auth;
    late GameReviewsStore store;

    late DebugPrintCallback originalDebugPrint;

    setUp(() {
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {};
      SharedPreferences.setMockInitialValues({});
      repo = FakeRepository();
      authService = FakeAuthService(testUser('u1'));
      auth = AuthStore(authService)..initialize();
      store = GameReviewsStore(repository: repo, auth: auth)..initialize();
      repo.gameReviews['g1'] = reviewsOf(25);
    });

    tearDown(() {
      debugPrint = originalDebugPrint;
      store.dispose();
      auth.dispose();
    });

    List<String> ids(List<GameReview> reviews) => [
      for (final r in reviews) r.member.id,
    ];

    test('nothing is fetched until a game screen asks', () {
      expect(store.viewOf('g1').status, LoadStatus.idle);
      expect(repo.reviewReads, isEmpty);
    });

    test(
      'loads the rating and the first page, and previews the first few',
      () async {
        await store.load('g1');

        final view = store.viewOf('g1');
        expect(view.status, LoadStatus.ready);
        expect(view.ratings.reviews, 25);
        expect(ids(view.preview), ['r0', 'r1', 'r2']);
        expect(view.listStatus, LoadStatus.ready);
        expect(view.reviews, hasLength(20));
        expect(view.hasMore, isTrue);
        expect(view.filter, ReviewFilter.standard);
      },
    );

    test('friends come first in the standard order', () async {
      repo.gameReviews['g1'] = reviewsOf(5, following: (i) => i == 3);

      await store.load('g1');

      expect(ids(store.viewOf('g1').preview), ['r3', 'r0', 'r1']);
    });

    test('signed out, nothing is asked', () async {
      authService.emit(null);
      await pumpEventQueue();
      await store.load('g1');

      expect(repo.reviewReads, isEmpty);
      expect(store.viewOf('g1').status, LoadStatus.idle);
    });

    test('asks again each time, showing the copy held meanwhile', () async {
      await store.load('g1');
      repo.gameReviews['g1'] = reviewsOf(1);
      repo.reviewsGate = Completer<void>();

      final again = store.load('g1');
      expect(store.viewOf('g1').status, LoadStatus.ready);
      expect(store.viewOf('g1').reviews, hasLength(20));

      repo.reviewsGate!.complete();
      await again;
      expect(store.viewOf('g1').reviews, hasLength(1));
    });

    test('two screens asking at once share one request, and a change meanwhile asks once more', () async {
      repo.reviewsGate = Completer<void>();

      final first = store.load('g1');
      final second = store.load('g1');
      repo.reviewsGate!.complete();
      await Future.wait([first, second]);
      await pumpEventQueue();

      // The page is read for the first call, and again for the second.
      expect(repo.reviewReads.map((r) => r.offset), [0, 0]);
    });

    test(
      'a failed first read is failed; a failed refresh keeps what was shown',
      () async {
        repo.failReviewReads = true;
        await store.load('g1');
        expect(store.viewOf('g1').status, LoadStatus.failed);

        repo.failReviewReads = false;
        await store.load('g1');
        expect(store.viewOf('g1').status, LoadStatus.ready);

        repo.failReviewReads = true;
        await store.load('g1');
        expect(store.viewOf('g1').status, LoadStatus.ready);
        expect(store.viewOf('g1').reviews, isNotEmpty);
      },
    );

    test('refresh asks again for a game that was loaded, and ignores one that was not', () async {
      await store.refresh('g1');
      expect(repo.reviewReads, isEmpty);

      await store.load('g1');
      repo.gameReviews['g1'] = reviewsOf(2);
      await store.refresh('g1');

      expect(store.viewOf('g1').reviews, hasLength(2));
    });

    test('another account drops everything', () async {
      await store.load('g1');

      authService.emit(testUser('u2'));
      await pumpEventQueue();

      expect(store.viewOf('g1').status, LoadStatus.idle);
      expect(store.viewOf('g1').reviews, isEmpty);
    });

    group('the list', () {
      test('is the first page when the order is the standard one, without asking again', () async {
        await store.load('g1');
        final reads = repo.reviewReads.length;

        await store.loadList('g1');

        expect(repo.reviewReads, hasLength(reads));
      });

      test('another order is asked for, and replaces the list', () async {
        repo.gameReviews['g1'] = reviewsOf(4);
        await store.load('g1');

        await store.loadList(
          'g1',
          filter: const ReviewFilter(sort: ReviewSort.lowest),
        );

        final view = store.viewOf('g1');
        expect(view.filter.sort, ReviewSort.lowest);
        expect(ids(view.reviews), ['r0', 'r1', 'r2', 'r3']); // rated 1, 2, 3, 4
        expect(view.listStatus, LoadStatus.ready);
        // The game's screen keeps its preview in the standard order.
        expect(ids(view.preview), ['r0', 'r1', 'r2']);
      });

      test('only the members you follow', () async {
        repo.gameReviews['g1'] = reviewsOf(5, following: (i) => i.isEven);

        await store.loadList(
          'g1',
          filter: const ReviewFilter(onlyFollowing: true),
        );

        expect(ids(store.viewOf('g1').reviews), ['r0', 'r2', 'r4']);
      });

      test(
        'appends the next page after the reviews held, without repeats',
        () async {
          await store.load('g1');

          await store.loadMore('g1');

          final view = store.viewOf('g1');
          expect(view.reviews, hasLength(25));
          expect(view.hasMore, isFalse);
          expect(repo.reviewReads.last.offset, 20);
          expect(ids(view.reviews).toSet(), hasLength(25));
        },
      );

      test('a page with nothing new stops the paging', () async {
        // A source that answers every page alike.
        repo.gameReviews['g1'] = reviewsOf(20);
        await store.load('g1');
        expect(store.viewOf('g1').hasMore, isTrue);

        await store.loadMore('g1');

        expect(store.viewOf('g1').reviews, hasLength(20));
        expect(store.viewOf('g1').hasMore, isFalse);
      });

      test('a failed page can be tried again', () async {
        await store.load('g1');
        repo.failReviewReads = true;

        await store.loadMore('g1');
        expect(store.viewOf('g1').loadMoreFailed, isTrue);
        expect(store.viewOf('g1').hasMore, isTrue);

        repo.failReviewReads = false;
        await store.loadMore('g1');
        expect(store.viewOf('g1').loadMoreFailed, isFalse);
        expect(store.viewOf('g1').reviews, hasLength(25));
      });

      test('an answer overtaken by another order is dropped', () async {
        await store.load('g1');
        repo.reviewsGate = Completer<void>();

        final slow = store.loadList(
          'g1',
          filter: const ReviewFilter(sort: ReviewSort.highest),
        );
        final latest = store.loadList(
          'g1',
          filter: const ReviewFilter(
            sort: ReviewSort.newest,
            onlyFollowing: true,
          ),
        );
        repo.reviewsGate!.complete();
        await Future.wait([slow, latest]);

        expect(
          store.viewOf('g1').filter,
          const ReviewFilter(sort: ReviewSort.newest, onlyFollowing: true),
        );
        expect(store.viewOf('g1').reviews, isEmpty); // nobody is followed
        expect(store.viewOf('g1').listStatus, LoadStatus.ready);
      });

      test('a refresh keeps the order the screen is showing', () async {
        repo.gameReviews['g1'] = reviewsOf(4);
        await store.load('g1');
        await store.loadList(
          'g1',
          filter: const ReviewFilter(sort: ReviewSort.highest),
        );

        repo.gameReviews['g1'] = [
          ...reviewsOf(4),
          testReview('late', rating: 5, at: DateTime(2026, 10, 21)),
        ];
        await store.refresh('g1');
        await pumpEventQueue();

        final view = store.viewOf('g1');
        expect(view.filter.sort, ReviewSort.highest);
        expect(ids(view.reviews).take(2), ['late', 'r3']);
        expect(view.reviews, hasLength(5));
      });
    });

    group('reporting', () {
      test('takes the review off the lists, and out of the count', () async {
        await store.load('g1');
        final review = store.viewOf('g1').reviews[1];

        await store.report('g1', review, ReportReason.spam);

        final view = store.viewOf('g1');
        // The next review takes its place in the preview.
        expect(ids(view.preview), ['r0', 'r2', 'r3']);
        expect(view.reviews, hasLength(19));
        expect(view.ratings.reviews, 24);
        expect(repo.reviewReports.single, (
          userId: 'r1',
          gameId: 'g1',
          reason: ReportReason.spam,
        ));
      });

      test(
        'a report that could not be sent leaves the review and says so',
        () async {
          await store.load('g1');
          repo.failReviewReports = true;

          await expectLater(
            store.report(
              'g1',
              store.viewOf('g1').reviews.first,
              ReportReason.abuse,
            ),
            throwsException,
          );

          expect(store.viewOf('g1').reviews, hasLength(20));
          expect(store.viewOf('g1').ratings.reviews, 25);
        },
      );

      test(
        'a reported review stays out when the game is loaded again',
        () async {
          await store.load('g1');
          await store.report(
            'g1',
            store.viewOf('g1').reviews.first,
            ReportReason.other,
          );

          await store.load('g1');

          expect(ids(store.viewOf('g1').preview), ['r1', 'r2', 'r3']);
        },
      );
    });
  });

  group('the reviews of a game on screen', () {
    late FakeRepository repo;
    late AppStores stores;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      repo = FakeRepository()
        ..library = [testGame('g1', title: 'Hades', cover: false)];
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(testUser('u1')),
        connectivity: FakeConnectivity(),
        apiService: FakeDetailsApi(),
      );
    });

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> openGame(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(stores.initialize);
      await tester.pumpWidget(
        AppStoresScope(
          stores: stores,
          child: MaterialApp(
            theme: buildTheme(),
            home: const GameDetailScreen(gameId: 'g1'),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        stores.dispose();
      });
      await settle(tester);
    }

    /// Taps the chip of the Reviews screen named [label]; the row scrolls sideways
    /// and is wider than the screen in the test font.
    Future<void> tapChip(WidgetTester tester, String label) async {
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await settle(tester);
    }

    Future<void> openAllReviews(WidgetTester tester) async {
      await openGame(tester);
      await tester.tap(find.textContaining('Read all'));
      await settle(tester);
    }

    testWidgets(
      'the panel previews three reviews, and the rest are behind "Read all"',
      (tester) async {
        repo.gameReviews['g1'] = reviewsOf(8);
        await openGame(tester);

        expect(find.text('Review number 0.'), findsOneWidget);
        expect(find.text('Review number 2.'), findsOneWidget);
        expect(find.text('Review number 3.'), findsNothing);
        expect(find.text('Read all 8 reviews'), findsOneWidget);
      },
    );

    testWidgets('a few reviews have no "Read all"', (tester) async {
      repo.gameReviews['g1'] = reviewsOf(2);
      await openGame(tester);

      expect(find.text('Review number 1.'), findsOneWidget);
      expect(find.textContaining('Read all'), findsNothing);
    });

    testWidgets('signed out, the panel asks for a login and asks nothing', (
      tester,
    ) async {
      repo.popular = [testGame('g1', status: null, cover: false)];
      stores = AppStores(
        repository: repo,
        authService: FakeAuthService(),
        connectivity: FakeConnectivity(),
        apiService: FakeDetailsApi(),
      );
      await openGame(tester);

      expect(find.text('Log in'), findsWidgets);
      expect(
        find.text(
          'Reviews and the community rating are for signed-in members.',
        ),
        findsOneWidget,
      );
      expect(repo.reviewReads, isEmpty);
    });

    testWidgets(
      'the Reviews screen lists every review, with the rating on top',
      (tester) async {
        repo.gameReviews['g1'] = reviewsOf(8);
        await openAllReviews(tester);

        expect(find.text('Hades'), findsWidgets);
        expect(find.text('Review number 7.'), findsOneWidget);
        expect(find.text('8 ratings'), findsOneWidget);
        for (final label in [
          'Friends first',
          'Newest',
          'Highest rated',
          'Lowest rated',
          'Following only',
        ]) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
      },
    );

    testWidgets('the order and "Following only" ask for a new list', (
      tester,
    ) async {
      repo.gameReviews['g1'] = reviewsOf(6, following: (i) => i == 4);
      await openAllReviews(tester);

      await tapChip(tester, 'Lowest rated');
      expect(repo.reviewReads.last.filter.sort, ReviewSort.lowest);
      expect(
        tester.getTopLeft(find.text('Review number 0.')).dy,
        lessThan(tester.getTopLeft(find.text('Review number 1.')).dy),
      );

      await tapChip(tester, 'Following only');
      expect(
        repo.reviewReads.last.filter,
        const ReviewFilter(sort: ReviewSort.lowest, onlyFollowing: true),
      );
      expect(find.text('Review number 4.'), findsOneWidget);
      expect(find.text('Review number 0.'), findsNothing);
    });

    testWidgets('following nobody who reviewed it says so', (tester) async {
      repo.gameReviews['g1'] = reviewsOf(5);
      await openAllReviews(tester);

      await tapChip(tester, 'Following only');

      expect(find.text('No reviews from people you follow'), findsOneWidget);
    });

    testWidgets('a failed list can be tried again', (tester) async {
      repo.gameReviews['g1'] = reviewsOf(5);
      await openAllReviews(tester);
      repo.failReviewReads = true;
      await tapChip(tester, 'Newest');

      expect(find.text('Couldn’t load the reviews'), findsOneWidget);

      repo.failReviewReads = false;
      await tester.tap(find.text('Try again'));
      await settle(tester);

      expect(find.text('Review number 0.'), findsOneWidget);
    });

    testWidgets('a review is reported from its menu, and goes away', (
      tester,
    ) async {
      repo.gameReviews['g1'] = reviewsOf(5);
      await openAllReviews(tester);

      await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Report review'));
      await tester.pumpAndSettle();
      expect(find.text('Spam or ads'), findsOneWidget);
      expect(find.text('Abusive or hateful'), findsOneWidget);
      await tester.tap(find.text('Abusive or hateful'));
      await settle(tester);

      expect(repo.reviewReports.single.reason, ReportReason.abuse);
      expect(repo.reviewReports.single.gameId, 'g1');
      expect(find.text('Review number 0.'), findsNothing);
      expect(find.textContaining('we’ll take a look'), findsOneWidget);
    });

    testWidgets('a review author can be blocked from its menu, and their reviews go', (
      tester,
    ) async {
      repo.gameReviews['g1'] = reviewsOf(5);
      await openAllReviews(tester);
      expect(find.text('Review number 0.'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Block '));
      await tester.pumpAndSettle();
      // Asks first, and says what a block does.
      expect(find.textContaining('their profile, library, reviews'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await settle(tester);

      expect(repo.blockedMembers, hasLength(1));
      expect(find.text('Review number 0.'), findsNothing);
      expect(find.text('Review number 1.'), findsOneWidget);
      expect(find.textContaining('is blocked.'), findsOneWidget);
    });

    testWidgets('your own review has an Edit in its menu, not a Report', (
      tester,
    ) async {
      repo.gameReviews['g1'] = [
        testReview('u1', name: 'Me', text: 'My own words.', following: true),
        ...reviewsOf(4),
      ];
      await openAllReviews(tester);
      expect(find.text('You'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('Edit review'), findsOneWidget);
      expect(find.text('Report review'), findsNothing);
    });
  });
}
