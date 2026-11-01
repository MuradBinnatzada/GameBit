import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/admin_moderation.dart';
import 'package:checkpoint/services/admin_failure.dart';
import 'package:checkpoint/state/admin_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';

void _say(ScaffoldMessengerState messenger, String message) => messenger
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message)));

/// How long a suspension lasts, as the dialog offers it.
enum SuspensionLength {
  day(1),
  week(7),
  month(30),
  untilReinstated(null);

  const SuspensionLength(this.days);

  /// null: until a moderator reinstates the member.
  final int? days;

  String get label => switch (this) {
    day => L10n.current.adminLengthDay,
    week => L10n.current.adminLengthWeek,
    month => L10n.current.adminLengthMonth,
    untilReinstated => L10n.current.adminLengthForGood,
  };
}

/// The longest reason the server keeps; the same limit as the database's.
const int suspensionReasonMax = 500;

/// Asks why [member] is suspended and for how long, and does it: they are signed
/// out everywhere, can't sign in, and vanish for other members until reinstated;
/// the open reports about them are closed. True when they were suspended.
Future<bool> suspendMemberAfterAsking(
  BuildContext context,
  ModeratedMember member,
) async {
  final answer = await showDialog<({String reason, SuspensionLength length})>(
    context: context,
    builder: (_) => _SuspendDialog(name: member.displayName),
  );
  if (answer == null || !context.mounted) return false;
  final store = context.read<AdminStore>();
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  try {
    await store.suspend(
      memberId: member.id,
      reason: answer.reason,
      days: answer.length.days,
    );
    _say(messenger, l10n.adminMemberSuspended(member.displayName));
    return true;
  } catch (e) {
    _say(messenger, AdminFailure.from(e).message);
    return false;
  }
}

/// Asks to reinstate [member], and does: they can sign in again and other
/// members see them again. True when they were reinstated.
Future<bool> reinstateMemberAfterAsking(
  BuildContext context,
  ModeratedMember member,
) async {
  final l10n = context.l10n;
  final sure = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(l10n.adminReinstateTitle(member.displayName)),
      content: Text(l10n.adminReinstateBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.adminReinstate),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  final store = context.read<AdminStore>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    await store.reinstate(member.id);
    _say(messenger, l10n.adminMemberReinstated(member.displayName));
    return true;
  } catch (e) {
    _say(messenger, AdminFailure.from(e).message);
    return false;
  }
}

/// Closes the open reports about [member] without suspending them: [dismissed]
/// when nothing was wrong, otherwise they count as acted on. True when closed.
Future<bool> closeReportsAbout(
  BuildContext context,
  ModeratedMember member, {
  required bool dismissed,
}) async {
  final store = context.read<AdminStore>();
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  try {
    await store.closeReports(member.id, dismissed: dismissed);
    _say(messenger, l10n.adminReportsClosed);
    return true;
  } catch (e) {
    _say(messenger, AdminFailure.from(e).message);
    return false;
  }
}

class _SuspendDialog extends StatefulWidget {
  const _SuspendDialog({required this.name});

  final String name;

  @override
  State<_SuspendDialog> createState() => _SuspendDialogState();
}

class _SuspendDialogState extends State<_SuspendDialog> {
  final _reason = TextEditingController();
  SuspensionLength _length = SuspensionLength.week;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _ready => _reason.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.adminSuspendTitle(widget.name)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.adminSuspendBody,
              style: TextStyle(color: context.palette.muted),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _reason,
              autofocus: true,
              maxLength: suspensionReasonMax,
              maxLines: 3,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: l10n.adminReasonLabel,
                helperText: l10n.adminReasonHelper,
                helperMaxLines: 2,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final length in SuspensionLength.values)
                  ChoiceChip(
                    label: Text(length.label),
                    selected: length == _length,
                    onSelected: (_) => setState(() => _length = length),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _ready
              ? () =>
                    Navigator.of(context)
                        .pop((reason: _reason.text.trim(), length: _length))
              : null,
          child: Text(l10n.adminSuspend),
        ),
      ],
    );
  }
}
