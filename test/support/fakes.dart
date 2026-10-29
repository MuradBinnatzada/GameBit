import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/models/achievement.dart';
import 'package:checkpoint/models/achievement_summary.dart';
import 'package:checkpoint/models/activity_entry.dart';
import 'package:checkpoint/models/browse.dart';
import 'package:checkpoint/models/completion_time.dart';
import 'package:checkpoint/models/company.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/models/friend_activity.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_attributes.dart';
import 'package:checkpoint/models/game_details.dart';
import 'package:checkpoint/models/discussion.dart';
import 'package:checkpoint/models/game_friends.dart';
import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/models/game_list.dart';
import 'package:checkpoint/models/game_cover.dart';
import 'package:checkpoint/models/library_stats.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/models/public_profile.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/models/studio_filters.dart';
import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/models/user_profile.dart';
import 'package:checkpoint/services/auth_service.dart';
import 'package:checkpoint/services/discussion_api_service.dart';
import 'package:checkpoint/services/discussion_failure.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/services/connectivity_service.dart';
import 'package:checkpoint/services/game_api_service.dart';
import 'package:checkpoint/services/steam_link_service.dart';
import 'package:checkpoint/state/company_store.dart';

User testUser(String id) => User(
  id: id,
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: '2026-01-01T00:00:00Z',
);

Game testGame(
  String id, {
  String? title,
  GameStatus? status = GameStatus.playing,
  double hours = 12.5,
  bool favorite = false,
  bool cover = true,
  int year = 2020,
  List<GamePlatform> platforms = const [GamePlatform.pc, GamePlatform.ps5],
  GamePlatform? playedOn,
  int? steamAppId = 440,
  int? igdbId = 7,
  List<String> genres = const ['RPG'],
}) {
  final name = title ?? 'Game $id';
  return Game(
    id: id,
    title: name,
    publisher: 'Publisher',
    developer: 'Developer',
    releaseYear: year,
    platforms: platforms,
    genres: genres,
    synopsis: 'A game.',
    coverColors: coverColorsFor(id, name),
    coverIcon: coverIconFor(genres, platforms),
    coverUrl: cover ? 'https://example.com/$id.jpg' : null,
    igdbId: igdbId,
    steamAppId: steamAppId,
    status: status,
    rating: 4.5,
    hoursPlayed: hours,
    playedOn: playedOn ?? (status == null ? null : GamePlatform.pc),
    purchasePrice: 19.99,
    dateAdded: status == null ? null : DateTime.utc(2026, 1, 2, 3, 4, 5),
    isFavorite: favorite,
  );
}

/// A game in a browse list. [score] and [released] are what the list captions
/// show. Like a game from IGDB it has no rating: that is the user's own.
BrowseEntry testEntry(
  String id, {
  String? title,
  double? score = 92.4,
  DateTime? released,
}) => BrowseEntry(
  testGame(id, title: title, status: null, cover: false).copyWith(rating: 0),
  score: score,
  releaseDate: released,
);

LogEntry testLog(String id, String gameId) => LogEntry(
  id: id,
  gameId: gameId,
  timestamp: DateTime.utc(2026, 2, 3, 4, 5, 6),
  hours: 1.5,
  platform: GamePlatform.pc,
  note: 'a note',
);

/// A member as the lists and the search show them.
SocialUser testMember(String id, {String? name, String? avatarUrl}) => SocialUser(
  id: id,
  name: name ?? 'Member $id',
  handle: '@member_$id',
  gamesLogged: 0,
  followers: 0,
  avatarUrl: avatarUrl,
);

/// A thread of the discussions by member [author], written in at [at] (its last
/// post; the thread was started then too).
DiscussionThread testThread(
  String id, {
  String board = 'general',
  String? title,
  String text = 'Opening text of the thread.',
  String author = 'a',
  String? authorName,
  int replies = 0,
  DateTime? at,
  bool pinned = false,
  bool locked = false,
  DiscussionGame? game,
}) => DiscussionThread(
  id: id,
  boardId: board,
  author: testMember(author, name: authorName),
  title: title ?? 'Thread $id',
  text: text,
  createdAt: at ?? DateTime.utc(2026, 10, 20),
  lastPostAt: at ?? DateTime.utc(2026, 10, 20),
  replyCount: replies,
  pinned: pinned,
  locked: locked,
  game: game,
);

/// A reply to [threadId] by member [author].
DiscussionPost testPost(
  String id,
  String threadId, {
  String author = 'b',
  String? authorName,
  String text = 'A reply.',
  DateTime? at,
}) => DiscussionPost(
  id: id,
  threadId: threadId,
  author: testMember(author, name: authorName),
  text: text,
  createdAt: at ?? DateTime.utc(2026, 10, 21),
);

/// A review of a game by member [id], as `game_reviews` answers it.
GameReview testReview(
  String id, {
  String? name,
  String text = 'A fine game.',
  double rating = 0,
  GameStatus? status = GameStatus.completed,
  double hours = 0,
  DateTime? at,
  bool following = false,
}) => GameReview(
  member: testMember(id, name: name),
  text: text,
  status: status,
  rating: rating,
  hours: hours,
  writtenAt: at,
  isFollowing: following,
);

/// A member the signed-in user follows who has a game with [status].
FriendWithGame testFriend(
  String id,
  GameStatus status, {
  double rating = 0,
  DateTime? added,
  String? name,
}) => FriendWithGame(
  member: testMember(id, name: name),
  status: status,
  rating: rating,
  dateAdded: added,
);

/// [friends] as `following_game_activity` sends them: [totals] defaults to
/// counting [friends], as when every one of them was sent.
GameFriends testGameFriends(
  List<FriendWithGame> friends, {
  Map<GameStatus, int>? totals,
}) => GameFriends(
  friends: friends,
  totals:
      totals ??
      {
        for (final status in GameStatus.values)
          if (friends.any((f) => f.status == status))
            status: friends.where((f) => f.status == status).length,
      },
);

/// An item of Home's friends feed: [memberId] did [kind] on [gameId]. The game
/// is a catalog game, as `following_recent_activity` sends it.
FriendActivity testActivity(
  String memberId,
  String gameId,
  FriendActivityKind kind, {
  String? name,
  String? title,
  double hours = 0,
  double rating = 0,
  DateTime? at,
}) => FriendActivity(
  member: testMember(memberId, name: name),
  game: testGame(
    gameId,
    title: title,
    status: null,
    cover: false,
  ).copyWith(rating: 0),
  kind: kind,
  hours: hours,
  rating: rating,
  at: at ?? DateTime.utc(2026, 3, 4, 5, 6, 7),
);

/// A [CheckpointRepository] that answers from memory. [offline] makes every read
/// throw, like a dead connection; [gate] holds the library read until completed.
class FakeRepository implements CheckpointRepository {
  List<Game> library = [];
  List<LogEntry> logs = [];
  List<Game> popular = [];
  bool offline = false;

  /// Writes are refused (as by a constraint or policy) while reads still work.
  bool rejectWrites = false;

  /// The SQLSTATE a refused write carries: `CP422` is the server refusing text
  /// that breaks the chat rules.
  String rejectCode = '23514';

  /// Writes can't reach the server while reads still work, like a connection
  /// that dropped between the two.
  bool writesDown = false;

  /// Who the signed-in user follows on the server.
  Set<String> following = {'friend-1'};

  /// The bio saved on the signed-in user's profile.
  String profileBio = '';

