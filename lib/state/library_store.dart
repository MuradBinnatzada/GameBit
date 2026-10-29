import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/data/db_schema.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/achievement.dart';
import 'package:checkpoint/models/completion_time.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_details.dart';
import 'package:checkpoint/models/library_stats.dart';
import 'package:checkpoint/models/limits.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/services/connection_failure.dart';
import 'package:checkpoint/services/connectivity_service.dart';
import 'package:checkpoint/services/content_refusal.dart';
import 'package:checkpoint/services/game_api_service.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/services/pending_edits.dart';
import 'package:checkpoint/services/sync_failure.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/catalog_backfill.dart';
import 'package:checkpoint/state/profile_store.dart';

part 'library_store/steam_sync.dart';
part 'library_store/play_sessions.dart';
part 'library_store/library_editing.dart';
part 'library_store/pending_edits.dart';

/// The signed-in user's games and play sessions, plus the catalog slice behind
/// the Home carousels. Reloads when the account changes.
///
/// Opening the app paints the copy saved on the device first ([LocalCache]), then
/// refreshes from the server. When the server can't be reached the saved copy
/// stays on screen and [isOffline] turns on; only an account with nothing saved
/// gets [loadError].
///
/// Edits made while the server can't be reached are kept on the device
/// ([PendingEdits]), shown as if saved, and sent when the connection is back
/// ([flushPending]). An edit the server refuses is reverted instead.
/// How the last Steam sync ended.
enum SyncStatus {
  /// No sync has run since sign-in.
  idle,

  /// Everything was imported.
  synced,

  /// Steam or IGDB was rate limited or down, so the sync is incomplete or did
  /// not run. Trying again later is expected to work.
  delayed,

  /// The sync could not run and waiting will not fix it (a private Steam
  /// profile, no Steam ID saved, a server problem).
  failed,
}

/// The signed-in user's library and play sessions (see the top of this file).
///
/// Its methods are in this file and in the extensions of the files in
/// `library_store/`, one per concern (editing the library, play sessions, the
/// Steam sync, edits kept for later): they share this class's state, so they are
/// extensions of it in the same library. Import this file to call them.
class LibraryStore extends ChangeNotifier {
  LibraryStore({
    required this._repository,
    required this._auth,
    required this._profile,
    LocalCache? cache,
    PendingEditsStorage? pendingStorage,
    this._connectivity,
    this._externalGame,
    this._onCleared,
    this._onCatalogFilled,
    this._onSteamSynced,
    this._onCompletionTimeSaved,
    this._onReviewSaved,
    GameApiService? apiService,
  }) : _cache = cache ?? LocalCache(),
       _pendingStorage = pendingStorage ?? PendingEditsStorage(),
       _apiService = apiService ?? GameApiService();

  final CheckpointRepository _repository;
  final AuthStore _auth;
  final ProfileStore _profile;
  final LocalCache _cache;
  final PendingEditsStorage _pendingStorage;
  final ConnectivityService? _connectivity;

  /// Finds a game that isn't in the library or the catalog slice, e.g. a search
  /// result being opened or added.
  final Game? Function(String id)? _externalGame;

  /// Called with the user's id after [clearLibrary] emptied their library, so
  /// what other stores hold about it (their achievements) can be dropped too.
  final void Function(String userId)? _onCleared;

  /// Called when the server filled in catalog rows from IGDB (a game's screen was
  /// opened, a backfill batch landed): what it saved there (themes, modes,
  /// developers...) is not part of the library, so whoever reads it separately
  /// learns it may have changed.
  final void Function()? _onCatalogFilled;

  /// Called with the user's id after a Steam sync, which also counted their
  /// achievements again, so whoever holds those counts reads them again.
  final void Function(String userId)? _onSteamSynced;

  /// Called with a game's id once the member's completion time for it (or its
  /// removal) reached the server, so whoever holds the members' times for the
  /// game reads them again.
  final void Function(String gameId)? _onCompletionTimeSaved;

  /// Called with a game's id after the member's review or rating of it was
  /// saved (or, with no connection, kept for later), so whoever holds what the
  /// members think of the game reads it again.
  final void Function(String gameId)? _onReviewSaved;

  final GameApiService _apiService;

