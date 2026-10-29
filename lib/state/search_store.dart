import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/models/company.dart';
import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/models/studio_filters.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/services/game_api_service.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/nav_store.dart';

/// The Search tab: games and studios (publishers and developers) from IGDB,
/// members from the database, and the recent searches. Results are paged, one request at a time, as the lists are scrolled.
/// Nothing here is cached for offline use: a search is a live question.
///
/// The game search can be narrowed by [activeFilters] (genres, game modes,
/// themes, platforms, release years). With filters and no search text, the
/// results are the games matching the filters, in their sort order: what a tag
/// tapped on a game's screen opens (see [NavStore.switchTab]). The studio search
/// is narrowed the same way by [studioFilters] (country, founding years, role).
class SearchStore extends ChangeNotifier {
  SearchStore({
    required this._repository,
    required this._auth,
    required this._nav,
    GameApiService? apiService,
  }) : _apiService = apiService ?? GameApiService();

  final CheckpointRepository _repository;
  final AuthStore _auth;
  final NavStore _nav;
  final GameApiService _apiService;

  StreamSubscription<User?>? _authSubscription;
  String? _userId;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _recentSearches = List<String>.of(prefs.getStringList('recent_searches') ?? const []);
    _userId = _auth.user?.id;
    _authSubscription = _auth.userChanges.listen(_onUser);
    _nav.addListener(_onNavChanged);
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    _nav.removeListener(_onNavChanged);
    super.dispose();
  }

  /// Leaving the Search tab drops its results and its filters, and empties its
  /// search box (see [searchBoxResets]): coming back starts over. Being sent to
  /// it with filters browses by them.
  void _onNavChanged() {
    final requested = _nav.takeDiscoverFilters();
    if (requested != null) {
      unawaited(browseBy(requested));
      return;
    }
    clearSearch();
    _clearCompanySearch();
    _activeFilters = FilterOptions.none;
    _searchBoxResets++;
    notifyListeners();
  }

  /// A different account (or signing out) must not see the previous account's
  /// member results: the list leaves out that account's own row, and isn't theirs.
  void _onUser(User? user) {
    if (user?.id == _userId) return;
    _userId = user?.id;
    _resetUserSearch();
    notifyListeners();
  }

  // ---- Recent searches ----

  List<String> _recentSearches = [];
  List<String> get recentSearches => List.unmodifiable(_recentSearches);

  static const _maxRecentSearches = 10;

  /// Puts [query] at the top of the recent searches (dropping any earlier copy,
  /// ignoring case) and keeps only the newest [_maxRecentSearches].
  Future<void> addRecentSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _recentSearches
      ..removeWhere((e) => e.toLowerCase() == q.toLowerCase())
      ..insert(0, q);
    if (_recentSearches.length > _maxRecentSearches) {
      _recentSearches.removeRange(_maxRecentSearches, _recentSearches.length);
    }
    notifyListeners();

    // Save recent searches to device
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('recent_searches', _recentSearches);
  }

  // ---- Filters ----

  FilterOptions _activeFilters = FilterOptions.none;

  /// What the game search is narrowed down by, and the order of a filtered list
  /// without search text.
  FilterOptions get activeFilters => _activeFilters;

  /// Narrows the game search down by [filter]. With [triggerSearch] the results
  /// are fetched again for it: the current search text narrowed by [filter], or
  /// with no text the games matching it (with nothing picked either, the results
  /// are dropped). Without, the results stay as they are until the next search.
  Future<void> setFilter(
    FilterOptions filter, {
    bool triggerSearch = true,
  }) async {
    if (filter == _activeFilters &&
        (!triggerSearch || filter == _resultsFilters)) {
      return;
    }
    _activeFilters = filter;
    notifyListeners();
    if (triggerSearch) await _search(_searchTerm, remember: false);
  }

  int _searchBoxResets = 0;

  /// How many times the search text was dropped from outside the Search screen:
  /// by [browseBy], or by leaving the tab. The Search screen empties its search
  /// box when this goes up, so the box never holds text the results are not for.
  int get searchBoxResets => _searchBoxResets;

  /// Drops the search text and shows the games matching [filters].
  Future<void> browseBy(FilterOptions filters) async {
    _searchBoxResets++;
    _activeFilters = filters;
    notifyListeners();
    await _search('', remember: false);
  }

  // ---- Game search paging ----
  // [searchExternalGames] loads the first page; [loadMoreSearchResults] appends
  // the next ones as the results list is scrolled.
  List<Game> _searchResults = [];
  String _searchTerm = '';
  // The filters [_searchResults] were fetched with: the next pages use them too,
  // even when [_activeFilters] changed without a new search.
  FilterOptions _resultsFilters = FilterOptions.none;
  bool _searchLoading = false;
  int _searchNextOffset = 0; // IGDB hits consumed so far: where the next page starts
  bool _searchHasMore = false;
  bool _searchLoadingMore = false;
  bool _searchLoadMoreFailed = false;

  // Bumped by every search and by [clearSearch], so a response that arrives
  // after the box was emptied (or after a newer search started) is dropped
  // instead of bringing stale results back.
  int _searchSeq = 0;

  List<Game> get searchResults => _searchResults;

  /// The text of the search on screen (trimmed); empty for none, or for a list
  /// of games matching the filters alone.
  String get searchTerm => _searchTerm;

  /// The first page of a search is being fetched.
  bool get searchLoading => _searchLoading;

  /// A search result by id, for opening or adding a game that isn't in the
  /// library yet.
  Game? resultById(String id) {
    for (final g in _searchResults) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// IGDB may have more results than [searchResults] holds.
  bool get searchHasMore => _searchHasMore;

  /// The next page is being fetched.
  bool get searchLoadingMore => _searchLoadingMore;

  /// The last attempt to fetch the next page failed; [loadMoreSearchResults]
  /// retries it.
  bool get searchLoadMoreFailed => _searchLoadMoreFailed;

  /// Searches IGDB for [query], narrowed by [activeFilters], and with [remember]
  /// keeps [query] as a recent search (not for a search run while typing: it
  /// would keep every half-typed word). An empty [query] lists the games
  /// matching the filters, or, with none picked, drops the results.
  Future<void> searchExternalGames(String query, {bool remember = true}) =>
      _search(query, remember: remember);

  Future<void> _search(String query, {required bool remember}) async {
    final term = query.trim();
    if (remember) unawaited(addRecentSearch(term));
    final filters = _activeFilters;
    if (term.isEmpty && filters.isEmpty) {
      clearSearch();
      return;
    }
    final seq = ++_searchSeq;
    _searchTerm = term;
    _resultsFilters = filters;
    // Paging belongs to the previous search. Switch it off now, so a scroll
    // while this request is in flight can't append the old term's next page.
    _searchHasMore = false;
    _searchLoadingMore = false;
    _searchLoadMoreFailed = false;
    _searchLoading = true;
    notifyListeners();
    final page = await _apiService.searchGames(term, filters: filters);
    if (seq != _searchSeq) return;
    _searchLoading = false;
    // A failed request shows as "no results", as it did before paging.
    _searchResults = page?.items ?? const [];
    _searchNextOffset = page?.fetched ?? 0;
    _searchHasMore = page?.hasMore ?? false;
    notifyListeners();
  }

  /// Fetches the next page of the current game search and appends it. Safe to
  /// call whenever: the results list calls it each time its end scrolls into
  /// view, and it does nothing unless there is a next page and none is loading.
  Future<void> loadMoreSearchResults() async {
    if (!_searchHasMore || _searchLoadingMore) return;
    if (_searchTerm.isEmpty && _resultsFilters.isEmpty) return;
    final seq = _searchSeq;
    _searchLoadingMore = true;
    _searchLoadMoreFailed = false;
    notifyListeners();

    final page = await _apiService.searchGames(
      _searchTerm,
      filters: _resultsFilters,
      offset: _searchNextOffset,
    );
    // A newer search (or clearSearch) took over and already reset the flags.
    if (seq != _searchSeq) return;
    _searchLoadingMore = false;
    if (page == null) {
      _searchLoadMoreFailed = true;
    } else {
      final seen = {for (final g in _searchResults) g.id};
      final fresh = [
        for (final g in page.items)
          if (seen.add(g.id)) g,
      ];
      _searchResults = [..._searchResults, ...fresh];
      _searchNextOffset += page.fetched;
      // A page of nothing but games already listed means the source is not
      // advancing (an igdb-handler deployed before it learned `offset` answers
      // every page alike). Stop there instead of asking for the same page forever.
      _searchHasMore = page.hasMore && !(page.items.isNotEmpty && fresh.isEmpty);
    }
    notifyListeners();
  }

  /// Drops the current search results (search box emptied, or the user left
  /// the Search tab) and discards any search still in flight. The filters stay.
  void clearSearch() {
    _searchSeq++;
    final changed = _searchResults.isNotEmpty ||
        _searchLoading ||
        _searchHasMore ||
        _searchLoadingMore ||
        _searchLoadMoreFailed;
    _searchResults = [];
    _searchTerm = '';
    _resultsFilters = FilterOptions.none;
    _searchLoading = false;
    _searchNextOffset = 0;
    _searchHasMore = false;
    _searchLoadingMore = false;
    _searchLoadMoreFailed = false;
    if (changed) notifyListeners();
  }

  // ---- Studio search (Studios tab) ----
  // IGDB's companies by name, narrowed by [studioFilters]; with filters and no
  // name, the studios matching them. Paged like the game search.
  List<CompanySummary> _companyResults = const [];
  String _companyQuery = '';
  StudioFilters _studioFilters = StudioFilters.none;
  // The filters [_companyResults] were fetched with: the next pages use them
  // too, even when [_studioFilters] changed without a new search.
  StudioFilters _companyResultsFilters = StudioFilters.none;
  int _companySeq = 0; // bumped by every search and reset, like _searchSeq
  int _companyNextOffset = 0;
  bool _companyLoading = false;
  bool _companyFailed = false;
  bool _companyHasMore = false;
  bool _companyLoadingMore = false;
  bool _companyLoadMoreFailed = false;

  List<CompanySummary> get companyResults => _companyResults;

  /// What [companyResults] are for (trimmed); empty for none.
  String get companyQuery => _companyQuery;

  /// What the studio list is narrowed down by, and its order.
  StudioFilters get studioFilters => _studioFilters;

  /// A studio search is on its way.
  bool get companyLoading => _companyLoading;

  /// The last studio search failed; [findCompanies] tries again.
  bool get companyFailed => _companyFailed;

  /// There may be more studios than [companyResults] holds.
  bool get companyHasMore => _companyHasMore;

  /// The next page is being fetched.
  bool get companyLoadingMore => _companyLoadingMore;

  /// The last attempt to fetch the next page failed; [loadMoreCompanies] retries it.
  bool get companyLoadMoreFailed => _companyLoadMoreFailed;

  /// Searches the studios whose name has a word starting with every word of
  /// [query], narrowed by [studioFilters], and replaces the results with the
  /// first page. An empty [query] lists the studios matching the filters, or,
  /// with none picked, drops the results.
  Future<void> findCompanies(String query) async {
    final seq = ++_companySeq;
    final term = query.trim();
    final filters = _studioFilters;
    _companyQuery = term;
    _companyResultsFilters = filters;
    _companyFailed = false;
    _companyHasMore = false;
    _companyLoadingMore = false;
    _companyLoadMoreFailed = false;
    _companyNextOffset = 0;
    if (term.isEmpty && filters.isEmpty) {
      _companyResults = const [];
      _companyLoading = false;
      notifyListeners();
      return;
    }
    _companyLoading = true;
    notifyListeners();
    final page = await _apiService.searchCompanies(term, filters: filters);
    if (seq != _companySeq) return;
    _companyLoading = false;
    _companyResults = List.unmodifiable(page?.items ?? const <CompanySummary>[]);
    _companyFailed = page == null;
    _companyNextOffset = page?.fetched ?? 0;
    _companyHasMore = page?.hasMore ?? false;
    notifyListeners();
  }

  /// Narrows the studios down by [filters], for what is in the box ([query]): the
  /// results are fetched again for it.
  Future<void> filterStudios(StudioFilters filters, String query) {
    _studioFilters = filters;
    return findCompanies(query);
  }

  /// Fetches the next page of the current studio search and appends it. Safe to
  /// call whenever, like [loadMoreSearchResults].
  Future<void> loadMoreCompanies() async {
    if (!_companyHasMore || _companyLoadingMore || _companyLoading) return;
    final seq = _companySeq;
    _companyLoadingMore = true;
    _companyLoadMoreFailed = false;
    notifyListeners();

    final page = await _apiService.searchCompanies(
      _companyQuery,
      filters: _companyResultsFilters,
      offset: _companyNextOffset,
    );
    // A newer search (or a reset) took over and already reset the flags.
    if (seq != _companySeq) return;
    _companyLoadingMore = false;
    if (page == null) {
      _companyLoadMoreFailed = true;
    } else {
      final seen = {for (final c in _companyResults) c.id};
      final fresh = [
        for (final c in page.items)
          if (seen.add(c.id)) c,
      ];
      _companyResults = List.unmodifiable([..._companyResults, ...fresh]);
      _companyNextOffset += page.fetched;
      // A page of nothing but studios already listed means the source is not
      // advancing (an igdb-handler deployed before it learned `offset` answers
      // every page alike). Stop there instead of asking for the same page forever.
      _companyHasMore = page.hasMore && !(page.items.isNotEmpty && fresh.isEmpty);
    }
    notifyListeners();
  }

  /// Drops the studio results, the filters, and any studio search still on its way.
  void _clearCompanySearch() {
    _companySeq++;
    _companyResults = const [];
    _companyQuery = '';
    _studioFilters = StudioFilters.none;
    _companyResultsFilters = StudioFilters.none;
    _companyNextOffset = 0;
    _companyLoading = false;
    _companyFailed = false;
    _companyHasMore = false;
    _companyLoadingMore = false;
    _companyLoadMoreFailed = false;
  }

  // ---- Member search paging (Users tab) ----
  // Done on the server: the member list can't be downloaded up front once
  // signups are open. [findUsers] loads the first page for a query (empty means
  // everyone: "Suggested people"); [loadMoreUsers] appends the next ones.
  List<SocialUser> _userResults = const [];
  String _userQuery = '';
  int _userNextOffset = 0;
  int _userSeq = 0; // bumped by every search and reset, like _searchSeq
  bool _userSearchStale = true; // not searched yet for this account
  bool _userLoading = false;
  bool _userHasMore = false;
  bool _userLoadingMore = false;
  bool _userLoadMoreFailed = false;

  List<SocialUser> get userResults => _userResults;

  /// Takes the blocked member [memberId] off the member results.
  void forgetMember(String memberId) {
    _userResults = List.unmodifiable([
      for (final u in _userResults)
        if (u.id != memberId) u,
    ]);
    notifyListeners();
  }

  /// The Users tab has not loaded anything for the signed-in account yet (first
  /// visit, or the account changed). The tab calls [findUsers] when it sees this.
  bool get userSearchStale => _userSearchStale;

  /// The first page of a member search is being fetched.
  bool get userLoading => _userLoading;
  bool get userHasMore => _userHasMore;
  bool get userLoadingMore => _userLoadingMore;
  bool get userLoadMoreFailed => _userLoadMoreFailed;

  /// Forgets the member results: after sign-out, or when another account signs in.
  void _resetUserSearch() {
    _userSeq++;
    _userResults = const [];
    _userQuery = '';
    _userNextOffset = 0;
    _userSearchStale = true;
    _userLoading = false;
    _userHasMore = false;
    _userLoadingMore = false;
    _userLoadMoreFailed = false;
  }

  /// Searches members by name or @handle and replaces the results with the first
  /// page. An empty [query] lists everyone.
  Future<void> findUsers(String query) async {
    final seq = ++_userSeq;
    final current = _auth.user;
    final term = query.trim();
    _userSearchStale = false;
    _userHasMore = false;
    _userLoadingMore = false;
    _userLoadMoreFailed = false;
    if (current == null) {
      // Members are visible to signed-in users only.
      _userResults = const [];
      _userQuery = term;
      _userNextOffset = 0;
      _userLoading = false;
      notifyListeners();
      return;
    }

    _userLoading = true;
    notifyListeners();
    try {
      final page = await _repository.searchSocialUsers(current.id, query: term);
      if (seq != _userSeq) return;
      _userResults = List.unmodifiable(page.items);
      _userNextOffset = page.fetched;
      _userHasMore = page.hasMore;
    } catch (e, st) {
      if (seq != _userSeq) return;
      debugPrint('Member search failed: $e\n$st');
      _userResults = const [];
      _userNextOffset = 0;
    }
    _userQuery = term;
    _userLoading = false;
    notifyListeners();
  }

  /// Fetches the next page of the current member search and appends it. Safe to
  /// call whenever, like [loadMoreSearchResults].
  Future<void> loadMoreUsers() async {
    final current = _auth.user;
    if (current == null || _userLoading || _userLoadingMore || !_userHasMore) {
      return;
    }
    final seq = _userSeq;
    _userLoadingMore = true;
    _userLoadMoreFailed = false;
    notifyListeners();
    try {
      final page = await _repository.searchSocialUsers(
        current.id,
        query: _userQuery,
        offset: _userNextOffset,
      );
      if (seq != _userSeq) return;
      final seen = {for (final u in _userResults) u.id};
      _userResults = List.unmodifiable([
        ..._userResults,
        for (final u in page.items)
          if (seen.add(u.id)) u,
      ]);
      _userNextOffset += page.fetched;
      _userHasMore = page.hasMore;
    } catch (e, st) {
      if (seq != _userSeq) return;
      debugPrint('Loading more members failed: $e\n$st');
      _userLoadMoreFailed = true;
    }
    _userLoadingMore = false;
    notifyListeners();
  }
}
