import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/trophy.dart';

/// Why a PlayStation request failed. The import tells the member in words
/// ([PsnException.message]); nothing here is sent anywhere.
enum PsnFailure {
  /// This build has no PlayStation client ([PsnClient.fromConfig] was given
  /// nothing, or something that is not `client id:secret` in base64).
  notConfigured,

  /// Sony turned the sign-in's code down.
  signInRejected,

  /// Sony turned the access token down (it lasts about an hour).
  signInExpired,

  /// Sony would not hand over the list: the account's privacy settings, or its
  /// region or age restrictions.
  listNotShared,

  /// Sony asked to slow down.
  rateLimited,

  /// Sony could not be reached, or answered with a server error.
  unavailable,

  /// Sony answered, but not the way the unofficial interface used to: it may
  /// have changed.
  unexpected,
}

class PsnException implements Exception {
  const PsnException(this.failure);
  final PsnFailure failure;

  /// Safe to show.
  String get message {
    final l10n = L10n.current;
    return switch (failure) {
      PsnFailure.notConfigured => l10n.psnErrorNotConfigured,
      PsnFailure.signInRejected => l10n.psnErrorSignIn,
      PsnFailure.signInExpired => l10n.psnErrorExpired,
      PsnFailure.listNotShared => l10n.psnErrorListNotShared,
      PsnFailure.rateLimited => l10n.psnErrorRateLimited,
      PsnFailure.unavailable => l10n.psnErrorUnavailable,
      PsnFailure.unexpected => l10n.psnErrorUnexpected,
    };
  }

  @override
  String toString() => 'PsnException: ${failure.name}';
}

/// What Sony hands out when a sign-in succeeds. The access token (about an hour)
/// lives in memory only. The refresh token, which lets the phone sign in again
/// without the member typing anything, is kept by [PsnDevice] in the phone's
/// encrypted storage and nowhere else.
class PsnTokens {
  const PsnTokens({required this.accessToken, this.refreshToken, this.refreshExpiresAt});
  final String accessToken;
  final String? refreshToken;
  final DateTime? refreshExpiresAt;
}

/// A game from the member's PlayStation play history (`gamelist/v2`): what they
/// played, for how long, and when last.
class PsnPlayedGame {
  const PsnPlayedGame({
    required this.name,
    required this.category,
    required this.playTime,
    required this.lastPlayed,
  });

  final String name;

  /// `ps4_game`, `ps5_native_game`, `pspc_game` or `unknown`.
  final String category;
  final Duration playTime;
  final DateTime? lastPlayed;
}

/// A game from the member's trophy list (`trophy/v1`): the trophies it has and
/// how many of them the member earned.
class PsnTrophyTitle {
  const PsnTrophyTitle({
    required this.name,
    required this.platform,
    required this.earned,
    required this.total,
    required this.platinumEarned,
    required this.lastUpdated,
    this.npCommunicationId = '',
    this.npServiceName = 'trophy',
    this.earnedByGrade = const TrophyCounts(),
    this.definedByGrade = const TrophyCounts(),
  });

  final String name;

  /// Sony's id of the trophy set (`NPWR12345_00`), and which of its two trophy
  /// services holds it (`trophy` for PS3, PS4 and Vita, `trophy2` for PS5): what
  /// the list of the set's trophies is asked for with. Empty: not known.
  final String npCommunicationId;
  final String npServiceName;

  /// [earned] and [total] by grade, as the overview gives them.
  final TrophyCounts earnedByGrade;
  final TrophyCounts definedByGrade;

  /// `PS5`, `PS4`, `PS3`, `PSVITA`, or several joined by commas for a set shared
  /// between consoles (`PS4,PSVITA`).
  final String platform;

  /// Trophies earned, all grades together.
  final int earned;

  /// Trophies the game has, all grades together.
  final int total;
  final bool platinumEarned;
  final DateTime? lastUpdated;
}

