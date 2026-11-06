import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/library_csv.dart';
import 'package:checkpoint/models/trophy.dart';
import 'package:checkpoint/services/playstation/psn_client.dart';
import 'package:checkpoint/services/playstation/psn_device.dart';

/// What the import read from PlayStation: the play history and the trophy list.
/// A list Sony would not share is null, and why is in [playedError] or
/// [trophyError]; the import goes on with the other one.
class PsnLibrary {
  const PsnLibrary({
    this.played,
    this.trophies,
    this.playedError,
    this.trophyError,
    this.trophyLists = const {},
    this.trophyListsCut = false,
  });
  final List<PsnPlayedGame>? played;
  final List<PsnTrophyTitle>? trophies;
  final PsnException? playedError;
  final PsnException? trophyError;

  /// The trophies of the sets [loadTrophyLists] read, by Sony's id of the set.
  final Map<String, List<Trophy>> trophyLists;

  /// [loadTrophyLists] stopped before it had every list it wanted (Sony said to
  /// slow down, or the sign-in ran out): the rest come with the next sync.
  final bool trophyListsCut;

  PsnLibrary withLists(Map<String, List<Trophy>> lists, {required bool cut}) => PsnLibrary(
    played: played,
    trophies: trophies,
    playedError: playedError,
    trophyError: trophyError,
    trophyLists: lists,
    trophyListsCut: cut,
  );
}

/// The most trophy lists one sync reads: two requests each (so at most 203 with the
/// three before them, about three and a half minutes), and a bigger library fills
/// in over the next syncs. A game's list is also read when it is opened, so none
/// stays empty. The profile does not wait for the lists: its counts come from the
/// overview ([TrophyMeta]).
const psnMaxTrophyLists = 100;

/// Reads both lists with [tokens]. Fails (with the trophy list's error) only
/// when neither could be read.
Future<PsnLibrary> readPsnLibrary(PsnClient client, PsnTokens tokens) async {
  List<PsnTrophyTitle>? trophies;
  PsnException? trophyError;
  try {
    trophies = await client.trophyTitles(tokens);
  } on PsnException catch (e) {
    trophyError = e;
  }
  // An expired token fails the next request just the same: don't ask again.
  List<PsnPlayedGame>? played;
  PsnException? playedError;
  if (trophyError?.failure == PsnFailure.signInExpired || trophyError?.failure == PsnFailure.rateLimited) {
    throw trophyError!;
  }
  try {
    played = await client.playedGames(tokens);
  } on PsnException catch (e) {
    playedError = e;
  }
  if (trophies == null && played == null) throw trophyError ?? playedError!;
  return PsnLibrary(played: played, trophies: trophies, playedError: playedError, trophyError: trophyError);
}

/// The games of [library] as an import: one row per game, most recently played
/// first, at most [ImportRow.maxRows].
///
///  * Play history and trophy list name the same game the same way, so the two
///    are joined on the name (letters and digits only). The same game on two
///    consoles (PS4 and its PS5 version) becomes one row: hours added up, the
///    newer console, the trophy set the member got furthest in.
///  * A game with every trophy (or a Platinum) comes in Completed and perfected;
///    one with play time or trophies comes in Playing; a title only synced, never
///    played, comes in To play. Games already in the library keep their status
///    and platform ([ImportRow.fillGapsOnly]).
ImportFile buildPsnImport(PsnLibrary library, {void Function(ImportRow row)? onRowImported}) {
  final sorted = _entries(library);
  final skipped = <String>[];
  final taken = sorted.take(ImportRow.maxRows).toList();
  if (sorted.length > taken.length) {
    skipped.add(L10n.current.psnImportOverLimit(sorted.length - taken.length, ImportRow.maxRows));
  }
  return ImportFile(
    rows: [for (var i = 0; i < taken.length; i++) taken[i].toRow(i + 1, library.trophyLists)],
    skipped: skipped,
    source: ImportSource.playstation,
    onRowImported: onRowImported,
    notes: [
      if (library.playedError != null) L10n.current.psnPlayTimeMissing,
      if (library.trophyError != null) L10n.current.psnTrophiesMissing,
      if (library.trophyListsCut) L10n.current.psnTrophyListsCut,
    ],
  );
}

