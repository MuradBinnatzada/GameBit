import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/achievement.dart';
import 'package:checkpoint/models/completion_time.dart';
import 'package:checkpoint/models/game_cover.dart';

enum GameStatus {
  playing(Icons.play_circle_rounded, Color(0xFFBB86FC)),
  toPlay(Icons.inventory_2_rounded, Color(0xFF4FC3F7)),
  completed(Icons.verified_rounded, Color(0xFF7DDC9C)),
  dropped(Icons.block_rounded, Color(0xFFCF6679)),
  wishlist(Icons.bookmark_rounded, Color(0xFFFFC857));

  const GameStatus(this.icon, this.color);
  final IconData icon;
  final Color color;

  String get label => switch (this) {
    playing => L10n.current.statusPlaying,
    toPlay => L10n.current.statusToPlay,
    completed => L10n.current.statusCompleted,
    dropped => L10n.current.statusDropped,
    wishlist => L10n.current.statusWishlist,
  };
}

String gameStatusToDb(GameStatus status) => switch (status) {
      GameStatus.playing => 'playing',
      GameStatus.toPlay => 'to_play',
      GameStatus.completed => 'completed',
      GameStatus.dropped => 'dropped',
      GameStatus.wishlist => 'wishlist',
    };

GameStatus? gameStatusFromDb(Object? value) {
  final raw = value?.toString().trim();
  return switch (raw) {
    'playing' => GameStatus.playing,
    'to_play' || 'toPlay' || 'To Play' => GameStatus.toPlay,
    'completed' => GameStatus.completed,
    'dropped' => GameStatus.dropped,
    'wishlist' => GameStatus.wishlist,
    _ => null,
  };
}

/// Who makes a platform, or what kind of device it is. It gives each platform its
/// icon and colour, and says which ones an emulator can stand in for.
enum PlatformFamily {
  pc(Icons.desktop_windows_rounded, Color(0xFF8AB4F8)),
  playstation(Icons.sports_esports_rounded, Color(0xFF6E96FF)),
  xbox(Icons.videogame_asset_rounded, Color(0xFF6CC24A)),
  nintendo(Icons.videogame_asset_outlined, Color(0xFFFF6B6B)),
  sega(Icons.album_rounded, Color(0xFF4FC3F7)),
  mobile(Icons.smartphone_rounded, Color(0xFFFFB74D)),
  vr(Icons.headset_rounded, Color(0xFFB388FF)),

  /// What no maker owns: the emulator.
  other(Icons.memory_rounded, Color(0xFF4DB6AC));

  const PlatformFamily(this.icon, this.color);
  final IconData icon;
  final Color color;

  /// Game consoles and handhelds: the families an emulator can stand in for.
  bool get isConsole =>
      this == playstation || this == xbox || this == nintendo || this == sega;
}

/// A platform a game was released on or is played on, down to the console
/// (PS3 and PS4 are two platforms, as on IGDB). Declared newest first within
/// each family, which is the order the pickers list them in.
///
/// The enum name is what is stored (`games.platforms`, `user_games.played_on`,
/// `log_entries.platform`), except for [emulator] (see [gamePlatformToDb]).
/// [playstation], [xbox], [nintendo] and [mobile] are not a console but the whole
/// family: older versions of the app stored those, so saved data keeps them.
/// Nothing writes them any more, and a game's real platforms replace them as soon
/// as its details load.
enum GamePlatform {
  pc('PC', PlatformFamily.pc),
  steamDeck(
    'Steam Deck',
    PlatformFamily.pc,
    icon: Icons.videogame_asset_rounded,
    color: Color(0xFF66C0F4),
  ),

  ps5('PS5', PlatformFamily.playstation),
  ps4('PS4', PlatformFamily.playstation),
  ps3('PS3', PlatformFamily.playstation),
  ps2('PS2', PlatformFamily.playstation),
  ps1('PS1', PlatformFamily.playstation),
  vita('PS Vita', PlatformFamily.playstation),
  psp('PSP', PlatformFamily.playstation),
  playstation('PlayStation', PlatformFamily.playstation),

