import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/state/release_reminders_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/panel.dart';

/// Notifications: the release day reminders for the wishlist (see
/// [ReleaseRemindersStore]), a switch with what it needs said under it.
class NotificationsSection extends StatefulWidget {
  const NotificationsSection({super.key});

  @override
  State<NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<NotificationsSection> {
  /// The system's permission was refused when the switch was last turned on.
  bool _denied = false;

  Future<void> _toggle(bool on) async {
    final result = await context.read<ReleaseRemindersStore>().setEnabled(on);
    if (!mounted) return;
    setState(() => _denied = result == RemindersResult.denied);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final store = context.watch<ReleaseRemindersStore>();
    final String? unavailable = !store.isSupported
        ? l10n.releaseRemindersUnsupported
        : !store.isSignedIn
        ? l10n.releaseRemindersSignedOut
        : null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Panel(
          title: l10n.releaseRemindersTitle,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Its own Material, so the tap splash shows over the panel's background.
            Material(
              type: MaterialType.transparency,
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: Icon(Icons.notifications_active_rounded, color: palette.accent),
                title: Text(
                  l10n.releaseRemindersTitle,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  l10n.releaseRemindersBody,
                  style: TextStyle(color: palette.muted, fontSize: 12.5, height: 1.35),
                ),
                value: store.isEnabled,
                // Waits while the permission is asked for, and when it can't be.
                onChanged: unavailable != null || store.isBusy ? null : (on) => unawaited(_toggle(on)),
              ),
            ),
            if (unavailable != null) ...[
              const SizedBox(height: 8),
              Text(unavailable, style: TextStyle(color: palette.muted, height: 1.4)),
            ] else if (store.isEnabled) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  l10n.releaseRemindersCount(store.count),
                  style: TextStyle(color: palette.muted, fontWeight: FontWeight.w600),
                ),
              ),
            ],
            if (_denied && !store.isEnabled) ...[
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                child: Text(l10n.releaseRemindersDenied, style: TextStyle(color: palette.danger, height: 1.4)),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => unawaited(store.openSystemSettings()),
                child: Text(l10n.openDeviceSettings),
              ),
            ],
          ]),
        ),
      ],
    );
  }
}