  /// Fills in, in the background, the catalog rows of library games that IGDB
  /// never filled in (exact platforms, attributes), after each load.
  late final CatalogBackfill _backfill = CatalogBackfill(
    repository: _repository,
    apiService: _apiService,
    onUpdates: applyCatalogUpdates,
  );

  /// Start [_backfill] once the next library re-read has landed (after a sync).
  bool _backfillAfterRefresh = false;

  User? _user;
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<bool>? _connectivitySubscription;
  final List<StreamSubscription<dynamic>> _dataSubscriptions = [];

  /// Edits the server hasn't accepted yet, for the account in [_pendingFor].
  PendingEdits _pending = PendingEdits();
  String? _pendingFor;
  bool _flushing = false;

  /// Bumped by every account event, so a load that was overtaken (another
  /// account signed in, or a retry started) can tell and stop.
  int _loadSeq = 0;

  /// A small, fixed-size slice of the catalog for the Home carousels. This is
  /// not the whole `games` table: that is no longer downloaded (see
  /// [CheckpointRepository.fetchPopularGames]).
  List<Game> _popularGames = const [];

  /// Ids the server is known to have in `games`: everything it returned for the
  /// library or the popular list (the saved copy included: it only ever holds
  /// what the server returned), plus rows this session inserted. Deliberately
  /// not fed from local edits ([_replaceGame] puts a game in the library before
  /// it is saved), so it only ever holds confirmed rows.
  final Set<String> _gamesInDb = {};

  /// Library + popular games, for [maybeGame] and the Quick Log picker.
  List<Game> _games = const [];
  List<Game> _libraryGames = const [];
  List<LogEntry> _logs = const [];

  /// A load is running.
  bool _loading = true;

  /// There is a library on screen: fetched, or restored from the saved copy.
  bool _loaded = false;
  bool _offline = false;
  DateTime? _syncedAt;
  String? _loadError;
  String? _notice;

  /// Counts local edits (anything that goes through [_saveUserGame], and
  /// deletes). A fetch that was started before an edit can come back without it.
  int _editSeq = 0;

  /// No library on screen yet and one is being loaded: show a spinner. With a
  /// saved copy on screen the refresh happens quietly behind it.
  bool get isLoading => _loading && !_loaded;

  /// A refresh is running behind a library that is already on screen.
  bool get isRefreshing => _loading && _loaded;

  /// The last attempt to reach the server failed, so the library on screen is the
  /// copy saved on this device (or the last one fetched). Clears on the next
  /// successful fetch.
  bool get isOffline => _offline;

  /// When the library on screen was last fetched from (or saved by) the server.
  DateTime? get lastSyncedAt => _syncedAt;

  /// Why nothing could be loaded; set only when there is no library to show.
  String? get loadError => _loadError;

  /// A message about something that just went wrong with an edit (it could not be
  /// saved). The app shell shows it once and calls [clearNotice].
  String? get notice => _notice;

  void clearNotice() => _notice = null;

  /// How many edits are waiting for the server (see [flushPending]).
  int get pendingCount => _pending.count;

  /// For the extensions in `library_store/`: `notifyListeners` is protected.
  void _notify() => notifyListeners();

  void _setNotice(String message) {
    _notice = message;
    notifyListeners();
  }

  Future<void> initialize() async {
    _authSubscription = _auth.userChanges.listen((user) {
      unawaited(_onUser(user));
    });
    _connectivitySubscription = _connectivity?.onlineChanges.listen(_onOnline);
    await _onUser(_auth.user, force: true);
  }

  void _onOnline(bool online) {
    if (_user == null) return;
    if (!online) {
      if (_loaded && !_offline) {
        _offline = true;
        notifyListeners();
      }
      return;
    }
    if (_offline ||
        _loadError != null ||
        _pending.isNotEmpty ||
        _auth.isSessionPending) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    unawaited(_connectivitySubscription?.cancel());
    unawaited(_cancelDataSubscriptions());
    _refreshDebounce?.cancel();
    _backfill.stop();
    super.dispose();
  }

  /// Loads everything again for the signed-in user (the Retry buttons, and the
  /// connection coming back). When the session is still waiting to be restored,
  /// restoring it comes first; its auth event then does the loading.
  Future<void> refresh() async {
    if (_auth.isSessionPending && await _auth.restoreSession()) return;
    await _onUser(_user, force: true);
  }

