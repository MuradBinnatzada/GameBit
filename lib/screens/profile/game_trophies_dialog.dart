import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart' show ImageRenderMethodForWeb;
import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/trophy.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/public_trophies_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/app_choice_chip.dart';
import 'package:checkpoint/widgets/trophy_tile.dart';

/// Opens [gameId]'s trophies for the member [userId] in a dialog: their progress
/// and the count of each grade at the top, then every trophy, earned ones first.
/// The list is fetched as it opens (see [PublicTrophiesStore.loadGame]); [own] is
/// the signed-in member's own game, which is read again each time (a sync may have
/// changed it) and is told how to fill an empty list.
Future<void> showGameTrophiesDialog(
  BuildContext context, {
  required String userId,
  required String gameId,
  required String title,
  String? coverUrl,
  bool own = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => GameTrophiesDialog(userId: userId, gameId: gameId, title: title, coverUrl: coverUrl, own: own),
  );
}

enum _Filter { all, earned, locked }

class GameTrophiesDialog extends StatefulWidget {
  const GameTrophiesDialog({
    super.key,
    required this.userId,
    required this.gameId,
    required this.title,
    this.coverUrl,
    this.own = false,
  });

  final String userId;
  final String gameId;
  final String title;
  final String? coverUrl;
  final bool own;

  @override
  State<GameTrophiesDialog> createState() => _GameTrophiesDialogState();
}

class _GameTrophiesDialogState extends State<GameTrophiesDialog> {
  /// A list this short is laid out whole, so the dialog is only as tall as it.
  static const _shrinkWrapUpTo = 8;

  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    // After the frame: loading notifies, which isn't allowed during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(force: widget.own));
    });
  }

  Future<void> _load({bool force = false}) =>
      context.read<PublicTrophiesStore>().loadGame(widget.userId, widget.gameId, force: force);

  @override
  Widget build(BuildContext context) {
    final view = context.watch<PublicTrophiesStore>().gameOf(widget.userId, widget.gameId);
    final list = view.status == LoadStatus.ready ? view.trophies : null;
    final size = MediaQuery.sizeOf(context);

    return Dialog(
      backgroundColor: context.palette.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: context.palette.text.withValues(alpha: 0.08)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: math.min(size.height * 0.85, 820)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              title: widget.title,
              coverUrl: widget.coverUrl,
              trophies: list,
              refreshing: view.status == LoadStatus.loading,
              onRefresh: view.status == LoadStatus.loading ? null : () => unawaited(_load(force: true)),
            ),
            if (list != null && list.isNotEmpty) _filters(list),
            Flexible(child: _body(view.status, list)),
          ],
        ),
      ),
    );
  }

  Widget _filters(List<Trophy> list) {
    final earned = list.where((t) => t.earned).length;
    final locked = list.length - earned;
    if (earned == 0 || locked == 0) return const SizedBox(height: 12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (filter, label) in [
            (_Filter.all, context.l10n.filterAllCount(list.length)),
            (_Filter.earned, context.l10n.filterUnlockedCount(earned)),
            (_Filter.locked, context.l10n.filterLockedCount(locked)),
          ])
            AppChoiceChip(label: label, selected: _filter == filter, onSelected: () => setState(() => _filter = filter)),
        ],
      ),
    );
  }

  Widget _body(LoadStatus status, List<Trophy>? list) {
    switch (status) {
      case LoadStatus.idle:
      case LoadStatus.loading:
        return const SizedBox(
          height: 160,
          child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))),
        );
      case LoadStatus.failed:
        return _Message(
          text: context.l10n.trophiesLoadFailed,
          error: true,
          action: TextButton.icon(
            onPressed: () => unawaited(_load(force: true)),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(context.l10n.tryAgain),
          ),
        );
      case LoadStatus.ready:
        break;
    }

    if (list == null || list.isEmpty) {
      return _Message(text: widget.own ? context.l10n.trophiesNoneOwn : context.l10n.trophiesNoneOther);
    }
    final sorted = sortTrophies(list);
    final shown = [
      for (final t in sorted)
        if (_filter == _Filter.all || t.earned == (_filter == _Filter.earned)) t,
    ];
    return ListView.builder(
      shrinkWrap: sorted.length <= _shrinkWrapUpTo,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: shown.length,
      itemBuilder: (_, i) => TrophyTile(trophy: shown[i]),
    );
  }
}

