import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/social_user.dart';

/// What a followed member did: logged a session, completed a game, or rated one
/// they have not completed.
enum FriendActivityKind { session, completed, rated }

/// One item of "From people you follow" on Home. The session note is not part
/// of it.
@immutable
class FriendActivity {
  const FriendActivity({
    required this.member,
    required this.game,
    required this.kind,
    required this.at,
    this.hours = 0,
    this.rating = 0,
  });

  final SocialUser member;

  /// The game as the catalog knows it, with none of the member's tracking state.
  final Game game;
  final FriendActivityKind kind;

  /// When the session was logged; for a completion or a rating, when the game
  /// was added to the member's library (the only date other members can see).
  final DateTime at;

  /// The session's hours; 0 for the other kinds.
  final double hours;

  /// Out of 10 stars, in halves; 0 when they did not rate it (always for a session).
  final double rating;
}