  /// A library fetched this recently is current enough for a repeat auth event
  /// (resuming the app, a token refresh) not to fetch it all again.
  static const _freshFor = Duration(minutes: 15);

  Future<void> _onUser(User? user, {bool force = false}) async {
    if (!force &&
        user != null &&
        user.id == _user?.id &&
        _loaded &&
        !_loading &&
        !_offline &&
        _loadError == null &&
        !_auth.isSessionPending &&
        _dataSubscriptions.isNotEmpty &&
        _syncedAt != null &&
        DateTime.now().difference(_syncedAt!) < _freshFor) {
      return;
    }
    final seq = ++_loadSeq;
    // Token refreshes and pull-to-retry re-enter here for the same user; their
    // already-loaded achievements stay valid, a different user's do not.
    final previous = _user;
    final sameUser = user != null && user.id == previous?.id;
    _user = user;
    if (!sameUser) {
      _refreshDebounce?.cancel();
      _backfill.stop();
      _backfillAfterRefresh = false;
      _libraryGames = const [];
      _logs = const [];
      _games = List.unmodifiable(_mergeGames(_popularGames, const []));
      _loaded = false;
      _offline = false;
      _syncedAt = null;
      _pending = PendingEdits();
      _pendingFor = null;
      _syncStatus = SyncStatus.idle;
      _syncFailure = null;
      // The previous account's saved copy goes too (it stays valid only while
      // that account stays signed in).
      if (previous != null) unawaited(_cache.clearAccount(previous.id));
    }
    _loading = true;
    _loadError = null;
    notifyListeners();

    await _cancelDataSubscriptions();
    if (seq != _loadSeq) return;

    try {
      await _hydratePopular(seq);
      if (user == null) {
        // Signed out: only the Home carousels to load, and nothing to subscribe to.
        final popular = await _fetchPopularGamesSafe();
        if (seq != _loadSeq) return;
        _popularGames = popular;
        _games = List.unmodifiable(popular);
      } else {
        // Keyed on what is on screen, not on "a different user": a load that was
        // overtaken by a second auth event never got to read the saved copy, and
        // the load that overtook it sees the same user.
        if (_pendingFor != user.id) {
          final saved = await _pendingStorage.read(user.id);
          if (seq != _loadSeq) return;
          _pending = saved;
          _pendingFor = user.id;
        }
        if (!_loaded) await _hydrateFromCache(user.id, seq);
        if (seq != _loadSeq) return;
        // No live session (the app started offline): the saved copy is all
        // there is until the session is restored.
        if (_auth.isSessionPending) throw const SessionPending();
        await _refreshSignedInData(user, seq, keepLoadedAchievements: sameUser);
        if (seq != _loadSeq) return;
        _startSubscriptions(user);
      }
      _offline = false;
    } catch (e, st) {
      if (seq != _loadSeq) return;
      debugPrint('Supabase load failed: $e\n$st');
      if (_loaded) {
        // The saved copy (or the last fetch) is still on screen: say so, don't
        // replace it with an error.
        _offline = true;
      } else {
        _loadError =
            L10n.current.libraryLoadFailed;
      }
    } finally {
      if (seq == _loadSeq) {
        _loading = false;
        notifyListeners();
        if (!_offline && _loadError == null) {
          // Whatever was queued while the server was out of reach goes now.
          unawaited(flushPending());
          // Games whose catalog row IGDB never filled in get it, quietly.
          if (user != null) _backfill.start(user.id);
        }
      }
    }
  }

  /// Puts the saved Home carousel games on screen while the network answers.
  Future<void> _hydratePopular(int seq) async {
    if (_popularGames.isNotEmpty) return;
    final saved = await _cache.readPopular();
    if (saved == null || seq != _loadSeq || _popularGames.isNotEmpty) return;
    _popularGames = saved.value;
    _gamesInDb.addAll(saved.value.map((g) => g.id));
    _games = List.unmodifiable(_mergeGames(_popularGames, _libraryGames));
    notifyListeners();
  }

