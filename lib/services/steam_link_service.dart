import 'dart:async';
import 'dart:io' show ContentType, HttpServer, HttpStatus, InternetAddress;

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/services/web_address.dart';

/// Asks the server to start a Steam link (CheckpointRepository.startSteamLink):
/// answers Steam's sign-in page, which ends at [returnTo] (null: nowhere, see
/// [SteamLinkOpened]).
typedef StartSteamLink = Future<Uri> Function(Uri? returnTo);

/// How far a Steam sign-in got, as far as this device can tell.
sealed class SteamLinkOutcome {
  const SteamLinkOutcome();
}

/// Steam's return reached the app: [result] is `ok` or the server's error code
/// (a [SyncFailureCode] wire name). The desktop apps.
class SteamLinkReturned extends SteamLinkOutcome {
  const SteamLinkReturned(this.result);
  final String result;
}

/// Steam's page is open in a browser tab over the app, which can't be called
/// back from it: whether it worked shows on the profile. Android and iOS.
class SteamLinkOpened extends SteamLinkOutcome {
  const SteamLinkOpened();
}

/// The page itself went to Steam, and comes back reloaded with the result in
/// its address ([takeWebSteamLinkResult]). The web app.
class SteamLinkLeftApp extends SteamLinkOutcome {
  const SteamLinkLeftApp();
}

/// A Steam sign-in that could not be opened or did not come back. [message] is
/// safe to show.
class SteamLinkException implements Exception {
  const SteamLinkException(this.message);
  final String message;

  @override
  String toString() => 'SteamLinkException: $message';
}

/// Opens "Sign in through Steam" (the `steam-link` Edge Function) the way each
/// platform can come back from it. Where the server has a confirm page
/// (web/steam-link.html, its STEAM_LINK_CONFIRM_URL), every platform passes
/// through it after Steam: the member checks which Gamebit account the
/// Steam account is linked to, and the result comes back once they confirm or
/// cancel there:
///  * web: the page itself goes to Steam, and Steam's return sends it back to
///    the app with `?steam_link=<result>`;
///  * Linux, Windows, macOS: the system browser, and the result comes back to a
///    listener on 127.0.0.1, the way Google sign-in does in AuthService (on a
///    free port: nothing has to allow this address in advance);
///  * Android, iOS: an in-app browser tab (Custom Tabs, SFSafariViewController).
///    The app has no link scheme Steam's return could call it back on, so
///    ProfileStore watches the profile for the Steam ID instead.
class SteamLinkFlow {
  /// A little longer than the server accepts a sign-in (10 minutes).
  static const _returnWait = Duration(minutes: 11);
  static const _returnPath = '/steam-link';

  static String get unsupportedMessage => L10n.current.steamLinkUnsupported;
  static String get _noBrowser => L10n.current.steamLinkNoBrowser;
  static String get _timedOut => L10n.current.steamLinkTimedOut;
  static String get _cancelled => L10n.current.steamLinkCancelled;

  /// The listener of an unfinished desktop sign-in, and what it waits for.
  HttpServer? _loopback;
  Completer<String>? _returned;

  /// Opens Steam's sign-in page, asking [start] for it. Throws a
  /// [SteamLinkException] when it can't be opened or (desktop) never comes back,
  /// and whatever [start] throws.
  Future<SteamLinkOutcome> open(StartSteamLink start) async {
    if (kIsWeb) {
      final page = await start(webReturnUrl(Uri.base));
      await _launch(page, webOnlyWindowName: '_self');
      return const SteamLinkLeftApp();
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS:
        return SteamLinkReturned(await _openWithLoopback(start));
      case TargetPlatform.android || TargetPlatform.iOS:
        await _launch(await start(null), mode: LaunchMode.inAppBrowserView);
        return const SteamLinkOpened();
      case TargetPlatform.fuchsia:
        throw SteamLinkException(unsupportedMessage);
    }
  }

  /// Stops waiting for the sign-in [open] started (the desktop listener).
  Future<void> cancel() async {
    final returned = _returned;
    if (returned != null && !returned.isCompleted) {
      returned.completeError(SteamLinkException(_cancelled));
    }
    await _loopback?.close(force: true);
  }

