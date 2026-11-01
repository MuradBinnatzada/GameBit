import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import 'package:checkpoint/app/new_password_screen.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/screens/settings/backup_codes_screen.dart';
import 'package:checkpoint/screens/settings/two_factor_setup_screen.dart';
import 'package:checkpoint/services/connection_failure.dart';
import 'package:checkpoint/services/mfa_recovery_failure.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/panel.dart';
import 'package:checkpoint/widgets/profile_link_rows.dart';

/// How the account signs in, a way to change the password of an email account,
/// and a way to end the sessions left on other devices.
class SecuritySection extends StatefulWidget {
  const SecuritySection({super.key});

  @override
  State<SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<SecuritySection> {
  static final _googleSecurity = Uri.https('myaccount.google.com', '/security');

  bool _signingOut = false;

  static String _methodLabel(AppLocalizations l10n, String? provider) => switch (provider) {
    'google' => 'Google',
    'email' => l10n.signInMethodEmail,
    null => l10n.unknownGame,
    final other => other[0].toUpperCase() + other.substring(1),
  };

  Future<void> _signOutOthers() async {
    final auth = context.read<AuthStore>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    setState(() => _signingOut = true);
    String message;
    try {
      await auth.signOutOtherDevices();
      message = l10n.signedOutOtherDevices;
    } catch (e) {
      debugPrint('Signing out other devices failed: $e');
      message = e is SessionPending || (e is! AuthException && isConnectionFailure(e))
          ? l10n.serverUnreachable
          : auth.messageFor(e);
    }
    if (mounted) setState(() => _signingOut = false);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final provider = auth.provider;
    final email = auth.email;
    final l10n = context.l10n;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Panel(
          title: l10n.signInPanel,
          child: Column(
            children: [
              _InfoRow(label: l10n.signInMethod, value: _methodLabel(l10n, provider)),
              if (email != null) _InfoRow(label: l10n.email, value: email),
            ],
          ),
        ),
        if (provider == 'email') ...[
          const SizedBox(height: 14),
          ProfileLinkRows(
            links: [
              ProfileLink(
                icon: Icons.password_rounded,
                label: l10n.changePassword,
                onTap: () => changePassword(context),
              ),
            ],
          ),
        ],
        if (provider == 'google') ...[
          const SizedBox(height: 14),
          ProfileLinkRows(
            links: [
              ProfileLink(
                icon: Icons.manage_accounts_rounded,
                label: l10n.manageGoogleAccount,
                onTap: () => launchUrl(
                  _googleSecurity,
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              l10n.googleSecurityNote,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Panel(
          title: l10n.twoFactorAuthentication,
          child: Column(
            children: [
              const _TwoFactorSwitch(),
              if (auth.hasTwoFactor) const _NewBackupCodesTile(),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Panel(
          title: l10n.sessionsPanel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.sessionsPanelBody,
                style: TextStyle(color: context.palette.muted, height: 1.4),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _signingOut ? null : _signOutOthers,
                icon: _signingOut
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.devices_other_rounded, size: 18),
                label: Text(l10n.signOutOtherDevices),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Two-factor authentication on or off. On opens the setup (an authenticator
/// app and its first code); off asks first.
class _TwoFactorSwitch extends StatefulWidget {
  const _TwoFactorSwitch();

  @override
  State<_TwoFactorSwitch> createState() => _TwoFactorSwitchState();
}

class _TwoFactorSwitchState extends State<_TwoFactorSwitch> {
  bool _busy = false;

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    if (on) {
      await setUpTwoFactor(context);
    } else {
      await _turnOff();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _turnOff() async {
    final auth = context.read<AuthStore>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.twoFactorTurnOffTitle),
        content: Text(context.l10n.twoFactorTurnOffBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.turnOff),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    String message;
    try {
      await auth.disableTwoFactor();
      message = L10n.current.twoFactorIsOff;
    } catch (e) {
      debugPrint('Turning off two-factor authentication failed: $e');
      message = e is SessionPending || (e is! AuthException && isConnectionFailure(e))
          ? L10n.current.serverUnreachable
          : auth.messageFor(e);
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final on = context.watch<AuthStore>().hasTwoFactor;
    // Its own Material, so the tap splash shows over the panel's background.
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: Icon(
          Icons.phonelink_lock_rounded,
          color: context.palette.accent,
        ),
        title: Text(
          context.l10n.authenticatorApp,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          on
              ? context.l10n.authenticatorAppOn
              : context.l10n.authenticatorAppOff,
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12.5,
            height: 1.35,
          ),
        ),
        value: on,
        onChanged: _busy ? null : (value) => unawaited(_toggle(value)),
      ),
    );
  }
}

/// Makes new backup codes while two-factor authentication is on, after asking
/// (the codes the account has stop working), and shows them.
class _NewBackupCodesTile extends StatefulWidget {
  const _NewBackupCodesTile();

  @override
  State<_NewBackupCodesTile> createState() => _NewBackupCodesTileState();
}

class _NewBackupCodesTileState extends State<_NewBackupCodesTile> {
  bool _busy = false;

  Future<void> _makeNew() async {
    final auth = context.read<AuthStore>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.newBackupCodesTitle),
        content: Text(context.l10n.newBackupCodesBody(10)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.makeNewCodes),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final codes = await auth.generateBackupCodes();
      if (mounted) await showBackupCodes(context, codes);
    } catch (e) {
      debugPrint('Making new backup codes failed: $e');
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(backupCodesMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Its own Material, so the tap splash shows over the panel's background.
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.key_rounded, color: context.palette.accent),
        title: Text(
          context.l10n.newBackupCodes,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          context.l10n.newBackupCodesSubtitle,
          style: TextStyle(color: context.palette.muted, fontSize: 12.5, height: 1.35),
        ),
        trailing: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.chevron_right_rounded, color: context.palette.muted),
        onTap: _busy ? null : _makeNew,
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(color: context.palette.muted, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
