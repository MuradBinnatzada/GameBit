part of '../checkpoint_repository.dart';

// Rows from the database as the app's models, and the bits they are built from.

UserProfile _profileFromRow(Map<String, dynamic> row, {User? fallbackUser}) {
  final metadata = fallbackUser?.userMetadata ?? const <String, dynamic>{};
  final name =
      _firstText([
        row[Db.displayName],
        metadata['full_name'],
        metadata['name'],
      ]) ??
      L10n.current.defaultPlayerName;

  return UserProfile(
    name: name,
    handle: _withAt(
      _firstText([row[Db.handle]]) ??
          _handleFrom(name, fallbackUser?.id ?? 'guest'),
    ),
    bio: _firstText([row[Db.bio]]) ?? '',
    avatarUrl: _firstText([row[Db.avatarUrl]]),
    steamId: _firstText([row[Db.steamId]]),
    connectedServices: connectedServicesFromDb(row[Db.connectedServices]),
    psnId: _firstText([row[Db.psnId]]),
    xboxId: _firstText([row[Db.xboxId]]),
    discordId: _firstText([row[Db.discordId]]),
    instagramId: _firstText([row[Db.instagramId]]),
    twitchId: _firstText([row[Db.twitchId]]),
    showSteamAchievements: row[Db.showSteamAchievements] != false,
    flair: _flairFromRow(row),
    joined: _date(row[Db.createdAt]) ?? DateTime.now(),
    followers: 0,
    following: 0,
  );
}

/// [value] trimmed, or null when it is not text or is blank.
String? _text(Object? value) => _firstText([value]);

/// The author columns of a discussion row (`author_*`) as a member.
SocialUser _authorFromRow(Map<String, dynamic> row) => _socialUserFromProfile({
  Db.id: row['author_id'],
  Db.handle: row['author_handle'],
  Db.displayName: row['author_name'],
  Db.avatarUrl: row['author_avatar_url'],
  Db.avatarFrame: row['author_avatar_frame'],
  Db.showcasedMilestones: row['author_showcase'],
});

/// A thread of `discussion_threads_page` ([textColumn] `preview`) or
/// `discussion_thread` (`body`), or null when it lacks what a thread needs.
DiscussionThread? _threadFromRow(Map<String, dynamic> row, String textColumn) {
  final id = _text(row['id']);
  final boardId = _text(row['board_id']);
  final title = _text(row['title']);
  final text = _text(row[textColumn]);
  final created = _date(row['created_at']);
  if (id == null || boardId == null || title == null || text == null || created == null) {
    return null;
  }
  final gameId = _text(row['game_id']);
  final gameTitle = _text(row['game_title']);
  return DiscussionThread(
    id: id,
    boardId: boardId,
    author: _authorFromRow(row),
    title: title,
    text: text,
    createdAt: created,
    lastPostAt: _date(row['last_post_at']) ?? created,
    replyCount: _int(row['reply_count']),
    pinned: row['pinned'] == true,
    locked: row['locked'] == true,
    game: gameId == null || gameTitle == null
        ? null
        : DiscussionGame(
            id: gameId,
            title: gameTitle,
            igdbId: _intOrNull(row['game_igdb_id']),
            coverUrl: _text(row['game_cover_url']),
          ),
  );
}

SocialUser _socialUserFromProfile(Map<String, dynamic> row) {
  final name = _firstText([row[Db.displayName], row[Db.handle]]) ?? L10n.current.defaultPlayerName;
  return SocialUser(
    id: '${row[Db.id]}',
    name: name,
    handle: _withAt(
      _firstText([row[Db.handle]]) ?? _handleFrom(name, '${row[Db.id]}'),
    ),
    // Only the Users tab selects the counts; other lists leave them at 0.
    gamesLogged: _int(row[Db.gamesCount]),
    followers: _int(row[Db.followersCount]),
    startsFollowed: row[Db.viewerFollows] == true,
    avatarUrl: _firstText([row[Db.avatarUrl]]),
    flair: _flairFromRow(row),
  );
}

/// The frame, title and showcase of a `profiles` or `public_profiles` row, or
/// of a member list's (which has no title).
ProfileFlair _flairFromRow(Map<String, dynamic> row) => ProfileFlair(
  frameId: _firstText([row[Db.avatarFrame]]),
  titleId: _firstText([row[Db.titleMilestone]]),
  showcaseIds: _strings(row[Db.showcasedMilestones]),
);

