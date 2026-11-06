/// What a build is configured with, set when it is made with `--dart-define`:
///
/// ```
/// flutter run \
///   --dart-define=SUPABASE_URL=https://<staging ref>.supabase.co \
///   --dart-define=SUPABASE_PUBLISHABLE_KEY=<staging anon key> \
///   --dart-define=CHECKPOINT_ENV=staging
/// ```
///
/// Without them the app is the production one. The publishable key is public by
/// design (Row Level Security is what protects the data), so it may sit in the
/// source; a staging key belongs in the build command or the CI secrets anyway.
library;

import 'package:flutter/foundation.dart' show kDebugMode;

abstract final class AppConfig {
  static const productionSupabaseUrl = 'https://nmbarqhvcjgyuwreebda.supabase.co';
  static const _productionPublishableKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5tYmFycWh2Y2pneXV3cmVlYmRhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEzODE5OTcsImV4cCI6MjEwNjk1Nzk5N30.tXIvaeJPK1ZEI75U6f-SkD-4iRZBVVE3Cy5OxBCscGQ';

  /// The Supabase project the app talks to.
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: productionSupabaseUrl,
  );

  /// That project's publishable (anon) key.
  static const supabasePublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: _productionPublishableKey,
  );

  /// Which backend this build is for (`production`, `staging`, ...). Tags crash
  /// reports, so a staging crash is never mistaken for a production one.
  static const environment = String.fromEnvironment(
    'CHECKPOINT_ENV',
    defaultValue: 'production',
  );

  /// Where crash reports go ([Sentry](https://sentry.io) DSN). Empty: the app
  /// sends none. The DSN is not a secret either, but a project of its own per
  /// environment keeps the noise apart.
  static const sentryDsn = String.fromEnvironment('SENTRY_DSN');

  /// Where the landing page, the privacy policy and the terms are served (the
  /// `docs/` folder). The Privacy and Terms links of the sign-in panel and of
  /// Settings open pages below it.
  static const docsUrl = String.fromEnvironment(
    'CHECKPOINT_DOCS_URL',
    defaultValue: 'https://muradbinnatzada.github.io/Checkpoint',
  );

  /// Where questions, data requests and reports about members go. Also in
  /// `docs/` (privacy.html, terms.html, index.html): change them together.
  static const contactEmail = String.fromEnvironment(
    'CHECKPOINT_CONTACT_EMAIL',
    defaultValue: 'muradbinnetzade14@gmail.com',
  );

  /// The sign-in client of the PlayStation import, as the `Basic` credential
  /// (`client id:secret` in base64) of PlayStation's own phone app, which the
  /// open-source PSN libraries publish (`psn-api`). Empty: the build has no
  /// PlayStation import, and Settings does not offer it. Set it as the default
  /// below, or for one build with `--dart-define=PSN_CLIENT_BASIC=<credential>`
  /// (README, "PlayStation import").
  static const psnClientBasic = String.fromEnvironment(
    'PSN_CLIENT_BASIC',
    defaultValue: 'MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A=',
  );

  /// The Firebase project that sends push notifications (price drops, replies),
  /// from its `google-services.json` (Android) and `GoogleService-Info.plist`
  /// (iOS): project id, API key, the sender id (`project_number` / `GCM_SENDER_ID`)
  /// and the app id of each platform (`mobilesdk_app_id` / `GOOGLE_APP_ID`).
  /// The defaults are the Gamebit project's (client configuration, not secrets: every
  /// app carries it); `--dart-define=FIREBASE_...` replaces them for a build (an empty
  /// project id switches push off, and Settings says so; README, "Push notifications").
  static const firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: 'gamebit-9523b',
  );
  static const firebaseApiKey = String.fromEnvironment(
    'FIREBASE_API_KEY',
    defaultValue: 'AIzaSyA2otawT7t8_RgKRCM5esImGABNV8tX9vk',
  );
  static const firebaseSenderId = String.fromEnvironment(
    'FIREBASE_SENDER_ID',
    defaultValue: '46116590395',
  );
  static const firebaseAndroidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
    defaultValue: '1:46116590395:android:d17b9e63fabbc58e3c9d1e',
  );
  static const firebaseIosAppId = String.fromEnvironment(
    'FIREBASE_IOS_APP_ID',
    defaultValue: '1:46116590395:ios:a9f4469fde89f8a03c9d1e',
  );

  static const _psnSyncHours = int.fromEnvironment('PSN_SYNC_COOLDOWN_HOURS', defaultValue: -1);

  /// The least time between two PlayStation syncs of one member on one phone. A
  /// day for a release build, so Sony is asked about an account at most once a
  /// day; none for a debug build, so it can be tried again and again. Either is
  /// replaced by `--dart-define=PSN_SYNC_COOLDOWN_HOURS=<hours>` (0: no limit).
  static Duration get psnSyncCooldown =>
      _psnSyncHours >= 0 ? Duration(hours: _psnSyncHours) : (kDebugMode ? Duration.zero : const Duration(hours: 24));

  static Uri get privacyUri => Uri.parse('$docsUrl/privacy.html');
  static Uri get termsUri => Uri.parse('$docsUrl/terms.html');
  static Uri get contactUri => Uri(scheme: 'mailto', path: contactEmail);

  /// Whether [url] and [key] name the same project. A staging URL with the
  /// production key (or the other way round) signs nobody in and looks like an
  /// outage, so [main] refuses to start with a mix.
  static bool backendIsConsistent({
    String url = supabaseUrl,
    String key = supabasePublishableKey,
  }) {
    final usingProductionUrl = url == productionSupabaseUrl;
    final usingProductionKey = key == _productionPublishableKey;
    return usingProductionUrl == usingProductionKey;
  }
}
