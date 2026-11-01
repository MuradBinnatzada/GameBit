import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/admin_moderation.dart';
import 'package:checkpoint/sheets/admin_actions.dart';
import 'package:checkpoint/state/admin_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/app_choice_chip.dart';
import 'package:checkpoint/widgets/empty_state.dart';
import 'package:checkpoint/widgets/sheet_frame.dart';

enum _AdminTab { reports, suspended }

/// Moderating from the app, for the members who may (see [AdminStore]): the queue
/// of open reports, with what to do about each, and the members suspended right
/// now, with a way to reinstate them. Shown in Settings only to an admin; the
/// server checks it again on every request.
class AdminSection extends StatefulWidget {
  const AdminSection({super.key});

  @override
  State<AdminSection> createState() => _AdminSectionState();
}

class _AdminSectionState extends State<AdminSection> {
  _AdminTab _tab = _AdminTab.reports;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<AdminStore>();
      unawaited(store.loadReports());
      unawaited(store.loadSuspended());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final store = context.watch<AdminStore>();
    final reports = store.reports.length;
    final suspended = store.suspended.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              AppChoiceChip(
                label: store.reportsStatus == LoadStatus.ready
                    ? l10n.adminReportsCount(reports)
                    : l10n.adminReports,
                selected: _tab == _AdminTab.reports,
                onSelected: () => setState(() => _tab = _AdminTab.reports),
              ),
              const SizedBox(width: 8),
              AppChoiceChip(
                label: store.suspendedStatus == LoadStatus.ready
                    ? l10n.adminSuspendedCount(suspended)
                    : l10n.adminSuspendedTab,
                selected: _tab == _AdminTab.suspended,
                onSelected: () => setState(() => _tab = _AdminTab.suspended),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_tab) {
            _AdminTab.reports => _ReportsList(store: store),
            _AdminTab.suspended => _SuspendedList(store: store),
          },
        ),
      ],
    );
  }
}

class _ReportsList extends StatelessWidget {
  const _ReportsList({required this.store});

  final AdminStore store;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (store.reportsStatus == LoadStatus.failed) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: l10n.adminLoadFailed,
        message: store.reportsFailure?.message ?? l10n.checkConnection,
        actionLabel: l10n.tryAgain,
        onAction: () => unawaited(store.loadReports()),
      );
    }
    if (store.reportsStatus != LoadStatus.ready) {
      return const Center(child: CircularProgressIndicator());
    }
    final reports = store.reports;
    if (reports.isEmpty) {
      return EmptyState(
        icon: Icons.verified_user_outlined,
        title: l10n.adminNoReports,
        message: l10n.adminNoReportsMessage,
        onRefresh: store.loadReports,
      );
    }
    return RefreshIndicator(
      onRefresh: store.loadReports,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        itemCount: reports.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _ReportTile(
          report: reports[i],
          onTap: () => unawaited(_openActions(context, reports[i])),
        ),
      ),
    );
  }
}

/// What to do about a report: suspend the member, or close the reports about
/// them as nothing wrong or as handled.
Future<void> _openActions(BuildContext context, AdminReport report) async {
  final action = await showModalBottomSheet<_ReportAction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ReportActionsSheet(report: report),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _ReportAction.suspend:
      await suspendMemberAfterAsking(context, report.member);
    case _ReportAction.dismiss:
      await closeReportsAbout(context, report.member, dismissed: true);
    case _ReportAction.handled:
      await closeReportsAbout(context, report.member, dismissed: false);
  }
}

enum _ReportAction { suspend, dismiss, handled }

class _ReportActionsSheet extends StatelessWidget {
  const _ReportActionsSheet({required this.report});

