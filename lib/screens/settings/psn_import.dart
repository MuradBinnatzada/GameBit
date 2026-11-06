import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:checkpoint/app/app_config.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/library_csv.dart';
import 'package:checkpoint/services/playstation/psn_client.dart';
import 'package:checkpoint/services/playstation/psn_device.dart';
import 'package:checkpoint/services/playstation/psn_library.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';

/// The import from PlayStation, which reads the member's own play history and
/// trophies from Sony on their phone. It is unofficial (see [PsnClient]), so it is
/// offered only where it can work and the build has asked for it:
///  * the build has a PlayStation client (`--dart-define=PSN_CLIENT_BASIC`);
///  * the device is an Android phone or an iPhone, the only places the sign-in
///    page can be shown inside the app.
///
/// Everything PlayStation is in `lib/services/playstation/`, this file, the
/// row in `data_section.dart`, the trophy screens (`game_trophies_dialog.dart`,
/// `trophies_section.dart`) and the strings that start with `psn` or `trophy`.
bool psnImportAvailable({String clientBasic = AppConfig.psnClientBasic, bool? web, TargetPlatform? platform}) {
  if (clientBasic.trim().isEmpty) return false;
  if (web ?? kIsWeb) return false;
  final target = platform ?? defaultTargetPlatform;
  return target == TargetPlatform.android || target == TargetPlatform.iOS;
}

/// Shows Sony's sign-in page ([signInUri]) and calls [onRedirect] with the link
/// it ends at ([PsnClient.redirectUri]); [onFailed] when the page could not load.
/// A parameter so that tests can stand in for the web view.
typedef PsnSignInBuilder = Widget Function(
  BuildContext context,
  Uri signInUri,
  ValueChanged<String> onRedirect,
  VoidCallback onFailed,
);

enum _Choice { go, forget }

/// Syncs the member with PlayStation: checks the once-a-day limit, asks them to
/// confirm (the first time with what it means, afterwards with a way to forget the
/// saved sign-in), signs in (silently with the saved sign-in, on Sony's page
/// otherwise), reads their lists and answers them as an import to review. Null
/// when they backed out, were limited or it failed (the screen has said why).
Future<ImportFile?> readPlayStationLibrary(
  BuildContext context, {
  PsnClient Function()? makeClient,
  PsnSignInBuilder? signInBuilder,
  PsnDevice? device,
  String? userId,
  Duration? cooldown,
}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final language = Localizations.localeOf(context).languageCode == 'ru' ? 'ru-RU' : 'en-US';
  final account = userId ?? context.read<AuthStore>().user?.id ?? '';
  final phone = device ?? PsnDevice();

  final wait = await phone.waitFor(account, cooldown ?? AppConfig.psnSyncCooldown);
  if (!context.mounted) return null;
  if (wait != null) {
    final text = wait.inMinutes >= 60 ? l10n.psnSyncLimitHours((wait.inMinutes / 60).ceil()) : l10n.psnSyncLimitMinutes(wait.inMinutes < 1 ? 1 : wait.inMinutes);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
    return null;
  }

  final saved = await phone.savedSignIn(account);
  if (!context.mounted) return null;
  final choice = await showDialog<_Choice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(saved == null ? context.l10n.psnDisclosureTitle : context.l10n.psnResumeTitle),
      content: SingleChildScrollView(
        child: Text(saved == null ? context.l10n.psnDisclosureBody : context.l10n.psnResumeBody),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l10n.cancel)),
        if (saved != null)
          TextButton(onPressed: () => Navigator.pop(context, _Choice.forget), child: Text(context.l10n.psnForgetSignIn)),
        FilledButton(
          onPressed: () => Navigator.pop(context, _Choice.go),
          child: Text(saved == null ? context.l10n.psnDisclosureContinue : context.l10n.psnResumeSync),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice == _Choice.forget) {
    await phone.forget(account);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l10n.psnSignInForgotten)));
    return null;
  }

  final PsnClient client;
  try {
    client = (makeClient ?? () => PsnClient(clientBasic: AppConfig.psnClientBasic, language: language))();
  } on PsnException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return null;
  }
  try {
    return await Navigator.of(context).push<ImportFile>(
      MaterialPageRoute(
        builder: (_) => PsnImportScreen(
          client: client,
          signInBuilder: signInBuilder,
          savedSignIn: saved,
          device: phone,
          userId: account,
        ),
      ),
    );
  } finally {
    client.close();
  }
}