  /// The Steam ID saved on the profile; null means no Steam account is connected.
  String? steamId;

  /// `profiles.show_steam_achievements`: whether other members see them.
  bool showSteamAchievements = true;

  /// Holds [setShowSteamAchievements] until completed.
  Completer<void>? privacyGate;

  /// `profiles.avatar_frame`, `title_milestone` and `showcased_milestones`.
  ProfileFlair profileFlair = ProfileFlair.none;

  /// Holds [setProfileFlair] until completed.
  Completer<void>? flairGate;

  /// `user_milestones`: what each member has earned, with when.
  final Map<String, Map<String, DateTime>> memberMilestones = {};

  /// What the next [awardMilestones] finds the signed-in member ([awardTo])
  /// has reached, as the function works it out from their rows. Those not
  /// earned yet are recorded and returned.
  Map<String, DateTime> reachable = {};
  String awardTo = 'u1';

  /// The UTC offset of each [awardMilestones] call, in order.
  final List<int> awardCalls = [];
  Completer<void>? awardGate;
  bool failAwards = false;

  /// `profiles.connected_services`: the services saved for the signed-in user, as
  /// other members see them (Steam is never in it), and the account names saved
  /// with them (`psn_id`, `xbox_id`, `discord_id`, `instagram_id`, `twitch_id`).
  Set<ConnectedService> connectedServices = {};
  String? savedPsnId;
  String? savedXboxId;
  String? savedDiscordId;
  String? savedInstagramId;
  String? savedTwitchId;

  /// What `sync-steam` answers, or the error it throws when [syncError] is set.
  Object? syncData = {'success': true, 'delayed': null};
  Object? syncError;
  int syncCalls = 0;

  /// Holds [follow] until completed, to have a request in flight.
  Completer<void>? followGate;

  /// Holds [setConnectedAccounts] until completed.
  Completer<void>? servicesGate;

  /// Holds the signed-in user's own profile read ([ensureProfile]) until completed.
  Completer<void>? profileLoadGate;
  Completer<void>? gate;
  int libraryFetches = 0;

  /// The IGDB ids of the library's games whose catalog row IGDB never filled in
  /// ([fetchUnsyncedIgdbIds]). Empty by default, so no catalog backfill runs.
  List<int> unsyncedIgdbIds = [];
  int unsyncedReads = 0;

  /// What the server holds of the library games' IGDB details, by game id
  /// ([fetchLibraryAttributes]): the games filled in from IGDB. Holds [gate]-like
  /// [attributesGate] until completed.
  Map<String, GameAttributes> libraryAttributes = {};
  int attributeReads = 0;
  Completer<void>? attributesGate;

  /// Only the attribute read fails, while the rest of the library still loads.
  bool attributesDown = false;

  /// What reached the server, in order.
  final List<String> writes = [];

  void _checkOnline() {
    if (offline) throw Exception('network down');
  }

  void _checkWrite() {
    _checkOnline();
    if (writesDown) throw Exception('network down');
    if (rejectWrites) throw PostgrestException(message: 'refused', code: rejectCode);
  }

  @override
  Future<List<Game>> fetchUserGames(String userId) async {
    libraryFetches++;
    await gate?.future;
    _checkOnline();
    return library;
  }

  @override
  Future<Map<String, GameAttributes>> fetchLibraryAttributes(
    String userId,
  ) async {
    attributeReads++;
    await attributesGate?.future;
    _checkOnline();
    if (attributesDown) throw Exception('details unavailable');
    return Map.of(libraryAttributes);
  }

  @override
  Future<List<int>> fetchUnsyncedIgdbIds(String userId) async {
    unsyncedReads++;
    _checkOnline();
    return List.of(unsyncedIgdbIds);
  }

  @override
  Future<List<LogEntry>> fetchLogEntries(String userId) async {
    _checkOnline();
    return logs;
  }

  @override
  Future<List<Game>> fetchPopularGames({int limit = 20}) async {
    _checkOnline();
    return popular;
  }

  @override
  Future<UserProfile> ensureProfile(User user) async {
    // The row as it is when the request is made, like a read that is under way.
    final services = {...connectedServices};
    await profileLoadGate?.future;
    _checkOnline();
    return UserProfile(
      name: 'Ada',
      handle: '@ada',
      bio: profileBio,
      steamId: steamId,
      connectedServices: services,
      psnId: savedPsnId,
      xboxId: savedXboxId,
      discordId: savedDiscordId,
      instagramId: savedInstagramId,
      twitchId: savedTwitchId,
      showSteamAchievements: showSteamAchievements,
      flair: profileFlair,
      joined: DateTime.utc(2026, 1, 1),
      followers: 0,
      following: 0,
    );
  }

  @override
  Future<UserProfile> fetchProfile(User user) => ensureProfile(user);

  @override
  Future<void> setConnectedAccounts(ConnectedAccounts accounts) async {
    await servicesGate?.future;
    _checkWrite();
    connectedServices = {...accounts.services};
    savedPsnId = accounts.psnId;
    savedXboxId = accounts.xboxId;
    savedDiscordId = accounts.discordId;
    savedInstagramId = accounts.instagramId;
    savedTwitchId = accounts.twitchId;
    writes.add('services:${connectedServicesToDb(accounts.services).join(',')}');
  }

  /// Where each `steam-link` start asked to come back to (null: nowhere).
  final List<Uri?> steamLinkStarts = [];

  /// What `steam-link` throws instead of answering, when set.
  Object? steamLinkError;

  /// Like the function: answers Steam's sign-in page. The Steam ID is saved by
  /// the server once the member signs in there (see [FakeSteamLink]).
  @override
  Future<Uri> startSteamLink({Uri? returnTo}) async {
    steamLinkStarts.add(returnTo);
    final error = steamLinkError;
    if (error != null) throw error;
    return Uri.parse(
      'https://steamcommunity.com/openid/login?openid.mode=checkid_setup',
    );
  }

  @override
  Future<void> setShowSteamAchievements(bool show) async {
    await privacyGate?.future;
    _checkWrite();
    showSteamAchievements = show;
    writes.add('show-achievements:$show');
  }

  /// Like the trigger, refuses what the signed-in member hasn't earned.
  @override
  Future<void> setProfileFlair(ProfileFlair flair) async {
    await flairGate?.future;
    _checkWrite();
    final earned = memberMilestones[awardTo] ?? const {};
    final frameEarned = flair.frame == null || earned.containsKey(flair.frame!.milestone.id);
    final titleEarned = flair.titleId == null || earned.containsKey(flair.titleId);
    final showcaseEarned = flair.showcaseIds.length <= ProfileFlair.maxShowcase &&
        flair.showcaseIds.every(earned.containsKey);
    if (!frameEarned || !titleEarned || !showcaseEarned) {
      throw const PostgrestException(message: 'not unlocked', code: '23514');
    }
    profileFlair = flair;
    writes.add('flair:${flair.frameId}:${flair.titleId}:${flair.showcaseIds.join(',')}');
  }

  @override
  Future<Map<String, DateTime>> awardMilestones(int utcOffsetMinutes) async {
    awardCalls.add(utcOffsetMinutes);
    await awardGate?.future;
    _checkOnline();
    if (failAwards) throw Exception('award failed');
    final earned = memberMilestones.putIfAbsent(awardTo, () => {});
    final fresh = {
      for (final MapEntry(:key, :value) in reachable.entries)
        if (!earned.containsKey(key)) key: value,
    };
    earned.addAll(fresh);
    return fresh;
  }