  xboxSeries('Xbox Series X|S', PlatformFamily.xbox),
  xboxOne('Xbox One', PlatformFamily.xbox),
  xbox360('Xbox 360', PlatformFamily.xbox),
  xboxOriginal('Xbox (Original)', PlatformFamily.xbox),
  xbox('Xbox', PlatformFamily.xbox),

  nswitch2('Switch 2', PlatformFamily.nintendo),
  nswitch('Switch', PlatformFamily.nintendo),
  wiiU('Wii U', PlatformFamily.nintendo),
  wii('Wii', PlatformFamily.nintendo),
  gamecube('GameCube', PlatformFamily.nintendo),
  n64('Nintendo 64', PlatformFamily.nintendo),
  snes('SNES', PlatformFamily.nintendo),
  nes('NES', PlatformFamily.nintendo),
  n3ds('3DS', PlatformFamily.nintendo),
  nds('DS', PlatformFamily.nintendo),
  gba('Game Boy Advance', PlatformFamily.nintendo),
  gbc('Game Boy Color', PlatformFamily.nintendo),
  gameBoy('Game Boy', PlatformFamily.nintendo),
  virtualBoy('Virtual Boy', PlatformFamily.nintendo),
  nintendo('Nintendo', PlatformFamily.nintendo),

  dreamcast('Dreamcast', PlatformFamily.sega),
  saturn('Saturn', PlatformFamily.sega),
  genesis('Genesis', PlatformFamily.sega),
  masterSystem('Master System', PlatformFamily.sega),
  gameGear('Game Gear', PlatformFamily.sega),

  ios('iOS', PlatformFamily.mobile),
  android('Android', PlatformFamily.mobile),
  mobile('Mobile', PlatformFamily.mobile),

  vr('VR', PlatformFamily.vr),
  emulator('Emulator', PlatformFamily.other);

  const GamePlatform(this._label, this.family, {this._icon, this._color});

  final String _label;
  final PlatformFamily family;

  /// Its name: the console's own, which no language translates, except for
  /// the few that are words.
  String get label => switch (this) {
    xboxOriginal => L10n.current.platformXboxOriginal,
    mobile => L10n.current.platformMobile,
    emulator => L10n.current.platformEmulator,
    _ => _label,
  };
  final IconData? _icon;
  final Color? _color;

  IconData get icon => _icon ?? family.icon;
  Color get color => _color ?? family.color;

  /// True for the ways of playing a game that are never a release platform: no
  /// game is "released on" Steam Deck or an emulator. They can be chosen as
  /// "played on" (see [Game.playedOnOptions]) but are not part of
  /// [Game.platforms], which holds release platforms only.
  bool get isManualOnly => this == steamDeck || this == emulator;

  /// A console or handheld, which an emulator can stand in for.
  bool get isConsole => family.isConsole;

  /// What the pickers offer for a game whose release platforms are not known (see
  /// [Game.playedOnOptions]): the platforms people play on today. A game whose
  /// platforms are known is offered exactly those.
  static const List<GamePlatform> selectable = [
    pc,
    steamDeck,
    ps5,
    ps4,
    xboxSeries,
    xboxOne,
    nswitch,
    ios,
    android,
    vr,
    emulator,
  ];
}

// Emulator is stored under its original name, 'retro', so saved rows keep
// satisfying any database constraint that predates the rename.
String gamePlatformToDb(GamePlatform platform) =>
    platform == GamePlatform.emulator ? 'retro' : platform.name;

