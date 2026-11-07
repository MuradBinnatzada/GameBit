import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart' show ImageRenderMethodForWeb;
import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/achievement.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';

/// One achievement: icon, name, description, how many Steam players have it
/// and, when unlocked, how long ago. Locked ones are dimmed and greyed out.
class AchievementTile extends StatelessWidget {
  const AchievementTile({super.key, required this.achievement});
  final Achievement achievement;

  @override
  Widget build(BuildContext context) {
    final a = achievement;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: a.unlocked
            ? context.palette.star.withValues(alpha: 0.07)
            : context.palette.text.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: a.unlocked
              ? context.palette.star.withValues(alpha: 0.28)
              : context.palette.hairline,
        ),
      ),
      child: Row(
        children: [
          _AchievementIcon(achievement: a),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: a.unlocked ? context.palette.text : context.palette.textSoft,
                  ),
                ),
                if (a.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    a.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: context.palette.muted,
                    ),
                  ),
                ],
                if (a.globalPercent != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    context.l10n.playersHaveThis(fmtPercent(a.globalPercent!)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: a.globalPercent! < 10
                          ? context.palette.star.withValues(alpha: context.palette.isDark ? 0.85 : 1)
                          : context.palette.muted,
                      fontWeight: a.globalPercent! < 10
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (a.unlocked)
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Icon(Icons.emoji_events_rounded, size: 18, color: context.palette.star),
                if (a.unlockedAt != null)
                  Text(
                    timeAgo(a.unlockedAt!),
                    style: TextStyle(fontSize: 12, color: context.palette.muted),
                  ),
              ],
            )
          else
            Icon(
              Icons.lock_outline_rounded,
              size: 18,
              color: context.palette.muted,
            ),
        ],
      ),
    );
  }
}

class _AchievementIcon extends StatelessWidget {
  const _AchievementIcon({required this.achievement});
  final Achievement achievement;

  // Steam also ships a grey icon, but desaturating the colour one means we only
  // have to store (and fetch) a single URL per achievement.
  static const ColorFilter _greyscale = ColorFilter.matrix(<double>[
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  @override
  Widget build(BuildContext context) {
    final a = achievement;
    final Widget fallback = Container(
      color: context.palette.text.withValues(alpha: 0.06),
      child: Icon(
        Icons.emoji_events_outlined,
        size: 22,
        color: context.palette.muted,
      ),
    );
    Widget image = a.iconUrl.isEmpty
        ? fallback
        : CachedNetworkImage(
            imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
            imageUrl: a.iconUrl,
            fit: BoxFit.cover,
            memCacheWidth:
                96, // 2x of the 44 px slot; keeps long lists light on memory
            fadeInDuration: Duration.zero,
            errorWidget: (_, _, _) => fallback,
          );
    if (!a.unlocked) {
      image = Opacity(
        opacity: 0.55,
        child: ColorFiltered(colorFilter: _greyscale, child: image),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(width: 44, height: 44, child: image),
    );
  }
}