  /// Whose milestones were read, in order.
  final List<String> milestoneReads = [];

  @override
  Future<Map<String, DateTime>> fetchMilestones(String userId) async {
    milestoneReads.add(userId);
    _checkOnline();
    return Map.of(memberMilestones[userId] ?? const {});
  }

  @override
  Future<void> clearSteamId() async {
    _checkWrite();
    steamId = null;
    writes.add('steam:');
  }

  @override
  Future<Object?> syncSteamLibrary() async {
    syncCalls++;
    final error = syncError;
    if (error != null) throw error;
    return syncData;
  }

  @override
  Future<Set<String>> fetchFollowingIds(String userId) async {
    _checkOnline();
    return {...following};
  }

  @override
  Future<int> fetchFollowersCount(String userId) async {
    _checkOnline();
    return 3;
  }

  @override
  Future<void> follow({required String followerId, required String followeeId}) async {
    await followGate?.future;
    _checkWrite();
    // The table's key is (follower, followee): following twice is an error.
    if (!following.add(followeeId)) {
      throw const PostgrestException(message: 'duplicate key', code: '23505');
    }
    writes.add('follow:$followeeId');
  }

  @override
  Future<void> unfollow({required String followerId, required String followeeId}) async {
    _checkWrite();
    following.remove(followeeId);
    writes.add('unfollow:$followeeId');
  }

  @override
  Future<void> deleteUserGame(String userId, String gameId) async {
    _checkWrite();
    writes.add('delete:$gameId');
  }

  @override
  Future<void> clearLibrary(String userId) async {
    _checkWrite();
    writes.add('clear-library');
    library = [];
    logs = [];
    // Achievements are stored with the games.
    achievementSummaries.remove(userId);
    memberAchievements.removeWhere((key, _) => key.$1 == userId);
  }

  @override
  Future<void> addToCatalog(Game game) async {
    _checkWrite();
    writes.add('base:${game.id}');
  }

  @override
  Future<void> insertLogEntry({
    required String userId,
    required String gameId,
    required double hours,
    required GamePlatform platform,
    required String note,
    DateTime? loggedAt,
  }) async {
    _checkWrite();
    writes.add('log:$gameId:$hours');
    logTimes.add(loggedAt);
  }

  /// The `logged_at` each inserted session was sent with, in order (null: the
  /// server's own time).
  final List<DateTime?> logTimes = [];

  /// The shared catalog by IGDB id, for [fetchCatalogGame].
  final Map<int, Game> catalog = {};

  @override
  Future<Game?> fetchCatalogGame(int igdbId) async {
    _checkOnline();
    return catalog[igdbId];
  }

  /// The member's lists on the server, by id, in the order they were made.
  final Map<String, GameList> lists = {};
  int _listIds = 0;

  @override
  Future<List<GameList>> fetchLists(String userId) async {
    _checkOnline();
    return [for (final l in lists.values) if (l.ownerId == userId || l.isPublic) l].reversed.toList();
  }

  @override
  Future<GameList?> fetchList(String listId) async {
    _checkOnline();
    return lists[listId];
  }

  @override
  Future<GameList> createList({required String title, String description = '', bool isPublic = false}) async {
    _checkWrite();
    final list = GameList(id: 'list-${++_listIds}', ownerId: 'u1', title: title.trim(), description: description.trim(), isPublic: isPublic);
    lists[list.id] = list;
    writes.add('create-list:${list.title}');
    return list;
  }

  @override
  Future<void> updateList(String listId, {required String title, required String description, required bool isPublic}) async {
    _checkWrite();
    writes.add('update-list:$listId:$title');
    lists[listId] = lists[listId]!.copyWith(title: title, description: description, isPublic: isPublic);
  }

  @override
  Future<void> deleteList(String listId) async {
    _checkWrite();
    writes.add('delete-list:$listId');
    lists.remove(listId);
  }

  @override
  Future<void> addToList(String listId, String gameId, int position) async {
    _checkWrite();
    writes.add('list-add:$listId:$gameId:$position');
  }

  @override
  Future<void> removeFromList(String listId, String gameId) async {
    _checkWrite();
    writes.add('list-remove:$listId:$gameId');
  }

  @override
  Future<void> reorderList(String listId, List<String> gameIds) async {
    _checkWrite();
    writes.add('list-order:$listId:${gameIds.join(',')}');
  }

  /// Like the server: changes the session in [logs] with that id, if any.
  @override
  Future<void> updateLogEntry({
    required String id,
    required double hours,
    required GamePlatform platform,
    required String note,
    required DateTime loggedAt,
  }) async {
    _checkWrite();
    writes.add('edit-log:$id:$hours');
    logs = [
      for (final l in logs)
        l.id == id
            ? LogEntry(
                id: id,
                gameId: l.gameId,
                timestamp: loggedAt,
                hours: hours,
                platform: platform,
                note: note,
              )
            : l,
    ];
  }

  @override
  Future<void> deleteLogEntry(String id) async {
    _checkWrite();
    writes.add('delete-log:$id');
    logs = [for (final l in logs) if (l.id != id) l];
  }

  @override
  Future<void> upsertUserGame({
    required String userId,
    required String gameId,
    required GameStatus status,
    required double rating,
    required double hoursPlayed,
    required GamePlatform? playedOn,
    required double purchasePrice,
    required bool isFavorite,
    String? customBackdropUrl,
    DateTime? dateAdded,
    String review = '',
    bool stillPlaying = false,
    bool perfected = false,
  }) async {
    await userGameGate?.future;
    _checkWrite();
    writes.add('game:$gameId:$status:$rating');
    backdrops[gameId] = customBackdropUrl;
    reviews[gameId] = review;
    stillPlayingSent[gameId] = stillPlaying;
    perfectedSent[gameId] = perfected;
  }

  /// Holds [upsertUserGame] until completed, to have a game's save in flight.
  Completer<void>? userGameGate;

  /// The review each game's last save sent.
  final Map<String, String> reviews = {};

  /// The "still playing" flag each game's last save sent.
  final Map<String, bool> stillPlayingSent = {};

  /// The perfected flag (Platinum, all achievements, 100%) each game's last
  /// save sent.
  final Map<String, bool> perfectedSent = {};

  @override
  Future<void> upsertCompletionTime({
    required String userId,
    required String gameId,
    required CompletionTime time,
  }) async {
    _checkWrite();
    writes.add('time:$gameId:${time.category.wire}:${time.minutes}');
    completionTimes[gameId] = time;
  }

  @override
  Future<void> deleteCompletionTime(String userId, String gameId) async {
    _checkWrite();
    writes.add('time-delete:$gameId');
    completionTimes.remove(gameId);
  }

  /// The signed-in user's completion times on the server, by game id.
  final Map<String, CompletionTime> completionTimes = {};

  /// The backdrop each game's last save sent.
  final Map<String, String?> backdrops = {};

  @override
  Future<ResultsPage<SocialUser>> searchSocialUsers(
    String currentUserId, {
    String query = '',
    int offset = 0,
    int limit = 30,
  }) async {
    _checkOnline();
    return ResultsPage<SocialUser>(const [
      SocialUser(id: 'm1', name: 'Member', handle: '@member', gamesLogged: 0, followers: 0),
    ], hasMore: false);
  }

  // ---- Other members ----

  /// Members the server knows, by id. A missing id is a deleted account.
  final Map<String, PublicProfile> members = {
    'm1': const PublicProfile(
      id: 'm1',
      name: 'Member One',
      handle: '@member_one',
      steamConnected: true,
    ),
  };

