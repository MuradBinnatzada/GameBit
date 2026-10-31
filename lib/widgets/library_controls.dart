import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/state/library_state.dart';
import 'package:checkpoint/state/library_view_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/cover_art.dart';
import 'package:checkpoint/widgets/star_rating.dart';

// The controls and game views of a Library screen: search box, grid / list toggle,
// sort and platform-filter menus, and the poster grid and list themselves. They
// read and write the nearest [LibraryViewStore], so the signed-in member's Library
// tab and another member's Library screen (which provides its own store) share
// them.

/// Dark rounded search field shown between the tab bar and the game grid/list.
class LibrarySearchField extends StatelessWidget {
  const LibrarySearchField({
    super.key,
    required this.controller,
    required this.tabLabel,
    required this.hasText,
    required this.onChanged,
    required this.onClear,
    this.trailing,
  });
  final TextEditingController controller;
  final String tabLabel;
  final bool hasText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  /// Beside the field, on its right (the filter button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    );
    final field = TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      cursorColor: context.palette.accent,
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: context.palette.surfaceHigh,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        hintText: context.l10n.searchInTab(tabLabel),
        hintStyle: TextStyle(color: context.palette.muted),
        prefixIcon: Icon(Icons.search_rounded, color: context.palette.muted),
        suffixIcon: hasText
            ? IconButton(
                tooltip: context.l10n.clearSearch,
                icon: Icon(Icons.close_rounded, color: context.palette.muted),
                onPressed: onClear,
              )
            : null,
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(
            color: context.palette.accent.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
    final trailing = this.trailing;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(16, 0, trailing == null ? 16 : 6, 4),
      child: trailing == null
          ? field
          : Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 2),
                trailing,
              ],
            ),
    );
  }
}

class LibraryViewToggle extends StatelessWidget {
  const LibraryViewToggle({super.key, required this.view});
  final LibraryView view;