enum _Phase { signingIn, reading, failed }

/// Sony's sign-in page (or the saved sign-in, which skips it), then "reading your
/// games and trophies"; closes with the [ImportFile] when it has them.
class PsnImportScreen extends StatefulWidget {
  const PsnImportScreen({
    super.key,
    required this.client,
    this.signInBuilder,
    this.savedSignIn,
    this.device,
    this.userId = '',
  });
  final PsnClient client;
  final PsnSignInBuilder? signInBuilder;

  /// The refresh token an earlier sync left; tried before the sign-in page.
  final String? savedSignIn;

  /// What the phone keeps between syncs; the real one when null.
  final PsnDevice? device;

  /// The Gamebit account the sync is for (what [device] keeps things under).
  final String userId;

  @override
  State<PsnImportScreen> createState() => _PsnImportScreenState();
}

class _PsnImportScreenState extends State<PsnImportScreen> {
  late _Phase _phase = widget.savedSignIn == null ? _Phase.signingIn : _Phase.reading;
  String _error = '';

  /// How far the trophy lists are read: (done, total); null before that.
  (int, int)? _progress;

  /// A new sign-in page for every attempt, so "Try again" starts clean.
  int _attempt = 0;

  late final PsnDevice _device = widget.device ?? PsnDevice();
  bool get _hasAccount => widget.userId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final saved = widget.savedSignIn;
    if (saved != null) unawaited(_resume(saved));
  }

  void _fail(String message) {
    if (kDebugMode) debugPrint('PSN: shown to the member: $message');
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _error = message;
    });
  }

  /// Signs in again with the sign-in the phone kept. When Sony no longer takes it
  /// it is forgotten and the sign-in page opens instead.
  Future<void> _resume(String saved) async {
    try {
      await _signedIn(await widget.client.refresh(saved));
    } on PsnException catch (e) {
      if (e.failure == PsnFailure.signInRejected) {
        if (_hasAccount) await _device.forget(widget.userId);
        if (mounted) setState(() => _phase = _Phase.signingIn);
      } else {
        _fail(e.message);
      }
    } catch (e, st) {
      debugPrint('Reading PlayStation failed: $e\n$st');
      _fail(const PsnException(PsnFailure.unexpected).message);
    }
  }

  void _onRedirect(String url) {
    // The page may report the link more than once.
    if (_phase != _Phase.signingIn) return;
    final code = PsnClient.codeFromRedirect(url);
    if (kDebugMode) debugPrint('PSN: the sign-in ended, code present: ${code != null}');
    if (code == null) {
      _fail(PsnException(PsnFailure.signInRejected).message);
      return;
    }
    unawaited(_read(code));
  }

  Future<void> _read(String code) async {
    setState(() => _phase = _Phase.reading);
    try {
      await _signedIn(await widget.client.exchangeCode(code));
    } on PsnException catch (e) {
      _fail(e.message);
    } catch (e, st) {
      debugPrint('Reading PlayStation failed: $e\n$st');
      _fail(const PsnException(PsnFailure.unexpected).message);
    }
  }

  /// With the sign-in done: keeps it for next time, reads both lists, then the
  /// trophy lists of the games that changed, and closes with the import.
  Future<void> _signedIn(PsnTokens tokens) async {
    final account = widget.userId;
    if (_hasAccount) await _device.saveSignIn(account, tokens);
    var library = await readPsnLibrary(widget.client, tokens);
    // Sony has been asked: that counts as the day's sync, whatever the member does
    // with the result.
    if (_hasAccount) await _device.markSynced(account);
    final stored = _hasAccount ? await _device.storedLists(account) : <String, String>{};
    library = await loadTrophyLists(
      widget.client,
      tokens,
      library,
      stored: stored,
      onProgress: (done, total) {
        if (mounted && total > 0) setState(() => _progress = (done, total));
      },
    );
    final file = buildPsnImport(
      library,
      onRowImported: (row) {
        final set = row.trophySet;
        if (_hasAccount && set != null) {
          unawaited(_device.rememberList(account, set, PsnDevice.listMark(row.trophiesEarned ?? 0, row.trophiesTotal ?? 0)));
        }
      },
    );
    if (mounted) Navigator.pop(context, file);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopScope(
      // Reading takes a few seconds and has nothing to undo; backing out of it
      // would only leave the import half-seen.
      canPop: _phase != _Phase.reading,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.psnSignInTitle)),
        body: switch (_phase) {
          _Phase.signingIn => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(l10n.psnSignInNote, style: TextStyle(color: context.palette.muted, fontSize: 12.5)),
              ),
              Expanded(
                child: KeyedSubtree(
                  key: ValueKey(_attempt),
                  child: (widget.signInBuilder ?? _sonyWebView)(
                    context,
                    widget.client.signInUri,
                    _onRedirect,
                    () => _fail(const PsnException(PsnFailure.unavailable).message),
                  ),
                ),
              ),
            ],
          ),
          _Phase.reading => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_progress == null ? l10n.psnReading : l10n.psnReadingTrophies(_progress!.$1, _progress!.$2)),
              ],
            ),
          ),
          _Phase.failed => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error, textAlign: TextAlign.center, style: TextStyle(color: context.palette.danger, height: 1.4)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => setState(() {
                      _attempt++;
                      _phase = _Phase.signingIn;
                    }),
                    child: Text(l10n.tryAgain),
                  ),
                  TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.close)),
                ],
              ),
            ),
          ),
        },
      ),
    );
  }
}