  /// What `public_profile_stats` answers, per member (default: 5 / 2 / not
  /// following / 2 games).
  final Map<String, PublicProfileStats> stats = {};

  /// A member's games. The profile's favorites, rated list and library pages are
  /// cut from these the way the database does it.
  final Map<String, List<Game>> memberGames = {};

  /// Followers and following lists, per member id.
  final Map<String, List<SocialUser>> followersOf = {};
  final Map<String, List<SocialUser>> followingOf = {};

  /// Per member: the progress per game, and the achievements of each game.
  final Map<String, List<GameAchievementSummary>> achievementSummaries = {};
  final Map<(String, String), List<Achievement>?> memberAchievements = {};

  /// What Steam has for a member's game, handed out by the `sync-achievements`
  /// fake. A game missing here fails, as one Steam can't answer for does.
  final Map<(String, String), List<Achievement>> steamAchievements = {};

  /// Thrown by the Steam fetch instead of answering (a FunctionException with a
  /// code, say). Null: answer from [steamAchievements].
  Object? steamAchievementsError;

  /// Holds profile reads / follower and following lists until completed, to
  /// have a request in flight.
  Completer<void>? profileGate;
  Completer<void>? followListGate;

  /// Fails these reads, as a dropped connection does.
  bool failProfileReads = false;
  bool failFollowLists = false;
  bool failAchievementReads = false;

  /// Fails only the count, as a database without `public_achievement_totals` does.
  bool failAchievementTotals = false;

  /// What was asked of the server about other members, in order.
  final List<String> memberReads = [];

  List<Game> _gamesOf(String userId) => memberGames[userId] ?? const [];

  @override
  Future<PublicProfile?> fetchPublicProfile(String userId) async {
    memberReads.add('profile:$userId');
    await profileGate?.future;
    _checkOnline();
    if (failProfileReads) throw Exception('profile read failed');
    return members[userId];
  }

  @override
  Future<PublicProfileStats> fetchPublicProfileStats(String userId) async {
    memberReads.add('stats:$userId');
    _checkOnline();
    if (failProfileReads) throw Exception('profile read failed');
    return stats[userId] ??
        PublicProfileStats(
          followers: 5,
          following: 2,
          viewerFollows: false,
          games: _gamesOf(userId).length,
        );
  }

  @override
  Future<List<Game>> fetchPublicFavorites(String userId) async {
    _checkOnline();
    return [
      for (final g in _gamesOf(userId))
        if (g.isFavorite) g,
    ].take(CheckpointRepository.publicFavoritesLimit).toList();
  }

  /// A member's latest sessions, newest first.
  final Map<String, List<ActivityEntry>> memberActivity = {};

  /// Holds the whole-library read of another member until completed.
  Completer<void>? memberLibraryGate;
  bool failMemberLibrary = false;

  @override
  Future<LibraryStats> fetchPublicLibraryStats(String userId) async {
    memberReads.add('stats-rows:$userId');
    _checkOnline();
    if (failProfileReads) throw Exception('profile read failed');
    return LibraryStats.of(_gamesOf(userId));
  }

  @override
  Future<List<Game>> fetchPublicLibrary(String userId) async {
    memberReads.add('library:$userId');
    await memberLibraryGate?.future;
    _checkOnline();
    if (failMemberLibrary) throw Exception('library read failed');
    return _gamesOf(userId);
  }

  @override
  Future<List<ActivityEntry>> fetchPublicActivity(
    String userId, {
    int limit = CheckpointRepository.publicActivityLimit,
  }) async {
    _checkOnline();
    return (memberActivity[userId] ?? const <ActivityEntry>[])
        .take(limit)
        .toList();
  }

  ResultsPage<SocialUser> _page(List<SocialUser> all, int offset, int limit) {
    final items = all.skip(offset).take(limit).toList();
    return ResultsPage<SocialUser>(items, hasMore: items.length >= limit);
  }

  @override
  Future<ResultsPage<SocialUser>> fetchFollowers(
    String userId, {
    int offset = 0,
    int limit = CheckpointRepository.followListPageSize,
  }) async {
    memberReads.add('followers:$userId:$offset');
    await followListGate?.future;
    _checkOnline();
    if (failFollowLists) throw Exception('list failed');
    return _page(followersOf[userId] ?? const [], offset, limit);
  }

  @override
  Future<ResultsPage<SocialUser>> fetchFollowing(
    String userId, {
    int offset = 0,
    int limit = CheckpointRepository.followListPageSize,
  }) async {
    memberReads.add('following:$userId:$offset');
    await followListGate?.future;
    _checkOnline();
    if (failFollowLists) throw Exception('list failed');
    return _page(followingOf[userId] ?? const [], offset, limit);
  }

  /// The members the signed-in user follows who have each game, by game id, as
  /// `following_game_activity` answers. [friendsGate] holds the read until
  /// completed; [failFriendsReads] fails it.
  final Map<String, GameFriends> friendsWithGame = {};
  Completer<void>? friendsGate;
  bool failFriendsReads = false;

  /// The games [fetchFriendsWithGame] was asked about, in order.
  final List<String> friendReads = [];

  @override
  Future<GameFriends> fetchFriendsWithGame(String gameId) async {
    friendReads.add(gameId);
    await friendsGate?.future;
    _checkOnline();
    if (failFriendsReads) throw Exception('friends read failed');
    return friendsWithGame[gameId] ?? const GameFriends();
  }

  /// The reviews of each game, by game id, as the members wrote them (the fake
  /// orders, narrows and pages them like `game_reviews`, and leaves out those
  /// reported). [reviewStats] is what `game_review_stats` answers; a game left out
  /// of it gets the stats of its reviews. [reviewsGate] holds the reads until
  /// completed; [failReviewReads] and [failReviewReports] fail them.
  final Map<String, List<GameReview>> gameReviews = {};
  final Map<String, CommunityRatings> reviewStats = {};
  Completer<void>? reviewsGate;
  bool failReviewReads = false;
  bool failReviewReports = false;

  /// The pages of reviews asked for, and the reviews reported, in order.
  final List<({String gameId, ReviewFilter filter, int offset})> reviewReads = [];
  final List<({String userId, String gameId, ReportReason reason})> reviewReports = [];

  @override
  Future<ResultsPage<GameReview>> fetchGameReviews(
    String gameId, {
    ReviewFilter filter = ReviewFilter.standard,
    int offset = 0,
    int limit = CheckpointRepository.reviewsPageSize,
  }) async {
    reviewReads.add((gameId: gameId, filter: filter, offset: offset));
    await reviewsGate?.future;
    _checkOnline();
    if (failReviewReads) throw Exception('reviews read failed');
    final reported = {
      for (final r in reviewReports)
        if (r.gameId == gameId) r.userId,
    };
    final all = [
      for (final r in gameReviews[gameId] ?? const <GameReview>[])
        if (!reported.contains(r.member.id) && (!filter.onlyFollowing || r.isFollowing)) r,
    ];
    int newest(GameReview a, GameReview b) =>
        (b.writtenAt ?? DateTime(1970)).compareTo(a.writtenAt ?? DateTime(1970));
    int followedFirst(GameReview a, GameReview b) => (b.isFollowing ? 1 : 0) - (a.isFollowing ? 1 : 0);
    int ratedFirst(GameReview a, GameReview b) => (b.rating > 0 ? 1 : 0) - (a.rating > 0 ? 1 : 0);
    int firstDifference(List<int> comparisons) => comparisons.firstWhere((c) => c != 0, orElse: () => 0);
    all.sort(
      (a, b) => switch (filter.sort) {
        ReviewSort.friends => firstDifference([followedFirst(a, b), newest(a, b)]),
        ReviewSort.newest => newest(a, b),
        ReviewSort.highest => firstDifference([ratedFirst(a, b), b.rating.compareTo(a.rating), newest(a, b)]),
        ReviewSort.lowest => firstDifference([ratedFirst(a, b), a.rating.compareTo(b.rating), newest(a, b)]),
      },
    );
    final page = all.skip(offset).take(limit).toList();
    return ResultsPage(page, hasMore: page.length >= limit);
  }

