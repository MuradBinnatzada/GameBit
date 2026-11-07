import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/sheet_frame.dart';

/// A milestone's round badge: its icon in a ring of its tier's colour. A locked
/// one is grey.
class MilestoneBadge extends StatelessWidget {
  const MilestoneBadge({
    super.key,
    required this.milestone,
    this.size = 44,
    this.unlocked = true,
  });

  final Milestone milestone;
  final double size;
  final bool unlocked;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final tier = milestone.tier.color;
    final ring = math.max(2.0, size * 0.07);
    return Semantics(
      label:
          '${milestone.title}, ${milestone.tier.label}${unlocked ? '' : ', ${context.l10n.lockedLower}'}',
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(ring),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: unlocked ? null : palette.hairline,
          gradient: unlocked
              ? LinearGradient(
                  colors: [tier, Color.lerp(tier, Colors.black, 0.4)!],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: unlocked
                ? Color.alphaBlend(
                    tier.withValues(alpha: 0.16),
                    palette.surfaceHigh,
                  )
                : palette.surfaceHigh,
          ),
          child: Center(
            child: Icon(
              milestone.icon,
              size: size * 0.46,
              color: unlocked ? palette.legible(tier) : palette.faint,
            ),
          ),
        ),
      ),
    );
  }
}

/// [child], a round photo [size] across, in the member's [frame] ring, with
/// their [level] on a chip at the bottom. Without either it is just [child].
class FramedAvatar extends StatefulWidget {
  const FramedAvatar({
    super.key,
    required this.child,
    required this.size,
    this.frame,
    this.level,
    this.animate = true,
  });

  final Widget child;
  final double size;
  final AvatarFrame? frame;
  final int? level;

  /// Whether an animated frame turns. Off for small previews side by side.
  final bool animate;

  /// How much wider than the photo a framed one is, on each side.
  static double inset(double size) => _ring(size) + _gap(size);
  static double _ring(double size) => math.max(2.5, size * 0.055);
  static double _gap(double size) => math.max(1.5, size * 0.035);

  @override
  State<FramedAvatar> createState() => _FramedAvatarState();
}

class _FramedAvatarState extends State<FramedAvatar>
    with SingleTickerProviderStateMixin {
  AnimationController? _spin;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateSpin();
  }

  @override
  void didUpdateWidget(FramedAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateSpin();
  }

  // The rarest frames turn slowly, unless the system asks for less motion.
  void _updateSpin() {
    final spin =
        widget.animate &&
        (widget.frame?.animated ?? false) &&
        !MediaQuery.disableAnimationsOf(context);
    if (spin && _spin == null) {
      _spin = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 6),
      )..repeat();
    } else if (!spin && _spin != null) {
      _spin!.dispose();
      _spin = null;
    }
  }

  @override
  void dispose() {
    _spin?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final level = widget.level;
    if (frame == null && level == null) return widget.child;

    final palette = context.palette;
    final size = widget.size;
    final ring = FramedAvatar._ring(size);
    final gap = FramedAvatar._gap(size);
    final outer = size + 2 * (ring + gap);

    Widget ringed(double turns) => Container(
      width: outer,
      height: outer,
      padding: EdgeInsets.all(ring),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: frame == null
            ? null
            : SweepGradient(
                colors: frame.colors,
                transform: GradientRotation(turns * 2 * math.pi),
              ),
      ),
      child: Container(
        padding: EdgeInsets.all(gap),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: frame == null ? null : palette.background,
        ),
        child: widget.child,
      ),
    );

    final spin = _spin;
    final framed = spin == null
        ? ringed(0)
        : AnimatedBuilder(
            animation: spin,
            builder: (_, _) => ringed(spin.value),
          );

    return Semantics(
      label: [
        if (frame != null) context.l10n.frameLabel(frame.label),
        if (level != null) context.l10n.levelN(level),
      ].join(', '),
      child: SizedBox(
        width: outer,
        height: outer,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            framed,
            if (level != null)
              Positioned(
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: palette.accent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: palette.background, width: 2),
                  ),
                  child: Text(
                    context.l10n.levelShort(level),
                    style: TextStyle(
                      color: palette.onAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shows [milestone] in full: its badge, what it takes and gives, and either
/// when it was earned ([unlockedAt]) or how far along it is ([value], when
/// known).
Future<void> showMilestoneSheet(
  BuildContext context,
  Milestone milestone, {
  DateTime? unlockedAt,
  num? value,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _MilestoneSheet(
    milestone: milestone,
    unlockedAt: unlockedAt,
    value: value,
  ),
);

class _MilestoneSheet extends StatelessWidget {
  const _MilestoneSheet({required this.milestone, this.unlockedAt, this.value});

  final Milestone milestone;
  final DateTime? unlockedAt;
  final num? value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final m = milestone;
    final at = unlockedAt;
    return SheetFrame(
      title: m.title,
      subtitle: '${m.category.label} · ${m.tier.label} · ${context.l10n.pointsCount(m.points, '${m.points}')}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MilestoneBadge(milestone: m, size: 72, unlocked: at != null),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  m.description,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: palette.textSoft,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (at != null)
            _Line(
              icon: Icons.check_circle_rounded,
              color: palette.success,
              text: context.l10n.unlockedOn(fmtDay(at)),
            )
          else if (value != null && !m.isYesNo) ...[
            MilestoneProgressBar(milestone: m, value: value!),
          ] else
            _Line(
              icon: Icons.lock_rounded,
              color: palette.muted,
              text: context.l10n.locked,
            ),
          for (final reward in milestoneRewards(m)) ...[
            const SizedBox(height: 10),
            _Line(
              icon: Icons.card_giftcard_rounded,
              color: palette.accent,
              text: reward,
            ),
          ],
        ],
      ),
    );
  }
}

/// What [m] unlocks, one line each: "Gold frame", "Title: Collector".
List<String> milestoneRewards(Milestone m) => [
  if (m.frame case final frame?) L10n.current.frameLabel(frame.label),
  if (m.rewardTitle case final title?) L10n.current.titleReward(title),
];

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: context.palette.legible(color)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// A bar towards [milestone] and "37 / 50 games" under it.
class MilestoneProgressBar extends StatelessWidget {
  const MilestoneProgressBar({
    super.key,
    required this.milestone,
    required this.value,
  });

  final Milestone milestone;
  final num value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final m = milestone;
    final shown = math.min(value, m.threshold);
    final amount = shown is int
        ? fmtThousands(shown)
        : fmtHours(shown.toDouble());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (value / m.threshold).clamp(0, 1).toDouble(),
            minHeight: 6,
            backgroundColor: palette.track,
            color: palette.legible(m.tier.color),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$amount / ${fmtThousands(m.threshold)} ${m.metric.unit(m.threshold)}',
          style: TextStyle(fontSize: 12, color: palette.muted),
        ),
      ],
    );
  }
}

/// A member's title under their name ("Completionist"), in the colour of the
/// milestone that gave it.
class ProfileTitleText extends StatelessWidget {
  const ProfileTitleText({
    super.key,
    required this.milestone,
    this.fontSize = 13,
  });

  /// The milestone whose [Milestone.rewardTitle] it is.
  final Milestone milestone;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final color = context.palette.legible(milestone.tier.color);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(milestone.icon, size: fontSize + 2, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            milestone.rewardTitle ?? milestone.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
