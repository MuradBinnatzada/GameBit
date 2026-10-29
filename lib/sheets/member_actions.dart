import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/services/content_refusal.dart';
import 'package:checkpoint/sheets/report_review_sheet.dart';
import 'package:checkpoint/state/blocks_store.dart';
import 'package:checkpoint/state/lists_store.dart';
import 'package:checkpoint/state/public_profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';

void _say(ScaffoldMessengerState messenger, String message) => messenger
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message)));

/// Asks to block [member], and does: they are gone from the whole app (profile,
/// library, reviews, lists, discussions) and any follow between the two ends.
/// True when they were blocked.
Future<bool> blockMemberAfterAsking(BuildContext context, SocialUser member) async {
  final l10n = context.l10n;
  final sure = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(l10n.blockMemberTitle(member.name)),
      content: Text(l10n.blockMemberBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.block),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  final store = context.read<BlocksStore>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    await store.block(member);
    _say(messenger, l10n.memberBlocked(member.name));
    return true;
  } catch (_) {
    _say(messenger, l10n.blockFailed);
    return false;
  }
}

/// Asks why [name]'s profile or photo ([subject]) is reported, sends the report
/// and says how it went. True when it was sent.
Future<bool> reportMemberProfile(
  BuildContext context, {
  required String userId,
  required String name,
  required MemberReportSubject subject,
}) async {
  assert(subject != MemberReportSubject.list);
  final l10n = context.l10n;
  final isPhoto = subject == MemberReportSubject.avatar;
  final reason = await pickReportReason(
    context,
    title: isPhoto ? l10n.reportPhoto : l10n.reportProfile,
    subtitle: isPhoto ? l10n.reportPhotoSubtitle(name) : l10n.reportProfileSubtitle(name),
  );
  if (reason == null || !context.mounted) return false;
  final store = context.read<PublicProfileStore>();
  final messenger = ScaffoldMessenger.of(context);
  return _send(messenger, l10n, () => store.report(userId, subject, reason));
}

/// Asks why the public list [listId] (called [title]) of [ownerId] is reported,
/// sends the report and says how it went. True when it was sent.
Future<bool> reportMemberList(
  BuildContext context, {
  required String ownerId,
  required String listId,
  required String title,
}) async {
  final l10n = context.l10n;
  final reason = await pickReportReason(
    context,
    title: l10n.reportList,
    subtitle: l10n.reportListSubtitle(title),
  );
  if (reason == null || !context.mounted) return false;
  final store = context.read<ListsStore>();
  final messenger = ScaffoldMessenger.of(context);
  return _send(messenger, l10n, () => store.reportList(ownerId, listId, reason));
}

Future<bool> _send(
  ScaffoldMessengerState messenger,
  AppLocalizations l10n,
  Future<void> Function() report,
) async {
  try {
    await report();
    _say(messenger, l10n.memberReported);
    return true;
  } catch (e) {
    _say(messenger, isRateLimited(e) ? l10n.memberReportRateLimited : l10n.memberReportFailed);
    return false;
  }
}