GamePlatform? gamePlatformFromDb(Object? value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return null;
  final normalized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  return switch (normalized) {
    'pc' || 'windows' || 'win' || 'mac' || 'linux' || 'dos' => GamePlatform.pc,
    'steamdeck' => GamePlatform.steamDeck,
    'ps5' || 'playstation5' => GamePlatform.ps5,
    'ps4' || 'playstation4' => GamePlatform.ps4,
    'ps3' || 'playstation3' => GamePlatform.ps3,
    'ps2' || 'playstation2' => GamePlatform.ps2,
    'ps1' || 'psx' || 'playstation1' => GamePlatform.ps1,
    'vita' || 'psvita' || 'playstationvita' => GamePlatform.vita,
    'psp' || 'playstationportable' => GamePlatform.psp,
    'playstation' => GamePlatform.playstation,
    'xboxseries' ||
    'xboxseriesx' ||
    'xboxseriess' ||
    'xboxseriesxs' => GamePlatform.xboxSeries,
    'xboxone' => GamePlatform.xboxOne,
    'xbox360' => GamePlatform.xbox360,
    'xboxoriginal' => GamePlatform.xboxOriginal,
    'xbox' => GamePlatform.xbox,
    'nswitch2' || 'switch2' || 'nintendoswitch2' => GamePlatform.nswitch2,
    'switch' || 'nswitch' || 'nintendoswitch' => GamePlatform.nswitch,
    'wiiu' => GamePlatform.wiiU,
    'wii' => GamePlatform.wii,
    'gamecube' || 'ngc' => GamePlatform.gamecube,
    'n64' || 'nintendo64' => GamePlatform.n64,
    'snes' || 'supernintendo' => GamePlatform.snes,
    'nes' => GamePlatform.nes,
    'n3ds' || '3ds' || 'nintendo3ds' => GamePlatform.n3ds,
    'nds' || 'ds' || 'nintendods' => GamePlatform.nds,
    'gba' || 'gameboyadvance' => GamePlatform.gba,
    'gbc' || 'gameboycolor' => GamePlatform.gbc,
    'gameboy' || 'gb' => GamePlatform.gameBoy,
    'virtualboy' => GamePlatform.virtualBoy,
    'nintendo' => GamePlatform.nintendo,
    'dreamcast' || 'dc' => GamePlatform.dreamcast,
    'saturn' || 'segasaturn' => GamePlatform.saturn,
    'genesis' || 'megadrive' || 'segagenesis' => GamePlatform.genesis,
    'mastersystem' || 'segamastersystem' => GamePlatform.masterSystem,
    'gamegear' || 'segagamegear' => GamePlatform.gameGear,
    'ios' => GamePlatform.ios,
    'android' => GamePlatform.android,
    'mobile' => GamePlatform.mobile,
    'vr' => GamePlatform.vr,
    // 'retro' is how Emulator is stored (see gamePlatformToDb); accept both.
    'emulator' || 'retro' => GamePlatform.emulator,
    _ => null,
  };
}

/// A game's release platforms from a stored list (`games.platforms`, or the
/// offline cache): known spellings only, de-duplicated, in stored order. The
/// manual-only "played on" choices (Steam Deck, Emulator) are dropped: they are
/// never a release platform, so a stored one is stray data and would put a
/// platform on a game that was never released there.
List<GamePlatform> releasePlatformsFromDb(Iterable<Object?> values) {
  final result = <GamePlatform>{};
  for (final value in values) {
    final platform = gamePlatformFromDb(value);
    if (platform != null && !platform.isManualOnly) result.add(platform);
  }
  return result.toList();
}

/// What getting everything out of a game ([Game.perfected]) is called where it
/// was played: the Platinum trophy on the PlayStations that have trophies,
/// every achievement on PC and the Xboxes that have them, and 100% anywhere
/// else (Nintendo has neither). It is one flag whatever the name.
enum PerfectMark {
  platinum(Icons.emoji_events_rounded, Color(0xFF8FE3EC)),
  achievements(Icons.military_tech_rounded, Color(0xFFFFC857)),
  complete(Icons.workspace_premium_rounded, Color(0xFFFFC857));

  const PerfectMark(this.icon, this.color);

  /// On the game's badges.
  String get label => switch (this) {
    platinum => L10n.current.perfectPlatinumLabel,
    achievements => L10n.current.perfectAchievementsLabel,
    complete => L10n.current.perfectCompleteLabel,
  };

  /// On the switch that marks it.
  String get title => switch (this) {
    platinum => L10n.current.perfectPlatinumTitle,
    achievements => L10n.current.perfectAchievementsTitle,
    complete => L10n.current.perfectCompleteTitle,
  };

  String get description => switch (this) {
    platinum => L10n.current.perfectPlatinumDescription,
    achievements => L10n.current.perfectAchievementsDescription,
    complete => L10n.current.perfectCompleteDescription,
  };

  /// Said when it is marked.
  String get done => switch (this) {
    platinum => L10n.current.perfectPlatinumDone,
    achievements => L10n.current.perfectAchievementsDone,
    complete => L10n.current.perfectCompleteDone,
  };

  final IconData icon;

