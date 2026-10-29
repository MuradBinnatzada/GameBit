import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/activity_entry.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_reviews.dart' show MemberReportSubject, ReportReason;
import 'package:checkpoint/models/library_stats.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/models/public_profile.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/utils/lru_cache.dart';

enum PublicProfileStatus {
  /// The first answer is on its way (or nothing was asked for yet).
  loading,
  ready,

  /// No member has this id (the account was deleted, or the id is wrong).
  notFound,

  /// The request failed and there is nothing saved to show.
  failed,
}

/// Everything the Public Profile screen shows about one member, as of [loadedAt].
@immutable
class PublicProfileView {
  const PublicProfileView({
    required this.status,
    this.profile,
    this.stats,
    this.library = const LibraryStats(),
    this.favorites = const [],
    this.activity = const [],
    this.milestones = const EarnedMilestones(),
    this.refreshFailed = false,
    this.loadedAt,
  });

  const PublicProfileView.loading() : this(status: PublicProfileStatus.loading);

  final PublicProfileStatus status;
  final PublicProfile? profile;

  /// Follower and following counts, and whether the viewer follows them.
  final PublicProfileStats? stats;

  /// Numbers over their whole library: games per status, hours, ratings.
  final LibraryStats library;

  /// Their (up to four) favorites.
  final List<Game> favorites;

  /// Their latest sessions, one per game, newest first.
  final List<ActivityEntry> activity;

  /// The milestones they earned. Empty when they have none, or when they could
  /// not be read (the rest of the profile still shows).
  final EarnedMilestones milestones;

  /// The last refresh failed, so what is shown may be out of date.
  final bool refreshFailed;
  final DateTime? loadedAt;

  /// Their follower count with the signed-in member's own follow or unfollow
  /// since [stats] were read applied, so the count moves as soon as the button
  /// does. [viewerFollows] is the signed-in member's follow state now.
  int followersFor({required bool viewerFollows}) {
    final s = stats;
    if (s == null) return 0;
    final delta = (viewerFollows ? 1 : 0) - (s.viewerFollows ? 1 : 0);
    return math.max(0, s.followers + delta);
  }

  PublicProfileView copyWith({bool? refreshFailed}) => PublicProfileView(
    status: status,
    profile: profile,
    stats: stats,
    library: library,
    favorites: favorites,
    activity: activity,
    milestones: milestones,
    refreshFailed: refreshFailed ?? this.refreshFailed,
    loadedAt: loadedAt,
  );
}

/// Other members' profiles: header, counts, favorites, latest sessions and library
/// numbers. It never touches [ProfileStore], which holds the signed-in member's own
/// profile. A member's whole library is in [PublicLibraryStore], loaded only when
/// their Library screen opens.
///
/// A profile is fetched when its screen opens and kept in memory (the 20 most
/// recently opened) so that opening it again is instant; one older than
/// [cacheLifetime] is shown while a fresh copy is fetched. Nothing is saved to
/// the device, and everything is dropped when the account changes.
///
/// Achievements are not part of a profile: see [PublicAchievementsStore]. The
/// follower and following lists are in [SocialGraphStore].
class PublicProfileStore extends AccountScopedStore {
  PublicProfileStore({
    required this._repository,
    required AuthStore auth,
    this.cacheLifetime = const Duration(minutes: 5),
    DateTime Function()? now,
    int capacity = 20,
  }) : _now = now ?? DateTime.now,
       _views = LruCache(capacity),
       super(auth);

  final CheckpointRepository _repository;
  final Duration cacheLifetime;
  final DateTime Function() _now;

  final LruCache<String, PublicProfileView> _views;
  final Map<String, Future<void>> _loading = {};

  @override
  void resetForAccount() {
    _views.clear();
    _loading.clear();
  }

  /// Reports [userId]'s profile or photo as the signed-in member. Throws when the
  /// report could not be sent.
  Future<void> report(
    String userId,
    MemberReportSubject subject,
    ReportReason reason,
  ) => _repository.reportMember(userId: userId, subject: subject, reason: reason);

