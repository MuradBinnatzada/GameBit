import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/service_link.dart';

/// A row of small brand icons, one per connected account. Each opens the
/// account; one with nothing to open yet (no ID saved) is shown but not tappable.
///
/// Every connected account is proved (the server saves the ID the service
/// confirmed after a sign-in), so each carries a check.
///
/// Empty when nothing is connected.
class ConnectedAccountIcons extends StatelessWidget {
  const ConnectedAccountIcons({
    super.key,
    required this.services,
    required this.names,
  });

  /// Every connected service.
  final Set<ConnectedService> services;

  /// The ID each connected service confirmed. A connected service may have none
  /// yet.
  final Map<ConnectedService, String> names;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final s in ConnectedService.values)
        if (services.contains(s)) s,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [for (final s in shown) _AccountIcon(service: s, id: names[s])],
    );
  }
}

class _AccountIcon extends StatelessWidget {
  const _AccountIcon({required this.service, required this.id});

  final ConnectedService service;
  final String? id;

  @override
  Widget build(BuildContext context) {
    final link = serviceLink(service, id);
    final note = context.l10n.accountVerified;
    final icon = Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.palette.legible(service.color).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: FaIcon(service.icon, size: 16, color: context.palette.legible(service.color)),
    );
    final tile = Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -3,
          bottom: -3,
          child: Icon(
            Icons.check_circle,
            size: 14,
            color: context.palette.legible(Colors.green),
          ),
        ),
      ],
    );

    if (link == null) {
      return Tooltip(
        message: '${service.label}\n$note',
        child: Semantics(label: '${service.label}, $note', child: tile),
      );
    }
    return Tooltip(
      message: '${link.tooltip}\n$note',
      child: Semantics(
        button: true,
        label: '${link.tooltip}, $note',
        excludeSemantics: true,
        // Transparent Material so the InkWell ripple still has somewhere to paint.
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => openServiceLink(context, link),
            child: tile,
          ),
        ),
      ),
    );
  }
}
