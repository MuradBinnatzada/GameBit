import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/app/app_shell.dart';
import 'package:checkpoint/app/second_factor_gate.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/appearance_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';

class CheckpointApp extends StatefulWidget {
  const CheckpointApp({super.key, this.appearance});

  /// The theme saved on this device, read before the first frame (see main.dart).
  final AppearanceStore? appearance;

  @override
  State<CheckpointApp> createState() => _CheckpointAppState();
}

class _CheckpointAppState extends State<CheckpointApp> {
  late final AppStores _stores = AppStores.supabase(Supabase.instance.client);
  late final AppearanceStore _appearance = widget.appearance ?? AppearanceStore();

  @override
  void initState() {
    super.initState();
    unawaited(_stores.initialize());
  }

  @override
  void dispose() {
    _stores.dispose();
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The scopes sit above MaterialApp so pushed routes and sheets can read them.
    return AppStoresScope(
      stores: _stores,
      child: AppearanceApp(appearance: _appearance, home: const AppShell()),
    );
  }
}

/// The MaterialApp, dressed the way Settings > Appearance and the device ask:
/// the language (the one picked, else the device's when the app has it, else
/// English), the theme (light, dark or the device's; high contrast when the
/// switch or the device's setting is on), the text size (the device's, up to
/// [maxTextScale]) and motion (less of it when the switch, Android's Remove
/// animations or iOS's Reduce Motion asks). [appearance] is in scope below it,
/// for the settings.
class AppearanceApp extends StatefulWidget {
  const AppearanceApp({
    super.key,
    required this.appearance,
    required this.home,
    this.navigatorKey,
  });

  final AppearanceStore appearance;
  final Widget home;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<AppearanceApp> createState() => _AppearanceAppState();
}

class _AppearanceAppState extends State<AppearanceApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The device's Reduce Motion or Remove animations changed.
  @override
  void didChangeAccessibilityFeatures() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final appearance = widget.appearance;
    return StoreScope<AppearanceStore>(
      store: appearance,
      child: ListenableBuilder(
        listenable: appearance,
        builder: (context, _) {
          final device = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
          final reduceMotion = appearance.reduceMotion || device.disableAnimations || device.reduceMotion;
          final highContrast = appearance.highContrast;
          return MaterialApp(
            navigatorKey: widget.navigatorKey,
            title: 'Gamebit',
            debugShowCheckedModeBanner: false,
            locale: appearance.locale,
            supportedLocales: L10n.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: highContrast ? lightHighContrastTheme : lightTheme,
            darkTheme: highContrast ? darkHighContrastTheme : darkTheme,
            // What the device's own high contrast setting picks.
            highContrastTheme: lightHighContrastTheme,
            highContrastDarkTheme: darkHighContrastTheme,
            themeMode: appearance.themeMode,
            themeAnimationDuration: reduceMotion ? Duration.zero : kThemeAnimationDuration,
            builder: (context, child) {
              if (L10n.use(Localizations.localeOf(context))) {
                // Labels that stores and models made with L10n.current are in
                // widgets that don't depend on the language: rebuild them all.
                WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildAll());
              }
              return MediaQuery(
                // Read by motion() and the page transitions. (Flutter's own
                // animations follow Android's Remove animations by themselves.)
                data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  // Screens without an app bar: the system bars follow the theme.
                  value: systemBarsStyle(context.palette),
                  child: MediaQuery.withClampedTextScaling(
                    minScaleFactor: 0.9,
                    maxScaleFactor: maxTextScale,
                    // Over every route: a sign-in that still owes its two-factor code.
                    child: SecondFactorGate(child: child!),
                  ),
                ),
              );
            },
            home: widget.home,
          );
        },
      ),
    );
  }
}

/// Marks every widget for a rebuild, the way a hot reload does: after the
/// language changes, nothing keeps text in the old one.
void _rebuildAll() {
  void mark(Element element) {
    element.markNeedsBuild();
    element.visitChildren(mark);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(mark);
}
