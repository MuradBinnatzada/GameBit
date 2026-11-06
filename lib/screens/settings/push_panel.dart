import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/state/push_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/panel.dart';

/// Push notifications (see [PushStore]): a switch for this phone, with what it needs
/// said under it, and once it is on, one for each kind the server sends (price drops
/// of the wishlist, replies to the member's threads).
class PushNotificationsPanel extends StatefulWidget {
  const PushNotificationsPanel({super.key});

  @override
  State<PushNotificationsPanel> createState() => _PushNotificationsPanelState();
}

class _PushNotificationsPanelState extends State<PushNotificationsPanel> {
  /// How the last change went, to say why a switch did not turn.
  PushResult? _result;

  Future<void> _toggle(bool on) async {
    final result = await context.read<PushStore>().setEnabled(on);
    if (!mounted) return;
    setState(() => _result = result);
  }

  Future<void> _kind(Future<bool> Function() change) async {
    final saved = await change();
    if (!mounted) return;
    setState(() => _result = saved ? null : PushResult.failed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final store = context.watch<PushStore>();
    final String? unavailable = !store.isSupported
        ? l10n.pushUnsupported
        : !store.isSignedIn
        ? l10n.pushSignedOut
        : null;
    final settings = store.settings;
    return Panel(
      title: l10n.pushTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Its own Material, so the tap splash shows over the panel's background.
          Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(Icons.notifications_rounded, color: palette.accent),
                  title: Text(l10n.pushTitle, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    l10n.pushBody,
                    style: TextStyle(color: palette.muted, fontSize: 12.5, height: 1.35),
                  ),
                  value: store.isEnabled,
                  // Waits while the permission is asked for, and when it can't be.
                  onChanged: unavailable != null || store.isBusy ? null : (on) => unawaited(_toggle(on)),
                ),
                if (store.isEnabled) ...[
                  SwitchListTile(
                    contentPadding: const EdgeInsets.only(left: 16),
                    title: Text(l10n.pushPriceDrops, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(l10n.pushPriceDropsBody, style: TextStyle(color: palette.muted, fontSize: 12.5)),
                    value: settings.priceDrops,
                    onChanged: (on) => unawaited(_kind(() => store.setPriceDrops(on))),
                  ),
                  SwitchListTile(
                    contentPadding: const EdgeInsets.only(left: 16),
                    title: Text(l10n.pushReplies, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(l10n.pushRepliesBody, style: TextStyle(color: palette.muted, fontSize: 12.5)),
                    value: settings.threadReplies,
                    onChanged: (on) => unawaited(_kind(() => store.setThreadReplies(on))),
                  ),
                ],
              ],
            ),
          ),
          if (unavailable != null) ...[
            const SizedBox(height: 8),
            Text(unavailable, style: TextStyle(color: palette.muted, height: 1.4)),
          ],
          if (_result == PushResult.denied && !store.isEnabled) ...[
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(l10n.pushDenied, style: TextStyle(color: palette.danger, height: 1.4)),
            ),
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => unawaited(store.openSystemSettings()),
              child: Text(l10n.openDeviceSettings),
            ),
          ] else if (_result == PushResult.failed) ...[
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(l10n.pushFailed, style: TextStyle(color: palette.danger, height: 1.4)),
            ),
          ],
        ],
      ),
    );
  }
}