PublicProfile _publicProfileFromRow(Map<String, dynamic> row) {
  final name = _firstText([row[Db.displayName], row[Db.handle]]) ?? L10n.current.defaultPlayerName;
  return PublicProfile(
    id: '${row[Db.id]}',
    name: name,
    handle: _withAt(
      _firstText([row[Db.handle]]) ?? _handleFrom(name, '${row[Db.id]}'),
    ),
    avatarUrl: _firstText([row[Db.avatarUrl]]),
    steamConnected: row[Db.steamConnected] == true,
    // Only an explicit "no" hides them, as the column's default is "yes".
    showSteamAchievements: row[Db.showSteamAchievements] != false,
    services: connectedServicesFromDb(row[Db.connectedServices]),
    bio: _firstText([row[Db.bio]]),
    steamId: _firstText([row[Db.steamId]]),
    psnId: _firstText([row[Db.psnId]]),
    xboxId: _firstText([row[Db.xboxId]]),
    discordId: _firstText([row[Db.discordId]]),
    instagramId: _firstText([row[Db.instagramId]]),
    twitchId: _firstText([row[Db.twitchId]]),
    joined: _date(row[Db.joinedAt]),
    flair: _flairFromRow(row),
  );
}

/// A play session on someone's profile, from a `public_recent_activity` row. The
/// game is the catalog game, with none of the player's own state.
ActivityEntry _activityFromRow(Map<String, dynamic> row) => ActivityEntry(
  game: _gameFromCatalogRow({...row, Db.id: row[Db.gameId]}),
  hours: _double(row[Db.hours]),
  platform: gamePlatformFromDb(row[Db.platform]) ?? GamePlatform.pc,
  at: _date(row[Db.loggedAt]) ?? DateTime.now(),
);

/// A game on another member's profile: the catalog data and the owner's tracking
/// fields, from a `public_user_games` row. The purchase price is never read.
Game _gameFromPublicRow(Map<String, dynamic> row) {
  final catalogGame = _gameFromCatalogRow({...row, Db.id: row[Db.gameId]});
  return catalogGame.copyWith(
    status: gameStatusFromDb(row[Db.status]),
    rating: _double(row[Db.rating]),
    hoursPlayed: _double(row[Db.hoursPlayed]),
    playedOn: gamePlatformFromDb(row[Db.playedOn]),
    dateAdded: _date(row[Db.dateAdded]),
    isFavorite: row[Db.isFavorite] == true,
    review: _firstText([row[Db.review]]) ?? '',
    perfected: row[Db.perfected] == true,
  ).withBackdrop(_firstText([row[Db.customBackdropUrl]])).withCompletedAt(_date(row[Db.completedAt]));
}

GameAttributes _attributesFromRow(Map<String, dynamic> row) => GameAttributes(
  themes: _strings(row[Db.themes]),
  gameModes: _strings(row[Db.gameModes]),
  perspectives: _strings(row[Db.playerPerspectives]),
  engines: _strings(row[Db.gameEngines]),
  developers: _strings(row[Db.developers]),
  publishers: _strings(row[Db.publishers]),
);

GameAchievementSummary _achievementSummaryFromRow(Map<String, dynamic> row) =>
    GameAchievementSummary(
      gameId: '${row[Db.gameId]}',
      title: _firstText([row[Db.title]]) ?? L10n.current.untitledGame,
      coverUrl: _firstText([row[Db.coverUrl]]),
      unlocked: _int(row['unlocked']),
      total: _int(row['total']),
    );

Game _gameFromCatalogRow(Map<String, dynamic> row) {
  final id = '${row[Db.id]}';
  final title = _firstText([row[Db.title]]) ?? L10n.current.untitledGame;
  final steamAppId = _intOrNull(row[Db.steamAppId]);
  // Release platforms only: a stored Steam Deck / Emulator is stray data (see
  // releasePlatformsFromDb). Steam sync used to leave the list empty, and a game
  // owned on Steam is a PC game; any other game with none known keeps none rather
  // than being given a platform it may never have been released on.
  var platforms = releasePlatformsFromDb(_strings(row[Db.platforms]));
  if (platforms.isEmpty &&
      (steamAppId != null || id.startsWith(legacySteamIdPrefix))) {
    platforms = const [GamePlatform.pc];
  }
  final genres = _strings(row[Db.genres]);
  return Game(
    id: id,
    title: title,
    publisher: _firstText([row[Db.publisher]]) ?? L10n.current.unknownPublisher,
    developer: _firstText([row[Db.developer]]) ?? L10n.current.unknownDeveloper,
    releaseYear: _int(row[Db.releaseYear]),
    platforms: platforms,
    genres: genres,
    synopsis: _firstText([row[Db.summary]]) ?? '',
    coverColors: coverColorsFor(id, title),
    coverIcon: coverIconFor(genres, platforms),
    coverUrl: _firstText([row[Db.coverUrl]]),
    igdbId: _intOrNull(row[Db.igdbId]),
    steamAppId: steamAppId,
    releaseDate: _releaseDay(row[Db.releaseDate]),
  );
}

