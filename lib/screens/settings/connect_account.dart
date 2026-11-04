import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/widgets/connected_accounts_panel.dart';

/// What the buttons of the Connect accounts box in Settings do: sign in through
/// Steam, or disconnect it.
AccountEditor accountEditorFor(BuildContext context) => AccountEditor(
  onConnect: (service) => connectService(context, service),
  onDisconnect: (service) => disconnectService(context, service),
);

/// Connects [service] by signing in through it.
Future<void> connectService(
  BuildContext context,
  ConnectedService service,
) async {
  final store = context.read<ProfileStore>();
  final messenger = ScaffoldMessenger.of(context);

  switch (service) {
    case ConnectedService.steam:
      // Proved by signing in through Steam, never typed in: the server saves
      // the Steam ID Steam confirms, and Steam shows as connected by itself once
      // the profile has it. A dialog waits for the sign-in and can call it off.
      final linking = store.connectSteam();
      final message = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SteamLinkDialog(
          linking: linking,
          onCancel: store.cancelSteamLink,
        ),
      );
      if (message != null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      }
  }
}

/// Disconnects [service] after a confirmation.
Future<void> disconnectService(
  BuildContext context,
  ConnectedService service,
) async {
  final store = context.read<ProfileStore>();
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.disconnectServiceTitle(service.label)),
      content: Text(context.l10n.disconnectSteamBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.disconnect),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  switch (service) {
    case ConnectedService.steam:
      final error = await store.disconnectSteam();
      if (error != null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error)));
      }
  }
}

/// Waits for the Steam sign-in [linking] (ProfileStore.connectSteam) and pops
/// with what it says. Cancel stops waiting and pops with nothing.
class _SteamLinkDialog extends StatefulWidget {
  const _SteamLinkDialog({required this.linking, required this.onCancel});

  final Future<String?> linking;
  final VoidCallback onCancel;

  @override
  State<_SteamLinkDialog> createState() => _SteamLinkDialogState();
}

class _SteamLinkDialogState extends State<_SteamLinkDialog> {
  @override
  void initState() {
    super.initState();
    unawaited(
      widget.linking.then((message) {
        if (mounted) Navigator.pop(context, message);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.connectService('Steam')),
      content: Row(
        children: [
          const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(context.l10n.connectSteamBody),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.onCancel();
            Navigator.pop(context);
          },
          child: Text(context.l10n.cancel),
        ),
      ],
    );
  }
}
