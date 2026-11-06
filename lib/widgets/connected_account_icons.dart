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
/// [playStation] adds a PlayStation icon after them for a member who has synced
/// PlayStation. It is no connected account: the sign-in was made on their phone, so
/// the server proves nothing, and the tooltip says "synced", not "verified". It has
/// no link.
///
/// Empty when nothing is connected.
class ConnectedAccountIcons extends StatelessWidget {
  const ConnectedAccountIcons({
    super.key,
    required this.services,
    required this.names,
    this.playStation = false,
  });

  /// Every connected service.
  final Set<ConnectedService> services;

  /// The ID each connected service confirmed. A connected service may have none
  /// yet.
  final Map<ConnectedService, String> names;

  /// The member has synced PlayStation.
  final bool playStation;

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final s in ConnectedService.values)
        if (services.contains(s)) s,
    ];
    if (shown.isEmpty && !playStation) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final s in shown) _AccountIcon(service: s, id: names[s]),
        if (playStation) const _PlayStationIcon(),
      ],
    );
  }
}

/// The PlayStation icon: the look of the accounts' icons, with a check, and the
/// words "synced from PlayStation". Nothing opens from it.
class _PlayStationIcon extends StatelessWidget {
  const _PlayStationIcon();

  static const color = Color(0xFF0070D1);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Tooltip(
      message: '${l10n.playStation}\n${l10n.playStationSynced}',
      child: Semantics(
        label: '${l10n.playStation}, ${l10n.playStationSynced}',
        child: _tile(context, FontAwesomeIcons.playstation, color),
      ),
    );
  }
}

/// A brand icon on its tinted square with the green check at the corner.
Widget _tile(BuildContext context, dynamic icon, Color color) {
  final legible = context.palette.legible(color);
  return Stack(
    clipBehavior: Clip.none,
    children: [
      Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: legible.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(10),
        ),
        child: FaIcon(icon, size: 16, color: legible),
      ),
      Positioned(
        right: -3,
        bottom: -3,
        child: Icon(Icons.check_circle, size: 14, color: context.palette.legible(Colors.green)),
      ),
    ],
  );
}

class _AccountIcon extends StatelessWidget {
  const _AccountIcon({required this.service, required this.id});

  final ConnectedService service;
  final String? id;

  @override
  Widget build(BuildContext context) {
    final link = serviceLink(service, id);
    final note = context.l10n.accountVerified;
    final tile = _tile(context, service.icon, service.color);

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
