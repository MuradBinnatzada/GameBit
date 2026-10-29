import 'package:flutter/foundation.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_list.dart';
import 'package:checkpoint/models/game_reviews.dart' show MemberReportSubject, ReportReason;
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/services/connection_failure.dart';
import 'package:checkpoint/services/content_refusal.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';

/// The signed-in member's lists of games, the public lists of other members they
/// look at, and lists opened from a link. Held in memory and dropped when the
/// account changes.
///
/// Lists need the server: unlike the library they aren't kept for offline use.
/// An edit shows at once and is put back, with a [notice], when the server
/// refuses it or can't be reached.
class ListsStore extends AccountScopedStore {
  ListsStore({
    required this._repository,
    required AuthStore auth,
    required this._ensureInCatalog,
  }) : super(auth);

  final CheckpointRepository _repository;

  /// Adds a game to the shared catalog if it isn't there yet (a search result
  /// put on a list): list entries point at catalog rows.
  final Future<void> Function(Game game) _ensureInCatalog;

  LoadStatus _status = LoadStatus.idle;
  List<GameList> _lists = const [];
  final Map<String, List<GameList>> _publicLists = {};
  final Map<String, LoadStatus> _publicStatus = {};
  final Map<String, GameList?> _opened = {};
  String? _notice;

  LoadStatus get status => _status;

  /// The member's own lists, the last changed first.
  List<GameList> get lists => _lists;

  /// Something that just went wrong with an edit. The app shell shows it once
  /// and calls [clearNotice].
  String? get notice => _notice;
  void clearNotice() => _notice = null;

  @override
  void resetForAccount() {
    _status = LoadStatus.idle;
    _lists = const [];
    _publicLists.clear();
    _publicStatus.clear();
    _opened.clear();
  }

  /// A list of the member's, one of someone else's that was loaded, or one
  /// opened from a link; null when none of those has it.
  GameList? listById(String id) {
    for (final list in [..._lists, ..._publicLists.values.expand((l) => l)]) {
      if (list.id == id) return list;
    }
    return _opened[id];
  }

  /// The member's lists that hold [gameId].
  List<GameList> listsWith(String gameId) => [
    for (final list in _lists)
      if (list.contains(gameId)) list,
  ];

  /// A game on any list held here, as the catalog knows it: how a game tapped
  /// on a list is found by its screen.
  Game? gameById(String id) {
    for (final list in [..._lists, ..._publicLists.values.expand((l) => l), ..._opened.values.nonNulls]) {
      for (final game in list.games) {
        if (game.id == id) return game;
      }
    }
    return null;
  }

  /// Reads the member's lists. Does nothing when signed out or while a read
  /// runs; once they are here only [force] reads them again.
  Future<void> load({bool force = false}) async {
    final userId = accountId;
    if (userId == null || _status == LoadStatus.loading) return;
    if (_status == LoadStatus.ready && !force) return;
    final epoch = this.epoch;
    if (_status != LoadStatus.ready) {
      _status = LoadStatus.loading;
      notifyIfAlive();
    }
    try {
      final lists = await _repository.fetchLists(userId);
      if (isStale(epoch)) return;
      _lists = List.unmodifiable(lists);
      _status = LoadStatus.ready;
    } catch (e, st) {
      debugPrint('Loading lists failed: $e\n$st');
      if (isStale(epoch)) return;
      if (_status != LoadStatus.ready) _status = LoadStatus.failed;
    }
    notifyIfAlive();
  }

  /// [userId]'s public lists (their private ones are never sent).
  List<GameList> publicListsOf(String userId) => _publicLists[userId] ?? const [];
  LoadStatus publicStatusOf(String userId) => _publicStatus[userId] ?? LoadStatus.idle;

  Future<void> loadPublic(String userId) async {
    if (accountId == null || _publicStatus[userId] == LoadStatus.loading) return;
    final epoch = this.epoch;
    _publicStatus[userId] = LoadStatus.loading;
    notifyIfAlive();
    try {
      final lists = await _repository.fetchLists(userId);
      if (isStale(epoch)) return;
      _publicLists[userId] = List.unmodifiable(lists.where((l) => l.isPublic));
      _publicStatus[userId] = LoadStatus.ready;
    } catch (e, st) {
      debugPrint('Loading public lists failed: $e\n$st');
      if (isStale(epoch)) return;
      _publicStatus[userId] = LoadStatus.failed;
    }
    notifyIfAlive();
  }

