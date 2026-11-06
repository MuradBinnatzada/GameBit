import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/share_link.dart';

/// Which push notifications the member wants (`notification_settings`): both on
/// until they turn one off.
@immutable
class NotificationSettings {
  const NotificationSettings({this.priceDrops = true, this.threadReplies = true});

  /// A wishlist game goes on sale.
  final bool priceDrops;

  /// Someone replies to the member's discussion thread.
  final bool threadReplies;

  NotificationSettings copyWith({bool? priceDrops, bool? threadReplies}) =>
      NotificationSettings(priceDrops: priceDrops ?? this.priceDrops, threadReplies: threadReplies ?? this.threadReplies);

  @override
  bool operator ==(Object other) =>
      other is NotificationSettings && other.priceDrops == priceDrops && other.threadReplies == threadReplies;

  @override
  int get hashCode => Object.hash(priceDrops, threadReplies);
}

/// What a tapped push notification opens, from the `data` the server sent
/// (`supabase/functions/_shared/push_messages.ts`): a game for a price drop, a
/// thread for a reply. Null for anything else (a notification from a newer
/// server, or a made-up one).
LinkTarget? pushTarget(Map<String, Object?> data) {
  switch (data['kind']) {
    case 'price_drop':
      final id = int.tryParse('${data['igdb_id']}');
      return id != null && id > 0 ? GameLink(id) : null;
    case 'thread_reply':
      final target = LinkTarget.parse('/thread/${data['thread_id']}');
      return target is ThreadLink ? target : null;
  }
  return null;
}

/// The payload of a notification the app shows itself when a push arrives while it is
/// open, so a tap on it opens what [pushTarget] says.
const _pushPayloadPrefix = 'push:';

String pushPayload(Map<String, Object?> data) => '$_pushPayloadPrefix${jsonEncode(data)}';

/// What a tap on a notification with [payload] opens: [pushTarget] of the data it was
/// made from, or null for any other payload (a release reminder's, say) or one that
/// is not whole.
LinkTarget? pushTargetOfPayload(String payload) {
  if (!payload.startsWith(_pushPayloadPrefix)) return null;
  try {
    final data = jsonDecode(payload.substring(_pushPayloadPrefix.length));
    return data is Map ? pushTarget(Map<String, Object?>.from(data)) : null;
  } on FormatException {
    return null;
  }
}
