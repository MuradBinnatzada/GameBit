import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/utils/lru_cache.dart';

/// One game's reviews and community rating, with where the requests stand.
///
/// [preview] is what the game's screen shows: the first few reviews of the
/// [ReviewFilter.standard] order. [reviews] is the list on the Reviews screen,
/// in the order and narrowed as [filter] says, paged.
@immutable
class GameReviewsView {
  const GameReviewsView({
    this.status = LoadStatus.idle,
    this.ratings = const CommunityRatings(),
    this.preview = const [],
    this.filter = ReviewFilter.standard,
    this.listStatus = LoadStatus.idle,
    this.reviews = const [],
    this.hasMore = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
  });

  /// Of the rating and the preview.
  final LoadStatus status;
  final CommunityRatings ratings;
  final List<GameReview> preview;

  final ReviewFilter filter;

  /// Of the first page of [reviews].
  final LoadStatus listStatus;
  final List<GameReview> reviews;
  final bool hasMore;
  final bool loadingMore;
  final bool loadMoreFailed;

  GameReviewsView _copy({
    LoadStatus? status,
    CommunityRatings? ratings,
    List<GameReview>? preview,
    ReviewFilter? filter,
    LoadStatus? listStatus,
    List<GameReview>? reviews,
    bool? hasMore,
    bool? loadingMore,
    bool? loadMoreFailed,
  }) => GameReviewsView(
    status: status ?? this.status,
    ratings: ratings ?? this.ratings,
    preview: preview ?? this.preview,
    filter: filter ?? this.filter,
    listStatus: listStatus ?? this.listStatus,
    reviews: reviews ?? this.reviews,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
  );
}

/// What the members wrote about a game, and how they rated it: the Reviews panel
/// on the game's screen and the Reviews screen behind it. The panel's data is
/// asked for each time the game's screen opens (and again when the member's own
/// review or rating of the game reached the server, see [refresh]), showing the
/// copy held meanwhile: who wrote what changes under you. The Reviews screen
/// starts from that first page when it opens in the standard order, and asks for
/// a new list when the order or the narrowing changes.
///
/// Kept in memory only (the 30 games opened last), dropped when the account
/// changes; signed out, nothing is asked.
class GameReviewsStore extends AccountScopedStore {
  GameReviewsStore({
    required this._repository,
    required AuthStore auth,
    int capacity = 30,
  }) : _views = LruCache(capacity),
       super(auth);

  final CheckpointRepository _repository;

  /// Reviews the game's screen previews.
  static const int previewSize = 3;

  final LruCache<String, GameReviewsView> _views;
  final Map<String, Future<void>> _loading = {};

  /// Bumped by every request for a game's list, so an answer that arrives after
  /// a newer request (another order picked) is dropped.
  final Map<String, int> _listSeq = {};

  /// Games asked about again while a request for them was running: that answer
  /// may predate the change.
  final Set<String> _stale = {};

  @override
  void resetForAccount() {
    _views.clear();
    _loading.clear();
    _listSeq.clear();
    _stale.clear();
  }

  /// Takes the blocked member [memberId]'s reviews off every game held.
  void forgetMember(String memberId) {
    List<GameReview> without(List<GameReview> reviews) => [
      for (final r in reviews)
        if (r.member.id != memberId) r,
    ];
    _views.updateAll(
      (_, view) => view._copy(
        preview: without(view.preview),
        reviews: without(view.reviews),
      ),
    );
    notifyIfAlive();
  }

  GameReviewsView viewOf(String gameId) =>
      _views.peek(gameId) ?? const GameReviewsView();

  void _set(String gameId, GameReviewsView view) => _views[gameId] = view;

  // ---- The game's screen: rating and first reviews ----

  /// Fetches the community rating of [gameId] and its first page of reviews in
  /// the standard order, and makes that page the Reviews screen's list. Does
  /// nothing when signed out. A call while a request for the game is running
  /// asks again once it is done.
  Future<void> load(String gameId) {
    if (accountId == null) return Future.value();
    final running = _loading[gameId];
    if (running != null) {
      _stale.add(gameId);
      return running;
    }

    late final Future<void> request;
    request = _fetch(gameId).whenComplete(() {
      if (!identical(_loading[gameId], request)) return;
      _loading.remove(gameId);
      if (_stale.remove(gameId)) unawaited(load(gameId));
    });
    return _loading[gameId] = request;
  }

  /// [load] again for a game whose screen is open (or was opened lately): its
  /// own review or rating just reached the server. Nothing for a game never
  /// loaded.
  Future<void> refresh(String gameId) {
    if (_views.peek(gameId) == null) return Future.value();
    return load(gameId);
  }

  Future<void> _fetch(String gameId) async {
    final epoch = this.epoch;
    final cached = _views[gameId];
    final hasContent = cached != null && cached.status == LoadStatus.ready;
    if (!hasContent) {
      _set(
        gameId,
        (cached ?? const GameReviewsView())._copy(
          status: LoadStatus.loading,
          listStatus: LoadStatus.loading,
        ),
      );
      notifyIfAlive();
    }
    final seq = _nextListSeq(gameId);
    try {
      final (ratings, page) = await (
        _repository.fetchReviewStats(gameId),
        _repository.fetchGameReviews(gameId),
      ).wait;
      if (isStale(epoch)) return;
      final current = viewOf(gameId);
      // No list was asked for since: the page is the list too when the Reviews
      // screen is on the standard order, and a list in another order is asked
      // for again, so it shows the review that just changed.
      final listIsOurs = seq == _listSeq[gameId];
      final standard = current.filter == ReviewFilter.standard;
      _set(
        gameId,
        current._copy(
          status: LoadStatus.ready,
          ratings: ratings,
          preview: page.items.take(previewSize).toList(growable: false),
          listStatus: listIsOurs && standard ? LoadStatus.ready : null,
          reviews: listIsOurs && standard ? page.items : null,
          hasMore: listIsOurs && standard ? page.hasMore : null,
          loadingMore: listIsOurs && standard ? false : null,
          loadMoreFailed: listIsOurs && standard ? false : null,
        ),
      );
      if (listIsOurs && !standard) {
        unawaited(loadList(gameId, filter: current.filter, refresh: true));
      }
    } catch (e, st) {
      debugPrint('Loading the reviews of $gameId failed: $e\n$st');
      if (isStale(epoch)) return;
      if (!hasContent) {
        _set(
          gameId,
          viewOf(gameId)._copy(
            status: LoadStatus.failed,
            listStatus: seq == _listSeq[gameId] ? LoadStatus.failed : null,
          ),
        );
      }
    }
    notifyIfAlive();
  }

