import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart' show ImageRenderMethodForWeb;
import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/trophy.dart';
import 'package:checkpoint/screens/profile/game_trophies_dialog.dart';
import 'package:checkpoint/screens/settings/psn_import.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/public_trophies_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/panel.dart';
import 'package:checkpoint/widgets/trophy_tile.dart';

/// A member's PlayStation trophies: how many of each grade over all their games,
/// then every game they earned one in, most complete first. Both come from one
/// request of counts; a game's trophies are fetched when it is tapped (see
/// [showGameTrophiesDialog]). The card is left out while there is nothing to show
/// (no PlayStation sync yet, or the member keeps their trophies private); your own
/// profile says how to fill it where the sync is offered.
class TrophiesSection extends StatefulWidget {
  const TrophiesSection({super.key, required this.userId});

  final String userId;

  @override
  State<TrophiesSection> createState() => _TrophiesSectionState();
}

class _TrophiesSectionState extends State<TrophiesSection> {
  static const int _initialGames = 5;
  static const int _pageSize = 10;

  int _visible = _initialGames;

  bool get _own => context.read<AuthStore>().user?.id == widget.userId;

  @override
  void initState() {
    super.initState();
    // After the frame: loading notifies, which isn't allowed during build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(TrophiesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId) {
      _visible = _initialGames;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  /// Your own are read again each time the page opens: a sync may have changed
  /// them. Another member's are held until the account changes.
  void _load({bool force = false}) {
    if (!mounted) return;
    final store = context.read<PublicTrophiesStore>();
    unawaited(store.loadSummary(widget.userId, force: force || _own));
    // Your own profile's PlayStation icon is read here too: it is the same page.
    if (_own) unawaited(store.loadPsnSynced(widget.userId));
  }

  @override
  Widget build(BuildContext context) {
    final view = context.watch<PublicTrophiesStore>().summaryOf(widget.userId);
    final own = context.watch<AuthStore>().user?.id == widget.userId;
    final l10n = context.l10n;

    final Widget? body = switch (view.status) {
      LoadStatus.idle || LoadStatus.loading => null,
      LoadStatus.failed => own
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.trophiesLoadFailed, style: TextStyle(color: context.palette.danger, fontSize: 12.5, height: 1.35)),
                TextButton.icon(
                  onPressed: () => _load(force: true),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(l10n.tryAgain),
                ),
              ],
            )
          : null,
      LoadStatus.ready when view.games.isEmpty => own && psnImportAvailable()
          ? Text(l10n.noTrophiesOwn, style: TextStyle(color: context.palette.muted, fontSize: 12.5, height: 1.35))
          : null,
      LoadStatus.ready => _content(view),
    };
    if (body == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Panel(
        title: l10n.trophiesLabel,
        trailing: view.status == LoadStatus.ready && view.games.isNotEmpty
            ? IconButton(
                tooltip: l10n.refreshTrophies,
                visualDensity: VisualDensity.compact,
                onPressed: () => _load(force: true),
                icon: Icon(Icons.refresh_rounded, color: context.palette.muted),
              )
            : null,
        child: body,
      ),
    );
  }

  Widget _content(TrophySummaryView view) {
    final all = view.games;
    final shown = all.take(_visible).toList();
    final remaining = all.length - shown.length;
    final nextPage = remaining < _pageSize ? remaining : _pageSize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Totals(totals: view.totals),
        const SizedBox(height: 10),
        for (final game in shown)
          _GameRow(
            game: game,
            onTap: () => showGameTrophiesDialog(
              context,
              userId: widget.userId,
              gameId: game.gameId,
              title: game.title,
              coverUrl: game.coverUrl,
              own: _own,
              loadFromPlayStation: psnTrophyListLoader(game.gameId),
            ),
          ),
        if (remaining > 0 || _visible > _initialGames)
          Row(
            children: [
              if (remaining > 0)
                Flexible(
                  child: TextButton(
                    onPressed: () => setState(() => _visible += _pageSize),
                    child: Text(context.l10n.showMoreLeft(nextPage, remaining), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              if (remaining > 0 && _visible > _initialGames) const SizedBox(width: 16),
              if (_visible > _initialGames)
                TextButton(onPressed: () => setState(() => _visible = _initialGames), child: Text(context.l10n.showLess)),
            ],
          ),
      ],
    );
  }
}

/// The count that is always there: the cups of each grade earned, and the trophies
/// earned out of all over every game with a list.
class _Totals extends StatelessWidget {
  const _Totals({required this.totals});
  final TrophyTotals totals;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final gold = trophyColor(context, TrophyGrade.gold);
    final done = totals.total > 0 && totals.earned >= totals.total;
    final percent = done ? 100 : (totals.progress * 100).floor();
    final detail = '$percent% · ${l10n.gamesCount(totals.games)}'
        '${totals.completedGames > 0 ? ' · ${l10n.completedCount(totals.completedGames)}' : ''}';
    return Semantics(
      container: true,
      label: '${l10n.trophiesLabel}: ${l10n.trophiesProgress(totals.earned, totals.total)}. $detail',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.palette.text.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: context.palette.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final grade in TrophyGrade.values.reversed)
                  Column(
                    children: [
                      TrophyCup(grade: grade, size: grade == TrophyGrade.platinum ? 28 : 24),
                      const SizedBox(height: 2),
                      Text('${totals.counts.of(grade)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                      Text(trophyGradeName(context, grade), style: TextStyle(fontSize: 11, color: context.palette.muted)),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: totals.progress.clamp(0.0, 1.0),
                minHeight: 8,
                color: gold,
                backgroundColor: context.palette.track,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${l10n.trophiesProgress(totals.earned, totals.total)} · $detail',
              style: TextStyle(color: context.palette.muted, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// One game's progress; tapping it opens the game's trophies.
class _GameRow extends StatelessWidget {
  const _GameRow({required this.game, required this.onTap});
  final GameTrophySummary game;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final percent = game.complete ? 100 : (game.progress * 100).floor();
    final gold = trophyColor(context, TrophyGrade.gold);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            _Cover(url: game.coverUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    game.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (game.hasPlatinum) ...[
                        const TrophyCup(grade: TrophyGrade.platinum, size: 14),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        '${game.earned} / ${game.total} · $percent%',
                        style: TextStyle(
                          color: game.complete ? gold : context.palette.muted,
                          fontSize: 12.5,
                          fontWeight: game.complete ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: game.progress.clamp(0.0, 1.0),
                      minHeight: 6,
                      color: gold,
                      backgroundColor: context.palette.track,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, color: context.palette.muted),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: context.palette.surfaceHigh,
      child: Icon(Icons.sports_esports_rounded, size: 20, color: context.palette.muted),
    );
    final link = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 40,
        height: 54,
        child: link == null || link.isEmpty
            ? fallback
            : CachedNetworkImage(
                imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
                imageUrl: link,
                fit: BoxFit.cover,
                memCacheWidth: 120,
                fadeInDuration: Duration.zero,
                placeholder: (_, _) => fallback,
                errorWidget: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