  /// Picked for the dark theme, like the milestone tiers; pass it through
  /// `Palette.legible` for text and icons on the light one.
  final Color color;

  static PerfectMark forPlatform(GamePlatform? platform) => switch (platform) {
        GamePlatform.ps5 ||
        GamePlatform.ps4 ||
        GamePlatform.ps3 ||
        GamePlatform.vita ||
        // What older builds stored for "some PlayStation": most likely one
        // with trophies.
        GamePlatform.playstation =>
          platinum,
        GamePlatform.pc ||
        GamePlatform.steamDeck ||
        GamePlatform.xboxSeries ||
        GamePlatform.xboxOne ||
        GamePlatform.xbox360 ||
        GamePlatform.xbox =>
          achievements,
        _ => complete,
      };
}

/// `games.release_year` only accepts 1950-2100 or NULL (`games_release_year_check`).
/// Returns [year] when it fits, otherwise null. This covers the model's
/// `0 = unknown` placeholder as well as any out-of-range value.
int? sanitizeReleaseYear(int? year) =>
    (year == null || year < 1950 || year > 2100) ? null : year;

/// IGDB `first_release_date` (UNIX seconds, UTC) -> 4-digit year, or null when
/// the value is missing, malformed, or outside 1950-2100.
int? releaseYearFromUnixSeconds(Object? seconds) {
  if (seconds is! num || !seconds.isFinite) return null;
  final s = seconds.toInt();
  if (s.abs() > 8640000000000) return null; // beyond what DateTime can represent
  final year = DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true).year;
  return sanitizeReleaseYear(year);
}

/// Prefix of the ids of legacy Steam-keyed catalog rows, which sync-steam hasn't
/// adopted into an IGDB id yet (see `steamUuid` in sync-steam).
const legacySteamIdPrefix = '57e40000-';

/// The `games.id` for an IGDB game. A game's identity is its IGDB id: the
/// database makes `games.id` a pure function of `games.igdb_id` (constraint
/// `games_id_matches_igdb_id`) and `igdb_id` unique, so a game added from search
/// and the same game imported by Steam sync are one row. Must match
/// `igdb_game_uuid()` in the migration and `igdbGameUuid` in sync-steam.
String gameIdForIgdb(int igdbId) =>
    '00000000-0000-4000-8000-${igdbId.toString().padLeft(12, '0')}';

/// Catalog metadata + the user's tracking state for that game.
/// `status == null` means "in the catalog, not in my library".
@immutable
class Game {
  const Game({
    required this.id,
    required this.title,
    required this.publisher,
    required this.developer,
    required this.releaseYear,
    required this.platforms,
    required this.genres,
    required this.synopsis,
    required this.coverColors,
    required this.coverIcon,
    this.coverUrl,
    this.igdbId,
    this.steamAppId,
    this.status,
    this.rating = 0,
    this.hoursPlayed = 0,
    this.playedOn,
    this.purchasePrice = 0,
    this.dateAdded,
    this.isFavorite = false,
    this.isHidden = false,
    this.achievements,
    this.customBackdropUrl,
    this.releaseDate,
    this.completedAt,
    this.review = '',
    this.completionTime,
    this.stillPlaying = false,
    this.perfected = false,
  });

  final String id;
  final String title;
  final String publisher;
  final String developer;
  final int releaseYear;
  final List<GamePlatform> platforms;
  final List<String> genres;
  final String synopsis;
  final List<Color> coverColors;
  final IconData coverIcon;
  final String? coverUrl;
  final bool isFavorite;

  /// The member hid the game from every other member (`user_games.is_hidden`): it
  /// stays in their library, listed only under Hidden, and others never get it.
  final bool isHidden;

  /// The member's own backdrop for the game (behind its screen's header and its
  /// Home card), an IGDB artwork or screenshot (`user_games.custom_backdrop_url`);
  /// null: the blurred cover.
  final String? customBackdropUrl;

  /// The game's IGDB id (`games.igdb_id`). `null` only for legacy Steam-keyed
  /// catalog rows that sync-steam hasn't adopted yet; everything the app adds
  /// from search has one.
  final int? igdbId;

  /// The Steam app this game is (`games.steam_app_id`), set by Steam sync.
  /// Achievements can be loaded only for games that have one.
  final int? steamAppId;

