import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/activity_entry.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/cover_art.dart';
import 'package:checkpoint/widgets/panel.dart';

/// A member's latest play sessions, one row per game: cover, title, hours and
/// platform, and how long ago. Tapping a row opens the game.
class RecentActivityPanel extends StatelessWidget {
  const RecentActivityPanel({super.key, required this.entries});

  final List<ActivityEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: context.l10n.privacyRecentActivity,
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      child: entries.isEmpty
          ? Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                context.l10n.noSessionsLoggedYet,
                style: TextStyle(color: context.palette.muted, fontSize: 13),
              ),
            )
          : Column(
              children: [
                for (final e in entries)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => openGame(context, e.game.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 40,
                            child: CoverArt(game: e.game, radius: 8),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.game.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  children: [
                                    Icon(
                                      e.platform.icon,
                                      size: 13,
                                      color: context.palette.legible(e.platform.color),
                                    ),
                                    const SizedBox(width: 5),
                                    Flexible(
                                      child: Text(
                                        '${context.l10n.hoursShort(fmtHours(e.hours))} · ${e.platform.label}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: context.palette.muted,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Narrow enough that large text wraps it instead of
                          // squeezing the title out, but growing with the text so
                          // the date still fits on a line of its own.
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: 110 * textScale(context).clamp(1.0, 1.4)),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  timeAgo(e.at),
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                    color: context.palette.muted,
                                    fontSize: 12,
                                  ),
                                ),
                                // The exact time: a sync adds sessions that were
                                // played earlier.
                                Text(
                                  fmtDateTime(e.at),
                                  textAlign: TextAlign.end,
                                  style: TextStyle(
                                    color: context.palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
