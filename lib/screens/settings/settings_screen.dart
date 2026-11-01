import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/screens/settings/admin_section.dart';
import 'package:checkpoint/screens/settings/account_section.dart';
import 'package:checkpoint/screens/settings/appearance_section.dart';
import 'package:checkpoint/screens/settings/data_section.dart';
import 'package:checkpoint/screens/settings/notifications_section.dart';
import 'package:checkpoint/screens/settings/privacy_section.dart';
import 'package:checkpoint/screens/settings/security_section.dart';
import 'package:checkpoint/state/admin_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/app_choice_chip.dart';

/// The parts of Settings, in the order they are listed. [admin] is listed only to
/// a member who may moderate (see [AdminStore]).
enum SettingsSection {
  account(Icons.person_rounded),
  security(Icons.shield_rounded),
  privacy(Icons.lock_rounded),
  notifications(Icons.notifications_rounded),
  appearance(Icons.palette_rounded),
  data(Icons.import_export_rounded),
  admin(Icons.admin_panel_settings_rounded);

  const SettingsSection(this.icon);
  final IconData icon;

  String get label => switch (this) {
    account => L10n.current.settingsAccount,
    security => L10n.current.settingsSecurity,
    privacy => L10n.current.settingsPrivacy,
    notifications => L10n.current.settingsNotifications,
    appearance => L10n.current.settingsAppearance,
    data => L10n.current.settingsData,
    admin => L10n.current.settingsAdmin,
  };
}

/// Settings, split into sections. On a wide window the sections are a sidebar on
/// the left; on a phone they are a row of chips across the head of the screen.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.initialSection = SettingsSection.account,
  });

  final SettingsSection initialSection;

  /// Windows at least this wide get the sidebar.
  static const double sidebarBreakpoint = 720;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsSection _section = widget.initialSection;

  /// The account is being deleted: the screen can't be left or switched, because
  /// leaving would hide whether it worked.
  bool _deleting = false;

  void _select(SettingsSection section) {
    if (_deleting || section == _section) return;
    setState(() => _section = section);
  }

  Widget _content(SettingsSection section) {
    final body = switch (section) {
      SettingsSection.account => AccountSection(
        onDeletingChanged: (deleting) => setState(() => _deleting = deleting),
      ),
      SettingsSection.security => const SecuritySection(),
      SettingsSection.privacy => const PrivacySection(),
      SettingsSection.notifications => const NotificationsSection(),
      SettingsSection.appearance => const AppearanceSection(),
      SettingsSection.data => const DataSection(),
      SettingsSection.admin => const AdminSection(),
    };
    // A section starts at its top, whatever the one before was scrolled to.
    return KeyedSubtree(key: ValueKey(section), child: body);
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AdminStore>().isAdmin;
    final sections = [
      for (final section in SettingsSection.values)
        if (section != SettingsSection.admin || isAdmin) section,
    ];
    // Admin goes when the member stops being one (or signs out) while it is open.
    final section = sections.contains(_section)
        ? _section
        : SettingsSection.account;
    return PopScope(
      canPop: !_deleting,
      child: Scaffold(
        appBar: AppBar(title: Text(context.l10n.settings)),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final content = Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: _content(section),
                ),
              );
              if (constraints.maxWidth >= SettingsScreen.sidebarBreakpoint) {
                return Row(
                  children: [
                    SizedBox(
                      width: 232,
                      child: _Sidebar(
                        sections: sections,
                        selected: section,
                        enabled: !_deleting,
                        onSelect: _select,
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      color: context.palette.text.withValues(alpha: 0.08),
                    ),
                    Expanded(child: content),
                  ],
                );
              }
              return Column(
                children: [
                  _SectionChips(
                    sections: sections,
                    selected: section,
                    enabled: !_deleting,
                    onSelect: _select,
                  ),
                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The sections down the left side of a wide window.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.sections,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final List<SettingsSection> sections;
  final SettingsSection selected;
  final bool enabled;
  final ValueChanged<SettingsSection> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      children: [
        for (final section in sections)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ListTile(
              enabled: enabled,
              selected: section == selected,
              selectedColor: context.palette.accent,
              selectedTileColor: context.palette.accent.withValues(alpha: 0.12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              leading: Icon(section.icon),
              title: Text(
                section.label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: () => onSelect(section),
            ),
          ),
      ],
    );
  }
}

/// The sections as a row of chips across the top of a narrow screen.
class _SectionChips extends StatelessWidget {
  const _SectionChips({
    required this.sections,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final List<SettingsSection> sections;
  final SettingsSection selected;
  final bool enabled;
  final ValueChanged<SettingsSection> onSelect;

  @override
  Widget build(BuildContext context) {
    // As tall as the chips, which take 48 px to tap and grow with large text.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          for (final section in sections) ...[
            if (section != sections.first)
              const SizedBox(width: 8),
            IgnorePointer(
              ignoring: !enabled,
              child: AppChoiceChip(
                label: section.label,
                selected: section == selected,
                onSelected: () => onSelect(section),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