/// [trophies] with the earned ones first, the most recently earned on top, then
/// the ones not earned in Sony's order (the Platinum first).
List<Trophy> sortTrophies(List<Trophy> trophies) {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return [...trophies]..sort((a, b) {
    if (a.earned != b.earned) return a.earned ? -1 : 1;
    if (a.earned) {
      final byDate = (b.earnedAt ?? epoch).compareTo(a.earnedAt ?? epoch);
      if (byDate != 0) return byDate;
    }
    return a.id.compareTo(b.id);
  });
}

/// Cover, title, progress and the earned count of each grade, refresh and close.
/// Glows gold once every trophy is earned.
class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.coverUrl,
    required this.trophies,
    required this.refreshing,
    required this.onRefresh,
  });

  final String title;
  final String? coverUrl;

  /// Null until the list is here.
  final List<Trophy>? trophies;
  final bool refreshing;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final list = trophies ?? const <Trophy>[];
    final earned = list.where((t) => t.earned).length;
    final total = list.length;
    final complete = total > 0 && earned >= total;
    final counts = TrophyCounts.earnedIn(list);
    final totals = TrophyCounts(
      bronze: list.where((t) => t.grade == TrophyGrade.bronze).length,
      silver: list.where((t) => t.grade == TrophyGrade.silver).length,
      gold: list.where((t) => t.grade == TrophyGrade.gold).length,
      platinum: list.where((t) => t.grade == TrophyGrade.platinum).length,
    );
    final gold = trophyColor(context, TrophyGrade.gold);
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 8, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [(complete ? gold : context.palette.accent).withValues(alpha: 0.16), context.palette.surface],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Cover(url: coverUrl),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, height: 1.2, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              if (refreshing)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                IconButton(
                  tooltip: context.l10n.refreshTrophies,
                  onPressed: onRefresh,
                  icon: Icon(Icons.refresh_rounded, color: context.palette.muted),
                ),
              IconButton(
                tooltip: context.l10n.close,
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(Icons.close_rounded, color: context.palette.muted),
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('$earned', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: complete ? gold : null)),
                      const SizedBox(width: 6),
                      Text(
                        '/ $total',
                        style: TextStyle(color: context.palette.muted, fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      for (final grade in TrophyGrade.values.reversed)
                        if (totals.of(grade) > 0)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(start: 10),
                            child: Semantics(
                              label: '${trophyGradeName(context, grade)}: ${counts.of(grade)} / ${totals.of(grade)}',
                              excludeSemantics: true,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TrophyCup(grade: grade, size: 16),
                                  const SizedBox(width: 3),
                                  Text(
                                    '${counts.of(grade)}/${totals.of(grade)}',
                                    style: TextStyle(fontSize: 12, color: context.palette.muted),
                                  ),
                                ],
                              ),
                            ),
                          ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: earned / total,
                      minHeight: 8,
                      color: gold,
                      backgroundColor: context.palette.track,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
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
      child: Icon(Icons.sports_esports_rounded, size: 22, color: context.palette.muted),
    );
    final link = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 48,
        height: 64,
        child: link == null || link.isEmpty
            ? fallback
            : CachedNetworkImage(
                imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
                imageUrl: link,
                fit: BoxFit.cover,
                memCacheWidth: 144,
                fadeInDuration: Duration.zero,
                placeholder: (_, _) => fallback,
                errorWidget: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.error = false, this.action});
  final String text;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: error ? context.palette.danger : context.palette.muted, height: 1.4),
          ),
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}
