import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/services/discussion_failure.dart';

/// Posting to the discussions, through the `discussions` Supabase Edge Function:
/// the only way to write a thread or a reply, because it holds the rate limit and
/// the word filter. Reading, reporting and deleting go through the database (see
/// `CheckpointRepository`). Every failure is thrown as a [DiscussionFailure].
class DiscussionApiService {
  Future<Map<String, dynamic>> _invoke(Map<String, Object> body) async {
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'discussions',
        body: body,
      );
      final raw = res.data;
      final decoded = raw is String ? json.decode(raw) : raw;
      if (decoded is Map<String, dynamic>) return decoded;
      throw const DiscussionFailure(DiscussionFailureCode.other);
    } catch (e) {
      debugPrint('discussions request failed: $e');
      throw DiscussionFailure.from(e);
    }
  }

  /// Starts a thread on [boardId], optionally about the game [gameId] (its
  /// catalog id), and answers its id.
  Future<String> createThread({
    required String boardId,
    required String title,
    required String text,
    String? gameId,
  }) async {
    final answer = await _invoke({
      'mode': 'thread',
      'board': boardId,
      'title': title,
      'body': text,
      'game_id': ?gameId,
    });
    final thread = answer['thread'];
    final id = thread is Map ? thread['id'] : null;
    if (id is! String || id.isEmpty) {
      throw const DiscussionFailure(DiscussionFailureCode.other);
    }
    return id;
  }

  /// Replies to the thread [threadId], to the post [replyTo] of it when one is named
  /// (that member is told).
  Future<void> reply(String threadId, String text, {String? replyTo}) async {
    final answer = await _invoke({
      'mode': 'reply',
      'thread': threadId,
      'body': text,
      'reply_to': ?replyTo,
    });
    if (answer['post'] is! Map) {
      throw const DiscussionFailure(DiscussionFailureCode.other);
    }
  }
}
