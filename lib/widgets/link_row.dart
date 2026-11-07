import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:checkpoint/theme/palette.dart';

/// A row of a settings panel that opens something: a screen of the app (the
/// chevron), or a page outside it ([external], the arrow out of a box).
class LinkRow extends StatelessWidget {
  const LinkRow({
    super.key,
    this.icon,
    this.brandIcon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.external = false,
  }) : assert(icon != null || brandIcon != null, 'A row needs an icon');

  /// The icon at the start: one of Material's, or a [brandIcon] (Font Awesome's
  /// logo of a service).
  final IconData? icon;
  final FaIconData? brandIcon;
  final String title;
  final String? subtitle;

  /// What a tap does. Without one the row only tells something, and has no arrow.
  final VoidCallback? onTap;

  /// The row leaves the app (a web page, a mail), which its trailing icon says.
  final bool external;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: brandIcon != null
            ? FaIcon(brandIcon, color: palette.accent, size: 22)
            : Icon(icon, color: palette.accent),
        title: Text(
          title,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, style: TextStyle(color: palette.muted, fontSize: 12.5, height: 1.35)),
        trailing: onTap == null
            ? null
            : Icon(
                external ? Icons.open_in_new_rounded : Icons.chevron_right_rounded,
                color: palette.muted,
                size: external ? 20 : null,
              ),
        onTap: onTap,
      ),
    );
  }
}
