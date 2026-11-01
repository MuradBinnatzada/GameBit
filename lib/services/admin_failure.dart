import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/services/connection_failure.dart';

/// Why a moderation action or list failed, as named by the `admin-moderation`
/// Edge Function in the `code` of its answer (see the header there). The app
/// words each itself, so it can be reworded and translated without a deploy.
enum AdminFailureCode {
  unauthenticated('UNAUTHENTICATED'),
  mfaRequired('MFA_REQUIRED'),

  /// The account is not an admin (any more).
  forbidden('FORBIDDEN'),
  rateLimited('RATE_LIMITED'),

  /// The member no longer exists.
  notFound('NOT_FOUND'),

  /// Admins are not suspended from the app.
  memberIsAdmin('MEMBER_IS_ADMIN'),
  offline('OFFLINE'),
  other('OTHER');

  const AdminFailureCode(this.wire);

  final String wire;

  static AdminFailureCode fromWire(Object? wire) =>
      values.firstWhere((c) => c.wire == wire, orElse: () => other);
}

/// A moderation request that was refused or could not be sent.
class AdminFailure implements Exception {
  const AdminFailure(this.code);

  final AdminFailureCode code;

  /// What went wrong, from what was thrown calling the function.
  factory AdminFailure.from(Object error) {
    if (error is AdminFailure) return error;
    if (error is FunctionException) {
      final body = error.details;
      final code = AdminFailureCode.fromWire(body is Map ? body['code'] : null);
      if (code == AdminFailureCode.other && error.status == 401) {
        return const AdminFailure(AdminFailureCode.unauthenticated);
      }
      // Status 0: the request never got an answer.
      if (code == AdminFailureCode.other && error.status == 0) {
        return const AdminFailure(AdminFailureCode.offline);
      }
      return AdminFailure(code);
    }
    if (isConnectionFailure(error)) {
      return const AdminFailure(AdminFailureCode.offline);
    }
    return const AdminFailure(AdminFailureCode.other);
  }

  /// What to tell the moderator, in the app's language.
  String get message {
    final l10n = L10n.current;
    return switch (code) {
      AdminFailureCode.unauthenticated => l10n.syncErrorUnauthenticated,
      AdminFailureCode.mfaRequired => l10n.syncErrorMfaRequired,
      AdminFailureCode.forbidden => l10n.adminForbidden,
      AdminFailureCode.rateLimited => l10n.adminRateLimited,
      AdminFailureCode.notFound => l10n.adminMemberGone,
      AdminFailureCode.memberIsAdmin => l10n.adminMemberIsAdmin,
      AdminFailureCode.offline => l10n.serverUnreachable,
      AdminFailureCode.other => l10n.adminFailed,
    };
  }

  @override
  String toString() => 'AdminFailure(${code.wire})';
}