/// Sony's PlayStation Network the way the open-source libraries (`psn-api`,
/// `PSNAWP`) reach it: PlayStation's own phone app signs in with a fixed OAuth
/// client, and this does the same, so Sony treats it as that app. Sony publishes
/// no such interface for other apps, documents none of it, and its terms forbid
/// automated access to PlayStation Network: an import through here is unofficial
/// and can stop working, or be acted on, at any time. Everything PlayStation lives
/// under `lib/services/playstation/` and `lib/screens/settings/psn_import.dart`
/// so it can be taken out whole.
///
/// The client is the `Basic` credential of that app (`client id:secret` in
/// base64), given to the build with `--dart-define=PSN_CLIENT_BASIC=...` (see
/// `AppConfig.psnClientBasic`); it is not kept in the source.
class PsnClient {
  PsnClient({
    required String clientBasic,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.pace = const Duration(milliseconds: 700),
    this.language,
    Random? random,
  }) : _client = client ?? http.Client(),
       _random = random ?? Random(),
       _basic = clientBasic.trim() {
    if (!_looksLikeClient(_basic)) throw const PsnException(PsnFailure.notConfigured);
  }

  final http.Client _client;
  final String _basic;
  final Duration timeout;

  /// The least time between two requests to Sony, so a long import reads at the
  /// pace of a person scrolling the PlayStation app rather than in a burst. Each
  /// gap is stretched by a random share of up to [paceSpread] of it (700 ms becomes
  /// 0.7 to 1.3 s, a second on average), as people do not tap on the beat. Zero:
  /// no wait at all, for tests.
  final Duration pace;
  static const paceSpread = 0.85;
  final Random _random;

  /// The language trophy names and descriptions are asked for in (`en-US`);
  /// null: the account's own.
  final String? language;

  DateTime? _lastRequest;

  /// What this client has asked of Sony and been answered with, for the debug log.
  final PsnTraffic traffic = PsnTraffic();

  static const _authBase = 'https://ca.account.sony.com/api/authz/v3/oauth';
  static const _trophyApi = 'https://m.np.playstation.com/api/trophy/v1';
  static const _trophyBase = '$_trophyApi/users/me/trophyTitles';
  static const _gamesBase = 'https://m.np.playstation.com/api/gamelist/v2/users/me/titles';

  /// Where Sony's sign-in sends the browser when it is done: a link of the
  /// PlayStation phone app, not a page. The sign-in screen catches it before it
  /// opens and reads the `code` from it.
  static const redirectUri = 'com.scee.psxandroid.scecompcall://redirect';
  static const _scope = 'psn:mobile.v2.core psn:clientapp';

  /// Pages are read this many titles at a time, and never more than [_maxPages].
  static const _gamesPage = 200;
  static const _trophyPage = 400;
  static const _trophyListPage = 200;
  static const _maxPages = 25;

  /// The sign-in client id, from the credential.
  String get clientId => utf8.decode(base64.decode(_basic)).split(':').first;

  /// Sony's sign-in page, which asks for the member's PlayStation account and
  /// ends at [redirectUri] with a one-time `code`.
  Uri get signInUri {
    String q(String s) => Uri.encodeComponent(s);
    return Uri.parse(
      '$_authBase/authorize?access_type=offline'
      '&client_id=${q(clientId)}'
      '&redirect_uri=${q(redirectUri)}'
      '&response_type=code'
      '&scope=${q(_scope)}',
    );
  }

  /// Whether [url] is where the sign-in ends ([redirectUri]).
  static bool isRedirect(String url) => url.startsWith('$redirectUri/') || url == redirectUri || url.startsWith('$redirectUri?');

  /// The one-time code Sony's sign-in ended with, or null when [url] is not that
  /// (or carries none).
  static String? codeFromRedirect(String url) {
    if (!isRedirect(url)) return null;
    final code = Uri.tryParse(url)?.queryParameters['code'];
    return code == null || code.isEmpty ? null : code;
  }

  /// Swaps the sign-in's one-time [code] for an access token.
  Future<PsnTokens> exchangeCode(String code) => _token('token exchange', {
    'code': code,
    'redirect_uri': redirectUri,
    'grant_type': 'authorization_code',
    'token_format': 'jwt',
  });

  /// Signs in again with the [refreshToken] an earlier sign-in left, without the
  /// member's password. [PsnFailure.signInRejected] when Sony no longer accepts it
  /// (it lasts about two months, and ends when the member changes their password).
  Future<PsnTokens> refresh(String refreshToken) => _token('token refresh', {
    'refresh_token': refreshToken,
    'grant_type': 'refresh_token',
    'token_format': 'jwt',
    'scope': _scope,
  });

