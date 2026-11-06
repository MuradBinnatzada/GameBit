import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/activity_entry.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/library_stats.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/screens/profile/achievements_section.dart';
import 'package:checkpoint/screens/profile/trophies_section.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/connected_account_icons.dart';
import 'package:checkpoint/widgets/count_stat.dart';
import 'package:checkpoint/widgets/favorite_games_row.dart';
import 'package:checkpoint/widgets/hours_by_platform_panel.dart';
import 'package:checkpoint/widgets/milestone_badge.dart';
import 'package:checkpoint/widgets/panel.dart';
import 'package:checkpoint/widgets/profile_avatar.dart';
import 'package:checkpoint/widgets/profile_link_rows.dart';
import 'package:checkpoint/widgets/ratings_panel.dart';
import 'package:checkpoint/widgets/recent_activity_panel.dart';
import 'package:checkpoint/widgets/stat_tile.dart';

/// Photo, name, @handle and, once known, when they joined. [trailing] sits at the
/// top right, level with the name. With [flair] and [milestones], the photo is
/// in their frame with their level on it, their title is under the name and
/// the milestones they show off are under the date.
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    required this.name,
    required this.handle,
    this.avatarUrl,
    this.joined,
    this.isSelf = false,
    this.trailing,
    this.flair = ProfileFlair.none,
    this.milestones,
  });

  final String name;
  final String handle;
  final String? avatarUrl;
  final DateTime? joined;

  /// Another member's page that is yours: says "This is you" instead of the date.
  final bool isSelf;

  final Widget? trailing;
  final ProfileFlair flair;

  /// What they earned, for the level; null while it isn't known.
  final EarnedMilestones? milestones;

  @override
  Widget build(BuildContext context) {
    final titled = milestoneById(flair.titleId);
    final showcase = flair.showcase;
    return Row(
      children: [
        FramedAvatar(
          size: 76,
          frame: flair.frame,
          level: milestones?.level.level,
          child: ProfileAvatar(name: name, size: 76, imageUrl: avatarUrl),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              if (titled != null) ProfileTitleText(milestone: titled),
              Text(
                handle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.palette.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (isSelf || joined != null) ...[
                const SizedBox(height: 2),
                Text(
                  isSelf
                      ? context.l10n.thisIsYou
                      : context.l10n.memberSince(fmtMonthYear(joined!)),
                  style: TextStyle(color: context.palette.muted, fontSize: 12.5),
                ),
              ],
              if (showcase.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (final m in showcase)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => unawaited(
                            showMilestoneSheet(
                              context,
                              m,
                              unlockedAt: milestones?.unlockedAt[m.id],
                            ),
                          ),
                          child: MilestoneBadge(milestone: m, size: 28),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One profile page for everyone, yours included: who they are, icons of the
/// accounts they connected, their bio, who follows them, then their favorites,
/// latest sessions, playtime, library numbers (each box opens a library), hours per
/// platform, ratings, their milestones, their achievements (when
/// [showAchievements]), and last of all a short menu into their library and
/// follow lists.
///
/// It only lays things out. Where the numbers come from, and what a tap does,
/// differ between your own profile (your live library, the Library tab) and
/// someone else's (what the server returned, their library screen), so both are
/// handed in.
class ProfileLayout extends StatelessWidget {
  const ProfileLayout({
    super.key,
    required this.userId,
    required this.header,
    required this.followers,
    required this.following,
    required this.onFollowers,
    required this.onFollowing,
    required this.favorites,
    required this.activity,
    required this.library,
    required this.onStatus,
    required this.links,
    required this.showAchievements,
    this.showTrophies = false,
    this.milestones,
    this.notice,
    this.bio,
    this.actions,
    this.services = const {},
    this.accountNames = const {},
    this.emptyFavorites,
    this.emptyHours,
  });

  /// Whose achievements the page offers.
  final String userId;
  final Widget header;

  /// Small line under the header, e.g. that a refresh failed.
  final String? notice;
  final String? bio;

  final int followers;
  final int following;
  final VoidCallback onFollowers;
  final VoidCallback onFollowing;

  /// The button(s) under the counts: Follow, or Edit profile and Settings.
  final Widget? actions;

  final List<Game> favorites;
  final List<ActivityEntry> activity;
  final LibraryStats library;
  final void Function(GameStatus status) onStatus;

  /// The connected services and the names behind them, shown as icons above the
  /// bio; none leaves the row out.
  final Set<ConnectedService> services;
  final Map<ConnectedService, String> accountNames;
  final List<ProfileLink> links;

  /// Whether the page has the Achievements card. Only with Steam connected, and
  /// on someone else's page only when they share them (Settings > Privacy); the
  /// callers decide.
  final bool showAchievements;

  /// Whether the page has the Trophies card ([TrophiesSection], PlayStation). On
  /// someone else's page only when they share them (Settings > Privacy); the card
  /// leaves itself out while there is nothing to show.
  final bool showTrophies;

  /// The Milestones card ([MilestonesSection]), just above the achievements.
  final Widget? milestones;

  final String? emptyFavorites;
  final String? emptyHours;

  @override
  Widget build(BuildContext context) {
    final text = bio?.trim();
    final hasBio = text != null && text.isNotEmpty;

    Widget statTile(IconData icon, GameStatus status, String label) => Expanded(
      child: StatTile(
        icon: icon,
        value: '${library.count(status)}',
        label: label,
        onTap: () => onStatus(status),
      ),
    );

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        header,
        if (notice != null) ...[
          const SizedBox(height: 10),
          Text(
            notice!,
            style: TextStyle(color: context.palette.muted, fontSize: 12.5),
          ),
        ],
        const SizedBox(height: 14),
        if (services.isNotEmpty) ...[
          ConnectedAccountIcons(services: services, names: accountNames),
          const SizedBox(height: 14),
        ],
        if (hasBio) ...[
          Text(
            text,
            style: TextStyle(height: 1.4, color: context.palette.textSoft),
          ),
          const SizedBox(height: 16),
        ],
        // Tapping a count opens the list behind it. With large text the second
        // goes under the first.
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            CountStat(
              value: fmtCount(followers),
              label: context.l10n.followers,
              onTap: onFollowers,
            ),
            CountStat(
              value: fmtCount(following),
              label: context.l10n.following,
              onTap: onFollowing,
            ),
          ],
        ),
        if (actions != null) ...[const SizedBox(height: 14), actions!],
        const SizedBox(height: 28),
        _SectionTitle(context.l10n.favoriteGames),
        if (favorites.isEmpty)
          Panel(
            child: Text(
              emptyFavorites ?? context.l10n.noFavoritesOther,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          )
        else
          FavoriteGamesRow(games: favorites),
        const SizedBox(height: 28),
        RecentActivityPanel(entries: activity),
        const SizedBox(height: 24),
        Text(
          context.l10n.totalPlaytime(context.l10n.hoursLong(library.totalHours, fmtHours(library.totalHours))),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            statTile(Icons.play_arrow_rounded, GameStatus.playing, GameStatus.playing.label),
            const SizedBox(width: 10),
            statTile(Icons.verified_rounded, GameStatus.completed, GameStatus.completed.label),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            statTile(Icons.inventory_2_rounded, GameStatus.toPlay, GameStatus.toPlay.label),
            const SizedBox(width: 10),
            statTile(Icons.block_rounded, GameStatus.dropped, GameStatus.dropped.label),
          ],
        ),
        const SizedBox(height: 14),
        HoursByPlatformPanel(
          hours: library.hoursByPlatform,
          emptyText: emptyHours ?? context.l10n.noHoursOther,
        ),
        const SizedBox(height: 14),
        RatingsPanel(stats: library),
        if (milestones != null) ...[const SizedBox(height: 14), milestones!],
        // The count shows at once; the games and their achievements are fetched
        // only when asked for.
        if (showAchievements) ...[
          const SizedBox(height: 14),
          AchievementsSection(userId: userId),
        ],
        if (showTrophies) TrophiesSection(userId: userId),
        const SizedBox(height: 24),
        ProfileLinkRows(links: links),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      // A heading, so screen readers can jump from section to section.
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}
