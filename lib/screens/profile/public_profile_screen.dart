import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_reviews.dart' show MemberReportSubject;
import 'package:checkpoint/models/public_profile.dart';
import 'package:checkpoint/models/share_link.dart';
import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/screens/lists/lists_screen.dart';
import 'package:checkpoint/screens/profile/milestones_section.dart';
import 'package:checkpoint/widgets/share_link_button.dart';
import 'package:checkpoint/screens/profile/profile_layout.dart';
import 'package:checkpoint/sheets/member_actions.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_state.dart';
import 'package:checkpoint/state/milestones_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/public_profile_store.dart';
import 'package:checkpoint/state/social_graph_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/empty_state.dart';
import 'package:checkpoint/widgets/profile_link_rows.dart';

/// Another member's profile, laid out like your own ([ProfileLayout]): who they
/// are, icons of the accounts they connected, their bio, who follows them, then
/// their favorites, latest sessions, playtime, library numbers (each box opens
/// their library), hours per platform, ratings, their achievement count, and last
/// of all a short menu into their library and follow lists. The achievements are
/// left out when they have not connected Steam or keep them private (on your own
/// page, only when you have not connected Steam).
///
/// [preview] is the row the member was tapped from; it fills in the name and
/// photo while the profile loads.
class PublicProfileScreen extends StatefulWidget {
  const PublicProfileScreen({super.key, required this.userId, this.preview});

  final String userId;
  final SocialUser? preview;

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  @override
  void initState() {
    super.initState();
    // After the first frame: loading notifies, which isn't allowed during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load({bool force = false}) =>
      context.read<PublicProfileStore>().load(widget.userId, force: force);

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PublicProfileStore>();
    final view = store.viewOf(widget.userId);
    final isSelf = context.watch<AuthStore>().user?.id == widget.userId;

    final Widget body;
    switch (view.status) {
      case PublicProfileStatus.notFound:
        body = EmptyState(
          icon: Icons.person_off_rounded,
          title: context.l10n.profileNotFound,
          message: context.l10n.profileNotFoundMessage,
        );
      case PublicProfileStatus.failed:
        body = EmptyState(
          icon: Icons.cloud_off_rounded,
          title: context.l10n.profileLoadFailed,
          message: context.l10n.checkConnection,
          actionLabel: context.l10n.tryAgain,
          onAction: () => unawaited(_load(force: true)),
        );
      case PublicProfileStatus.loading:
        body = _Loading(preview: widget.preview);
      case PublicProfileStatus.ready:
        body = RefreshIndicator(
          onRefresh: () => _load(force: true),
          child: _Loaded(userId: widget.userId, view: view, isSelf: isSelf),
        );
    }

    return Scaffold(
      appBar: AppBar(
        actions: [
          ShareLinkButton(target: MemberLink(widget.userId)),
          if (!isSelf && view.profile != null) _MemberMenu(profile: view.profile!),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: body,
          ),
        ),
      ),
    );
  }
}

enum _MemberAction { reportProfile, reportPhoto, block }

/// Report this profile or its photo, or block the member (who is then gone from
/// the whole app, and this screen closes).
class _MemberMenu extends StatelessWidget {
  const _MemberMenu({required this.profile});

  final PublicProfile profile;

