import 'package:flutter/foundation.dart';

import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_attributes.dart';
import 'package:checkpoint/state/library_attributes_store.dart';
import 'package:checkpoint/state/library_state.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/nav_store.dart';

/// How the Library tab is arranged: grid or list, sort, the filters and the
/// selected status tab. It is screen state only, with no data of its own, so
/// re-sorting rebuilds the Library tab and nothing that merely reads the games.
/// Hand [visible] / [count] the games from [LibraryStore].
///
/// The filters ([filters]) narrow the games by platform, release year, and by
/// genre, theme, game mode, perspective, engine, developer and publisher (any
/// number of values of each). A game must pass all of them; of one kind's picked
/// values it needs any one. A game whose release year is not known passes no
/// year range.
/// Genres are on the games handed in; the other attributes are looked up in
/// [LibraryAttributesStore], which only knows the games IGDB details were saved
/// for, so a game without them passes no filter on those attributes.
///
/// Another member's Library screen makes its own instance, without a [NavStore]
/// or attributes: that one has no tab of the app to switch to, so [openTab] is the
/// signed-in member's only, and the filters it offers are the platform's only.
class LibraryViewStore extends ChangeNotifier {
  LibraryViewStore({this._nav, this._attributes}) {
    _attributes?.addListener(_onAttributesChanged);
  }

  final NavStore? _nav;
  final LibraryAttributesStore? _attributes;

  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  LibraryView _view = LibraryView.grid;
  SortField _sortField = SortField.dateAdded;
  bool _sortDescending = true;
  FilterOptions _filters = FilterOptions.none;

  /// Selected status tab. `null` means "All" (the default).
  GameStatus? _selectedStatus;

  /// The Hidden tab is selected, which only the signed-in member's own Library
  /// has (games they hid from other members); then [selectedStatus] is null.
  bool _showHidden = false;

  LibraryView get view => _view;
  SortField get sortField => _sortField;
  bool get sortDescending => _sortDescending;

  /// Everything picked. Its sort is not used: the Library has [sortField].
  FilterOptions get filters => _filters;

  /// The platforms picked; a game needs to be on any one of them.
  Set<GamePlatform> get platformFilters => _filters.platforms;

  /// The platform picked when it is the only one, else null: what a menu that
  /// picks one platform (another member's Library) shows.
  GamePlatform? get platformFilter =>
      _filters.platforms.length == 1 ? _filters.platforms.single : null;

  /// The release years picked.
  YearRange get yearFilter => _filters.years;

  /// Selected status, or `null` when "All" is selected.
  GameStatus? get selectedStatus => _selectedStatus;

  /// Whether the Hidden tab is the one showing.
  bool get showingHidden => _showHidden;

  /// Tab index: 0 is the "All" tab, then one tab per [GameStatus], then Hidden
  /// (the signed-in member's Library only).
  int get currentTabIndex => _showHidden
      ? GameStatus.values.length + 1
      : _selectedStatus == null
      ? 0
      : GameStatus.values.indexOf(_selectedStatus!) + 1;

  void setTabIndex(int i) {
    final hidden = i > GameStatus.values.length;
    final next = i <= 0 || hidden ? null : GameStatus.values[i - 1];
    if (next == _selectedStatus && hidden == _showHidden) return;
    _selectedStatus = next;
    _showHidden = hidden;
    notifyListeners();
  }

  /// Jumps to the Library tab on [status] (`null` is "All"), clearing the
  /// filters. With [sortBy], also sorts by that field, highest first.
  void openTab(GameStatus? status, {SortField? sortBy}) {
    _selectedStatus = status;
    _showHidden = false;
    _filters = FilterOptions.none;
    if (sortBy != null) {
      _sortField = sortBy;
      _sortDescending = true;
    }
    notifyListeners();
    _nav?.select(NavTab.library);
  }

  void setView(LibraryView v) {
    _view = v;
    notifyListeners();
  }

  void setSort(SortField f) {
    if (f == _sortField) {
      _sortDescending = !_sortDescending;
    } else {
      _sortField = f;
      _sortDescending = true;
    }
    notifyListeners();
  }

  /// Replaces every filter with [filters] (the filter sheet's changes).
  void setFilters(FilterOptions filters) {
    if (filters == _filters) return;
    _filters = filters;
    notifyListeners();
  }

  /// Picks only [p], or no platform at all when it is null.
  void setPlatformFilter(GamePlatform? p) =>
      setFilters(_filters.withPlatforms([?p]));

  /// Picks [p] as well, or lets go of it when it is picked.
  void togglePlatform(GamePlatform p) =>
      setFilters(_filters.togglePlatform(p));

  void setYearFilter(YearRange years) => setFilters(_filters.withYears(years));

  /// The values picked for [attribute], none when it is not filtered.
  Set<String> filterValues(GameAttribute attribute) =>
      _filters.valuesOf(attribute);

  /// Whether [value] is picked for [attribute].
  bool isFilterOn(GameAttribute attribute, String value) =>
      _filters.has(attribute, value);

  /// Picks [value] of [attribute], or lets go of it when it is picked.
  void toggleFilter(GameAttribute attribute, String value) =>
      setFilters(_filters.toggle(attribute, value));

  /// Lets go of every value picked for [attribute].
  void clearFilter(GameAttribute attribute) =>
      setFilters(_filters.clear(attribute));

  /// Removes every filter.
  void clearFilters() => setFilters(_filters.cleared());

  /// Whether any filter narrows the Library.
  bool get hasFilters => !_filters.isEmpty;