  @override
  Widget build(BuildContext context) {
    Widget cell(LibraryView v, IconData icon, String tooltip) {
      final active = v == view;
      // A 48 px square to tap, with the highlight inside it.
      return Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: active,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => context.read<LibraryViewStore>().setView(v),
            child: SizedBox.square(
              dimension: 48,
              child: Center(
                child: AnimatedContainer(
                  duration: motion(context, const Duration(milliseconds: 180)),
                  width: 40,
                  height: 38,
                  decoration: BoxDecoration(
                    color: active
                        ? context.palette.accent.withValues(alpha: 0.20)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: active ? context.palette.accent : context.palette.muted,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: context.palette.surfaceHigh,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          cell(LibraryView.grid, Icons.grid_view_rounded, context.l10n.posterGrid),
          cell(LibraryView.list, Icons.view_list_rounded, context.l10n.listView),
        ],
      ),
    );
  }
}

class LibrarySortButton extends StatelessWidget {
  const LibrarySortButton({
    super.key,
    required this.field,
    required this.descending,
  });
  final SortField field;
  final bool descending;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<SortField>(
      tooltip: context.l10n.sort,
      icon: const Icon(Icons.sort_rounded),
      onSelected: context.read<LibraryViewStore>().setSort,
      itemBuilder: (_) => [
        for (final f in SortField.values)
          PopupMenuItem(
            value: f,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    f.label,
                    style: TextStyle(
                      fontWeight: f == field
                          ? FontWeight.w800
                          : FontWeight.w500,
                      color: f == field ? context.palette.accent : null,
                    ),
                  ),
                ),
                if (f == field)
                  Icon(
                    descending
                        ? Icons.arrow_downward_rounded
                        : Icons.arrow_upward_rounded,
                    size: 16,
                    color: context.palette.accent,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class LibraryPlatformFilterButton extends StatelessWidget {
  const LibraryPlatformFilterButton({
    super.key,
    required this.selected,
    required this.options,
  });
  final GamePlatform? selected;
  final List<GamePlatform> options;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Object>(
      tooltip: context.l10n.filterByPlatform,
      icon: Icon(
        Icons.filter_list_rounded,
        color: selected != null ? context.palette.accent : null,
      ),
      onSelected: (v) => context.read<LibraryViewStore>().setPlatformFilter(
        v is GamePlatform ? v : null,
      ),
      itemBuilder: (_) => [
        PopupMenuItem<Object>(
          value: 'all',
          child: Text(
            context.l10n.allPlatforms,
            style: TextStyle(
              fontWeight: selected == null ? FontWeight.w800 : FontWeight.w500,
              color: selected == null ? context.palette.accent : null,
            ),
          ),
        ),
        for (final p in options)
          PopupMenuItem<Object>(
            value: p,
            child: Row(
              children: [
                Icon(p.icon, size: 18, color: context.palette.legible(p.color)),
                const SizedBox(width: 10),
                Text(
                  p.label,
                  style: TextStyle(
                    fontWeight: selected == p
                        ? FontWeight.w800
                        : FontWeight.w500,
                    color: selected == p ? context.palette.accent : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// [list] pulled down to refresh when [onRefresh] says how; as it is when null.
Widget _pullable(Widget list, Future<void> Function()? onRefresh) =>
    onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh, child: list);

class LibraryPosterGrid extends StatelessWidget {
  const LibraryPosterGrid({super.key, required this.games, this.onRefresh});
  final List<Game> games;

  /// Reads the games again when the grid is pulled down; none: it isn't.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 900 ? 6 : (c.maxWidth >= 600 ? 5 : 3);
        return _pullable(
          GridView.builder(
            physics: onRefresh == null ? null : const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 2 / 3,
            ),
            itemCount: games.length,
            itemBuilder: (_, i) => _PosterTile(game: games[i]),
          ),
          onRefresh,
        );
      },
    );
  }
}

class _PosterTile extends StatelessWidget {
  const _PosterTile({required this.game});
  final Game game;

  Widget _badge(Widget child) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(8),
    ),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    // One button for screen readers, named after the game: a cover image says
    // nothing, and the badges alone would be read as "4.5, 12h".
    final label = [
      game.title,
      if (game.rating > 0) context.l10n.ratedOutOf5(fmtHours(game.rating)),
      if (game.hoursPlayed > 0) context.l10n.hoursPlayedLabel(game.hoursPlayed, fmtHours(game.hoursPlayed)),
      if (game.isPerfected) game.perfectMark.title,
    ].join(', ');
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: () => openGame(context, game.id),
      child: _tile(context),
    );
  }

  Widget _tile(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: CoverArt(game: game)),
        // The rating and the Platinum (or 100%) share the corner: a cover
        // with no image has its title along the bottom.
        if (game.rating > 0 || game.isPerfected)
          PositionedDirectional(
            start: 6,
            top: 6,
            child: _badge(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The badges are dark in either theme, on the cover art.
                  if (game.rating > 0) ...[
                    Icon(Icons.star_rounded, size: 12, color: Palette.dark.star),
                    const SizedBox(width: 2),
                    Text(
                      fmtHours(game.rating),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  if (game.rating > 0 && game.isPerfected)
                    const SizedBox(width: 4),
                  if (game.isPerfected)
                    Icon(
                      game.perfectMark.icon,
                      size: 12,
                      color: game.perfectMark.color,
                    ),
                ],
              ),
            ),
          ),
        if (game.hoursPlayed > 0)
          PositionedDirectional(
            end: 6,
            top: 6,
            child: _badge(
              Text(
                context.l10n.hoursCompact(fmtHours(game.hoursPlayed)),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => openGame(context, game.id),
            ),
          ),
        ),
      ],
    );
  }
}

class LibraryGameList extends StatelessWidget {
  const LibraryGameList({super.key, required this.games, this.onRefresh});
  final List<Game> games;

  /// Reads the games again when the list is pulled down; none: it isn't.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    return _pullable(
      ListView.separated(
        physics: onRefresh == null ? null : const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: games.length,
        separatorBuilder: (context, index) => Divider(
          height: 1,
          indent: 82,
          color: context.palette.hairline,
        ),
        itemBuilder: (_, i) => _LibraryListTile(game: games[i]),
      ),
      onRefresh,
    );
  }
}