  final AdminReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    Widget row(
      _ReportAction action,
      IconData icon,
      String title,
      String subtitle, {
      bool enabled = true,
      Color? color,
    }) => ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      leading: Icon(icon, color: enabled ? color : null),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      onTap: () => Navigator.of(context).pop(action),
    );
    return SheetFrame(
      title: l10n.adminReportsAbout(report.member.displayName),
      subtitle: report.member.atHandle.isEmpty ? null : report.member.atHandle,
      child: Column(
        children: [
          row(
            _ReportAction.suspend,
            Icons.block_rounded,
            l10n.adminSuspendAction,
            report.member.suspended
                ? l10n.adminAlreadySuspended
                : l10n.adminSuspendActionSubtitle,
            enabled: !report.member.suspended,
            color: palette.danger,
          ),
          row(
            _ReportAction.dismiss,
            Icons.check_circle_outline_rounded,
            l10n.adminDismissAction,
            l10n.adminDismissActionSubtitle,
          ),
          row(
            _ReportAction.handled,
            Icons.task_alt_rounded,
            l10n.adminHandledAction,
            l10n.adminHandledActionSubtitle,
          ),
        ],
      ),
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.report, required this.onTap});

  final AdminReport report;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final member = report.member;
    final hours = report.hoursOpen.floor();
    final age = report.overdue
        ? l10n.adminOverdue(hours)
        : hours < 1
        ? l10n.adminOpenUnderHour
        : l10n.adminOpenHours(hours);
    return Material(
      color: palette.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: report.overdue
              ? palette.danger.withValues(alpha: 0.6)
              : palette.hairline,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(report.source.icon, size: 16, color: palette.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      report.source.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    age,
                    style: TextStyle(
                      color: report.overdue ? palette.danger : palette.muted,
                      fontSize: 12.5,
                      fontWeight: report.overdue
                          ? FontWeight.w800
                          : FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: member.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (member.atHandle.isNotEmpty)
                      TextSpan(
                        text: '  ${member.atHandle}',
                        style: TextStyle(color: palette.muted, fontSize: 12.5),
                      ),
                  ],
                ),
              ),
              if (member.suspended) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.block_rounded, size: 14, color: palette.danger),
                    const SizedBox(width: 4),
                    Text(
                      l10n.adminSuspendedBadge,
                      style: TextStyle(
                        color: palette.danger,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
              if (report.content.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  report.content,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                l10n.adminReportedFor(report.reason.label),
                style: TextStyle(color: palette.muted, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuspendedList extends StatelessWidget {
  const _SuspendedList({required this.store});

  final AdminStore store;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (store.suspendedStatus == LoadStatus.failed) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: l10n.adminLoadFailed,
        message: store.suspendedFailure?.message ?? l10n.checkConnection,
        actionLabel: l10n.tryAgain,
        onAction: () => unawaited(store.loadSuspended()),
      );
    }
    if (store.suspendedStatus != LoadStatus.ready) {
      return const Center(child: CircularProgressIndicator());
    }
    final members = store.suspended;
    if (members.isEmpty) {
      return EmptyState(
        icon: Icons.how_to_reg_outlined,
        title: l10n.adminNoSuspended,
        message: l10n.adminNoSuspendedMessage,
        onRefresh: store.loadSuspended,
      );
    }
    return RefreshIndicator(
      onRefresh: store.loadSuspended,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        itemCount: members.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _SuspendedTile(suspended: members[i]),
      ),
    );
  }
}

class _SuspendedTile extends StatelessWidget {
  const _SuspendedTile({required this.suspended});

  final SuspendedMember suspended;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final member = suspended.member;
    final until = suspended.until;
    final ends = until == null
        ? l10n.adminSuspendedForGood
        : l10n.adminSuspendedUntil(
            MaterialLocalizations.of(context).formatMediumDate(until.toLocal()),
          );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: member.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (member.atHandle.isNotEmpty)
                        TextSpan(
                          text: '  ${member.atHandle}',
                          style: TextStyle(
                            color: palette.muted,
                            fontSize: 12.5,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  ends,
                  style: TextStyle(
                    color: palette.danger,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (suspended.reason.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    suspended.reason,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () =>
                unawaited(reinstateMemberAfterAsking(context, member)),
            child: Text(l10n.adminReinstate),
          ),
        ],
      ),
    );
  }
}
