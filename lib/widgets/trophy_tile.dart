import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart' show ImageRenderMethodForWeb;
import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/trophy.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';

/// The colour of a trophy grade: bronze, silver, gold, and the Platinum's ice blue.
Color trophyColor(BuildContext context, TrophyGrade grade) => context.palette.legible(switch (grade) {
  TrophyGrade.bronze => const Color(0xFFCD7F32),
  TrophyGrade.silver => const Color(0xFFB8C2CC),
  TrophyGrade.gold => const Color(0xFFFFC857),
  TrophyGrade.platinum => const Color(0xFF7FD3F0),
});

/// The name of a trophy grade.
String trophyGradeName(BuildContext context, TrophyGrade grade) => switch (grade) {
  TrophyGrade.bronze => context.l10n.trophyGradeBronze,
  TrophyGrade.silver => context.l10n.trophyGradeSilver,
  TrophyGrade.gold => context.l10n.trophyGradeGold,
  TrophyGrade.platinum => context.l10n.trophyGradePlatinum,
};

/// A cup in the colour of [grade].
class TrophyCup extends StatelessWidget {
  const TrophyCup({super.key, required this.grade, this.size = 18, this.dim = false});
  final TrophyGrade grade;
  final double size;

  /// Not earned: the same cup, faded.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final color = trophyColor(context, grade);
    return Icon(Icons.emoji_events_rounded, size: size, color: dim ? color.withValues(alpha: 0.4) : color);
  }
}

/// One trophy: its icon, name, what it asks for, how rare it is and, when the
/// member earned it, the day. A trophy not earned is dimmed and greyed out, and a
/// secret one keeps its name and task hidden until it is earned. Laid out like
/// [AchievementTile], so trophies read like Steam achievements.
class TrophyTile extends StatelessWidget {
  const TrophyTile({super.key, required this.trophy});
  final Trophy trophy;

  @override
  Widget build(BuildContext context) {
    final t = trophy;
    final l10n = context.l10n;
    final secret = t.hidden && !t.earned;
    final color = trophyColor(context, t.grade);
    final rare = t.rarity != null && t.rarity! <= 1;
    final rarityName = switch (t.rarity) {
      0 => l10n.trophyRarityUltraRare,
      1 => l10n.trophyRarityVeryRare,
      2 => l10n.trophyRarityRare,
      3 => l10n.trophyRarityCommon,
      _ => null,
    };
    final rate = t.earnedRate == null ? null : l10n.trophyEarnedRate(fmtPercent(t.earnedRate!));
    final rarity = [?rarityName, ?rate].join(' · ');

    return Semantics(
      container: true,
      label: '${trophyGradeName(context, t.grade)}. ${secret ? l10n.trophySecretName : t.name}',
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: t.earned ? color.withValues(alpha: 0.08) : context.palette.text.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: t.earned ? color.withValues(alpha: 0.32) : context.palette.hairline),
        ),
        child: Row(
          children: [
            _TrophyIcon(trophy: t, secret: secret),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    secret ? l10n.trophySecretName : t.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      color: t.earned ? context.palette.text : context.palette.textSoft,
                    ),
                  ),
                  if (secret || t.detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      secret ? l10n.trophySecretDetail : t.detail,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, height: 1.3, color: context.palette.muted),
                    ),
                  ],
                  if (rarity.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      rarity,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: rare ? color.withValues(alpha: context.palette.isDark ? 0.9 : 1) : context.palette.muted,
                        fontWeight: rare ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                TrophyCup(grade: t.grade, size: t.grade == TrophyGrade.platinum ? 24 : 20, dim: !t.earned),
                if (t.earned && t.earnedAt != null)
                  Text(
                    MaterialLocalizations.of(context).formatShortDate(t.earnedAt!),
                    style: TextStyle(fontSize: 11, color: context.palette.muted),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TrophyIcon extends StatelessWidget {
  const _TrophyIcon({required this.trophy, required this.secret});
  final Trophy trophy;
  final bool secret;

  // Sony ships one colour icon; greying it means a single link per trophy is kept.
  static const ColorFilter _greyscale = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final url = trophy.iconUrl;
    final Widget fallback = Container(
      color: context.palette.text.withValues(alpha: 0.06),
      child: Icon(
        secret ? Icons.help_outline_rounded : Icons.emoji_events_outlined,
        size: 22,
        color: context.palette.muted,
      ),
    );
    Widget image = secret || url == null
        ? fallback
        : CachedNetworkImage(
            imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
            imageUrl: url,
            fit: BoxFit.cover,
            memCacheWidth: 96,
            fadeInDuration: Duration.zero,
            errorWidget: (_, _, _) => fallback,
          );
    if (!trophy.earned) {
      image = Opacity(opacity: 0.55, child: ColorFiltered(colorFilter: _greyscale, child: image));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(width: 48, height: 48, child: image),
    );
  }
}
