import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/panel.dart';
import 'package:checkpoint/widgets/service_link.dart';

/// What the buttons of the box do.
class AccountEditor {
  const AccountEditor({required this.onConnect, required this.onDisconnect});

  final void Function(ConnectedService service) onConnect;
  final void Function(ConnectedService service) onDisconnect;
}

/// The "Connect accounts" box of Settings, one row per service the app can
/// verify (Steam). A service that is not connected has Connect; one that is has
/// Disconnect, and tapping its row opens the account. [footer] goes under the
/// rows, where the library sync lives.
class ConnectedAccountsPanel extends StatelessWidget {
  const ConnectedAccountsPanel({
    super.key,
    required this.services,
    required this.names,
    required this.editor,
    this.footer,
  });

  /// Every connected service.
  final Set<ConnectedService> services;

  /// The ID each connected service confirmed. A connected service may have none
  /// yet.
  final Map<ConnectedService, String> names;

  final AccountEditor editor;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final s in ConnectedService.values)
        _AccountRow(
          service: s,
          connected: services.contains(s),
          name: names[s],
          editor: editor,
        ),
    ];
    return Panel(
      title: context.l10n.connectAccounts,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: context.palette.hairline),
            rows[i],
          ],
          if (footer != null) ...[const SizedBox(height: 12), footer!],
        ],
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.service,
    required this.connected,
    required this.name,
    required this.editor,
  });

  final ConnectedService service;
  final bool connected;
  final String? name;
  final AccountEditor editor;

  /// What the row says under the service: the ID, "Connected" while it has none,
  /// or "Not connected".
  String get _subtitle {
    if (!connected) return L10n.current.notConnected;
    final text = name;
    if (text == null || text.isEmpty) return L10n.current.connected;
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final link = connected ? serviceLink(service, name) : null;

    final Widget trailing = connected
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (link != null)
                Icon(
                  Icons.open_in_new_rounded,
                  size: 18,
                  color: context.palette.muted,
                ),
              // Flexible, so with large text the label is cut rather than overflowing.
              Flexible(
                child: TextButton(
                  onPressed: () => editor.onDisconnect(service),
                  child: Text(
                    context.l10n.disconnect,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          )
        : TextButton(
            onPressed: () => editor.onConnect(service),
            child: Text(context.l10n.connect),
          );

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.palette.legible(service.color).withValues(alpha: connected ? 0.16 : 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: FaIcon(
              service.icon,
              size: 18,
              color: connected ? context.palette.legible(service.color) : context.palette.muted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.label,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  _subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: connected && (name?.isNotEmpty ?? false)
                        ? context.palette.textSoft
                        : context.palette.muted,
                  ),
                ),
              ],
            ),
          ),
          // Capped, so with large text the button can't take the whole row.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: trailing,
          ),
        ],
      ),
    );

    if (link == null) return row;
    return Tooltip(
      message: link.tooltip,
      // Transparent Material so the InkWell ripple still has somewhere to paint.
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => openServiceLink(context, link),
          child: row,
        ),
      ),
    );
  }
}