  /// Forgets the blocked member [memberId]: their profile is not shown again
  /// (the server leaves it out from now on).
  void forgetMember(String memberId) {
    _views.remove(memberId);
    _loading.remove(memberId);
    notifyIfAlive();
  }

  /// What is known about [userId]'s profile; "loading" until [load] has an answer.
  PublicProfileView viewOf(String userId) =>
      _views.peek(userId) ?? const PublicProfileView.loading();

  /// A game from any loaded profile, as the catalog knows it: the owner's status,
  /// rating and hours are cleared, so the game screen never shows them as the
  /// signed-in member's own. This is how a poster tapped on someone's profile is
  /// found by the game screen (it is usually not in the member's library).
  Game? gameById(String id) {
    for (final view in _views.values) {
      for (final game in view.favorites) {
        if (game.id == id) return game.withoutUserState();
      }
      for (final entry in view.activity) {
        if (entry.game.id == id) return entry.game.withoutUserState();
      }
    }
    return null;
  }

  bool _isFresh(PublicProfileView view) {
    final at = view.loadedAt;
    return (view.status == PublicProfileStatus.ready ||
            view.status == PublicProfileStatus.notFound) &&
        at != null &&
        _now().difference(at) < cacheLifetime;
  }

  /// Makes sure [userId]'s profile is loaded: does nothing while a request for it
  /// is running or the copy held is fresh, otherwise fetches it. A copy that is
  /// stale stays on screen while the new one is on its way (and if that fails).
  /// [force] fetches whatever the age, for pull-to-refresh and retry.
  Future<void> load(String userId, {bool force = false}) {
    final running = _loading[userId];
    if (running != null) return running;
    final cached = _views[userId];
    if (!force && cached != null && _isFresh(cached)) return Future.value();

    late final Future<void> request;
    request = _fetch(userId, cached).whenComplete(() {
      if (identical(_loading[userId], request)) _loading.remove(userId);
    });
    return _loading[userId] = request;
  }

  Future<void> _fetch(String userId, PublicProfileView? cached) async {
    final epoch = this.epoch;
    final hasContent =
        cached != null &&
        (cached.status == PublicProfileStatus.ready ||
            cached.status == PublicProfileStatus.notFound);
    if (!hasContent) {
      _views[userId] = const PublicProfileView.loading();
      notifyIfAlive();
    }

    try {
      final (profile, stats, library, favorites, activity, milestones) = await (
        _repository.fetchPublicProfile(userId),
        _repository.fetchPublicProfileStats(userId),
        _repository.fetchPublicLibraryStats(userId),
        _repository.fetchPublicFavorites(userId),
        _repository.fetchPublicActivity(userId),
        _fetchMilestones(userId),
      ).wait;
      if (isStale(epoch)) return;
      _views[userId] = profile == null
          ? PublicProfileView(
              status: PublicProfileStatus.notFound,
              loadedAt: _now(),
            )
          : PublicProfileView(
              status: PublicProfileStatus.ready,
              profile: profile,
              stats: stats,
              library: library,
              favorites: favorites,
              activity: activity,
              milestones: milestones,
              loadedAt: _now(),
            );
    } catch (e, st) {
      debugPrint('Public profile load failed: $e\n$st');
      if (isStale(epoch)) return;
      _views[userId] = hasContent
          ? cached.copyWith(refreshFailed: true)
          : const PublicProfileView(status: PublicProfileStatus.failed);
    }
    notifyIfAlive();
  }

  /// Their milestones, or none when they can't be read: a profile is worth
  /// showing without them.
  Future<EarnedMilestones> _fetchMilestones(String userId) async {
    try {
      return EarnedMilestones(await _repository.fetchMilestones(userId));
    } catch (e) {
      debugPrint('Milestones of $userId could not be read: $e');
      return const EarnedMilestones();
    }
  }
}
