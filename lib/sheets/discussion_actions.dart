import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/sheets/member_actions.dart';
import 'package:checkpoint/sheets/report_review_sheet.dart';
import 'package:checkpoint/state/discussions_store.dart';
import 'package:checkpoint/state/store_scope.dart';

void _say(ScaffoldMessengerState messenger, String message) => messenger
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message)));

/// Asks why a thread ([postId] null) or a reply ([postId]) of the thread
/// [threadId] by [authorName] is reported, sends the report and says how it went.
/// True when it was sent: the thread or reply is gone from the lists, as the server
/// leaves it out for the member who reported it.
Future<bool> reportDiscussionPost(
  BuildContext context, {
  required String threadId,
  String? postId,
  required String authorName,
}) async {
  final reason = await pickReportReason(
    context,
    title: context.l10n.reportPost,
    subtitle: context.l10n.reportPostSubtitle(authorName),
  );
  if (reason == null || !context.mounted) return false;
  final store = context.read<DiscussionsStore>();
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  try {
    if (postId == null) {
      await store.reportThread(threadId, reason);
    } else {
      await store.reportPost(threadId, postId, reason);
    }
    _say(messenger, l10n.postReported);
    return true;
  } catch (_) {
    _say(messenger, l10n.postReportFailed);
    return false;
  }
}

/// Asks to block [author], and does (for the whole app, see
/// [blockMemberAfterAsking]). True when they were blocked.
Future<bool> blockDiscussionAuthor(BuildContext context, SocialUser author) =>
    blockMemberAfterAsking(context, author);

/// Asks to delete the member's own thread ([postId] null) or reply, and does.
/// True when it was deleted.
Future<bool> deleteDiscussionPost(
  BuildContext context, {
  required String threadId,
  String? postId,
}) async {
  final l10n = context.l10n;
  final isThread = postId == null;
  final sure = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(isThread ? l10n.deleteThreadTitle : l10n.deleteReplyTitle),
      content: Text(isThread ? l10n.deleteThreadBody : l10n.deleteReplyBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  final store = context.read<DiscussionsStore>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (isThread) {
      await store.deleteThread(threadId);
    } else {
      await store.deletePost(threadId, postId);
    }
    return true;
  } catch (_) {
    _say(messenger, l10n.deleteFailed);
    return false;
  }
}
