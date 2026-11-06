part of '../checkpoint_repository.dart';

/// Push notifications: the phones registered for them and what the member wants
/// to hear about (20261107120000_push_notifications.sql).
mixin _PushQueries on _RepositoryBase {
  /// Registers this phone's FCM [token] for the signed-in member, or moves it to
  /// them when it was another member's. [platform] is `android` or `ios`;
  /// [language] (two letters) is what the notifications are written in and
  /// [country] (two letters) picks the currency of prices.
  Future<void> registerPushDevice({
    required String token,
    required String platform,
    required String language,
    required String country,
  }) async {
    await _client.rpc(
      Db.rpcRegisterPushDevice,
      params: {
        'device_token': token,
        'device_platform': platform,
        'device_language': language,
        'device_country': country,
      },
    );
  }

  /// Forgets this phone's [token]: no notification goes to it any more.
  Future<void> unregisterPushDevice(String token) async {
    await _client.rpc(Db.rpcUnregisterPushDevice, params: {'device_token': token});
  }

  /// The member's switches; both on when they never set them.
  Future<NotificationSettings> fetchNotificationSettings() async {
    final row = await _client
        .from(Db.notificationSettings)
        .select('${Db.priceDrops}, ${Db.threadReplies}')
        .eq(Db.userId, _requireUserId())
        .maybeSingle();
    if (row == null) return const NotificationSettings();
    return NotificationSettings(
      priceDrops: row[Db.priceDrops] != false,
      threadReplies: row[Db.threadReplies] != false,
    );
  }

  Future<void> saveNotificationSettings(NotificationSettings settings) async {
    await _client.from(Db.notificationSettings).upsert({
      Db.userId: _requireUserId(),
      Db.priceDrops: settings.priceDrops,
      Db.threadReplies: settings.threadReplies,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: Db.userId);
  }
}
