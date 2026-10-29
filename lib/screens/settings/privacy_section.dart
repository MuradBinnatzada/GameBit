import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/app/app_config.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/screens/settings/blocked_members_screen.dart';
import 'package:checkpoint/services/crash_reporting.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/legal_links.dart';
import 'package:checkpoint/widgets/panel.dart';

/// What other members can see of the account, and what never leaves it, under
/// the switch that hides your Steam achievements from them. This mirrors the
/// "Who can see what" part of the privacy policy (docs/privacy.html); keep the
/// two in step.
class PrivacySection extends StatelessWidget {
  const PrivacySection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Panel(
          title: l10n.yourProfile,
          child: _ShowAchievementsSwitch(),
        ),
        SizedBox(height: 14),
        Panel(
          title: l10n.blockedMembers,
          child: _LinkRow(
            icon: Icons.person_off_outlined,
            title: l10n.blockedMembers,
            subtitle: l10n.blockedMembersSubtitle,
            onTap: () => openBlockedMembers(context),
          ),
        ),
        SizedBox(height: 14),
        Panel(
          title: l10n.privacyVisibleTitle,
          child: Column(
            children: [
              _Item(
                icon: Icons.badge_rounded,
                title: l10n.navProfile,
                text: l10n.privacyProfileText,
              ),
              _Item(
                icon: Icons.collections_bookmark_rounded,
                title: l10n.milestoneCategoryLibrary,
                text: l10n.privacyLibraryText,
              ),
              _Item(
                icon: Icons.history_rounded,
                title: l10n.privacyRecentActivity,
                text: l10n.privacyRecentActivityText,
              ),
              _Item(
                icon: Icons.people_alt_rounded,
                title: l10n.privacyFollows,
                text: l10n.privacyFollowsText,
              ),
              _Item(
                icon: Icons.link_rounded,
                title: l10n.connectedAccounts,
                text: l10n.privacyConnectedText,
              ),
              _Item(
                icon: Icons.emoji_events_rounded,
                title: l10n.achievements,
                text: l10n.privacyAchievementsText(l10n.showSteamAchievements),
              ),
            ],
          ),
        ),
        SizedBox(height: 14),
        Panel(
          title: l10n.privacyPrivateTitle,
          child: Column(
            children: [
              _Item(
                icon: Icons.mail_outline_rounded,
                title: l10n.emailAddress,
                text: l10n.privacyEmailText,
              ),
              _Item(
                icon: Icons.sell_outlined,
                title: l10n.purchasePrices,
                text: l10n.privacyPricesText,
              ),
              _Item(
                icon: Icons.sticky_note_2_outlined,
                title: l10n.sessionNotes,
                text: l10n.privacyNotesText,
              ),
            ],
          ),
        ),
        if (CrashReporting.configured) ...[
          SizedBox(height: 14),
          Panel(title: l10n.diagnosticsTitle, child: _CrashReportsSwitch()),
        ],
        SizedBox(height: 14),
        Panel(
          title: l10n.legalTitle,
          child: Column(
            children: [
              _LinkRow(
                icon: Icons.description_outlined,
                title: l10n.termsOfUse,
                onTap: () => openLegalLink(AppConfig.termsUri),
              ),
              _LinkRow(
                icon: Icons.privacy_tip_outlined,
                title: l10n.privacyPolicy,
                onTap: () => openLegalLink(AppConfig.privacyUri),
              ),
              _LinkRow(
                icon: Icons.mail_outline_rounded,
                title: l10n.contactUs,
                subtitle: l10n.contactUsSubtitle,
                onTap: () => openLegalLink(AppConfig.contactUri),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(
            l10n.privacyFootnote,
            style: TextStyle(color: context.palette.muted, fontSize: 12.5, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// "Show Steam Achievements": whether other members see the Achievements card on
/// your profile. Your own view of it shows them either way.
class _ShowAchievementsSwitch extends StatelessWidget {
  const _ShowAchievementsSwitch();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ProfileStore>();
    // Its own Material, so the tap splash shows over the panel's background.
    return Material(
      type: MaterialType.transparency,
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        secondary: Icon(
          Icons.emoji_events_rounded,
          color: context.palette.accent,
        ),
        title: Text(
          context.l10n.showSteamAchievements,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          context.l10n.showSteamAchievementsSubtitle,
          style: TextStyle(color: context.palette.muted, fontSize: 12.5, height: 1.35),
        ),
        value: store.showSteamAchievements,
        // Waits while the last change is being saved.
        onChanged: store.savingSteamAchievementsPrivacy
            ? null
            : (value) => unawaited(_toggle(context, value)),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, bool value) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await context
        .read<ProfileStore>()
        .toggleSteamAchievementsPrivacy(value);
    if (error == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error)));
  }
}

/// "Send crash reports": whether this device reports a crash. Shown only in
/// builds that have somewhere to send them.
class _CrashReportsSwitch extends StatelessWidget {
  const _CrashReportsSwitch();

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ValueListenableBuilder<bool>(
        valueListenable: CrashReporting.enabledListenable,
        builder: (context, enabled, _) => SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.bug_report_outlined, color: context.palette.accent),
          title: Text(
            context.l10n.crashReportsTitle,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            context.l10n.crashReportsSubtitle,
            style: TextStyle(color: context.palette.muted, fontSize: 12.5, height: 1.35),
          ),
          value: enabled,
          onChanged: (value) => unawaited(CrashReporting.setEnabled(value)),
        ),
      ),
    );
  }
}

/// A row that opens something: a screen, a page of the site, a mail.
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.icon, required this.title, this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: palette.accent),
        title: Text(
          title,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, style: TextStyle(color: palette.muted, fontSize: 12.5, height: 1.35)),
        trailing: Icon(Icons.chevron_right_rounded, color: palette.muted),
        onTap: onTap,
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: context.palette.accent),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