  /// Puts the library saved on this device on screen while the network answers.
  Future<void> _hydrateFromCache(String userId, int seq) async {
    final library = await _cache.readLibrary(userId);
    final logs = await _cache.readLogs(userId);
    if (seq != _loadSeq) return;
    if (library == null && logs == null) return;
    if (library != null) {
      _applyUserGames(_withPendingEdits(library.value));
      _syncedAt = library.savedAt;
      _loaded = true;
    }
    if (logs != null) _logs = List.unmodifiable(_withPendingLogs(logs.value));
    notifyListeners();
  }

  Future<void> _refreshSignedInData(
    User user,
    int seq, {
    bool keepLoadedAchievements = false,
  }) async {
    final editsAtStart = _editSeq;
    // Three independent reads, started together, so launch waits for the slowest
    // one instead of the sum of all of them. Nothing is assigned until every
    // read has finished, so a failure leaves the previous state untouched. (If
    // any read fails, the record `.wait` throws a ParallelWaitError once all of
    // them are done; the caller already treats any error as "load failed".)
    final (fetched, logs, popular) = await (
      _repository.fetchUserGames(user.id),
      _repository.fetchLogEntries(user.id),
      _fetchPopularGamesSafe(),
    ).wait;
    if (seq != _loadSeq) return;

    _popularGames = popular;
    final shown = _withPendingEdits(fetched);
    _applyUserGames(
      keepLoadedAchievements ? _withLoadedAchievements(shown) : shown,
    );
    _logs = List.unmodifiable(_withPendingLogs(logs));
    _loaded = true;
    _offline = false;
    _syncedAt = DateTime.now();
    unawaited(_cache.writeLibrary(user.id, fetched));
    unawaited(_cache.writeLogs(user.id, logs));

    // The saved copy let the user edit games while this was still loading. If one
    // of those edits landed after the server was read, the data above predates
    // it: fetch again once the writes have settled.
    if (_editSeq != editsAtStart || _pendingSaves > 0) {
      unawaited(_refreshLibrary(user));
    }
  }

  /// Makes [userGames] the library, records their ids as known to exist in
  /// `games`, and rebuilds the combined [_games] list.
  void _applyUserGames(List<Game> userGames) {
    _libraryGames = List.unmodifiable(userGames);
    _gamesInDb.addAll(userGames.map((g) => g.id));
    _games = List.unmodifiable(_mergeGames(_popularGames, userGames));
  }

  /// The Home carousels are a nicety, so a failure here must not fail the whole
  /// load. Keeps whatever was loaded before and logs the error.
  Future<List<Game>> _fetchPopularGamesSafe() async {
    try {
      final games = await _repository.fetchPopularGames();
      _gamesInDb.addAll(games.map((g) => g.id));
      unawaited(_cache.writePopular(games));
      return games;
    } catch (e, st) {
      debugPrint('Popular games load failed: $e\n$st');
      return _popularGames;
    }
  }

  /// Puts the exact platforms and genres IGDB gave for [gameId] on the game, in the
  /// library and in the combined list, so every screen and picker shows them, not
  /// only the one that loaded them. The server saves them on the catalog row too,
  /// so the next library fetch holds them. Nothing changes (and nothing is
  /// notified) when IGDB had none, or when they are what the game already has.
  void applyDetails(String gameId, GameDetails details) {
    _applyCatalog({gameId: details});
    _onCatalogFilled?.call();
  }

  /// [applyDetails] for what the catalog backfill filled in: each game's exact
  /// platforms and genres, by IGDB id, with one notification for the batch.
  void applyCatalogUpdates(List<GameDetails> updates) {
    final byIgdbId = {for (final details in updates) details.igdbId: details};
    _applyCatalog({for (final g in _games) g.id: ?byIgdbId[g.igdbId]});
    if (updates.isNotEmpty) _onCatalogFilled?.call();
  }

  /// Puts the platforms and genres of [byGameId] on those games (see
  /// [applyDetails]); notifies once, when anything changed.
  void _applyCatalog(Map<String, GameDetails> byGameId) {
    if (byGameId.isEmpty) return;
    var changed = false;
    Game patch(Game g) {
      final details = byGameId[g.id];
      if (details == null) return g;
      final platforms =
          details.platforms.isEmpty ||
              listEquals(details.platforms, g.platforms)
          ? null
          : details.platforms;
      final genres =
          details.genres.isEmpty || listEquals(details.genres, g.genres)
          ? null
          : details.genres;
      if (platforms == null && genres == null) return g;
      changed = true;
      return g.copyWith(platforms: platforms, genres: genres);
    }

    final library = [for (final g in _libraryGames) patch(g)];
    final games = [for (final g in _games) patch(g)];
    if (!changed) return;
    _libraryGames = List.unmodifiable(library);
    _games = List.unmodifiable(games);
    notifyListeners();
  }

