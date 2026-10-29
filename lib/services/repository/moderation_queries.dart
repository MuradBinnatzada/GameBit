part of '../checkpoint_repository.dart';

/// Reporting content and members, and blocking a member (20261028235500_moderation_and_blocking.sql).
mixin _ModerationQueries on _RepositoryBase {
  /// Reports [userId]'s review of [gameId] as the signed-in member. Reporting
  /// the same review again changes nothing. Throws when it could not be sent.
  Future<void> reportReview({
    required String userId,
    required String gameId,
    required ReportReason reason,
  }) async {
    try {
      await _client.from(Db.reviewReports).insert({
        Db.reviewUserId: userId,
        Db.gameId: gameId,
        Db.reason: reason.wireName,
      });
    } on PostgrestException catch (e) {
      // 23505: this member reported the review already.
      if (e.code != '23505') rethrow;
    }
  }

  /// Reports a thread ([threadId]) or a reply ([postId]), one of them, as the
  /// signed-in member. Reporting the same thing again changes nothing. Throws
  /// when it could not be sent.
  Future<void> reportDiscussion({
    String? threadId,
    String? postId,
    required ReportReason reason,
  }) async {
    assert((threadId == null) != (postId == null));
    try {
      await _client.from(Db.discussionReports).insert({
        'thread_id': ?threadId,
        'post_id': ?postId,
        Db.reason: reason.wireName,
      });
    } on PostgrestException catch (e) {
      // 23505: this member reported it already.
      if (e.code != '23505') rethrow;
    }
  }

  /// Blocks [userId] as the signed-in member; blocking twice changes nothing.
  /// The server then leaves the member out of every read (profile, library,
  /// reviews, lists, discussions) and ends any follow between the two.
  Future<void> blockMember(String userId) async {
    try {
      await _client.from(Db.userBlocks).insert({Db.blockedId: userId});
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow;
    }
  }

  Future<void> unblockMember(String userId) async {
    await _client.from(Db.userBlocks).delete().eq(Db.blockedId, userId);
  }

  /// The members the signed-in one blocked, the newest block first.
  Future<List<SocialUser>> fetchBlockedMembers() async {
    final data = await _client.rpc(Db.rpcMyBlockedMembers);
    if (data is! List) return const [];
    return List.unmodifiable([
      for (final raw in data)
        if (raw is Map) _socialUserFromProfile(Map<String, dynamic>.from(raw)),
    ]);
  }

  /// Reports [userId]'s profile, photo or list ([listId], for a list) as the
  /// signed-in member. Reporting the same thing again changes nothing. Throws
  /// when it could not be sent (`CP429`: too many reports lately).
  Future<void> reportMember({
    required String userId,
    required MemberReportSubject subject,
    required ReportReason reason,
    String? listId,
  }) async {
    assert((subject == MemberReportSubject.list) == (listId != null));
    try {
      await _client.from(Db.userReports).insert({
        Db.reportedId: userId,
        Db.subject: subject.wireName,
        Db.listId: ?listId,
        Db.reason: reason.wireName,
      });
    } on PostgrestException catch (e) {
      // 23505: this member reported it already.
      if (e.code != '23505') rethrow;
    }
  }
}
