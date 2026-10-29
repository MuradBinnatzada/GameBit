import 'package:flutter/foundation.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/social_user.dart';

/// A member the signed-in one follows who has a game in their library.
@immutable
class FriendWithGame {
  const FriendWithGame({
    required this.member,
    required this.status,
    this.rating = 0,
    this.dateAdded,
  });

  final SocialUser member;
  final GameStatus status;

  /// Out of 5, in halves; 0 when they did not rate it.
  final double rating;
  final DateTime? dateAdded;
}

/// The rows of the Friends panel on a game's screen. Dropped is left out: the
/// panel is about who liked, is playing or wants to play the game.
enum FriendGroup {
  completed({GameStatus.completed}),
  playing({GameStatus.playing}),
  wantToPlay({GameStatus.toPlay, GameStatus.wishlist});

  const FriendGroup(this.statuses);
  final Set<GameStatus> statuses;

  String get label => switch (this) {
    completed => L10n.current.friendGroupCompleted,
    playing => L10n.current.friendGroupPlaying,
    wantToPlay => L10n.current.friendGroupWantToPlay,
  };
}

/// Which of the members the signed-in one follows have a game, and how. The
/// server sends a few members per status (see `CheckpointRepository.fetchFriendsWithGame`)
/// with the full count of each, so [countOf] can be more than [membersOf] holds.
@immutable
class GameFriends {
  const GameFriends({this.friends = const [], this.totals = const {}});

  /// Rated first, then the most recently added, within each status.
  final List<FriendWithGame> friends;

  /// How many followed members have each status, all of them.
  final Map<GameStatus, int> totals;

  bool get isEmpty => FriendGroup.values.every((g) => countOf(g) == 0);

  /// These friends without [memberId], and the totals one lower for their status:
  /// the member was blocked.
  GameFriends without(String memberId) {
    final gone = [
      for (final f in friends)
        if (f.member.id == memberId) f,
    ];
    if (gone.isEmpty) return this;
    final next = {...totals};
    for (final f in gone) {
      final left = (next[f.status] ?? 0) - 1;
      next[f.status] = left < 0 ? 0 : left;
    }
    return GameFriends(
      friends: [
        for (final f in friends)
          if (f.member.id != memberId) f,
      ],
      totals: next,
    );
  }

  int countOf(FriendGroup group) =>
      group.statuses.fold(0, (sum, s) => sum + (totals[s] ?? 0));

  /// The members of [group] that were sent: rated first, then the most
  /// recently added (To Play and Wishlist are merged, so they are sorted again).
  List<FriendWithGame> membersOf(FriendGroup group) {
    final members = [
      for (final f in friends)
        if (group.statuses.contains(f.status)) f,
    ];
    if (group.statuses.length > 1) members.sort(_ratedThenNewest);
    return members;
  }
}

int _ratedThenNewest(FriendWithGame a, FriendWithGame b) {
  final rated = (b.rating > 0 ? 1 : 0) - (a.rating > 0 ? 1 : 0);
  if (rated != 0) return rated;
  final at = a.dateAdded;
  final bt = b.dateAdded;
  // Undated last.
  if (at == null || bt == null) {
    return (at == null ? 1 : 0) - (bt == null ? 1 : 0);
  }
  return bt.compareTo(at);
}