  /// [CheckpointRepository.fetchUserGames] doesn't return achievements, so a
  /// freshly fetched library has `achievements == null` everywhere. Copy over
  /// whatever is already loaded in memory, otherwise every realtime refresh
  /// (a favourite toggled, a rating changed...) would wipe them. Read from
  /// [_libraryGames] at call time so achievements that arrive while a fetch is
  /// in flight are kept too.
  List<Game> _withLoadedAchievements(List<Game> fetched) {
    final loaded = <String, List<Achievement>>{
      for (final g in _libraryGames)
        if (g.achievements != null) g.id: g.achievements!,
    };
    if (loaded.isEmpty) return fetched;
    return [
      for (final g in fetched)
        loaded.containsKey(g.id)
            ? g.copyWith(achievements: loaded[g.id])
            : g,
    ];
  }

  List<Game> _mergeGames(List<Game> popular, List<Game> userGames) {
    final byId = <String, Game>{for (final game in popular) game.id: game};
    for (final game in userGames) {
      byId[game.id] = game;
    }
    final merged = byId.values.toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    return merged;
  }

  void _startSubscriptions(User user) {
    void onError(Object e, StackTrace st) =>
        debugPrint('Library realtime stream failed: $e\n$st');
    _dataSubscriptions
      ..add(
        _repository
            .watchUserGames(user.id)
            .listen((_) => unawaited(_refreshLibrary(user)), onError: onError),
      )
      ..add(
        _repository
            .watchLogEntries(user.id)
            .listen((_) => unawaited(_refreshLogs(user.id)), onError: onError),
      );
  }

  Future<void> _cancelDataSubscriptions() async {
    for (final subscription in _dataSubscriptions) {
      await subscription.cancel();
    }
    _dataSubscriptions.clear();
  }

  int _pendingSaves = 0;
  bool _refreshQueued = false;
  Timer? _refreshDebounce;