  // user state
  final GameStatus? status;
  final double rating; // 0 = unrated, 0.5 steps up to 5
  final double hoursPlayed;
  final GamePlatform? playedOn;
  final double purchasePrice; // 0 = unknown
  final DateTime? dateAdded;

  /// Steam achievements merged with the user's unlocks. `null` = never loaded;
  /// an empty list = loaded, but the game has none.
  final List<Achievement>? achievements;

  /// The day the game first came out (`games.release_date`, from IGDB), for
  /// wishlist release alerts; null when IGDB has no exact date (yet).
  final DateTime? releaseDate;

  /// When the member last marked it completed (`user_games.completed_at`, kept
  /// by the database); null for a game that isn't completed, or one completed
  /// before the date was recorded.
  final DateTime? completedAt;

  /// The member's review next to their rating (`user_games.review`);
  /// empty: none.
  final String review;

  /// How long the member took to finish it (`completion_times`), which they
  /// can add once it is completed; null: none. Kept when the status changes.
  final CompletionTime? completionTime;

  /// A completed game the member still plays (online, post-game, DLC...):
  /// it stays Completed and is listed under Playing too
  /// (`user_games.still_playing`). Always false for any other status: the
  /// database clears it when the status changes, and so does
  /// `LibraryStore.setStatus`.
  final bool stillPlaying;

  /// The member got everything out of it: a Platinum trophy, every achievement
  /// or 100%, named by where they played it ([perfectMark]). Self-reported
  /// (`user_games.perfected`); it counts for the Perfectionist milestone. Kept
  /// whatever the status, but never offered on a wishlisted game.
  final bool perfected;