  /// Closes the in-app browser tab [open] showed Steam's page in, where an app
  /// may (iOS). On Android the member closes it.
  Future<void> closeBrowser() async {
    if (kIsWeb) return;
    try {
      if (await supportsCloseForLaunchMode(LaunchMode.inAppBrowserView)) {
        await closeInAppWebView();
      }
    } catch (e) {
      debugPrint('Closing the Steam sign-in tab failed: $e');
    }
  }

  Future<void> _launch(
    Uri page, {
    LaunchMode mode = LaunchMode.platformDefault,
    String? webOnlyWindowName,
  }) async {
    final bool opened;
    try {
      opened = await launchUrl(
        page,
        mode: mode,
        webOnlyWindowName: webOnlyWindowName,
      );
    } catch (e) {
      debugPrint('Opening Steam sign-in failed: $e');
      throw SteamLinkException(_noBrowser);
    }
    if (!opened) throw SteamLinkException(_noBrowser);
  }

  /// Opens Steam's page in the system browser and waits for Steam's return on
  /// 127.0.0.1. Answers the result it brought.
  Future<String> _openWithLoopback(StartSteamLink start) async {
    // An earlier attempt that was never finished still listens.
    await cancel();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final returned = Completer<String>();
    // A [cancel] before anything waits on it must not be reported as unhandled.
    returned.future.ignore();
    _loopback = server;
    _returned = returned;
    final subscription = server.listen((request) {
      final uri = request.uri;
      final result = uri.path == _returnPath
          ? uri.queryParameters['steam_link']
          : null;
      final response = request.response;
      if (result != null) {
        response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_returnPage(ok: result == 'ok'));
      } else {
        response.statusCode = HttpStatus.notFound; // favicon.ico and friends
      }
      unawaited(response.close());
      if (result != null && !returned.isCompleted) returned.complete(result);
    });

    try {
      final page = await start(
        Uri.parse('http://127.0.0.1:${server.port}$_returnPath'),
      );
      // Cancelled while the server answered: don't open the browser.
      if (returned.isCompleted) return await returned.future;
      await _launch(page, mode: LaunchMode.externalApplication);
      return await returned.future.timeout(
        _returnWait,
        onTimeout: () => throw SteamLinkException(_timedOut),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      if (identical(_loopback, server)) {
        _loopback = null;
        _returned = null;
      }
    }
  }

  /// The page the browser shows when Steam's return reaches the desktop app.
  static String _returnPage({required bool ok}) {
    final l10n = L10n.current;
    final title = ok ? l10n.steamLinkPageConnected : l10n.steamLinkPageNotConnected;
    final body = ok ? l10n.authCallbackSignedInBody : l10n.steamLinkPageNotConnectedBody;
    return '<!doctype html><html lang="${L10n.languageCode}"><head><meta charset="utf-8"><title>Gamebit</title>'
        '<style>body{font-family:sans-serif;background:#0b0d12;color:#eee;display:grid;'
        'place-items:center;height:100vh;margin:0;text-align:center}</style></head>'
        '<body><div><h2>$title</h2><p>$body</p></div></body></html>';
  }
}

/// Where Steam's return sends the web app served at [page]: the app itself
/// (its folder included), without the query and the fragment it has now.
Uri webReturnUrl(Uri page) => Uri(
  scheme: page.scheme,
  host: page.host,
  port: page.hasPort ? page.port : null,
  path: page.path,
);

/// [page] without the `steam_link` result in its query.
Uri withoutSteamLinkResult(Uri page) {
  final rest = Map.of(page.queryParameters)..remove('steam_link');
  return Uri(
    scheme: page.scheme,
    host: page.host,
    port: page.hasPort ? page.port : null,
    path: page.path,
    queryParameters: rest.isEmpty ? null : rest,
    fragment: page.hasFragment ? page.fragment : null,
  );
}

/// The result Steam's return brought the web app back with (`?steam_link=`:
/// `ok` or an error code), or null. Takes it off the address bar, so a reload
/// doesn't report it again.
String? takeWebSteamLinkResult() {
  if (!kIsWeb) return null;
  final page = Uri.base;
  final result = page.queryParameters['steam_link'];
  if (result == null) return null;
  replaceWebAddress(withoutSteamLinkResult(page));
  return result;
}