/// The trophy sets whose lists a sync should read: the one each game is shown
/// with (see [buildPsnImport]), when the member earned something in it and the
/// list stored for it ([stored], from [PsnDevice.storedLists]) is not at this
/// progress already; most recently played first, at most [max].
List<PsnTrophyTitle> trophySetsToRead(PsnLibrary library, Map<String, String> stored, {int max = psnMaxTrophyLists}) {
  final sets = <PsnTrophyTitle>[];
  for (final e in _entries(library)) {
    final set = e.trophies;
    if (set == null || set.npCommunicationId.isEmpty || set.earned <= 0) continue;
    if (stored[set.npCommunicationId] == PsnDevice.listMark(set.earned, set.total)) continue;
    sets.add(set);
    if (sets.length >= max) break;
  }
  return sets;
}

/// Reads the trophy lists [trophySetsToRead] names, one game at a time, and answers
/// [library] with them. Sony saying to slow down (or the sign-in running out) ends
/// it early with what it has; one set Sony will not give is skipped. [onProgress]
/// hears how many of how many are done.
Future<PsnLibrary> loadTrophyLists(
  PsnClient client,
  PsnTokens tokens,
  PsnLibrary library, {
  Map<String, String> stored = const {},
  int max = psnMaxTrophyLists,
  void Function(int done, int total)? onProgress,
}) async {
  final wanted = trophySetsToRead(library, stored, max: max);
  final lists = <String, List<Trophy>>{};
  var cut = false;
  var failures = 0;
  for (var i = 0; i < wanted.length; i++) {
    onProgress?.call(i, wanted.length);
    try {
      lists[wanted[i].npCommunicationId] = await client.trophiesOf(tokens, wanted[i]);
      failures = 0;
    } on PsnException catch (e) {
      if (e.failure == PsnFailure.signInExpired || e.failure == PsnFailure.rateLimited) {
        cut = true;
        break;
      }
      // Three in a row failing is Sony changing something, not one odd game.
      if (++failures >= 3) {
        cut = true;
        break;
      }
    }
  }
  onProgress?.call(lists.length, wanted.length);
  return library.withLists(lists, cut: cut);
}

List<_Entry> _entries(PsnLibrary library) {
  final entries = <String, _Entry>{};

  _Entry entry(String rawName) {
    final name = psnGameName(rawName);
    final key = psnTitleKey(name);
    return entries.putIfAbsent(key.isEmpty ? name : key, () => _Entry(name));
  }

  for (final game in library.played ?? const <PsnPlayedGame>[]) {
    final e = entry(game.name);
    e.seconds += game.playTime.inSeconds;
    e.noteSeen(game.lastPlayed);
    e.notePlatform(_platformOfCategory(game.category));
  }
  for (final title in library.trophies ?? const <PsnTrophyTitle>[]) {
    final e = entry(title.name);
    e.noteSeen(title.lastUpdated);
    e.notePlatform(_platformOfTrophySet(title.platform));
    e.noteTrophies(title);
  }

  return entries.values.toList()
    ..sort((a, b) {
      final byDate = (b.lastSeen ?? _epoch).compareTo(a.lastSeen ?? _epoch);
      return byDate != 0 ? byDate : a.name.compareTo(b.name);
    });
}

/// A game's name as the two PlayStation lists may spell it differently: lower
/// case, letters and digits of any script only (so ™, ® and punctuation do not
/// matter).
String psnTitleKey(String name) => name.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