  /// Rebuilds a game from [toJson]'s output (the offline cache). The cover
  /// colours and icon are derived from the other fields, as when a game is read
  /// from the database, so they are not stored.
  factory Game.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final title = json['title'] as String;
    final genres = [for (final g in json['genres'] as List) '$g'];
    final platforms = releasePlatformsFromDb(json['platforms'] as List);
    final dateAdded = json['dateAdded'];
    return Game(
      id: id,
      title: title,
      publisher: json['publisher'] as String,
      developer: json['developer'] as String,
      releaseYear: (json['releaseYear'] as num).toInt(),
      platforms: platforms,
      genres: genres,
      synopsis: json['synopsis'] as String,
      coverColors: coverColorsFor(id, title),
      coverIcon: coverIconFor(genres, platforms),
      coverUrl: json['coverUrl'] as String?,
      igdbId: (json['igdbId'] as num?)?.toInt(),
      steamAppId: (json['steamAppId'] as num?)?.toInt(),
      status: gameStatusFromDb(json['status']),
      rating: (json['rating'] as num).toDouble(),
      hoursPlayed: (json['hoursPlayed'] as num).toDouble(),
      playedOn: gamePlatformFromDb(json['playedOn']),
      purchasePrice: (json['purchasePrice'] as num).toDouble(),
      dateAdded: dateAdded == null ? null : DateTime.tryParse('$dateAdded')?.toLocal(),
      isFavorite: json['isFavorite'] == true,
      isHidden: json['isHidden'] == true,
      customBackdropUrl: json['customBackdropUrl'] as String?,
      releaseDate: _dateOrNull(json['releaseDate']),
      completedAt: _dateOrNull(json['completedAt']),
      review: json['review'] as String? ?? '',
      completionTime: CompletionTime.fromJson(json['completionTime']),
      stillPlaying: json['stillPlaying'] == true,
      perfected: json['perfected'] == true,
    );
  }

  static DateTime? _dateOrNull(Object? value) =>
      value == null ? null : DateTime.tryParse('$value')?.toLocal();

  /// What the offline cache keeps of this game. [achievements] are left out on
  /// purpose: the library queries don't load them either (they are fetched per
  /// game, on demand), so the cache only ever holds what the server returned
  /// for the library.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'publisher': publisher,
        'developer': developer,
        'releaseYear': releaseYear,
        'platforms': [for (final p in platforms) gamePlatformToDb(p)],
        'genres': genres,
        'synopsis': synopsis,
        'coverUrl': coverUrl,
        'igdbId': igdbId,
        'steamAppId': steamAppId,
        'status': status == null ? null : gameStatusToDb(status!),
        'rating': rating,
        'hoursPlayed': hoursPlayed,
        'playedOn': playedOn == null ? null : gamePlatformToDb(playedOn!),
        'purchasePrice': purchasePrice,
        'dateAdded': dateAdded?.toUtc().toIso8601String(),
        'isFavorite': isFavorite,
        'isHidden': isHidden,
        'customBackdropUrl': customBackdropUrl,
        'releaseDate': releaseDate?.toUtc().toIso8601String(),
        'completedAt': completedAt?.toUtc().toIso8601String(),
        'review': review,
        'completionTime': completionTime?.toJson(),
        'stillPlaying': stillPlaying,
        'perfected': perfected,
      };

  bool get inLibrary => status != null;

  /// Being played now: Playing, or Completed and [stillPlaying].
  bool get isPlaying =>
      status == GameStatus.playing ||
      (status == GameStatus.completed && stillPlaying);

  /// Listed under [s] in the library: its status, and Playing too while a
  /// completed game is [stillPlaying].
  bool isListedUnder(GameStatus s) =>
      status == s || (s == GameStatus.playing && isPlaying);

  /// Can be marked [perfected]: it is in the library, and not just wished for.
  bool get canBePerfected => inLibrary && status != GameStatus.wishlist;

  /// [perfected] and counted: as `award_milestones` counts it.
  bool get isPerfected => perfected && canBePerfected;

  /// What [perfected] is called for this game, by where it is played.
  PerfectMark get perfectMark => PerfectMark.forPlatform(playedOn);

  /// What the "Played on" pickers offer for this game, in [GamePlatform] order:
  /// exactly the platforms it was released on, the saved choice (so it never
  /// vanishes), Steam Deck when there is a PC release (Steam Deck plays PC games),
  /// and Emulator when there is a console release to emulate. A game with no known
  /// release platform offers [GamePlatform.selectable], as nothing says which are
  /// wrong.
  List<GamePlatform> get playedOnOptions {
    final options = <GamePlatform>{
      ...platforms,
      ?playedOn,
      if (platforms.contains(GamePlatform.pc)) GamePlatform.steamDeck,
      if (platforms.any((p) => p.isConsole)) GamePlatform.emulator,
    };
    if (options.isEmpty) options.addAll(GamePlatform.selectable);
    return options.toList()..sort((a, b) => a.index.compareTo(b.index));
  }

  /// [releaseYear] is 0 when the catalog has no (valid) release date.
  bool get hasReleaseYear => releaseYear > 0;

  double? get costPerHour =>
      (purchasePrice <= 0 || hoursPlayed <= 0) ? null : purchasePrice / hoursPlayed;

  Game copyWith({
    GameStatus? status,
    double? rating,
    double? hoursPlayed,
    GamePlatform? playedOn,
    double? purchasePrice,
    DateTime? dateAdded,
    String? coverUrl,
    bool? isFavorite,
    bool? isHidden,
    List<Achievement>? achievements,
    List<GamePlatform>? platforms,
    List<String>? genres,
    DateTime? releaseDate,
    String? review,
    bool? stillPlaying,
    bool? perfected,
  }) =>
      Game(
        id: id,
        title: title,
        publisher: publisher,
        developer: developer,
        releaseYear: releaseYear,
        platforms: platforms ?? this.platforms,
        genres: genres ?? this.genres,
        synopsis: synopsis,
        coverColors: coverColors,
        // The placeholder icon follows the genres and platforms when they change.
        coverIcon: platforms == null && genres == null
            ? coverIcon
            : coverIconFor(genres ?? this.genres, platforms ?? this.platforms),
        coverUrl: coverUrl ?? this.coverUrl,
        igdbId: igdbId,
        steamAppId: steamAppId,
        status: status ?? this.status,
        rating: rating ?? this.rating,
        hoursPlayed: hoursPlayed ?? this.hoursPlayed,
        playedOn: playedOn ?? this.playedOn,
        purchasePrice: purchasePrice ?? this.purchasePrice,
        dateAdded: dateAdded ?? this.dateAdded,
        isFavorite: isFavorite ?? this.isFavorite,
        isHidden: isHidden ?? this.isHidden,
        achievements: achievements ?? this.achievements,
        customBackdropUrl: customBackdropUrl,
        releaseDate: releaseDate ?? this.releaseDate,
        completedAt: completedAt,
        review: review ?? this.review,
        completionTime: completionTime,
        stillPlaying: stillPlaying ?? this.stillPlaying,
        perfected: perfected ?? this.perfected,
      );

  /// This game with [completedAt] set to exactly [at] (null: not completed).
  /// [copyWith] can't clear it: a null argument there means "keep the current
  /// value".
  Game withCompletedAt(DateTime? at) => Game(
        id: id,
        title: title,
        publisher: publisher,
        developer: developer,
        releaseYear: releaseYear,
        platforms: platforms,
        genres: genres,
        synopsis: synopsis,
        coverColors: coverColors,
        coverIcon: coverIcon,
        coverUrl: coverUrl,
        igdbId: igdbId,
        steamAppId: steamAppId,
        status: status,
        rating: rating,
        hoursPlayed: hoursPlayed,
        playedOn: playedOn,
        purchasePrice: purchasePrice,
        dateAdded: dateAdded,
        isFavorite: isFavorite,
        isHidden: isHidden,
        achievements: achievements,
        customBackdropUrl: customBackdropUrl,
        releaseDate: releaseDate,
        completedAt: at,
        review: review,
        completionTime: completionTime,
        stillPlaying: stillPlaying,
        perfected: perfected,
      );

  /// This game with the member's own backdrop set to exactly [url] (null: the
  /// blurred cover). [copyWith] can't clear it: a null argument there means
  /// "keep the current value".
  Game withBackdrop(String? url) => Game(
        id: id,
        title: title,
        publisher: publisher,
        developer: developer,
        releaseYear: releaseYear,
        platforms: platforms,
        genres: genres,
        synopsis: synopsis,
        coverColors: coverColors,
        coverIcon: coverIcon,
        coverUrl: coverUrl,
        igdbId: igdbId,
        steamAppId: steamAppId,
        status: status,
        rating: rating,
        hoursPlayed: hoursPlayed,
        playedOn: playedOn,
        purchasePrice: purchasePrice,
        dateAdded: dateAdded,
        isFavorite: isFavorite,
        isHidden: isHidden,
        achievements: achievements,
        customBackdropUrl: url,
        releaseDate: releaseDate,
        completedAt: completedAt,
        review: review,
        completionTime: completionTime,
        stillPlaying: stillPlaying,
        perfected: perfected,
      );

  /// This game with the member's completion time set to exactly [time] (null:
  /// none). [copyWith] can't clear it: a null argument there means "keep the
  /// current value".
  Game withCompletionTime(CompletionTime? time) => Game(
        id: id,
        title: title,
        publisher: publisher,
        developer: developer,
        releaseYear: releaseYear,
        platforms: platforms,
        genres: genres,
        synopsis: synopsis,
        coverColors: coverColors,
        coverIcon: coverIcon,
        coverUrl: coverUrl,
        igdbId: igdbId,
        steamAppId: steamAppId,
        status: status,
        rating: rating,
        hoursPlayed: hoursPlayed,
        playedOn: playedOn,
        purchasePrice: purchasePrice,
        dateAdded: dateAdded,
        isFavorite: isFavorite,
        isHidden: isHidden,
        achievements: achievements,
        customBackdropUrl: customBackdropUrl,
        releaseDate: releaseDate,
        completedAt: completedAt,
        review: review,
        completionTime: time,
        stillPlaying: stillPlaying,
        perfected: perfected,
      );

  /// This game as the catalog knows it, with all of the user's tracking state
  /// (status, rating, hours, favourite, achievements, backdrop...) cleared. [copyWith]
  /// can't do this: a null argument there means "keep the current value".
  Game withoutUserState() => Game(
        id: id,
        title: title,
        publisher: publisher,
        developer: developer,
        releaseYear: releaseYear,
        platforms: platforms,
        genres: genres,
        synopsis: synopsis,
        coverColors: coverColors,
        coverIcon: coverIcon,
        coverUrl: coverUrl,
        igdbId: igdbId,
        steamAppId: steamAppId,
        releaseDate: releaseDate,
      );
}