  @override
  Future<CommunityRatings> fetchReviewStats(String gameId) async {
    await reviewsGate?.future;
    _checkOnline();
    if (failReviewReads) throw Exception('review stats read failed');
    final given = reviewStats[gameId];
    if (given != null) return given;
    final reviews = gameReviews[gameId] ?? const <GameReview>[];
    final rated = [for (final r in reviews) if (r.rating > 0) r.rating];
    final halves = List.filled(10, 0);
    for (final r in rated) {
      halves[(r * 2).round() - 1]++;
    }
    return CommunityRatings(
      ratings: rated.length,
      average: rated.isEmpty ? 0 : rated.reduce((a, b) => a + b) / rated.length,
      reviews: reviews.length,
      halfStars: halves,
    );
  }

  @override
  Future<void> reportReview({
    required String userId,
    required String gameId,
    required ReportReason reason,
  }) async {
    _checkOnline();
    if (failReviewReports) throw Exception('report failed');
    reviewReports.add((userId: userId, gameId: gameId, reason: reason));
  }

  // ---- Discussions ----

  /// The boards, the threads and the replies of each thread, as the server holds
  /// them. The fake lists them like the functions do: the ones written in last
  /// first (pinned ones first on a board), leaving out the threads and replies of
  /// the members blocked and what was reported, and pages them.
  List<DiscussionBoard> discussionBoards = const [
    DiscussionBoard(id: 'general', titleFallback: 'General', descriptionFallback: 'Anything about games.', threadCount: 2),
    DiscussionBoard(id: 'games', titleFallback: 'Game talk', descriptionFallback: 'One game at a time.'),
    DiscussionBoard(id: 'help', titleFallback: 'Help & tips', descriptionFallback: 'Stuck? Ask.'),
  ];
  final List<DiscussionThread> discussionThreads = [];
  final Map<String, List<DiscussionPost>> discussionPosts = {};
  final Map<String, SocialUser> blockedMembers = {};
  final List<({String? threadId, String? postId, ReportReason reason})> discussionReports = [];
  final List<String> deletedDiscussionThreads = [];
  final List<String> deletedDiscussionPosts = [];

  /// The threads and replies read, in order.
  final List<({String? board, String? game, int offset})> threadReads = [];
  final List<({String thread, int offset})> postReads = [];
  Completer<void>? discussionGate;
  bool failDiscussionReads = false;
  bool failDiscussionWrites = false;

  Future<void> _discussionRead() async {
    await discussionGate?.future;
    _checkOnline();
    if (failDiscussionReads) throw Exception('discussions read failed');
  }

  bool _hidden(String? threadId, String? postId, String authorId) =>
      blockedMembers.containsKey(authorId) ||
      discussionReports.any((r) => (threadId != null && r.threadId == threadId) || (postId != null && r.postId == postId));

  @override
  Future<List<DiscussionBoard>> fetchDiscussionBoards() async {
    await _discussionRead();
    return [
      for (final b in discussionBoards)
        DiscussionBoard(
          id: b.id,
          titleFallback: b.titleFallback,
          descriptionFallback: b.descriptionFallback,
          threadCount: discussionThreads.where((t) => t.boardId == b.id && !_hidden(null, null, t.author.id)).length,
        ),
    ];
  }

  @override
  Future<ResultsPage<DiscussionThread>> fetchDiscussionThreads({
    String? boardId,
    String? gameId,
    int offset = 0,
    int limit = CheckpointRepository.discussionThreadsPageSize,
  }) async {
    threadReads.add((board: boardId, game: gameId, offset: offset));
    await _discussionRead();
    final all = [
      for (final t in discussionThreads)
        if ((boardId == null || t.boardId == boardId) &&
            (gameId == null || t.game?.id == gameId) &&
            !_hidden(t.id, null, t.author.id))
          t,
    ]..sort((a, b) {
      final pinned = boardId == null ? 0 : (b.pinned ? 1 : 0) - (a.pinned ? 1 : 0);
      return pinned != 0 ? pinned : b.lastPostAt.compareTo(a.lastPostAt);
    });
    final page = all.skip(offset).take(limit).toList();
    return ResultsPage(page, hasMore: page.length >= limit);
  }

  @override
  Future<DiscussionThread?> fetchDiscussionThread(String id) async {
    await _discussionRead();
    for (final t in discussionThreads) {
      if (t.id == id && !_hidden(t.id, null, t.author.id)) return t;
    }
    return null;
  }