Game _gameFromUserGameRow(Map<String, dynamic> row) {
  final nested = row[Db.games];
  final gameRow = nested is Map<String, dynamic>
      ? nested
      : Map<String, dynamic>.from(nested as Map);
  final catalogGame = _gameFromCatalogRow(gameRow);
  assert(row.containsKey(Db.isFavorite));
  return catalogGame.copyWith(
    status: gameStatusFromDb(row[Db.status]),
    rating: _double(row[Db.rating]),
    hoursPlayed: _double(row[Db.hoursPlayed]),
    playedOn: gamePlatformFromDb(row[Db.playedOn]),
    purchasePrice: _double(row[Db.purchasePrice]),
    dateAdded: _date(row[Db.dateAdded]),
    isFavorite: row[Db.isFavorite] == true,
    review: _firstText([row[Db.review]]) ?? '',
    stillPlaying: row[Db.stillPlaying] == true,
    perfected: row[Db.perfected] == true,
    // `achievements` is intentionally not read here: fetchUserGames doesn't
    // select it. See fetchGameAchievements.
  ).withBackdrop(_firstText([row[Db.customBackdropUrl]])).withCompletedAt(_date(row[Db.completedAt])).withCompletionTime(_completionTimeFromEmbed(row[Db.completionTimes]));
}

/// The member's completion time embedded in their library row: one object, or
/// null when they gave none. A list of at most one is read too, in case the API
/// ever embeds it as one-to-many.
CompletionTime? _completionTimeFromEmbed(Object? value) =>
    CompletionTime.fromJson(value is List ? value.firstOrNull : value);

GameList _listFromRow(Map<String, dynamic> row) {
  final items = [
    for (final item in row[Db.gameListItems] as List? ?? const [])
      if (item is Map && item[Db.games] is Map) Map<String, dynamic>.from(item),
  ]..sort((a, b) => _int(a[Db.position]).compareTo(_int(b[Db.position])));
  return GameList(
    id: '${row[Db.id]}',
    ownerId: '${row[Db.userId]}',
    title: _firstText([row[Db.title]]) ?? L10n.current.untitledList,
    description: _firstText([row[Db.description]]) ?? '',
    isPublic: row[Db.isPublic] == true,
    games: [
      for (final item in items)
        _gameFromCatalogRow(Map<String, dynamic>.from(item[Db.games] as Map)),
    ],
    updatedAt: _date(row[Db.updatedAt]),
  );
}

LogEntry _logFromRow(Map<String, dynamic> row) => LogEntry(
  id: '${row[Db.id]}',
  gameId: '${row[Db.gameId]}',
  timestamp: _date(row[Db.loggedAt]) ?? DateTime.now(),
  hours: _double(row[Db.hours]),
  platform: gamePlatformFromDb(row[Db.platform]) ?? GamePlatform.pc,
  note: _firstText([row[Db.note]]) ?? '',
  fromSteam: row[Db.source] == 'steam',
);

List<String> _strings(Object? value) {
  if (value is List) {
    return value.map((v) => '$v').where((v) => v.trim().isNotEmpty).toList();
  }
  if (value is String && value.trim().isNotEmpty) return [value.trim()];
  return const [];
}

String? _firstText(List<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return null;
}

String _withAt(String handle) => handle.startsWith('@') ? handle : '@$handle';

String _handleFrom(String seed, String suffix) {
  final base = seed
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  final safeBase = base.length < 3 ? 'player' : base;
  final safeSuffix = suffix.replaceAll('-', '');
  final handle = '${safeBase}_${safeSuffix.substring(0, math.min(6, safeSuffix.length))}';
  return handle.substring(0, math.min(24, handle.length));
}

DateTime? _date(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse('$value')?.toLocal();
}

/// A `date` column ("2026-11-14") as that calendar day, at midnight on the
/// device: a release day is the same day everywhere, not an instant.
DateTime? _releaseDay(Object? value) {
  final parsed = value == null ? null : DateTime.tryParse('$value');
  return parsed == null ? null : DateTime(parsed.year, parsed.month, parsed.day);
}

/// [d]'s calendar day as a `date` column takes it: "2026-11-14".
String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

double _double(Object? value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? fallback;
}

int _int(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

int? _intOrNull(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