  /// Whether a value of something IGDB's details say is picked (a theme, mode,
  /// perspective, engine, developer or publisher), which a game without them can
  /// never match. A platform, year or genre does not depend on them.
  bool get hasDetailFilters => _filters.hasDetailFilters;

  /// How many things are picked: every platform, the year range and every
  /// attribute value.
  int get filterCount => _filters.count;

  bool _matches(Game g) =>
      _matchesPlatform(g) &&
      _filters.years.contains(g.releaseYear) &&
      _matchesAttributes(g);

  bool _matchesPlatform(Game g) {
    final picked = _filters.platforms;
    return picked.isEmpty || picked.any((p) => _isOn(g, p));
  }

  bool _matchesAttributes(Game g) {
    for (final MapEntry(key: attribute, value: wanted)
        in _filters.attributes.entries) {
      if (!_valuesOf(g, attribute).any(wanted.contains)) return false;
    }
    return true;
  }

  /// [g]'s values of [attribute]: none when IGDB's details were not saved for it.
  Iterable<String> _valuesOf(Game g, GameAttribute attribute) =>
      attribute == GameAttribute.genre
      ? g.genres
      : _attributes?.of(g.id)?.valuesOf(attribute) ?? const [];

  /// A game counts for the platform it was played on, or, until that is chosen,
  /// for the platforms it was released on.
  static bool _isOn(Game g, GamePlatform p) =>
      g.playedOn == p || (g.playedOn == null && g.platforms.contains(p));

  /// The platforms the platform filter should offer: those at least one game of
  /// [library] is on, in [GamePlatform] order, so the menu never lists a platform
  /// that would only show an empty library. The platforms picked stay listed so
  /// they can still be seen and changed.
  List<GamePlatform> filterOptions(Iterable<Game> library) => [
    for (final p in GamePlatform.values)
      if (_filters.platforms.contains(p) || library.any((g) => _isOn(g, p))) p,
  ];

  /// The earliest and latest release year of [library]'s games (those whose year
  /// is known), widened to take in the years picked; null when no game has one,
  /// so there is nothing to pick from.
  ({int min, int max})? yearSpan(Iterable<Game> library) {
    int? min;
    int? max;
    for (final year in [
      for (final g in library)
        if (g.hasReleaseYear) g.releaseYear,
      ?_filters.years.from,
      ?_filters.years.to,
    ]) {
      if (min == null || year < min) min = year;
      if (max == null || year > max) max = year;
    }
    return min == null || max == null ? null : (min: min, max: max);
  }

  /// The values the filter for [attribute] should offer: those at least one game
  /// of [library] has, with how many do, most common first (then by name), so the
  /// menu never lists a value that would only show an empty library. The values
  /// picked stay listed (with 0 if need be) so they can still be seen and undone.
  List<FilterOption> attributeOptions(
    GameAttribute attribute,
    Iterable<Game> library,
  ) {
    final counts = <String, int>{};
    for (final g in library) {
      for (final value in _valuesOf(g, attribute).toSet()) {
        counts.update(value, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    for (final value in _filters.valuesOf(attribute)) {
      counts.putIfAbsent(value, () => 0);
    }
    return [
      for (final entry in counts.entries) FilterOption(entry.key, entry.value),
    ]..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0
          ? byCount
          : a.value.toLowerCase().compareTo(b.value.toLowerCase());
    });
  }

  /// How many games of [library] IGDB's details were not saved for yet, so no
  /// filter on themes, modes, perspectives, engines, developers or publishers can
  /// pick them. Null when that is not known: no details are loaded (yet, or they
  /// failed to), or this view has none (another member's Library).
  int? gamesWithoutDetails(Iterable<Game> library) {
    final attributes = _attributes;
    if (attributes == null || attributes.status != LoadStatus.ready) return null;
    return library.where((g) => !attributes.knows(g.id)).length;
  }

  int _compare(Game a, Game b) {
    final c = switch (_sortField) {
      SortField.dateAdded => (a.dateAdded ?? _epoch).compareTo(
        b.dateAdded ?? _epoch,
      ),
      SortField.rating => a.rating.compareTo(b.rating),
      SortField.hoursPlayed => a.hoursPlayed.compareTo(b.hoursPlayed),
      SortField.releaseYear => a.releaseYear.compareTo(b.releaseYear),
    };
    if (c != 0) return _sortDescending ? -c : c;
    return a.title.compareTo(b.title);
  }

  /// The games of [library] with status [s], filtered and sorted; pass `null` for
  /// every status ("All"). The filters apply either way. A completed game still
  /// being played is under Playing as well (see [Game.isListedUnder]). A game the
  /// member hid from other members is in none of these: it is only in the Hidden
  /// tab, which is [hiddenOnly] (and then [s] is null).
  List<Game> visible(Iterable<Game> library, GameStatus? s, {bool hiddenOnly = false}) => [
    for (final g in library)
      if ((s == null || g.isListedUnder(s)) && g.isHidden == hiddenOnly && _matches(g)) g,
  ]..sort(_compare);

  /// How many games [visible] would return, without sorting them.
  int count(Iterable<Game> library, GameStatus? s, {bool hiddenOnly = false}) => library
      .where((g) => (s == null || g.isListedUnder(s)) && g.isHidden == hiddenOnly && _matches(g))
      .length;

  /// The details arrived, or were dropped because another account signed in
  /// (which leaves the store idle, and it never is once asked): what was picked
  /// from the previous account's library means nothing for the next one's.
  void _onAttributesChanged() {
    if (_attributes?.status == LoadStatus.idle) {
      _filters = FilterOptions(
        platforms: _filters.platforms,
        years: _filters.years,
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _attributes?.removeListener(_onAttributesChanged);
    super.dispose();
  }
}