Widget _sonyWebView(BuildContext context, Uri signInUri, ValueChanged<String> onRedirect, VoidCallback onFailed) =>
    _SonyWebView(signInUri: signInUri, onRedirect: onRedirect, onFailed: onFailed);

/// Sony's sign-in page in a web view inside the app. The app does not read the
/// page: it only watches for the link the sign-in ends at (which the phone could
/// not open anyway) and keeps nothing the web view stored (cookies, storage).
class _SonyWebView extends StatefulWidget {
  const _SonyWebView({required this.signInUri, required this.onRedirect, required this.onFailed});
  final Uri signInUri;
  final ValueChanged<String> onRedirect;
  final VoidCallback onFailed;

  @override
  State<_SonyWebView> createState() => _SonyWebViewState();
}

class _SonyWebViewState extends State<_SonyWebView> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      // Sony's sign-in page is a script-driven form.
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onPageStarted: (url) => _log('page started: ${PsnClient.describe(url)}'),
          onPageFinished: (url) {
            _log('page finished: ${PsnClient.describe(url)}');
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            _log(
              'page error ${error.errorCode} ${error.errorType?.name} "${error.description}" '
              'main frame: ${error.isForMainFrame} at ${PsnClient.describe(error.url ?? '')}',
            );
            if (error.isForMainFrame ?? false) widget.onFailed();
          },
        ),
      );
    _log('sign-in page requested: ${PsnClient.describe(widget.signInUri.toString())}');
    unawaited(_start());
  }

  Future<void> _start() async {
    // A clean slate: Sony asks for the account instead of reusing whoever signed
    // in in this web view before.
    await WebViewCookieManager().clearCookies();
    await _controller.clearLocalStorage();
    await _controller.loadRequest(widget.signInUri);
  }

  /// Debug builds only; where the web view goes, without its query.
  static void _log(String message) {
    if (kDebugMode) debugPrint('PSN: $message');
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    if (PsnClient.isRedirect(request.url)) {
      _log('navigation to the sign-in end link (main frame: ${request.isMainFrame})');
      widget.onRedirect(request.url);
      return NavigationDecision.prevent;
    }
    // Pages only: no other app is opened from Sony's sign-in.
    final scheme = Uri.tryParse(request.url)?.scheme;
    final allowed = scheme == 'https' || scheme == 'http' || scheme == 'about';
    _log('${allowed ? 'navigate' : 'BLOCKED'}: ${PsnClient.describe(request.url)} (scheme $scheme, main frame: ${request.isMainFrame})');
    return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
  }

  @override
  void dispose() {
    unawaited(WebViewCookieManager().clearCookies());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      WebViewWidget(controller: _controller),
      if (_loading) const Center(child: CircularProgressIndicator()),
    ],
  );
}