  @override
  Future<ResultsPage<DiscussionPost>> fetchDiscussionPosts(
    String threadId, {
    int offset = 0,
    int limit = CheckpointRepository.discussionPostsPageSize,
  }) async {
    postReads.add((thread: threadId, offset: offset));
    await _discussionRead();
    final all = [
      for (final p in discussionPosts[threadId] ?? const <DiscussionPost>[])
        if (!_hidden(null, p.id, p.author.id)) p,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final page = all.skip(offset).take(limit).toList();
    return ResultsPage(page, hasMore: page.length >= limit);
  }

  void _discussionWrite() {
    _checkOnline();
    if (failDiscussionWrites) throw Exception('discussion write failed');
  }

  @override
  Future<bool> deleteDiscussionThread(String id) async {
    _discussionWrite();
    deletedDiscussionThreads.add(id);
    discussionThreads.removeWhere((t) => t.id == id);
    discussionPosts.remove(id);
    return true;
  }

  @override
  Future<bool> deleteDiscussionPost(String id) async {
    _discussionWrite();
    deletedDiscussionPosts.add(id);
    for (final entry in discussionPosts.entries) {
      entry.value.removeWhere((p) => p.id == id);
    }
    return true;
  }

  @override
  Future<void> reportDiscussion({String? threadId, String? postId, required ReportReason reason}) async {
    _discussionWrite();
    discussionReports.add((threadId: threadId, postId: postId, reason: reason));
  }

  @override
  Future<void> blockMember(String userId) async {
    _discussionWrite();
    SocialUser? member;
    for (final t in discussionThreads) {
      if (t.author.id == userId) member = t.author;
    }
    for (final posts in discussionPosts.values) {
      for (final p in posts) {
        if (p.author.id == userId) member = p.author;
      }
    }
    blockedMembers[userId] = member ?? testMember(userId);
  }

  @override
  Future<void> unblockMember(String userId) async {
    _discussionWrite();
    blockedMembers.remove(userId);
  }

  @override
  Future<List<SocialUser>> fetchBlockedMembers() async {
    await _discussionRead();
    return blockedMembers.values.toList();
  }

  /// The reports of profiles, photos and lists the member sent.
  final List<({String userId, MemberReportSubject subject, ReportReason reason, String? listId})>
  memberReports = [];

  @override
  Future<void> reportMember({
    required String userId,
    required MemberReportSubject subject,
    required ReportReason reason,
    String? listId,
  }) async {
    _discussionWrite();
    memberReports.add((userId: userId, subject: subject, reason: reason, listId: listId));
  }

  /// What `completion_time_stats` answers for each game, by game id.
  /// [communityGate] holds the read until completed; [failCommunityReads]
  /// fails it.
  final Map<String, CommunityTimes> communityTimes = {};
  Completer<void>? communityGate;
  bool failCommunityReads = false;

  /// The games [fetchCommunityTimes] was asked about, in order.
  final List<String> communityReads = [];

  @override
  Future<CommunityTimes> fetchCommunityTimes(String gameId) async {
    communityReads.add(gameId);
    await communityGate?.future;
    _checkOnline();
    if (failCommunityReads) throw Exception('completion times read failed');
    return communityTimes[gameId] ?? const CommunityTimes();
  }

  /// What `following_recent_activity` answers, newest first. [feedGate] holds
  /// the read until completed; [failFeedReads] fails it.
  List<FriendActivity> followingActivity = [];
  Completer<void>? feedGate;
  bool failFeedReads = false;

  /// How many times [fetchFollowingActivity] was called.
  int feedReads = 0;

  @override
  Future<List<FriendActivity>> fetchFollowingActivity({
    int limit = CheckpointRepository.friendsFeedLimit,
  }) async {
    feedReads++;
    await feedGate?.future;
    _checkOnline();
    if (failFeedReads) throw Exception('feed read failed');
    return followingActivity.take(limit).toList();
  }

  /// Added up from [achievementSummaries], as the database does.
  @override
  Future<AchievementTotals> fetchAchievementTotals(String userId) async {
    memberReads.add('achievement-totals:$userId');
    _checkOnline();
    if (failAchievementTotals) throw Exception('achievement totals failed');
    final games = achievementSummaries[userId] ?? const <GameAchievementSummary>[];
    return AchievementTotals(
      unlocked: games.fold(0, (sum, g) => sum + g.unlocked),
      total: games.fold(0, (sum, g) => sum + g.total),
      games: games.length,
      completedGames: games.where((g) => g.unlocked == g.total).length,
    );
  }

  @override
  Future<List<GameAchievementSummary>> fetchAchievementSummary(String userId) async {
    memberReads.add('achievements:$userId');
    _checkOnline();
    if (failAchievementReads) throw Exception('achievements failed');
    return achievementSummaries[userId] ?? const [];
  }

  @override
  Future<List<Achievement>?> fetchPublicGameAchievements(
    String userId,
    String gameId,
  ) async {
    memberReads.add('achievements:$userId:$gameId');
    _checkOnline();
    if (failAchievementReads) throw Exception('achievements failed');
    return memberAchievements[(userId, gameId)];
  }

  /// The signed-in user's stored list for one of their games (null: never
  /// loaded). It sits with every member's in [memberAchievements], as in the
  /// database, where both are the `achievements` column of a library row.
  @override
  Future<List<Achievement>?> fetchGameAchievements(
    String userId,
    String gameId,
  ) async {
    _checkOnline();
    return memberAchievements[(userId, gameId)];
  }

  /// Like the function, stores what Steam answered where the database keeps it.
  @override
  Future<List<Achievement>?> fetchSteamGameAchievements(
    String userId,
    String gameId,
  ) async {
    memberReads.add('steam:$userId:$gameId');
    _checkOnline();
    final error = steamAchievementsError;
    if (error != null) throw error;
    final list = steamAchievements[(userId, gameId)];
    if (list == null) throw Exception('steam failed');
    memberAchievements[(userId, gameId)] = list;
    return list;
  }

  @override
  Stream<void> watchUserGames(String userId) => const Stream.empty();

  @override
  Stream<List<Map<String, dynamic>>> watchLogEntries(String userId) =>
      const Stream.empty();

  @override
  Stream<List<Map<String, dynamic>>> watchProfile(String userId) =>
      const Stream.empty();

  @override
  Stream<List<Map<String, dynamic>>> watchFollows(String userId) =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An [AuthService] whose session the test controls.
class FakeAuthService implements AuthService {
  FakeAuthService([this.user]);

  User? user;

  /// What the device has saved while [user] is null (see persistedUserId).
  String? persistedId;
  bool restoreWorks = false;
  int restoreCalls = 0;
  final _changes = StreamController<AuthState>.broadcast();

  @override
  User? get currentUser => user;

  @override
  Future<String?> persistedUserId() async => persistedId;

  @override
  Future<bool> restoreSession() async {
    restoreCalls++;
    if (restoreWorks && persistedId != null) {
      emit(testUser(persistedId!));
      return true;
    }
    return false;
  }

  @override
  Future<void> discardPersistedSession() async => persistedId = null;

  /// What [deleteAccount] throws, when set; the account is untouched then.
  Object? deleteError;
  int deleteCalls = 0;

  /// Like the real one: the server removes the account, then the session ends.
  @override
  Future<void> deleteAccount() async {
    deleteCalls++;
    final error = deleteError;
    if (error != null) throw error;
    emit(null);
  }

  @override
  Future<void> signOut() async => emit(null);

  /// The account has a verified authenticator app (two-factor is on).
  bool twoFactorOn = false;

  /// This session entered its code (aal2). A sign-out ends it, so the next
  /// sign-in starts at aal1, as with Supabase.
  bool aal2 = false;

  /// The code the authenticator app shows; any other is refused.
  String validCode = '123456';

  /// What [enrollTwoFactor] and [disableTwoFactor] throw, when set.
  Object? twoFactorError;

  /// Every two-factor call, as `verify:<code>`, `enroll`,
  /// `confirm:<factor>:<code>`, `cancel:<factor>`, `disable`, `generate` and
  /// `redeem:<code>`.
  final List<String> twoFactorCalls = [];

  /// The account's unused backup codes, as they are shown. [generateBackupCodes]
  /// replaces them with [newBackupCodes]; [redeemBackupCode] takes one.
  List<String> backupCodes = const ['AAAAA-BBBBB'];

  static const newBackupCodes = [
    '7K3QD-M9XHT', 'P2W8N-4RJ6C', 'HX5ZT-0QG7M', 'B9VKE-31SYD', 'N6C2R-WF8JA',
    'T4MQX-7HZ05', 'G1DPS-K9VE3', 'Y8RJ2-C6TNW', 'E5HZB-Q0XM4', 'S3WAF-8PKG7',
  ];

  /// What [generateBackupCodes] and [redeemBackupCode] throw, when set.
  Object? backupCodeError;

  static const setup = TotpSetup(
    factorId: 'factor-1',
    secret: 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP',
    uri: 'otpauth://totp/Checkpoint:u1%40example.com?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Checkpoint',
  );

  static const _wrongCode = AuthException('Invalid TOTP code entered', code: 'mfa_verification_failed');

  @override
  bool get hasTwoFactor => user != null && twoFactorOn;

  @override
  bool get needsSecondFactor => user != null && twoFactorOn && !aal2;

  /// Like the real one: a right code makes the session aal2 and Supabase
  /// announces it.
  @override
  Future<void> verifySecondFactor(String code) async {
    twoFactorCalls.add('verify:$code');
    if (code != validCode) throw _wrongCode;
    aal2 = true;
    emit(user, event: AuthChangeEvent.mfaChallengeVerified);
  }

  @override
  Future<TotpSetup> enrollTwoFactor() async {
    twoFactorCalls.add('enroll');
    final error = twoFactorError;
    if (error != null) throw error;
    return setup;
  }

  @override
  Future<void> confirmTwoFactor(String factorId, String code) async {
    twoFactorCalls.add('confirm:$factorId:$code');
    if (code != validCode) throw _wrongCode;
    twoFactorOn = true;
    aal2 = true;
    emit(user, event: AuthChangeEvent.mfaChallengeVerified);
  }

  @override
  Future<void> cancelTwoFactor(String factorId) async =>
      twoFactorCalls.add('cancel:$factorId');

  /// Like the real one: the factor goes, then the refreshed session says so.
  @override
  Future<void> disableTwoFactor() async {
    twoFactorCalls.add('disable');
    final error = twoFactorError;
    if (error != null) throw error;
    twoFactorOn = false;
    emit(user, event: AuthChangeEvent.tokenRefreshed);
  }

  @override
  Future<List<String>> generateBackupCodes() async {
    twoFactorCalls.add('generate');
    final error = backupCodeError;
    if (error != null) throw error;
    return backupCodes = newBackupCodes;
  }

  /// Like the real one: a code of the account's (typed any way) turns
  /// two-factor off, then the refreshed session says so; any other is refused
  /// with the function's INVALID_CODE.
  @override
  Future<void> redeemBackupCode(String code) async {
    twoFactorCalls.add('redeem:$code');
    final error = backupCodeError;
    if (error != null) throw error;
    String plain(String c) => c.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    if (!twoFactorOn || !backupCodes.any((c) => plain(c) == plain(code))) {
      throw const FunctionException(
        status: 400,
        details: {'error': 'That backup code is not valid', 'code': 'INVALID_CODE'},
      );
    }
    backupCodes = const [];
    twoFactorOn = false;
    emit(user, event: AuthChangeEvent.tokenRefreshed);
  }

  /// What [signInWithGoogle] throws, when set; otherwise it signs `u1` in.
  Object? signInError;

  @override
  Future<void> signInWithGoogle() async {
    final error = signInError;
    if (error != null) throw error;
    emit(testUser('u1'));
  }

  /// Whether the device offers Sign in with Apple (the real one: iOS only).
  bool offersApple = false;

  @override
  bool get offersAppleSignIn => offersApple;

  /// What [signInWithApple] throws, when set; otherwise it signs `u1` in.
  Object? appleError;
  int appleCalls = 0;

  @override
  Future<void> signInWithApple() async {
    appleCalls++;
    final error = appleError;
    if (error != null) throw error;
    emit(testUser('u1'));
  }

  /// What the email calls ([signInWithEmail], [signUpWithEmail],
  /// [sendPasswordReset]) throw, when set.
  Object? emailError;

  /// Whether [signUpWithEmail] leaves the new account waiting for its email
  /// address to be confirmed (no session), as with "Confirm email" on.
  bool signUpNeedsConfirmation = false;

  /// Every email call, as `signIn:<email>:<password>`,
  /// `signUp:<email>:<password>:<name>` and `reset:<email>`.
  final List<String> emailCalls = [];

  @override
  Future<void> signInWithEmail(String email, String password) async {
    emailCalls.add('signIn:$email:$password');
    final error = emailError;
    if (error != null) throw error;
    emit(testUser('u1'));
  }

  @override
  Future<bool> signUpWithEmail(
    String email,
    String password, {
    String? displayName,
  }) async {
    emailCalls.add('signUp:$email:$password:$displayName');
    final error = emailError;
    if (error != null) throw error;
    if (signUpNeedsConfirmation) return false;
    emit(testUser('u1'));
    return true;
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    emailCalls.add('reset:$email');
    final error = emailError;
    if (error != null) throw error;
  }

  /// What [updatePassword] throws, when set; the password is unchanged then.
  Object? passwordError;

  /// Every password [updatePassword] was asked to save.
  final List<String> passwordUpdates = [];

  /// Like the real one: the server saves it and Supabase announces the update.
  @override
  Future<void> updatePassword(String password) async {
    passwordUpdates.add(password);
    final error = passwordError;
    if (error != null) throw error;
    emit(user, event: AuthChangeEvent.userUpdated);
  }

  /// Signs [next] in the way a password reset link does.
  void openResetLink(User next, {bool fromBroadcast = false}) => emit(
    next,
    event: AuthChangeEvent.passwordRecovery,
    fromBroadcast: fromBroadcast,
  );

  /// What [signOutOtherDevices] throws, when set.
  Object? signOutOthersError;
  int signOutOthersCalls = 0;

  @override
  Future<void> signOutOtherDevices() async {
    signOutOthersCalls++;
    final error = signOutOthersError;
    if (error != null) throw error;
  }

  @override
  Stream<AuthState> get changes => _changes.stream;

  /// Signs [next] in (or out, when null) and announces it, as Supabase does,
  /// with [event] in place of signedIn / signedOut when given. [fromBroadcast]
  /// is an event another browser tab passed on.
  void emit(User? next, {AuthChangeEvent? event, bool fromBroadcast = false}) {
    user = next;
    if (next == null) aal2 = false;
    _changes.add(
      AuthState(
        event ??
            (next == null
                ? AuthChangeEvent.signedOut
                : AuthChangeEvent.signedIn),
        next == null
            ? null
            : Session(accessToken: 't', tokenType: 'bearer', user: next),
        fromBroadcast: fromBroadcast,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [ConnectivityService] the test drives.
class FakeConnectivity implements ConnectivityService {
  final controller = StreamController<bool>.broadcast();

  @override
  Stream<bool> get onlineChanges => controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [GameApiService] whose browse lists the test controls. [answer] gives the
/// page for a mode and offset (null = the request failed); by default every mode
/// has one page of two games named after it. [gate] holds every answer until
/// completed, to have a request in flight.
class FakeBrowseApi extends GameApiService {
  ResultsPage<BrowseEntry>? Function(BrowseMode mode, int offset) answer =
      (mode, offset) => ResultsPage([
        testEntry('${mode.name}-1'),
        testEntry('${mode.name}-2'),
      ], hasMore: false);
  Completer<void>? gate;

  /// What was asked, in order.
  final List<(BrowseMode, int)> calls = [];

  int callsFor(BrowseMode mode) => calls.where((c) => c.$1 == mode).length;

  @override
  Future<ResultsPage<BrowseEntry>?> browseGames(
    BrowseMode mode, {
    int offset = 0,
    int limit = GameApiService.browsePageSize,
  }) async {
    calls.add((mode, offset));
    await gate?.future;
    return answer(mode, offset);
  }
}

/// A [GameApiService] whose game details the test controls. [answer] gives the
/// details for an IGDB id (null = the request failed). [gate] holds every answer
/// until completed, to have a request in flight.
class FakeDetailsApi extends GameApiService {
  GameDetails? Function(int igdbId) answer = (id) => null;
  Completer<void>? gate;

  /// The IGDB ids asked for, in order.
  final List<int> calls = [];

  @override
  Future<GameDetails?> fetchDetails(int igdbId) async {
    calls.add(igdbId);
    await gate?.future;
    return answer(igdbId);
  }
}

/// A [GameApiService] whose companies and their games (and, as a
/// [FakeDetailsApi], game details) the test controls. [company] gives a
/// company's page (null = the request failed); [games] gives a page of a list
/// for an offset (null = failed), by default one page of two games named after
/// the list; [companies] what the studio search finds. [gate] holds every
/// answer until completed.
class FakeCompanyApi extends FakeDetailsApi {
  Company? Function(int id) company = (id) => Company(id: id, name: 'Company $id', publishedCount: 3, developedCount: 2);
  ResultsPage<CompanyGame>? Function(CompanyGamesKey key, int offset) games = (key, offset) => ResultsPage([
    companyGame('${key.$1}-${key.$2.name}-1'),
    companyGame('${key.$1}-${key.$2.name}-2'),
  ], hasMore: false);

  /// What the studio search finds for a query (null = the request failed), as one page.
  List<CompanySummary>? Function(String query) companies = (query) => [
    CompanySummary(id: 56, name: 'Studio $query'),
  ];

  final List<int> companyCalls = [];
  final List<(CompanyGamesKey, int)> gameCalls = [];

  @override
  Future<ResultsPage<CompanySummary>?> searchCompanies(
    String query, {
    StudioFilters filters = StudioFilters.none,
    int offset = 0,
    int limit = GameApiService.searchPageSize,
  }) async {
    await gate?.future;
    final found = companies(query);
    return found == null ? null : ResultsPage(found, hasMore: false);
  }

  @override
  Future<Company?> fetchCompany(int companyId) async {
    companyCalls.add(companyId);
    await gate?.future;
    return company(companyId);
  }

  @override
  Future<ResultsPage<CompanyGame>?> companyGames(
    int companyId, {
    CompanyRole role = CompanyRole.any,
    DiscoverSort sort = DiscoverSort.popular,
    int offset = 0,
    int limit = GameApiService.browsePageSize,
  }) async {
    final key = (companyId, role, sort);
    gameCalls.add((key, offset));
    await gate?.future;
    return games(key, offset);
  }
}

/// A game on a company's page, developed by it.
CompanyGame companyGame(String id) => CompanyGame(testEntry(id), developed: true, published: false);

/// A [GameApiService] whose catalog backfill the test controls. [answer] gives
/// what a batch of IGDB ids comes back with; by default every game is filled in
/// with [backfilledPlatforms] and [backfilledGenres]. [gate] holds every answer
/// until completed, to have a request in flight.
class FakeBackfillApi extends GameApiService {
  static const backfilledPlatforms = [GamePlatform.pc, GamePlatform.ps3, GamePlatform.xbox360];
  static const backfilledGenres = ['Role-playing (RPG)', 'Adventure'];

  CatalogBackfillResult Function(List<int> igdbIds) answer = (ids) => CatalogBackfillResult([
    for (final id in ids)
      GameDetails(igdbId: id, platforms: backfilledPlatforms, genres: backfilledGenres),
  ]);
  Completer<void>? gate;

  /// Each batch of IGDB ids asked for, in order.
  final List<List<int>> calls = [];

  @override
  Future<CatalogBackfillResult> backfillCatalog(List<int> igdbIds) async {
    calls.add(List.of(igdbIds));
    await gate?.future;
    return answer(igdbIds);
  }
}

/// IGDB's details for a game, as [FakeDetailsApi] answers by default: Skyrim's
/// exact platforms, some attributes, a storyline and one similar game.
GameDetails testDetails({
  int igdbId = 7,
  List<GamePlatform> platforms = const [GamePlatform.pc, GamePlatform.ps3, GamePlatform.xbox360],
  List<Game>? similarGames,
  Map<String, int> companyIds = const {},
}) => GameDetails(
  igdbId: igdbId,
  platforms: platforms,
  genres: const ['Role-playing (RPG)', 'Adventure'],
  themes: const ['Fantasy', 'Open world'],
  gameModes: const ['Single player'],
  perspectives: const ['First person'],
  engines: const ['Creation Engine'],
  developers: const ['Bethesda Game Studios'],
  publishers: const ['Bethesda Softworks'],
  companyIds: companyIds,
  storyline: 'The Empire of Tamriel is on the edge.',
  similarGames: similarGames ?? [testGame('similar-1', title: 'Oblivion', status: null, cover: false, igdbId: 306)],
);

/// The browser and Steam, for "Sign in through Steam": [open] asks the server to
/// start (through [repository]), waits for [gate] when it is set (the member is
/// still on Steam's page), then, when [signsIn], has the server save [steamId]
/// on the profile, and answers [outcome] (by default the desktop return: `ok`).
class FakeSteamLink implements SteamLinkFlow {
  FakeSteamLink(this.repository);

  final FakeRepository repository;
  String steamId = '76561198000000000';
  bool signsIn = true;
  SteamLinkOutcome outcome = const SteamLinkReturned('ok');

  /// Thrown by [open] after the start, when set (no browser, say).
  Object? openError;
  Completer<void>? gate;

  /// Steam's pages that were opened.
  final List<Uri> opened = [];
  int cancels = 0;
  int browserCloses = 0;

  @override
  Future<SteamLinkOutcome> open(StartSteamLink start) async {
    opened.add(await start(null));
    final error = openError;
    if (error != null) throw error;
    await gate?.future;
    if (signsIn) repository.steamId = steamId;
    return outcome;
  }

  @override
  Future<void> cancel() async => cancels++;

  @override
  Future<void> closeBrowser() async => browserCloses++;
}

/// Posts to the discussions like the `discussions` function would, into the
/// [repo]'s threads and replies as [me]. [failWith] refuses the next posts with
/// that failure; [gate] holds every call until completed.
class FakeDiscussionApi extends DiscussionApiService {
  FakeDiscussionApi(this.repo, {required this.me});

  final FakeRepository repo;
  final SocialUser me;
  DiscussionFailure? failWith;
  Completer<void>? gate;

  final List<({String board, String title, String text, String? gameId})> threadCalls = [];
  final List<({String thread, String text})> replyCalls = [];
  int _made = 0;

  @override
  Future<String> createThread({
    required String boardId,
    required String title,
    required String text,
    String? gameId,
  }) async {
    threadCalls.add((board: boardId, title: title, text: text, gameId: gameId));
    await gate?.future;
    final failure = failWith;
    if (failure != null) throw failure;
    final id = 'new-thread-${++_made}';
    repo.discussionThreads.add(
      DiscussionThread(
        id: id,
        boardId: boardId,
        author: me,
        title: title,
        text: text,
        createdAt: DateTime.now().toUtc(),
        lastPostAt: DateTime.now().toUtc(),
        game: gameId == null ? null : DiscussionGame(id: gameId, title: 'Game $gameId'),
      ),
    );
    return id;
  }

  @override
  Future<void> reply(String threadId, String text) async {
    replyCalls.add((thread: threadId, text: text));
    await gate?.future;
    final failure = failWith;
    if (failure != null) throw failure;
    final now = DateTime.now().toUtc();
    final posts = repo.discussionPosts.putIfAbsent(threadId, () => []);
    posts.add(DiscussionPost(id: 'new-post-${++_made}', threadId: threadId, author: me, text: text, createdAt: now));
    final i = repo.discussionThreads.indexWhere((t) => t.id == threadId);
    if (i >= 0) {
      final t = repo.discussionThreads[i];
      repo.discussionThreads[i] = DiscussionThread(
        id: t.id,
        boardId: t.boardId,
        author: t.author,
        title: t.title,
        text: t.text,
        createdAt: t.createdAt,
        lastPostAt: now,
        replyCount: posts.length,
        pinned: t.pinned,
        locked: t.locked,
        game: t.game,
      );
    }
  }
}

