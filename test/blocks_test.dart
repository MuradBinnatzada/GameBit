import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:checkpoint/models/friend_activity.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_friends.dart';
import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/services/content_refusal.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/blocks_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/fakes.dart';

void main() {
  late FakeRepository repo;
  late FakeAuthService authService;
  late AppStores stores;

  setUp(() {
    debugPrint = (String? message, {int? wrapWidth}) {};
    SharedPreferences.setMockInitialValues({});
    repo = FakeRepository();
    authService = FakeAuthService(testUser('u1'));
    stores = AppStores(
      repository: repo,
      authService: authService,
      connectivity: FakeConnectivity(),
    );
  });

  tearDown(() {
    debugPrint = debugPrintThrottled;
    stores.dispose();
  });

  Future<BlocksStore> ready() async {
    await stores.auth.initialize();
    stores.blocks.initialize();
    return stores.blocks;
  }

  group('the blocked members', () {
    test('nothing is asked until a screen asks, or signed out', () async {
      final blocks = await ready();
      expect(blocks.status, LoadStatus.idle);

      authService.emit(null);
      await pumpEventQueue();
      await blocks.load();

      expect(blocks.status, LoadStatus.idle);
    });

    test('are listed, the newest block first', () async {
      final blocks = await ready();
      repo.blockedMembers['a'] = testMember('a', name: 'Ann');
      repo.blockedMembers['b'] = testMember('b', name: 'Bob');

      await blocks.load();

      expect(blocks.status, LoadStatus.ready);
      expect(blocks.blocked.map((m) => m.id), ['a', 'b']);
      expect(blocks.isBlocked('a'), isTrue);
      expect(blocks.isBlocked('z'), isFalse);
    });

    test('a failed load is failed, and keeps a list already shown', () async {
      final blocks = await ready();
      repo.failDiscussionReads = true;
      await blocks.load();
      expect(blocks.status, LoadStatus.failed);

      repo.failDiscussionReads = false;
      repo.blockedMembers['a'] = testMember('a');
      await blocks.load();
      expect(blocks.status, LoadStatus.ready);

      repo.failDiscussionReads = true;
      await blocks.load();
      expect(blocks.status, LoadStatus.ready);
      expect(blocks.blocked.map((m) => m.id), ['a']);
    });

    test('block adds the member, tells the others and is sent once', () async {
      final blocks = await ready();
      final told = <(String, bool)>[];
      final own = BlocksStore(
        repository: repo,
        auth: stores.auth,
        onChanged: (id, {required blocked}) => told.add((id, blocked)),
      )..initialize();
      addTearDown(own.dispose);

      await own.block(testMember('b', name: 'Bob'));
      await own.block(testMember('b', name: 'Bob'));

      expect(own.blocked.map((m) => m.id), ['b']);
      expect(repo.blockedMembers.keys, ['b']);
      expect(told, [('b', true), ('b', true)]);
      expect(blocks.blocked, isEmpty); // another store: not this one's business
    });

    test('a failed block throws and changes nothing', () async {
      await ready();
      final told = <String>[];
      final own = BlocksStore(
        repository: repo,
        auth: stores.auth,
        onChanged: (id, {required blocked}) => told.add(id),
      )..initialize();
      addTearDown(own.dispose);
      repo.failDiscussionWrites = true;

      await expectLater(own.block(testMember('b')), throwsException);

      expect(own.blocked, isEmpty);
      expect(told, isEmpty);
    });

    test('unblock removes the member and tells the others', () async {
      await ready();
      final told = <(String, bool)>[];
      final own = BlocksStore(
        repository: repo,
        auth: stores.auth,
        onChanged: (id, {required blocked}) => told.add((id, blocked)),
      )..initialize();
      addTearDown(own.dispose);
      await own.block(testMember('b'));

      await own.unblock('b');

      expect(own.blocked, isEmpty);
      expect(repo.blockedMembers, isEmpty);
      expect(told.last, ('b', false));
    });

    test('are forgotten when another account signs in', () async {
      final blocks = await ready();
      await blocks.block(testMember('b'));
      expect(blocks.blocked, hasLength(1));

      authService.emit(testUser('u2'));
      await pumpEventQueue();

      expect(blocks.blocked, isEmpty);
      expect(blocks.status, LoadStatus.idle);
    });
  });

  group('blocking a member, the app forgets them', () {
    test('in reviews, the friends feed, who has a game and member search', () async {
      repo.gameReviews['g1'] = [
        testReview('a', text: 'Great.', rating: 4),
        testReview('b', text: 'Awful.', rating: 1),
      ];
      repo.followingActivity = [
        testActivity('a', 'g1', FriendActivityKind.session, hours: 2),
        testActivity('b', 'g2', FriendActivityKind.completed, rating: 4),
      ];
      repo.friendsWithGame['g1'] = testGameFriends([
        testFriend('a', GameStatus.completed, rating: 4),
        testFriend('b', GameStatus.completed),
        testFriend('c', GameStatus.playing),
      ]);
      await ready();
      stores.gameReviews.initialize();
      stores.friendsFeed.initialize();
      stores.gameFriends.initialize();
      await stores.gameReviews.load('g1');
      await stores.friendsFeed.load();
      await stores.gameFriends.load('g1');
      expect(stores.gameReviews.viewOf('g1').preview, hasLength(2));

      await stores.blocks.block(testMember('b', name: 'Bob'));

      final reviews = stores.gameReviews.viewOf('g1');
      expect([for (final r in reviews.preview) r.member.id], ['a']);
      expect([for (final r in reviews.reviews) r.member.id], ['a']);
      expect(stores.friendsFeed.items.map((i) => i.member.id), ['a']);
      final friends = stores.gameFriends.viewOf('g1').friends;
      expect(friends.friends.map((f) => f.member.id), ['a', 'c']);
      expect(friends.countOf(FriendGroup.completed), 1);
      expect(friends.countOf(FriendGroup.playing), 1);
    });

    test('and the follow between you is gone', () async {
      repo.following.addAll(['b', 'c']);
      await ready();
      await stores.profile.initialize();
      expect(stores.profile.isFollowing('b'), isTrue);

      await stores.blocks.block(testMember('b'));

      expect(stores.profile.isFollowing('b'), isFalse);
      expect(stores.profile.isFollowing('c'), isTrue);
    });
  });

  group('reporting a member', () {
    test('sends the subject, the reason and the list', () async {
      await ready();

      await stores.publicProfiles.report('m1', MemberReportSubject.avatar, ReportReason.abuse);
      await stores.lists.reportList('m1', 'l1', ReportReason.spam);

      expect(repo.memberReports, [
        (userId: 'm1', subject: MemberReportSubject.avatar, reason: ReportReason.abuse, listId: null),
        (userId: 'm1', subject: MemberReportSubject.list, reason: ReportReason.spam, listId: 'l1'),
      ]);
    });

    test('a report that could not be sent throws', () async {
      await ready();
      repo.failDiscussionWrites = true;

      await expectLater(
        stores.publicProfiles.report('m1', MemberReportSubject.profile, ReportReason.other),
        throwsException,
      );
    });
  });

  group('text the server refuses', () {
    test('is told apart by its SQLSTATE', () {
      const refused = PostgrestException(message: 'content_not_allowed', code: 'CP422', details: 'bio');
      const other = PostgrestException(message: 'nope', code: '23505');

      expect(isContentRefusal(refused), isTrue);
      expect(refusedField(refused), 'bio');
      expect(isContentRefusal(other), isFalse);
      expect(isContentRefusal(Exception('x')), isFalse);
      expect(isRateLimited(const PostgrestException(message: 'rate_limited', code: 'CP429')), isTrue);
    });
  });
}