  /// Reads one list by id (a shared link). Null afterwards in [listById] means
  /// it doesn't exist or is private.
  Future<void> open(String listId) async {
    if (accountId == null) return;
    final epoch = this.epoch;
    try {
      final list = await _repository.fetchList(listId);
      if (isStale(epoch)) return;
      _opened[listId] = list;
    } catch (e, st) {
      debugPrint('Opening list $listId failed: $e\n$st');
      if (isStale(epoch)) return;
      // A copy already held stays on screen; pull to refresh asks again.
      if (_opened[listId] == null) _opened.remove(listId);
      _setNotice(L10n.current.listOpenFailed);
    }
    notifyIfAlive();
  }

  /// Whether [listId] was asked for by [open] (answered or not).
  bool wasOpened(String listId) => _opened.containsKey(listId);

  /// Makes a list and returns it, or null (with a [notice]) when it couldn't be.
  Future<GameList?> create({
    required String title,
    String description = '',
    bool isPublic = false,
  }) async {
    if (accountId == null) return null;
    if (_lists.length >= GameList.maxLists) {
      _setNotice(L10n.current.listsLimit(GameList.maxLists));
      return null;
    }
    final epoch = this.epoch;
    try {
      final list = await _repository.createList(
        title: title,
        description: description,
        isPublic: isPublic,
      );
      if (isStale(epoch)) return null;
      _lists = List.unmodifiable([list, ..._lists]);
      notifyIfAlive();
      return list;
    } catch (e, st) {
      debugPrint('Creating a list failed: $e\n$st');
      _failed(e);
      return null;
    }
  }

  Future<void> update(
    String listId, {
    required String title,
    required String description,
    required bool isPublic,
  }) async {
    final before = _own(listId);
    if (before == null) return;
    _put(before.copyWith(title: title.trim(), description: description.trim(), isPublic: isPublic));
    await _send(
      () => _repository.updateList(listId, title: title, description: description, isPublic: isPublic),
      undo: () => _put(before),
    );
  }

  /// Reports the public list [listId] of [ownerId] as the signed-in member.
  /// Throws when the report could not be sent.
  Future<void> reportList(String ownerId, String listId, ReportReason reason) =>
      _repository.reportMember(
        userId: ownerId,
        subject: MemberReportSubject.list,
        reason: reason,
        listId: listId,
      );

  Future<void> delete(String listId) async {
    final before = _lists;
    if (_own(listId) == null) return;
    _lists = List.unmodifiable(_lists.where((l) => l.id != listId));
    notifyIfAlive();
    await _send(() => _repository.deleteList(listId), undo: () {
      _lists = before;
      notifyIfAlive();
    });
  }

  /// Puts [game] on the list, at the end, or takes it off when it is there.
  Future<void> toggleGame(String listId, Game game) async {
    final before = _own(listId);
    if (before == null) return;
    if (before.contains(game.id)) {
      _put(before.copyWith(games: [for (final g in before.games) if (g.id != game.id) g]));
      await _send(() => _repository.removeFromList(listId, game.id), undo: () => _put(before));
      return;
    }
    if (before.games.length >= GameList.maxGames) {
      _setNotice(L10n.current.listGamesLimit(GameList.maxGames));
      return;
    }
    final catalogGame = game.withoutUserState();
    _put(before.copyWith(games: [...before.games, catalogGame]));
    await _send(() async {
      await _ensureInCatalog(game);
      await _repository.addToList(listId, game.id, before.games.length);
    }, undo: () => _put(before));
  }

  /// Moves the game at [from] to [to] (indexes of the list as it is, [to] after
  /// the move) and saves the new order.
  Future<void> move(String listId, int from, int to) async {
    final before = _own(listId);
    if (before == null || from == to) return;
    final games = [...before.games];
    if (from < 0 || from >= games.length || to < 0 || to >= games.length) return;
    games.insert(to, games.removeAt(from));
    _put(before.copyWith(games: games));
    await _send(
      () => _repository.reorderList(listId, [for (final g in games) g.id]),
      undo: () => _put(before),
    );
  }

  GameList? _own(String listId) {
    for (final list in _lists) {
      if (list.id == listId) return list;
    }
    return null;
  }

  /// Replaces the member's list with [list]'s id by [list].
  void _put(GameList list) {
    _lists = List.unmodifiable([for (final l in _lists) l.id == list.id ? list : l]);
    notifyIfAlive();
  }

  Future<void> _send(Future<void> Function() request, {required VoidCallback undo}) async {
    final epoch = this.epoch;
    try {
      await request();
    } catch (e, st) {
      debugPrint('Saving a list failed: $e\n$st');
      if (isStale(epoch)) return;
      undo();
      _failed(e);
    }
  }

  void _failed(Object e) => _setNotice(
    isConnectionFailure(e)
        ? L10n.current.listsNeedConnection
        : isContentRefusal(e)
        ? L10n.current.contentRefused
        : L10n.current.listSaveFailed,
  );

  void _setNotice(String message) {
    _notice = message;
    notifyIfAlive();
  }
}
