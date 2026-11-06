import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/activity_entry.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/library_stats.dart';
import 'package:checkpoint/models/share_link.dart';
import 'package:checkpoint/screens/lists/lists_screen.dart';
import 'package:checkpoint/screens/profile/edit_profile_screen.dart';
import 'package:checkpoint/screens/profile/milestones_section.dart';
import 'package:checkpoint/screens/profile/profile_layout.dart';
import 'package:checkpoint/screens/settings/settings_screen.dart';
import 'package:checkpoint/screens/stats/year_review_screen.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_state.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/library_view_store.dart';
import 'package:checkpoint/state/milestones_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/public_achievements_store.dart';
import 'package:checkpoint/state/public_trophies_store.dart';
import 'package:checkpoint/state/social_graph_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/utils/refresh.dart';
import 'package:checkpoint/widgets/favorite_games_row.dart';
import 'package:checkpoint/widgets/profile_link_rows.dart';
import 'package:checkpoint/widgets/share_link_button.dart';

/// The Profile tab: your own page, laid out exactly like another member's
/// ([ProfileLayout]) but from your live library, with Edit Profile and Settings
/// under the counts, the icons of your connected accounts above the bio and Sign
/// out beside your name. Connecting accounts is in Settings.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  /// Pull to refresh: your library and profile, then what the page reads from the
  /// server on its own (milestones, and the Steam achievements if connected).
  Future<void> _refresh(BuildContext context, String userId) {
    final steamConnected = context.read<ProfileStore>().steamConnected;
    final achievements = context.read<PublicAchievementsStore>();
    return Future.wait([
      context.read<PublicTrophiesStore>().loadSummary(userId, force: true),
      refreshMyData(context),
      context.read<MilestonesStore>().refresh(),
      if (steamConnected) ...[
        achievements.loadTotals(userId, force: true),
        achievements.loadSummary(userId, force: true),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final profileStore = context.watch<ProfileStore>();
    final library = context.watch<LibraryStore>();
    final milestones = context.watch<MilestonesStore>();
    final userId = context.watch<AuthStore>().user?.id;
    if (userId == null) return const SizedBox.shrink();

    final p = profileStore.profile;
    // Your page as others see it: without the games you hid from them.
    final games = library.listedGames;
    final stats = LibraryStats.of(games);
    final viewStore = context.read<LibraryViewStore>();

    final activity = [
      for (final log in library.recentActivity(
        limit: CheckpointRepository.publicActivityLimit,
      ))
        if (library.maybeGame(log.gameId) case final game?)
          ActivityEntry(
            game: game,
            hours: log.hours,
            platform: log.platform,
            at: log.timestamp,
          ),
    ];

    void openList(FollowListKind kind) =>
        openFollows(context, userId: userId, kind: kind, ownerName: p.name);

    return SafeArea(
      bottom: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: RefreshIndicator(
            onRefresh: () => _refresh(context, userId),
            child: ProfileLayout(
              userId: userId,
              header: ProfileHeader(
                name: p.name,
                handle: p.handle,
                avatarUrl: p.avatarUrl,
                joined: p.joined,
                flair: p.flair,
                milestones: milestones.earned,
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  ShareLinkButton(target: MemberLink(userId)),
                  IconButton(
                    tooltip: context.l10n.signOut,
                    onPressed: () => context.read<AuthStore>().logOut(),
                    icon: const Icon(Icons.logout_rounded),
                  ),
                ]),
              ),
              services: profileStore.connectedServices,
              accountNames: profileStore.accountNames,
              bio: p.bio,
              followers: profileStore.followersCount,
              following: profileStore.followingCount,
              onFollowers: () => openList(FollowListKind.followers),
              onFollowing: () => openList(FollowListKind.following),
              actions: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const EditProfileScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      label: Text(context.l10n.editProfileTitle),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.settings_rounded, size: 18),
                      label: Text(context.l10n.settings),
                    ),
                  ),
                ],
              ),
              favorites: [
                for (final g in games)
                  if (g.isFavorite) g,
              ].take(FavoriteGamesRow.slots).toList(),
              emptyFavorites: context.l10n.noFavoritesOwn,
              activity: activity,
              library: stats,
              emptyHours: context.l10n.noHoursOwn,
              onStatus: viewStore.openTab,
              // Your own achievements show whatever the privacy setting says; that
              // only hides them from others.
              showAchievements: profileStore.steamConnected,
              // Your own trophies show whatever the privacy setting says.
              showTrophies: true,
              milestones: MilestonesSection(
                earned: milestones.earned,
                progress: milestones.progress,
                own: true,
                onSeeAll: () => openMilestones(context, userId: userId),
              ),
              links: [
                ProfileLink(
                  icon: Icons.collections_bookmark_rounded,
                  label: context.l10n.milestoneCategoryLibrary,
                  count: stats.games,
                  onTap: () => viewStore.openTab(null),
                ),
                ProfileLink(
                  icon: Icons.bookmark_rounded,
                  label: GameStatus.wishlist.label,
                  count: stats.count(GameStatus.wishlist),
                  onTap: () => viewStore.openTab(GameStatus.wishlist),
                ),
                ProfileLink(
                  icon: Icons.star_rounded,
                  label: context.l10n.topRated,
                  count: stats.ratedCount,
                  onTap: () => viewStore.openTab(null, sortBy: SortField.rating),
                ),
                ProfileLink(
                  icon: Icons.format_list_bulleted_rounded,
                  label: context.l10n.lists,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const ListsScreen()),
                  ),
                ),
                ProfileLink(
                  icon: Icons.emoji_events_rounded,
                  label: context.l10n.milestones,
                  count: milestones.earned.count,
                  onTap: () => openMilestones(context, userId: userId),
                ),
                ProfileLink(
                  icon: Icons.insights_rounded,
                  label: context.l10n.yearInReview,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const YearReviewScreen()),
                  ),
                ),
                ProfileLink(
                  icon: Icons.people_alt_rounded,
                  label: context.l10n.followers,
                  count: profileStore.followersCount,
                  onTap: () => openList(FollowListKind.followers),
                ),
                ProfileLink(
                  icon: Icons.person_add_alt_1_rounded,
                  label: context.l10n.following,
                  count: profileStore.followingCount,
                  onTap: () => openList(FollowListKind.following),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
