import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/models/admin_moderation.dart';
import 'package:checkpoint/services/admin_failure.dart';

/// Moderating from the app, through the `admin-moderation` Supabase Edge
/// Function: the queue of open reports, the suspended members, and suspending,
/// reinstating and closing reports. The function checks the caller is an admin
/// (`moderation.admins`) on every request; the app only decides what to show.
/// Every failure is thrown as an [AdminFailure].
class AdminApiService {
  /// Whether the signed-in member is an admin. Asks the database about the
  /// caller only (`am_i_admin`, which says nothing about anyone else); a question
  /// that fails reads as "no", so nothing admin is shown on a guess.
  Future<bool> isAdmin() async {
    try {
      final answer = await Supabase.instance.client.rpc('am_i_admin');
      return answer == true;
    } catch (e) {
      debugPrint('Asking whether this is an admin failed: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object> body) async {
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'admin-moderation',
        body: body,
      );
      final raw = res.data;
      final decoded = raw is String ? json.decode(raw) : raw;
      if (decoded is Map<String, dynamic>) return decoded;
      throw const AdminFailure(AdminFailureCode.other);
    } catch (e) {
      debugPrint('admin-moderation request failed: $e');
      throw AdminFailure.from(e);
    }
  }

  /// The open reports, oldest first.
  Future<List<AdminReport>> reports() async {
    final answer = await _invoke({'action': 'reports'});
    return [
      for (final raw in answer['reports'] as List? ?? const [])
        if (raw is Map<String, dynamic>) AdminReport.fromJson(raw),
    ];
  }

  /// The members suspended right now, the newest suspension first.
  Future<List<SuspendedMember>> suspended() async {
    final answer = await _invoke({'action': 'suspended'});
    return [
      for (final raw in answer['members'] as List? ?? const [])
        if (raw is Map<String, dynamic>) SuspendedMember.fromJson(raw),
    ];
  }

  /// Suspends [memberId] for [days] days (null: until reinstated) and closes the
  /// open reports about them as actioned.
  Future<void> suspend({
    required String memberId,
    required String reason,
    int? days,
  }) async {
    await _invoke({
      'action': 'suspend',
      'member': memberId,
      'reason': reason,
      'days': ?days,
    });
  }

  Future<void> reinstate(String memberId) async {
    await _invoke({'action': 'reinstate', 'member': memberId});
  }

  /// Closes the open reports about [memberId]: [dismissed] when nothing was wrong,
  /// otherwise as actioned.
  Future<void> closeReports(String memberId, {required bool dismissed}) async {
    await _invoke({
      'action': 'close',
      'member': memberId,
      'result': dismissed ? 'dismissed' : 'actioned',
    });
  }
}
