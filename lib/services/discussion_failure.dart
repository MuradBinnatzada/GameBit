import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/services/connection_failure.dart';

/// Why a post to the discussions was not made, as named by the `discussions`
/// Edge Function in the `code` of its answer (see `ErrorCode` there). The app
/// words each itself, so it can be reworded and translated without a deploy.
enum DiscussionFailureCode {
  /// A word the chat rules refuse.
  contentNotAllowed('CONTENT_NOT_ALLOWED'),
  tooManyLinks('TOO_MANY_LINKS'),

  /// Too many posts lately: wait [DiscussionFailure.retryAfter].
  rateLimited('RATE_LIMITED'),
  duplicate('DUPLICATE'),

  /// The thread takes no more replies.
  locked('LOCKED'),

  /// The board, thread or game is gone.
  notFound('NOT_FOUND'),
  unauthenticated('UNAUTHENTICATED'),
  mfaRequired('MFA_REQUIRED'),

  /// A moderator suspended the account.
  suspended('SUSPENDED'),
  offline('OFFLINE'),
  other('OTHER');

  const DiscussionFailureCode(this.wire);

  final String wire;

  static DiscussionFailureCode fromWire(Object? wire) =>
      values.firstWhere((c) => c.wire == wire, orElse: () => other);
}

/// A post that was refused or could not be sent: what to tell the member.
class DiscussionFailure implements Exception {
  const DiscussionFailure(this.code, {this.retryAfter});

  final DiscussionFailureCode code;

  /// How long to wait, when the member is posting too fast.
  final Duration? retryAfter;

  /// What went wrong, from what was thrown calling the function.
  factory DiscussionFailure.from(Object error) {
    if (error is DiscussionFailure) return error;
    if (error is FunctionException) {
      final body = error.details;
      final code = DiscussionFailureCode.fromWire(
        body is Map ? body['code'] : null,
      );
      final wait = body is Map ? body['retry_after'] : null;
      if (code == DiscussionFailureCode.other && error.status == 401) {
        return const DiscussionFailure(DiscussionFailureCode.unauthenticated);
      }
      // Status 0: the request never got an answer.
      if (code == DiscussionFailureCode.other && error.status == 0) {
        return const DiscussionFailure(DiscussionFailureCode.offline);
      }
      return DiscussionFailure(
        code,
        retryAfter: wait is num && wait > 0
            ? Duration(seconds: wait.ceil())
            : null,
      );
    }
    if (isConnectionFailure(error)) {
      return const DiscussionFailure(DiscussionFailureCode.offline);
    }
    return const DiscussionFailure(DiscussionFailureCode.other);
  }

  /// What to tell the member, in the app's language.
  String get message {
    final l10n = L10n.current;
    return switch (code) {
      DiscussionFailureCode.contentNotAllowed => l10n.postBreaksRules,
      DiscussionFailureCode.tooManyLinks => l10n.postTooManyLinks,
      DiscussionFailureCode.rateLimited => _waitMessage(l10n),
      DiscussionFailureCode.duplicate => l10n.postDuplicate,
      DiscussionFailureCode.locked => l10n.postThreadLocked,
      DiscussionFailureCode.notFound => l10n.postNotFound,
      DiscussionFailureCode.unauthenticated => l10n.syncErrorUnauthenticated,
      DiscussionFailureCode.mfaRequired => l10n.syncErrorMfaRequired,
      DiscussionFailureCode.suspended => l10n.postSuspended,
      DiscussionFailureCode.offline => l10n.serverUnreachable,
      DiscussionFailureCode.other => l10n.postFailed,
    };
  }

  String _waitMessage(AppLocalizations l10n) {
    final wait = retryAfter;
    if (wait == null) return l10n.postRateLimited;
    final minutes = (wait.inSeconds / 60).ceil();
    return minutes <= 1
        ? l10n.postRateLimitedMinute
        : l10n.postRateLimitedMinutes(minutes);
  }

  @override
  String toString() => 'DiscussionFailure(${code.wire})';
}
