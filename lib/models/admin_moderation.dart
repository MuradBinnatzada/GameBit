import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game_reviews.dart' show ReportReason;

/// What a report is about: the `source` of an open report in the
/// `admin-moderation` Edge Function's answer.
enum ReportSource {
  profile('profile'),
  list('list'),
  review('review'),
  thread('thread'),
  reply('reply'),
  other('');

  const ReportSource(this.wire);

  final String wire;

  static ReportSource fromWire(Object? wire) => values.firstWhere(
    (s) => s != other && s.wire == wire,
    orElse: () => other,
  );

  String get label => switch (this) {
    profile => L10n.current.adminSourceProfile,
    list => L10n.current.adminSourceList,
    review => L10n.current.adminSourceReview,
    thread => L10n.current.adminSourceThread,
    reply => L10n.current.adminSourceReply,
    other => L10n.current.adminSourceOther,
  };

  IconData get icon => switch (this) {
    profile => Icons.person_outline_rounded,
    list => Icons.list_alt_rounded,
    review => Icons.rate_review_outlined,
    thread => Icons.forum_outlined,
    reply => Icons.chat_bubble_outline_rounded,
    other => Icons.flag_outlined,
  };
}

/// The member a report or a suspension is about, as far as a moderator needs.
@immutable
class ModeratedMember {
  const ModeratedMember({
    required this.id,
    required this.handle,
    required this.name,
    this.suspended = false,
  });

  final String id;

  /// Without the "@"; may be empty.
  final String handle;
  final String name;

  /// Whether they are suspended right now.
  final bool suspended;

  /// The name, or the handle when they have none.
  String get displayName => name.isNotEmpty
      ? name
      : handle.isNotEmpty
      ? handle
      : L10n.current.defaultPlayerName;

  /// "@handle", or nothing when there is none.
  String get atHandle => handle.isEmpty ? '' : '@$handle';
}

/// One open report from a member, as listed in the admin queue. Who reported is
/// never sent.
@immutable
class AdminReport {
  const AdminReport({
    required this.source,
    required this.reason,
    required this.member,
    required this.content,
    required this.hoursOpen,
    required this.overdue,
    this.reportedAt,
    this.reference,
  });

  factory AdminReport.fromJson(Map<String, dynamic> json) {
    final member = json['member'];
    final fields = member is Map ? member : const {};
    final hours = json['hours_open'];
    return AdminReport(
      source: ReportSource.fromWire(json['source']),
      reason: ReportReason.values.firstWhere(
        (r) => r.wireName == json['reason'],
        orElse: () => ReportReason.other,
      ),
      member: ModeratedMember(
        id: '${fields['id'] ?? ''}',
        handle: '${fields['handle'] ?? ''}',
        name: '${fields['name'] ?? ''}',
        suspended: fields['suspended'] == true,
      ),
      content: '${json['content'] ?? ''}',
      hoursOpen: hours is num ? hours.toDouble() : 0,
      overdue: json['overdue'] == true,
      reportedAt: DateTime.tryParse('${json['reported_at'] ?? ''}'),
      reference: json['reference'] is String
          ? json['reference'] as String
          : null,
    );
  }

  final ReportSource source;
  final ReportReason reason;
  final ModeratedMember member;

  /// What was reported: the text, or a description of the photo.
  final String content;

  /// How long the report has waited, and whether that is past the 24 hours the
  /// Terms of Use promise.
  final double hoursOpen;
  final bool overdue;
  final DateTime? reportedAt;

  /// The id of the thing reported (the list, the thread, the reply; a review's game).
  final String? reference;
}

/// A member suspended right now, as listed under Suspended.
@immutable
class SuspendedMember {
  const SuspendedMember({
    required this.member,
    required this.reason,
    this.suspendedAt,
    this.until,
  });

  factory SuspendedMember.fromJson(Map<String, dynamic> json) =>
      SuspendedMember(
        member: ModeratedMember(
          id: '${json['id'] ?? ''}',
          handle: '${json['handle'] ?? ''}',
          name: '${json['name'] ?? ''}',
          suspended: true,
        ),
        reason: '${json['reason'] ?? ''}',
        suspendedAt: DateTime.tryParse('${json['suspended_at'] ?? ''}'),
        until: DateTime.tryParse('${json['until'] ?? ''}'),
      );

  final ModeratedMember member;

  /// The moderator's note, never shown to the member.
  final String reason;
  final DateTime? suspendedAt;

  /// When it ends by itself; null: when a moderator reinstates them.
  final DateTime? until;

  bool get forGood => until == null;
}