  Future<PsnTokens> _token(String what, Map<String, String> form) async {
    await _pause();
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_authBase/token'),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              'Authorization': 'Basic $_basic',
            },
            body: form,
          )
          .timeout(timeout);
    } on Exception catch (e) {
      _log('$what failed before an answer: ${e.runtimeType}');
      throw const PsnException(PsnFailure.unavailable);
    }
    traffic.note(response.statusCode, response.bodyBytes.length);
    _log('$what -> HTTP ${response.statusCode}');
    if (response.statusCode >= 500) throw const PsnException(PsnFailure.unavailable);
    if (response.statusCode == 429) throw const PsnException(PsnFailure.rateLimited);
    final body = _json(response.body);
    final token = body is Map ? body['access_token'] : null;
    if (body is! Map || response.statusCode != 200 || token is! String || token.isEmpty) {
      if (body is Map) _log('$what refused: ${_reason(body)}');
      throw const PsnException(PsnFailure.signInRejected);
    }
    final refresh = body['refresh_token'];
    final lasts = _int(body['refresh_token_expires_in']);
    return PsnTokens(
      accessToken: token,
      refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
      refreshExpiresAt: lasts == null ? null : DateTime.now().add(Duration(seconds: lasts)),
    );
  }

  /// Waits until [pace], and a random share more, has passed since the last request.
  Future<void> _pause() async {
    final last = _lastRequest;
    if (last != null) {
      final gap = pace + Duration(microseconds: (pace.inMicroseconds * paceSpread * _random.nextDouble()).round());
      final wait = gap - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRequest = DateTime.now();
  }

  /// Everything in the member's play history. Throws [PsnException].
  Future<List<PsnPlayedGame>> playedGames(PsnTokens tokens) async {
    final games = <PsnPlayedGame>[];
    var offset = 0;
    for (var page = 0; page < _maxPages; page++) {
      final body = await _get('$_gamesBase?limit=$_gamesPage&offset=$offset', tokens);
      final titles = body['titles'];
      if (titles is! List) {
        // An account with no play history answers an empty page.
        if (page == 0 && body.isEmpty) return games;
        throw const PsnException(PsnFailure.unexpected);
      }
      for (final t in titles) {
        if (t is Map) {
          final game = _playedGame(t);
          if (game != null) games.add(game);
        }
      }
      final next = _int(body['nextOffset']);
      if (titles.isEmpty || next == null || next <= offset) break;
      offset = next;
    }
    _log('play history: ${games.length} games');
    return games;
  }

  /// Every game in the member's trophy list. Throws [PsnException].
  Future<List<PsnTrophyTitle>> trophyTitles(PsnTokens tokens) async {
    final titles = <PsnTrophyTitle>[];
    var offset = 0;
    for (var page = 0; page < _maxPages; page++) {
      final body = await _get('$_trophyBase?limit=$_trophyPage&offset=$offset', tokens);
      final list = body['trophyTitles'];
      if (list is! List) {
        if (page == 0 && body.isEmpty) return titles;
        throw const PsnException(PsnFailure.unexpected);
      }
      for (final t in list) {
        if (t is Map) {
          final title = _trophyTitle(t);
          if (title != null) titles.add(title);
        }
      }
      final next = _int(body['nextOffset']);
      if (list.isEmpty || next == null || next <= offset) break;
      offset = next;
    }
    _log('trophy list: ${titles.length} games');
    return titles;
  }

  /// The trophies of one game ([title]'s set): what each is called and asks for,
  /// its icon and grade, and whether and when the member earned it. Two requests:
  /// the set's definitions, and the member's own progress in it. Throws
  /// [PsnException].
  Future<List<Trophy>> trophiesOf(PsnTokens tokens, PsnTrophyTitle title) async {
    final id = Uri.encodeComponent(title.npCommunicationId);
    final service = Uri.encodeQueryComponent(title.npServiceName);
    final defined = await _trophyList('$_trophyApi/npCommunicationIds/$id/trophyGroups/all/trophies', service, tokens);
    final mine = await _trophyList('$_trophyApi/users/me/npCommunicationIds/$id/trophyGroups/all/trophies', service, tokens);
    final progress = <int, Map<dynamic, dynamic>>{};
    for (final t in mine) {
      final trophyId = _int(t['trophyId']);
      if (trophyId != null) progress[trophyId] = t;
    }
    final trophies = <Trophy>[];
    for (final t in defined) {
      final trophyId = _int(t['trophyId']);
      final grade = TrophyGrade.fromCode(t['trophyType']);
      final name = t['trophyName'];
      if (trophyId == null || grade == null || name is! String) continue;
      final p = progress[trophyId];
      final detail = t['trophyDetail'];
      final icon = t['trophyIconUrl'];
      final at = p?['earnedDateTime'];
      final rate = p?['trophyEarnedRate'] ?? t['trophyEarnedRate'];
      trophies.add(
        Trophy(
          id: trophyId,
          grade: grade,
          name: name.trim(),
          detail: detail is String ? detail.trim() : '',
          iconUrl: icon is String && icon.startsWith('https://') ? icon : null,
          earned: p?['earned'] == true,
          earnedAt: at is String ? DateTime.tryParse(at) : null,
          rarity: _int(p?['trophyRare'] ?? t['trophyRare']),
          earnedRate: rate is String ? double.tryParse(rate) : (rate is num ? rate.toDouble() : null),
          hidden: t['trophyHidden'] == true,
        ),
      );
    }
    trophies.sort((a, b) => a.id.compareTo(b.id));
    _log('trophy set: ${trophies.length} trophies');
    return trophies;
  }

  /// Every trophy object of one list request, following its pages.
  Future<List<Map<dynamic, dynamic>>> _trophyList(String url, String service, PsnTokens tokens) async {
    final all = <Map<dynamic, dynamic>>[];
    var offset = 0;
    for (var page = 0; page < _maxPages; page++) {
      final body = await _get('$url?npServiceName=$service&limit=$_trophyListPage&offset=$offset', tokens);
      final list = body['trophies'];
      if (list is! List) throw const PsnException(PsnFailure.unexpected);
      for (final t in list) {
        if (t is Map) all.add(t);
      }
      final next = _int(body['nextOffset']);
      if (list.isEmpty || next == null || next <= offset) break;
      offset = next;
    }
    return all;
  }

  void close() => _client.close();

  /// What happened, for the debug console of a build run from the command line:
  /// the step, an HTTP status, a count. Never a code, a token, a query or a name.
  static void _log(String message) {
    if (kDebugMode) debugPrint('PSN: $message');
  }

  /// [url] without its query: where a request went, safe to log.
  static String _where(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '?';
    final path = uri.path.length > 60 ? '${uri.path.substring(0, 60)}...' : uri.path;
    return '${uri.host}$path';
  }

  /// [url] as [_where] writes it, for the sign-in screen's log.
  static String describe(String url) => _where(url);

  Future<Map<dynamic, dynamic>> _get(String url, PsnTokens tokens) async {
    await _pause();
    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer ${tokens.accessToken}',
              'Accept-Language': ?language,
            },
          )
          .timeout(timeout);
    } on Exception catch (e) {
      _log('GET ${_where(url)} failed before an answer: ${e.runtimeType}');
      throw const PsnException(PsnFailure.unavailable);
    }
    final status = response.statusCode;
    traffic.note(status, response.bodyBytes.length);
    _log('GET ${_where(url)} -> HTTP $status');
    if (status != 200) {
      final body = _json(response.body);
      if (body is Map) _log('  reason: ${_reason(body)}');
    }
    if (status == 401) throw const PsnException(PsnFailure.signInExpired);
    if (status == 403) throw const PsnException(PsnFailure.listNotShared);
    if (status == 429) throw const PsnException(PsnFailure.rateLimited);
    if (status >= 500) throw const PsnException(PsnFailure.unavailable);
    final body = _json(response.body);
    // Sony can also refuse with an `error` object instead of the list.
    if (body is Map && body['error'] != null) {
      _log('  answered with an error object: ${_reason(body)}');
      throw const PsnException(PsnFailure.unexpected);
    }
    if (status != 200 || body is! Map) {
      _log('  not a list: status $status, ${body.runtimeType}');
      throw const PsnException(PsnFailure.unexpected);
    }
    return body;
  }

  /// The words Sony gave for a refusal (`error` / `error_description` / `message`),
  /// cut short: what a person needs to see in the log, never a token.
  static String _reason(Map<dynamic, dynamic> body) {
    final error = body['error'];
    final parts = <Object?>[
      if (error is Map) error['message'] else error,
      body['error_description'],
      body['message'],
    ].whereType<String>().where((p) => p.isNotEmpty);
    final text = parts.join(' / ');
    return text.isEmpty ? 'no words' : (text.length > 120 ? '${text.substring(0, 120)}...' : text);
  }

  static Object? _json(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  static bool _looksLikeClient(String basic) {
    if (basic.isEmpty) return false;
    try {
      final decoded = utf8.decode(base64.decode(basic));
      final colon = decoded.indexOf(':');
      return colon > 0 && colon < decoded.length - 1;
    } on FormatException {
      return false;
    }
  }

  static int? _int(Object? value) => value is num ? value.toInt() : null;

  static PsnPlayedGame? _playedGame(Map<dynamic, dynamic> t) {
    final name = t['name'] ?? t['localizedName'];
    if (name is! String || name.trim().isEmpty) return null;
    final category = t['category'];
    final last = t['lastPlayedDateTime'];
    return PsnPlayedGame(
      name: name.trim(),
      category: category is String ? category : 'unknown',
      playTime: parseIsoDuration(t['playDuration']),
      lastPlayed: last is String ? DateTime.tryParse(last) : null,
    );
  }

  static PsnTrophyTitle? _trophyTitle(Map<dynamic, dynamic> t) {
    final name = t['trophyTitleName'];
    if (name is! String || name.trim().isEmpty) return null;
    final defined = t['definedTrophies'];
    final earned = t['earnedTrophies'];
    if (defined is! Map || earned is! Map) return null;
    int sum(Map<dynamic, dynamic> counts) => [
      for (final grade in const ['bronze', 'silver', 'gold', 'platinum']) _int(counts[grade]) ?? 0,
    ].fold(0, (a, b) => a + b);
    final updated = t['lastUpdatedDateTime'];
    final platform = t['trophyTitlePlatform'];
    final set = t['npCommunicationId'];
    final service = t['npServiceName'];
    TrophyCounts byGrade(Map<dynamic, dynamic> counts) => TrophyCounts(
      bronze: _int(counts['bronze']) ?? 0,
      silver: _int(counts['silver']) ?? 0,
      gold: _int(counts['gold']) ?? 0,
      platinum: _int(counts['platinum']) ?? 0,
    );
    return PsnTrophyTitle(
      earnedByGrade: byGrade(earned),
      definedByGrade: byGrade(defined),
      name: name.trim(),
      npCommunicationId: set is String ? set : '',
      npServiceName: service is String && service.isNotEmpty ? service : 'trophy',
      platform: platform is String ? platform : '',
      earned: sum(earned),
      total: sum(defined),
      platinumEarned: (_int(earned['platinum']) ?? 0) > 0,
      lastUpdated: updated is String ? DateTime.tryParse(updated) : null,
    );
  }
}

