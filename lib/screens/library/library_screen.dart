import 'package:flutter/material.dart';

import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/state/library_state.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/library_view_store.dart';
import 'package:checkpoint/state/nav_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/utils/refresh.dart';
import 'package:checkpoint/widgets/empty_state.dart';
import 'package:checkpoint/widgets/library_controls.dart';
import 'package:checkpoint/widgets/library_filters.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

/// Owns the status-tab `TabController` and keeps it in lock-step with
/// `LibraryViewStore.currentTabIndex` in both directions (tab 0 is "All", then
/// one tab per `GameStatus`, then "Hidden"; `selectedStatus == null` means All):
///   user taps/swipes a tab  → controller listener → viewStore.setTabIndex
///   viewStore.openTab()     → store listener      → controller.index = …
/// Both sides compare before writing, so the two listeners can never loop.
class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late final LibraryViewStore _viewStore;
  late final TabController _tabs;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _viewStore = context.read<LibraryViewStore>(); // non-subscribing lookup is allowed in initState
    _tabs = TabController(
      length: GameStatus.values.length + 2, // the leading "All" tab and the trailing "Hidden" one
      vsync: this,
      initialIndex: _viewStore.currentTabIndex,
    )..addListener(_onTabsChanged);
    _viewStore.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    _viewStore.removeListener(_onStoreChanged);
    _tabs
      ..removeListener(_onTabsChanged)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onTabsChanged() {
    final i = _tabs.index;
    if (i != _viewStore.currentTabIndex) _viewStore.setTabIndex(i);
  }

  void _onStoreChanged() {
    final i = _viewStore.currentTabIndex;
    if (i != _tabs.index) _tabs.index = i;
  }

  void _onSearchChanged(String value) => setState(() => _searchQuery = value);

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final view = context.watch<LibraryViewStore>();
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.navLibrary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                  ),
                ),
                LibrarySortButton(
                  field: view.sortField,
                  descending: view.sortDescending,
                ),
                const SizedBox(width: 4),
                LibraryViewToggle(view: view.view),
                const SizedBox(width: 8),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
            child: Text(
              context.l10n.sortedBy(view.sortField.label, view.sortDescending ? context.l10n.highToLow : context.l10n.lowToHigh),
              style: TextStyle(color: context.palette.muted, fontSize: 12.5),
            ),
          ),
          LibraryActiveFilters(library: library.libraryGames),
          const _SyncBanner(),
          LibraryStatusTabBar(
            controller: _tabs,
            // "All" is injected at index 0, ahead of the per-status tabs.
            counts: [
              view.count(library.libraryGames, null),
              for (final s in GameStatus.values)
                view.count(library.libraryGames, s),
            ],
            hiddenCount: view.count(library.libraryGames, null, hiddenOnly: true),
          ),
          const SizedBox(height: 8),
          LibrarySearchField(
            controller: _searchController,
            tabLabel: view.showingHidden ? context.l10n.libraryHiddenTab : (view.selectedStatus?.label ?? context.l10n.all),
            hasText: _searchQuery.isNotEmpty,
            onChanged: _onSearchChanged,
            onClear: _clearSearch,
            trailing: LibraryFilterButton(count: view.filterCount),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                LibraryCollection(
                  status: null, // "All"
                  searchQuery: _searchQuery,
                  onClearSearch: _clearSearch,
                ),
                for (final s in GameStatus.values)
                  LibraryCollection(
                    status: s,
                    searchQuery: _searchQuery,
                    onClearSearch: _clearSearch,
                  ),
                LibraryCollection(
                  status: null,
                  hidden: true,
                  searchQuery: _searchQuery,
                  onClearSearch: _clearSearch,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The banner's own scope, so a follow being queued or sent rebuilds only this
/// and not the whole library.
class _SyncBanner extends StatelessWidget {
  const _SyncBanner();

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final profile = context.watch<ProfileStore>();
    // Follows made while offline wait for the server too, so they count here
    // (this is the one place that says "changes will sync").
    final pending = library.pendingCount + profile.pendingCount;
    if (!library.isOffline && pending == 0) return const SizedBox.shrink();
    return _OfflineBanner(
      offline: library.isOffline,
      pendingCount: pending,
      syncedAt: library.lastSyncedAt,
      retrying: library.isRefreshing,
      onRetry: () {
        library.refresh();
        profile.refresh();
      },
    );
  }
}

/// Shown while the library on screen is the copy saved on this device because
/// the server couldn't be reached, and while edits are waiting to be sent.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({
    required this.offline,
    required this.pendingCount,
    required this.syncedAt,
    required this.retrying,
    required this.onRetry,
  });
  final bool offline;
  final int pendingCount;
  final DateTime? syncedAt;
  final bool retrying;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final synced = syncedAt;
    final l10n = context.l10n;
    final pending = pendingCount == 0 ? '' : ' ${l10n.changesWillSync(pendingCount)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 4, 4),
        decoration: BoxDecoration(
          color: context.palette.surfaceHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_off_rounded, size: 18, color: context.palette.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                !offline
                    ? l10n.changesWaitingToSync(pendingCount)
                    : synced == null
                    ? '${l10n.offlineSavedLibrary}$pending'
                    : '${l10n.offlineSavedLibraryUpdated(timeAgo(synced))}$pending',
                style: TextStyle(color: context.palette.muted, fontSize: 12.5),
              ),
            ),
            TextButton(
              onPressed: retrying ? null : onRetry,
              child: Text(retrying ? l10n.retrying : l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}

class LibraryCollection extends StatelessWidget {
  const LibraryCollection({
    super.key,
    required this.status,
    this.hidden = false,
    this.searchQuery = '',
    this.onClearSearch,
  });
  /// Status shown by this tab; `null` shows every game ("All").
  final GameStatus? status;

  /// The Hidden tab: only the games hidden from other members, of any status.
  final bool hidden;

  /// Free-text title filter, applied only to this tab's games.
  final String searchQuery;
  final VoidCallback? onClearSearch;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>();
    final view = context.watch<LibraryViewStore>();
    if (library.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = library.loadError;
    if (error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: context.l10n.libraryLoadFailedTitle,
        message: error,
        actionLabel: context.l10n.retry,
        onAction: () {
          library.refresh();
          context.read<ProfileStore>().refresh();
        },
      );
    }

    final s = status; // local copy so null checks promote
    final query = searchQuery.trim().toLowerCase();
    final games = view
        .visible(library.libraryGames, s, hiddenOnly: hidden)
        .where((g) => g.title.toLowerCase().contains(query))
        .toList();
    if (games.isEmpty) {
      final p = view.platformFilter;
      final filtered = view.hasFilters;
      if (query.isNotEmpty) {
        return EmptyState(
          icon: Icons.search_off_rounded,
          title: context.l10n.noMatchesFor(searchQuery.trim()),
          message: filtered
              ? context.l10n.noMatchesFilteredMessage
              : context.l10n.noMatchesMessage,
          actionLabel: context.l10n.clearSearch,
          onAction: () => onClearSearch?.call(),
        );
      }
      // Only the platform picked: say which one. Anything else: the filters.
      final onlyPlatform = p != null && view.filterCount == 1;
      final missing = view.hasDetailFilters
          ? view.gamesWithoutDetails(library.libraryGames) ?? 0
          : 0;
      final l10n = context.l10n;
      if (hidden && !filtered) {
        return EmptyState(
          icon: Icons.visibility_off_rounded,
          title: l10n.noHiddenGames,
          message: l10n.noHiddenGamesMessage,
          onRefresh: () => refreshMyData(context),
        );
      }
      return EmptyState(
        icon: s?.icon ?? Icons.apps_rounded,
        title: onlyPlatform
            ? (s == null
                  ? l10n.noGamesOnPlatform(p.label)
                  : l10n.noStatusGamesOnPlatform(s.name, p.label))
            : filtered
            ? (s == null
                  ? l10n.noGamesMatchFilters
                  : l10n.noStatusGamesMatchFilters(s.name))
            : (s == null
                  ? l10n.libraryEmpty
                  : l10n.nothingInStatusYet(s.label)),
        message: filtered
            ? (missing > 0
                  ? l10n.clearFiltersMissingDetails(missing)
                  : l10n.clearFiltersToSeeEverything)
            : l10n.libraryEmptyMessage,
        actionLabel: filtered
            ? l10n.clearFilters(view.filterCount)
            : l10n.discoverGames,
        onAction: () => filtered
            ? context.read<LibraryViewStore>().clearFilters()
            : context.read<NavStore>().select(NavTab.search),
        // Games added on another device show up with a pull, not only a retry.
        onRefresh: () => refreshMyData(context),
      );
    }
    final tab = hidden ? 'hidden' : (s?.name ?? 'all');
    final body = AnimatedSwitcher(
      duration: motion(context, const Duration(milliseconds: 220)),
      child: view.view == LibraryView.grid
          ? LibraryPosterGrid(
              key: ValueKey('grid-$tab'),
              games: games,
              onRefresh: () => refreshMyData(context),
            )
          : LibraryGameList(
              key: ValueKey('list-$tab'),
              games: games,
              onRefresh: () => refreshMyData(context),
            ),
    );
    if (!hidden) return body;
    return Column(children: [
      const _HiddenNote(),
      Expanded(child: body),
    ]);
  }
}

/// Over the Hidden tab: who can and can't see what is in it.
class _HiddenNote extends StatelessWidget {
  const _HiddenNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.visibility_off_rounded, size: 16, color: context.palette.muted),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            context.l10n.hiddenGamesNote,
            style: TextStyle(color: context.palette.muted, fontSize: 12.5, height: 1.35),
          ),
        ),
      ]),
    );
  }
}

