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
