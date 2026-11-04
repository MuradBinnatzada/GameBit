import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_friends.dart';
import 'package:checkpoint/state/game_friends_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/panel.dart';
import 'package:checkpoint/widgets/profile_avatar.dart';

/// Which of the members you follow completed the game, are playing it or want to
/// play it (To Play or Wishlist), with their photos (each opens their profile)
/// and the rating they gave. Asks when the screen opens (see [GameFriendsStore]);
/// signed out, until the answer is here, when it fails or when none of them has
/// the game, nothing is drawn.
class FriendsPanel extends StatefulWidget {
  const FriendsPanel({super.key, required this.game});

  final Game game;

  @override
  State<FriendsPanel> createState() => _FriendsPanelState();
}

class _FriendsPanelState extends State<FriendsPanel> {
  @override
  void initState() {
    super.initState();
    _loadAfterFrame();
  }

  @override
  void didUpdateWidget(FriendsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.id != widget.game.id) _loadAfterFrame();
  }

  /// After the frame: loading notifies, which isn't allowed during build.
  void _loadAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<GameFriendsStore>().load(widget.game.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = context.watch<GameFriendsStore>().viewOf(widget.game.id);
    final friends = view.friends;
    if (view.status != LoadStatus.ready || friends.isEmpty) {
      return const SizedBox.shrink();
    }
    final groups = [
      for (final group in FriendGroup.values)
        if (friends.countOf(group) > 0) group,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Panel(
        title: context.l10n.friends,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < groups.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 28,
                  color: context.palette.hairline,
                ),
              _FriendGroupRow(
                group: groups[i],
                count: friends.countOf(groups[i]),
                members: friends.membersOf(groups[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "3 friends completed it", "1 friend is playing", "2 friends want to play".
String friendGroupHeadline(FriendGroup group, int count) {
  final l10n = L10n.current;
  return switch (group) {
    FriendGroup.completed => l10n.friendsCompletedIt(count),
    FriendGroup.playing => l10n.friendsArePlaying(count),
    FriendGroup.wantToPlay => l10n.friendsWantToPlay(count),
  };
}

class _FriendGroupRow extends StatelessWidget {
  const _FriendGroupRow({
    required this.group,
    required this.count,
    required this.members,
  });

  final FriendGroup group;

  /// All of them, which can be more than [members] holds.
  final int count;
  final List<FriendWithGame> members;

  static const double _avatar = 46;
  static const double _star = 10;

  @override
  Widget build(BuildContext context) {
    final more = count - members.length;
    final status = group.statuses.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(status.icon, size: 16, color: context.palette.legible(status.color)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                friendGroupHeadline(group, count),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.palette.muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: _avatar + 6 + _star + 2,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: members.length + (more > 0 ? 1 : 0),
            separatorBuilder: (context, index) => const SizedBox(width: 10),
            itemBuilder: (context, i) => i < members.length
                ? _FriendAvatar(
                    friend: members[i],
                    size: _avatar,
                    starSize: _star,
                  )
                : _MoreBubble(more: more, size: _avatar),
          ),
        ),
      ],
    );
  }
}

/// A friend's photo, which opens their profile, over the rating they gave (blank
/// when they did not rate the game): ten stars would be wider than the photo, so
/// it is one star and the number.
class _FriendAvatar extends StatelessWidget {
  const _FriendAvatar({
    required this.friend,
    required this.size,
    required this.starSize,
  });

  final FriendWithGame friend;
  final double size;
  final double starSize;

  @override
  Widget build(BuildContext context) {
    final member = friend.member;
    return SizedBox(
      // As wide as it was for five stars: room for "10" and a star under the photo.
      width: starSize * 5 + 2,
      child: Column(
        children: [
          Tooltip(
            message: member.name,
            child: Semantics(
              button: true,
              label: context.l10n.openMemberProfile(member.name),
              excludeSemantics: true,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () =>
                    openProfile(context, userId: member.id, preview: member),
                child: ProfileAvatar(
                  name: member.name,
                  size: size,
                  imageUrl: member.avatarUrl,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (friend.rating > 0)
            Semantics(
              label: context.l10n.outOf10Stars(fmtHours(friend.rating)),
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star_rounded, size: starSize + 2, color: context.palette.star),
                  const SizedBox(width: 1),
                  Text(
                    fmtHours(friend.rating),
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: starSize + 1,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ],
              ),
            )
          else
            SizedBox(height: starSize),
        ],
      ),
    );
  }
}

/// How many more friends have the status than are shown.
class _MoreBubble extends StatelessWidget {
  const _MoreBubble({required this.more, required this.size});

  final int more;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: context.palette.text.withValues(alpha: 0.06),
          border: Border.all(color: context.palette.text.withValues(alpha: 0.1)),
        ),
        child: Text(
          '+$more',
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