/// A game's name as the member would write it, from what Sony calls it:
///  * a trademark sign becomes a space, not nothing, so "PlayStation®3 Edition"
///    reads "PlayStation 3 Edition" (the way IGDB spells it), not "PlayStation3",
///    and "Rocket League®" reads "Rocket League";
///  * the trophy set of an older game is named "Battlefield Hardline Trophies" or
///    "... Trophy Set": that word is Sony's label for the list, not part of the game.
/// Kept as it is when nothing would be left.
String psnGameName(String name) {
  var plain = name.replaceAll(RegExp('[™®©℠]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final label = RegExp(r'^(.+?)\s+(?:Trophies|Trophy Set)$', caseSensitive: false).firstMatch(plain);
  if (label != null) plain = label[1]!.trim();
  return plain.isEmpty ? name : plain;
}

final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

class _Entry {
  _Entry(this.name);

  /// The game's name as [psnGameName] writes it.
  final String name;

  int seconds = 0;
  DateTime? lastSeen;
  GamePlatform? platform;
  PsnTrophyTitle? trophies;

  void noteSeen(DateTime? at) {
    if (at != null && (lastSeen == null || at.isAfter(lastSeen!))) lastSeen = at;
  }

  /// The newest console wins: PS5 over PS4 over PS3 over Vita.
  void notePlatform(GamePlatform? p) {
    if (p == null) return;
    if (platform == null || _rank(p) < _rank(platform!)) platform = p;
  }

  /// The trophy set the member got furthest in (the first, when equal).
  void noteTrophies(PsnTrophyTitle title) {
    final current = trophies;
    if (current == null || title.earned > current.earned) trophies = title;
  }

  ImportRow toRow(int position, Map<String, List<Trophy>> lists) {
    final set = trophies;
    final list = set == null ? null : lists[set.npCommunicationId];
    final hours = seconds <= 0 ? null : (seconds / 360).round() / 10;
    final everything = set != null && set.total > 0 && (set.platinumEarned || set.earned >= set.total);
    final started = (hours ?? 0) > 0 || (set?.earned ?? 0) > 0;
    return ImportRow(
      line: position,
      title: name,
      status: everything
          ? GameStatus.completed
          : started
          ? GameStatus.playing
          : GameStatus.toPlay,
      hours: hours,
      playedOn: platform,
      trophiesEarned: set != null && set.total > 0 ? set.earned : null,
      trophiesTotal: set != null && set.total > 0 ? set.total : null,
      perfected: everything,
      fillGapsOnly: true,
      trophyList: list,
      trophySet: list == null ? null : set!.npCommunicationId,
      trophyMeta: set == null || set.npCommunicationId.isEmpty || set.definedByGrade.total == 0
          ? null
          : TrophyMeta(set: set.npCommunicationId, service: set.npServiceName, earned: set.earnedByGrade, total: set.definedByGrade),
    );
  }
}

int _rank(GamePlatform p) => switch (p) {
  GamePlatform.ps5 => 0,
  GamePlatform.ps4 => 1,
  GamePlatform.ps3 => 2,
  GamePlatform.vita => 3,
  _ => 4,
};

GamePlatform? _platformOfCategory(String category) => switch (category) {
  'ps5_native_game' => GamePlatform.ps5,
  'ps4_game' => GamePlatform.ps4,
  'pspc_game' => GamePlatform.pc,
  _ => null,
};

/// The console of a trophy set; for a set shared between consoles (`PS4,PSVITA`)
/// the newest.
GamePlatform? _platformOfTrophySet(String platform) {
  GamePlatform? best;
  for (final part in platform.split(',')) {
    final p = switch (part.trim().toUpperCase()) {
      'PS5' => GamePlatform.ps5,
      'PS4' => GamePlatform.ps4,
      'PS3' => GamePlatform.ps3,
      'PSVITA' => GamePlatform.vita,
      _ => null,
    };
    if (p != null && (best == null || _rank(p) < _rank(best))) best = p;
  }
  return best;
}