/// How many requests a [PsnClient] made, how many bytes came back (the body as
/// decoded, so a little less than on the wire) and with which statuses, since it
/// was made. A request that got no answer counts for nothing.
class PsnTraffic {
  int requests = 0;
  int bytesReceived = 0;
  final Map<int, int> statuses = {};
  final Stopwatch _clock = Stopwatch()..start();

  void note(int status, int bytes) {
    requests++;
    bytesReceived += bytes;
    statuses[status] = (statuses[status] ?? 0) + 1;
  }

  /// "19 requests, 412 KB received in 21 s, statuses {200: 19}".
  String describe() {
    final kb = (bytesReceived / 1024).round();
    return '$requests requests, $kb KB received in ${_clock.elapsed.inSeconds} s, statuses $statuses';
  }
}

/// A length of time as Sony writes it ("PT228H56M33S", "P1DT2H"); zero for
/// anything else.
Duration parseIsoDuration(Object? value) {
  if (value is! String) return Duration.zero;
  final match = RegExp(
    r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
  ).firstMatch(value.trim());
  if (match == null) return Duration.zero;
  int part(int i) => int.tryParse(match.group(i) ?? '') ?? 0;
  final seconds = double.tryParse(match.group(4) ?? '') ?? 0;
  return Duration(
    days: part(1),
    hours: part(2),
    minutes: part(3),
    milliseconds: (seconds * 1000).round(),
  );
}