  Future<void> _selected(BuildContext context, _MemberAction action) async {
    final navigator = Navigator.of(context);
    switch (action) {
      case _MemberAction.reportProfile:
        await reportMemberProfile(
          context,
          userId: profile.id,
          name: profile.name,
          subject: MemberReportSubject.profile,
        );
      case _MemberAction.reportPhoto:
        await reportMemberProfile(
          context,
          userId: profile.id,
          name: profile.name,
          subject: MemberReportSubject.avatar,
        );
      case _MemberAction.block:
        final blocked = await blockMemberAfterAsking(
          context,
          SocialUser(
            id: profile.id,
            name: profile.name,
            handle: profile.handle,
            gamesLogged: 0,
            followers: 0,
            avatarUrl: profile.avatarUrl,
            flair: profile.flair,
          ),
        );
        if (blocked) navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    PopupMenuItem<_MemberAction> item(_MemberAction value, IconData icon, String label) =>
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 10),
              Flexible(child: Text(label)),
            ],
          ),
        );
    return PopupMenuButton<_MemberAction>(
      tooltip: l10n.memberOptions,
      onSelected: (action) => unawaited(_selected(context, action)),
      itemBuilder: (_) => [
        item(_MemberAction.reportProfile, Icons.flag_outlined, l10n.reportProfile),
        if (profile.avatarUrl != null)
          item(_MemberAction.reportPhoto, Icons.image_not_supported_outlined, l10n.reportPhoto),
        item(_MemberAction.block, Icons.person_off_outlined, l10n.blockMember(profile.name)),
      ],
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({this.preview});
  final SocialUser? preview;

  @override
  Widget build(BuildContext context) {
    final user = preview;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        if (user != null)
          ProfileHeader(
            name: user.name,
            handle: user.handle,
            avatarUrl: user.avatarUrl,
          ),
        const SizedBox(height: 48),
        const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}

class _Loaded extends StatelessWidget {
  const _Loaded({
    required this.userId,
    required this.view,
    required this.isSelf,
  });

  final String userId;
  final PublicProfileView view;
  final bool isSelf;

  @override
  Widget build(BuildContext context) {
    final profile = view.profile!;
    final stats = view.stats!;
    final library = view.library;
    final own = context.watch<ProfileStore>();
    final following = own.isFollowing(userId);

    // On your own profile the counts are the live ones from ProfileStore; on
    // someone else's, a follow you made after the page loaded is already in.
    final followers = isSelf
        ? own.followersCount
        : view.followersFor(viewerFollows: following);
    final followingCount = isSelf ? own.followingCount : stats.following;
    final showAchievements = isSelf
        ? own.steamConnected
        : profile.steamConnected && profile.showSteamAchievements;

    void openFollowers(FollowListKind kind) => openFollows(
      context,
      userId: userId,
      kind: kind,
      ownerName: profile.name,
    );
    // Your own are the live ones; someone else's came with their profile.
    final milestones = isSelf
        ? context.watch<MilestonesStore>().earned
        : view.milestones;
    void openAllMilestones() =>
        openMilestones(context, userId: userId, ownerName: profile.name);
    void openLibrary({GameStatus? status, SortField? sortBy}) =>
        openPublicLibrary(
          context,
          userId: userId,
          ownerName: profile.name,
          status: status,
          sortBy: sortBy,
        );

    return ProfileLayout(
      userId: userId,
      header: ProfileHeader(
        name: profile.name,
        handle: profile.handle,
        avatarUrl: profile.avatarUrl,
        joined: profile.joined,
        isSelf: isSelf,
        flair: isSelf ? own.flair : profile.flair,
        milestones: milestones,
      ),
      notice: view.refreshFailed
          ? context.l10n.refreshFailedShowingLast
          : null,
      bio: profile.bio,
      followers: followers,
      following: followingCount,
      onFollowers: () => openFollowers(FollowListKind.followers),
      onFollowing: () => openFollowers(FollowListKind.following),
      actions: isSelf
          ? null
          : SizedBox(
              width: double.infinity,
              child: following
                  ? OutlinedButton(
                      onPressed: () => _toggleFollow(context),
                      child: Text(context.l10n.followingButton),
                    )
                  : FilledButton(
                      onPressed: () => _toggleFollow(context),
                      child: Text(context.l10n.follow),
                    ),
            ),
      favorites: view.favorites,
      activity: view.activity,
      library: library,
      onStatus: (status) => openLibrary(status: status),
      showAchievements: showAchievements,
      milestones: MilestonesSection(
        earned: milestones,
        own: isSelf,
        onSeeAll: openAllMilestones,
      ),
      services: profile.connectedServices,
      accountNames: profile.accountNames,
      links: [
        ProfileLink(
          icon: Icons.collections_bookmark_rounded,
          label: context.l10n.milestoneCategoryLibrary,
          count: library.games,
          onTap: () => openLibrary(),
        ),
        ProfileLink(
          icon: Icons.bookmark_rounded,
          label: GameStatus.wishlist.label,
          count: library.count(GameStatus.wishlist),
          onTap: () => openLibrary(status: GameStatus.wishlist),
        ),
        ProfileLink(
          icon: Icons.star_rounded,
          label: context.l10n.topRated,
          count: library.ratedCount,
          onTap: () => openLibrary(sortBy: SortField.rating),
        ),
        ProfileLink(
          icon: Icons.format_list_bulleted_rounded,
          label: context.l10n.lists,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ListsScreen(userId: userId, ownerName: profile.name),
            ),
          ),
        ),
        ProfileLink(
          icon: Icons.emoji_events_rounded,
          label: context.l10n.milestones,
          count: milestones.count,
          onTap: openAllMilestones,
        ),
        ProfileLink(
          icon: Icons.people_alt_rounded,
          label: context.l10n.followers,
          count: followers,
          onTap: () => openFollowers(FollowListKind.followers),
        ),
        ProfileLink(
          icon: Icons.person_add_alt_1_rounded,
          label: context.l10n.following,
          count: followingCount,
          onTap: () => openFollowers(FollowListKind.following),
        ),
      ],
    );
  }

  void _toggleFollow(BuildContext context) {
    if (!context.read<AuthStore>().isLoggedIn) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.logInToFollow)),
        );
      return;
    }
    unawaited(context.read<ProfileStore>().toggleFollow(userId));
  }
}