class _LibraryListTile extends StatelessWidget {
  const _LibraryListTile({required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    final platform =
        game.playedOn ??
        (game.platforms.isNotEmpty ? game.platforms.first : null);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => openGame(context, game.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            SizedBox(width: 60, child: CoverArt(game: game, radius: 10)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    game.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (platform != null) ...[
                        Icon(platform.icon, size: 14, color: context.palette.legible(platform.color)),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            platform.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: context.palette.legible(platform.color),
                            ),
                          ),
                        ),
                      ],
                      if (platform != null && game.hasReleaseYear)
                        Text(
                          '  ·  ',
                          style: TextStyle(color: context.palette.muted),
                        ),
                      if (game.hasReleaseYear)
                        Text(
                          '${game.releaseYear}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: context.palette.muted,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      game.rating > 0
                          ? StarRating(rating: game.rating, size: 15)
                          : Text(
                              context.l10n.notRated,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.palette.muted,
                              ),
                            ),
                      if (game.isPerfected) ...[
                        const SizedBox(width: 8),
                        Tooltip(
                          message: game.perfectMark.title,
                          child: Icon(
                            game.perfectMark.icon,
                            size: 16,
                            color: context.palette.legible(
                              game.perfectMark.color,
                            ),
                            semanticLabel: game.perfectMark.title,
                          ),
                        ),
                      ],
                      const Spacer(),
                      Icon(
                        Icons.schedule_rounded,
                        size: 14,
                        color: context.palette.muted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        game.hoursPlayed > 0
                            ? context.l10n.hoursShort(fmtHours(game.hoursPlayed))
                            : '—',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: context.palette.muted),
          ],
        ),
      ),
    );
  }
}

/// The row of status tabs of a Library: "All", then one per [GameStatus], each
/// with how many games it holds, and "Hidden" for the signed-in member's own
/// ([hiddenCount]). [counts] has [GameStatus.values].length + 1
/// entries, "All" first.
class LibraryStatusTabBar extends StatelessWidget {
  const LibraryStatusTabBar({
    super.key,
    required this.controller,
    required this.counts,
    this.hiddenCount,
  });

  final TabController controller;
  final List<int> counts;

  /// How many games the member hid from other members; null: no Hidden tab.
  final int? hiddenCount;

  @override
  Widget build(BuildContext context) {
    Tab statusTab(String label, int count, {IconData? icon}) => Tab(
      height: 38,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 15), const SizedBox(width: 5)],
            Text(label),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
            ),
          ],
        ),
      ),
    );
    return TabBar(
      controller: controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      dividerColor: Colors.transparent,
      indicatorSize: TabBarIndicatorSize.tab,
      indicatorPadding: const EdgeInsets.symmetric(vertical: 2),
      splashBorderRadius: BorderRadius.circular(20),
      labelPadding: const EdgeInsets.symmetric(horizontal: 3),
      labelColor: context.palette.accent,
      unselectedLabelColor: context.palette.muted,
      labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
      unselectedLabelStyle: const TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 13.5,
      ),
      indicator: BoxDecoration(
        color: context.palette.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.palette.accent.withValues(alpha: 0.5)),
      ),
      tabs: [
        statusTab(context.l10n.all, counts[0]),
        for (var i = 0; i < GameStatus.values.length; i++)
          statusTab(GameStatus.values[i].label, counts[i + 1]),
        if (hiddenCount case final hidden?) statusTab(context.l10n.libraryHiddenTab, hidden, icon: Icons.visibility_off_rounded),
      ],
    );
  }
}
