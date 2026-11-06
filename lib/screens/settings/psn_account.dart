import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/screens/settings/data_section.dart';
import 'package:checkpoint/screens/settings/psn_import.dart';
import 'package:checkpoint/services/playstation/psn_device.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/connected_accounts_panel.dart';

/// PlayStation's place in the Connect accounts box of Settings, laid out like
/// Steam's: a row with its icon, its name and Connect or Disconnect, and under it
/// the Sync button (while connected).
///
/// "Connected" means this phone holds a PlayStation sign-in ([PsnDevice]): it is not
/// an account the server proved, and it follows the phone, not the Gamebit account.
/// Connect signs in on Sony's page and keeps the sign-in; Disconnect forgets it
/// (the games and trophies already synced stay); Sync reads the lists (once a day).
/// The line under the name says when the last sync was, as Steam's says its ID: the
/// PlayStation ID is not known without one more request to Sony, which is not made.
class PlayStationAccount extends StatefulWidget {
  const PlayStationAccount({super.key, this.device});

  /// What the phone keeps between syncs; the real one when null.
  final PsnDevice? device;

  @override
  State<PlayStationAccount> createState() => _PlayStationAccountState();
}

class _PlayStationAccountState extends State<PlayStationAccount> {
  static const _color = Color(0xFF0070D1);

  late final PsnDevice _device = widget.device ?? PsnDevice();
  bool _connected = false;
  DateTime? _lastSync;

  String get _userId => context.read<AuthStore>().user?.id ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  /// Reads what the phone holds now.
  Future<void> _refresh() async {
    if (!mounted) return;
    final id = _userId;
    final signedIn = id.isNotEmpty && await _device.savedSignIn(id) != null;
    final last = id.isEmpty ? null : await _device.lastSync(id);
    if (!mounted) return;
    setState(() {
      _connected = signedIn;
      _lastSync = last;
    });
  }

  Future<void> _connect() async {
    await connectPlayStation(context, device: _device, userId: _userId);
    await _refresh();
  }

  Future<void> _disconnect() async {
    final messenger = ScaffoldMessenger.of(context);
    final id = _userId;
    final forgotten = context.l10n.psnSignInForgotten;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.disconnectServiceTitle(context.l10n.playStation)),
        content: Text(context.l10n.disconnectPlayStationBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l10n.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l10n.disconnect)),
        ],
      ),
    );
    if (confirmed != true) return;
    await _device.forget(id);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(forgotten)));
    await _refresh();
  }

  Future<void> _sync() async {
    await importFromPlayStation(context);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final last = _lastSync;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AccountRowTile(
          icon: FontAwesomeIcons.playstation,
          color: _color,
          label: l10n.playStation,
          subtitle: !_connected
              ? l10n.notConnected
              : last == null
              ? l10n.connected
              : l10n.psnConnectedSynced(timeAgo(last)),
          connected: _connected,
          onConnect: _connect,
          onDisconnect: _disconnect,
        ),
        if (_connected) ...[
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _sync,
              icon: const Icon(Icons.sync_rounded),
              label: Text(l10n.psnSyncButton),
            ),
          ),
        ],
      ],
    );
  }
}
