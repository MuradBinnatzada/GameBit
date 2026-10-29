import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/app/app_config.dart';
import 'package:checkpoint/app/checkpoint_app.dart';
import 'package:checkpoint/services/crash_reporting.dart';
import 'package:checkpoint/services/session_storage.dart';
import 'package:checkpoint/state/appearance_store.dart';

Future<void> main() => CrashReporting.run(_start);

Future<void> _start() async {
  WidgetsFlutterBinding.ensureInitialized();

  // A staging URL with the production key (or the reverse) signs nobody in and
  // looks like an outage: stop at the cause.
  if (!AppConfig.backendIsConsistent()) {
    throw StateError(
      'SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY must be set together '
      '(see lib/app/app_config.dart).',
    );
  }

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabasePublishableKey,
    // Android and iOS keep the session's tokens encrypted; null is
    // supabase_flutter's own storage (the web and desktop apps).
    authOptions: FlutterAuthClientOptions(
      localStorage: EncryptedSessionStorage.supported
          ? EncryptedSessionStorage(sessionKeyFor(AppConfig.supabaseUrl))
          : null,
    ),
  );

  // Before the first frame, so the app opens in the theme it was left in. The
  // system bars follow the theme (see CheckpointApp).
  final appearance = await AppearanceStore.load();

  runApp(CheckpointApp(appearance: appearance));
}
