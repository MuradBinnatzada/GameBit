import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/social_user.dart';

/// A board of the discussions: one of the pre-made places threads are started on.
/// The database holds an English title and description for each; the boards the
/// app knows by id are shown in its own words (see [title]), any other as the
/// database has them.
@immutable
class DiscussionBoard {
  const DiscussionBoard({
    required this.id,
    required this.titleFallback,
    this.descriptionFallback = '',
    this.threadCount = 0,
    this.latestAt,
  });

  final String id;
  final String titleFallback;
  final String descriptionFallback;

  /// How many threads it has, and when one was last written in.
  final int threadCount;
  final DateTime? latestAt;

  String get title => switch (id) {
    'general' => L10n.current.boardGeneral,
    'games' => L10n.current.boardGames,
    'recommendations' => L10n.current.boardRecommendations,
    'help' => L10n.current.boardHelp,
    'news' => L10n.current.boardNews,
    'off-topic' => L10n.current.boardOffTopic,
    'feedback' => L10n.current.boardFeedback,
    _ => titleFallback,
  };

  String get description => switch (id) {
    'general' => L10n.current.boardGeneralDescription,
    'games' => L10n.current.boardGamesDescription,
    'recommendations' => L10n.current.boardRecommendationsDescription,
    'help' => L10n.current.boardHelpDescription,
    'news' => L10n.current.boardNewsDescription,
    'off-topic' => L10n.current.boardOffTopicDescription,
    'feedback' => L10n.current.boardFeedbackDescription,
    _ => descriptionFallback,
  };

  IconData get icon => switch (id) {
    'general' => Icons.forum_rounded,
    'games' => Icons.sports_esports_rounded,
    'recommendations' => Icons.recommend_rounded,
    'help' => Icons.help_outline_rounded,
    'news' => Icons.newspaper_rounded,
    'off-topic' => Icons.coffee_rounded,
    'feedback' => Icons.lightbulb_outline_rounded,
    _ => Icons.chat_bubble_outline_rounded,
  };
}

/// The game a thread is about.
@immutable
class DiscussionGame {
  const DiscussionGame({
    required this.id,
    required this.title,
    this.igdbId,
    this.coverUrl,
  });

  /// The game's catalog id (`games.id`).
  final String id;
  final String title;
  final int? igdbId;
  final String? coverUrl;
}

/// A thread: a title and an opening text on a board, written by a member, with the
/// replies to it counted. In a list [text] is the start of the opening text; on its
/// own screen it is all of it.
@immutable
class DiscussionThread {
  const DiscussionThread({
    required this.id,
    required this.boardId,
    required this.author,
    required this.title,
    required this.text,
    required this.createdAt,
    required this.lastPostAt,
    this.replyCount = 0,
    this.pinned = false,
    this.locked = false,
    this.game,
  });

  final String id;
  final String boardId;
  final SocialUser author;
  final String title;
  final String text;
  final DateTime createdAt;

  /// When the thread was last written in: started, or replied to.
  final DateTime lastPostAt;
  final int replyCount;

  /// Kept on top of its board by whoever moderates.
  final bool pinned;

  /// Takes no more replies.
  final bool locked;
  final DiscussionGame? game;
}

/// A reply to a thread.
@immutable
class DiscussionPost {
  const DiscussionPost({
    required this.id,
    required this.threadId,
    required this.author,
    required this.text,
    required this.createdAt,
    this.replyTo,
  });

  final String id;
  final String threadId;
  final SocialUser author;
  final String text;
  final DateTime createdAt;

  /// The post this one answers, when it names one (and the viewer may see it).
  final DiscussionQuote? replyTo;
}

/// The post a reply answers: who wrote it and how it starts, shown above the reply
/// as "Replying to" and the name.
@immutable
class DiscussionQuote {
  const DiscussionQuote({required this.postId, required this.authorName, this.excerpt = ''});

  final String postId;
  final String authorName;
  final String excerpt;
}

/// What a list of threads is of: a board, the threads about a game, or both; with
/// neither, the latest of every board.
@immutable
class DiscussionScope {
  const DiscussionScope({this.boardId, this.gameId});

  static const all = DiscussionScope();

  final String? boardId;

  /// A game's catalog id (`games.id`).
  final String? gameId;

  @override
  bool operator ==(Object other) =>
      other is DiscussionScope &&
      other.boardId == boardId &&
      other.gameId == gameId;

  @override
  int get hashCode => Object.hash(boardId, gameId);
}

/// The longest a thread's title may be, and the longest texts: what the
/// `discussions` function accepts (`_shared/discussions.ts`).
abstract final class DiscussionLimits {
  static const titleMin = 3;
  static const titleMax = 120;
  static const threadTextMax = 3000;
  static const replyMax = 2000;
}

/// What the member is told of one discussion by push notification
/// (`thread_notification_modes`, 20261107160000_thread_notification_modes.sql).
enum ThreadNotifications {
  /// The default: a reply to their post, and every reply in a thread they started.
  standard(null),

  /// Every new reply in the thread, whoever it answers.
  following('following'),

  /// Nothing from it.
  muted('muted');

  const ThreadNotifications(this.wire);

  /// The `mode` of the row; none for [standard].
  final String? wire;

  static ThreadNotifications fromWire(Object? wire) =>
      values.firstWhere((m) => m.wire != null && m.wire == wire, orElse: () => standard);
}