  Future<void> _refreshLibrary(User user) async {
    if (_pendingSaves > 0) {
      _refreshQueued = true; // Pause refresh until local writes finish
      return;
    }

    if (_auth.isSessionPending) return; // nothing to ask the server yet

    // Cancel any waiting refresh, and start a new 300ms countdown.
    // This absorbs "refresh storms" from bulk server inserts into a single UI update.
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final fetched = await _repository.fetchUserGames(user.id);
        if (_user?.id != user.id) return; // signed out or switched while we waited
        _applyUserGames(_withLoadedAchievements(_withPendingEdits(fetched)));
        _loaded = true;
        _offline = false;
        _syncedAt = DateTime.now();
        notifyListeners();
        unawaited(_cache.writeLibrary(user.id, fetched));
        if (_backfillAfterRefresh) {
          _backfillAfterRefresh = false;
          _backfill.start(user.id);
        }
      } catch (e, st) {
        debugPrint('Library refresh failed: $e\n$st');
        if (_user?.id == user.id && _loaded && !_offline) {
          _offline = true;
          notifyListeners();
        }
      }
    });
  }

  Future<void> _refreshLogs(String userId) async {
    try {
      if (_auth.isSessionPending) return;
      final logs = await _repository.fetchLogEntries(userId);
      if (_user?.id != userId) return;
      _logs = List.unmodifiable(_withPendingLogs(logs));
      notifyListeners();
      unawaited(_cache.writeLogs(userId, logs));
    } catch (e, st) {
      debugPrint('Log refresh failed: $e\n$st');
    }
  }

  // ---- Home carousel ----

  /// The games most recently added to the catalog, newest first: what Home shows
  /// when IGDB's popular list isn't there (signed out, still loading, or IGDB
  /// can't be reached).
  List<Game> get recentlyAdded => _popularGames.take(10).toList();

  // ---- Steam ----

  bool _isSyncing = false;
  SyncStatus _syncStatus = SyncStatus.idle;
  SyncFailure? _syncFailure;

  bool get isSyncing => _isSyncing;

  /// How the last [syncLibrary] ended. The Profile tab shows "Sync Delayed" for
  /// [SyncStatus.delayed].
  SyncStatus get syncStatus => _syncStatus;

  /// Why the last sync is [SyncStatus.delayed] or [SyncStatus.failed]; null
  /// otherwise. [SyncFailure.message] is safe to show.
  SyncFailure? get syncFailure => _syncFailure;

  final Set<String> _achievementsLoading = {};

  // ---- Reading the library ----

  /// The signed-in user's games, in no particular order. Sort and filter them
  /// with [LibraryViewStore.visible].
  List<Game> get libraryGames => _libraryGames;

  /// Library + popular games.
  List<Game> get games => _games;

  Game? maybeGame(String id) {
    for (final g in _libraryGames) {
      if (g.id == id) return g;
    }
    for (final g in _games) {
      if (g.id == id) return g;
    }
    return _externalGame?.call(id);
  }

  Game gameById(String id) => maybeGame(id)!;

  /// Games being played now, most recently played first: Playing, and
  /// completed ones the member still plays.
  List<Game> playingNow() {
    final list = _libraryGames.where((g) => g.isPlaying).toList();
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    list.sort(
      (a, b) =>
          (lastPlayed(b.id) ?? epoch).compareTo(lastPlayed(a.id) ?? epoch),
    );
    return list;
  }

  DateTime? lastPlayed(String gameId) {
    for (final l in _logs) {
      if (l.gameId == gameId) return l.timestamp;
    }
    return null;
  }

  /// Every play session, newest first.
  List<LogEntry> get sessions => _logs;

  List<LogEntry> logsFor(String gameId) =>
      _logs.where((l) => l.gameId == gameId).toList();

  List<LogEntry> recentActivity({int limit = 10}) {
    final seen = <String>{};
    final out = <LogEntry>[];
    for (final l in _logs) {
      if (seen.add(l.gameId)) {
        out.add(l);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  /// Games listed under [s] (see [Game.isListedUnder]): Playing counts the
  /// completed games still being played too.
  int count(GameStatus s) =>
      _libraryGames.where((g) => g.isListedUnder(s)).length;
  double get totalHours =>
      _libraryGames.fold<double>(0, (sum, g) => sum + g.hoursPlayed);

  double get hoursThisWeek {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    return _logs
        .where((l) => l.timestamp.isAfter(cutoff))
        .fold<double>(0, (s, l) => s + l.hours);
  }

  double get averageRating {
    final rated = _libraryGames.where((g) => g.rating > 0).toList();
    if (rated.isEmpty) return 0;
    return rated.fold<double>(0, (s, g) => s + g.rating) / rated.length;
  }

  /// Total hours per platform, based on each game's total playtime (so hours
  /// imported via Steam sync count too, not just manually logged sessions).
  Map<GamePlatform, double> get hoursByPlatform =>
      LibraryStats.hoursByPlatformOf(_libraryGames);

  List<Game> get topRated {
    final rated = _libraryGames.where((g) => g.rating > 0).toList()
      ..sort((a, b) {
        final c = b.rating.compareTo(a.rating);
        return c != 0 ? c : b.hoursPlayed.compareTo(a.hoursPlayed);
      });
    return rated.take(8).toList();
  }

  // ---- Editing the library ----

  // ---- Editing play sessions ----

  /// The library rows being sent now, by game id: each future is done when the
  /// send is, and never fails ([_saveUserGame] handles that).
  final Map<String, Future<void>> _gameSaves = {};

  /// Completed when the last save on its way is done.
  Completer<void>? _saved;

  // ---- Edits waiting for the server ----

}

String _cleanNote(String note) {
  final text = note.trim();
  return text.length <= maxNoteLength ? text : text.substring(0, maxNoteLength);
}

/// [logs] newest first, the order every reader of [_logs] relies on.
List<LogEntry> _newestFirst(List<LogEntry> logs) => List.unmodifiable(
  [...logs]..sort((a, b) => b.timestamp.compareTo(a.timestamp)),
);