  int _nextListSeq(String gameId) =>
      _listSeq[gameId] = (_listSeq[gameId] ?? 0) + 1;

  // ---- The Reviews screen: the list ----

  /// Fetches the first page of [gameId]'s reviews for [filter], replacing the
  /// list. Does nothing when signed out, or when the list is already for [filter]
  /// and was fetched (a failed one is tried again) unless [refresh] says it may
  /// have changed: then the list on screen stays until the new one is here.
  Future<void> loadList(
    String gameId, {
    ReviewFilter filter = ReviewFilter.standard,
    bool refresh = false,
  }) async {
    if (accountId == null) return;
    final held = viewOf(gameId);
    final shown = held.filter == filter && held.listStatus == LoadStatus.ready;
    if (shown && !refresh) return;
    final epoch = this.epoch;
    final seq = _nextListSeq(gameId);
    if (!shown) {
      _set(
        gameId,
        held._copy(
          filter: filter,
          listStatus: LoadStatus.loading,
          reviews: const [],
          hasMore: false,
          loadingMore: false,
          loadMoreFailed: false,
        ),
      );
      notifyIfAlive();
    }
    try {
      final page = await _repository.fetchGameReviews(gameId, filter: filter);
      if (isStale(epoch) || seq != _listSeq[gameId]) return;
      _set(
        gameId,
        viewOf(gameId)._copy(
          listStatus: LoadStatus.ready,
          reviews: page.items,
          hasMore: page.hasMore,
          loadingMore: false,
          loadMoreFailed: false,
        ),
      );
    } catch (e, st) {
      debugPrint('Loading the reviews of $gameId failed: $e\n$st');
      if (isStale(epoch) || seq != _listSeq[gameId]) return;
      if (!shown) {
        _set(gameId, viewOf(gameId)._copy(listStatus: LoadStatus.failed));
      }
    }
    notifyIfAlive();
  }

  /// Fetches the next page of the list and appends it. Safe to call whenever:
  /// it does nothing unless there is a next page and none is loading.
  Future<void> loadMore(String gameId) async {
    final held = viewOf(gameId);
    if (accountId == null ||
        !held.hasMore ||
        held.loadingMore ||
        held.listStatus != LoadStatus.ready) {
      return;
    }
    final epoch = this.epoch;
    final seq = _listSeq[gameId] ?? 0;
    _set(gameId, held._copy(loadingMore: true, loadMoreFailed: false));
    notifyIfAlive();
    try {
      final page = await _repository.fetchGameReviews(
        gameId,
        filter: held.filter,
        offset: held.reviews.length,
      );
      if (isStale(epoch) || seq != _listSeq[gameId]) return;
      final current = viewOf(gameId);
      final seen = {for (final r in current.reviews) r.member.id};
      final fresh = [
        for (final r in page.items)
          if (seen.add(r.member.id)) r,
      ];
      _set(
        gameId,
        current._copy(
          reviews: List.unmodifiable([...current.reviews, ...fresh]),
          // A page with nothing new means the source is not advancing: stop
          // there instead of asking for the same page forever.
          hasMore: page.hasMore && !(page.items.isNotEmpty && fresh.isEmpty),
          loadingMore: false,
        ),
      );
    } catch (e, st) {
      debugPrint('Loading more reviews of $gameId failed: $e\n$st');
      if (isStale(epoch) || seq != _listSeq[gameId]) return;
      _set(
        gameId,
        viewOf(gameId)._copy(loadingMore: false, loadMoreFailed: true),
      );
    }
    notifyIfAlive();
  }

  // ---- Reporting ----

  /// Reports [review] of [gameId] and takes it off the lists on screen, as the
  /// server leaves it out for the member who reported it. Throws when the report
  /// could not be sent (the review stays).
  Future<void> report(
    String gameId,
    GameReview review,
    ReportReason reason,
  ) async {
    if (accountId == null) return;
    await _repository.reportReview(
      userId: review.member.id,
      gameId: gameId,
      reason: reason,
    );
    final view = _views.peek(gameId);
    if (view == null) return;
    bool other(GameReview r) => r.member.id != review.member.id;
    final ratings = view.ratings;
    final reviews = view.reviews.where(other).toList(growable: false);
    _set(
      gameId,
      view._copy(
        // The next review takes its place in the preview, when the list is in
        // the order the preview is.
        preview:
            view.filter == ReviewFilter.standard &&
                view.listStatus == LoadStatus.ready
            ? reviews.take(previewSize).toList(growable: false)
            : view.preview.where(other).toList(growable: false),
        reviews: reviews,
        ratings: CommunityRatings(
          ratings: ratings.ratings,
          average: ratings.average,
          reviews: ratings.reviews > 0 ? ratings.reviews - 1 : 0,
          halfStars: ratings.halfStars,
        ),
      ),
    );
    notifyIfAlive();
  }
}
