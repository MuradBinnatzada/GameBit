import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/next_game_picker.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/app_choice_chip.dart';
import 'package:checkpoint/widgets/cover_art.dart';
import 'package:checkpoint/widgets/play_timer_widgets.dart';
import 'package:checkpoint/widgets/sheet_frame.dart';

/// "What should I play next?": a game picked at random from the backlog (or the
/// statuses and platform chosen here), with "Pick another" and "Play it".
Future<void> showPickNextSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => const PickNextSheet(),
);

class PickNextSheet extends StatefulWidget {
  const PickNextSheet({super.key});

  @override
  State<PickNextSheet> createState() => _PickNextSheetState();
}

class _PickNextSheetState extends State<PickNextSheet> {
  Set<GameStatus> _statuses = NextGamePicker.defaultStatuses;
  GamePlatform? _platform;
  late NextGamePicker _picker = _newPicker();
  late Game? _pick = _picker.next();

  NextGamePicker _newPicker() => NextGamePicker(
    library: context.read<LibraryStore>().listedGames,
    statuses: _statuses,
    platform: _platform,
  );

  /// Applies a filter change and picks again from what it leaves.
  void _refilter(VoidCallback change) => setState(() {
    change();
    _picker = _newPicker();
    _pick = _picker.next();
  });

  void _toggleStatus(GameStatus status) => _refilter(() {
    final next = {..._statuses};
    if (!next.remove(status)) next.add(status);
    if (next.isNotEmpty) _statuses = next;
    if (_platform != null &&
        !NextGamePicker.platformsOf(context.read<LibraryStore>().listedGames, _statuses).contains(_platform)) {
      _platform = null;
    }
  });

  Future<void> _play(Game game) async {
    final store = context.read<LibraryStore>();
    final navigator = Navigator.of(context);
    if (game.status != GameStatus.playing) await store.setStatus(game.id, GameStatus.playing);
    if (!mounted) return;
    await startPlayTimer(context, game);
    if (!mounted) return;
    navigator.pop();
    openGame(navigator.context, game.id);
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryStore>().listedGames;
    final platforms = NextGamePicker.platformsOf(library, _statuses);
    final pick = _pick;
    return SheetFrame(
      title: context.l10n.whatShouldIPlay,
      subtitle: context.l10n.gamesToPickFrom(_picker.candidates.length),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final status in NextGamePicker.choosable)
            AppChoiceChip(
              label: status.label,
              icon: status.icon,
              iconColor: context.palette.legible(status.color),
              selected: _statuses.contains(status),
              onSelected: () => _toggleStatus(status),
            ),
        ]),
        if (platforms.length > 1) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<GamePlatform?>(
            initialValue: _platform,
            // Fills the field, so a long name (or large text) gets an ellipsis.
            isExpanded: true,
            decoration: fieldDecoration(context, context.l10n.platform),
            items: [
              DropdownMenuItem(value: null, child: Text(context.l10n.anyPlatform, overflow: TextOverflow.ellipsis)),
              for (final p in platforms) DropdownMenuItem(value: p, child: Text(p.label, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (p) => _refilter(() => _platform = p),
          ),
        ],
        const SizedBox(height: 18),
        if (pick == null)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
              context.l10n.nothingToPick,
              style: TextStyle(color: context.palette.muted, height: 1.4),
            ),
          )
        else
          _PickCard(game: pick),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _picker.candidates.length < 2 ? null : () => setState(() => _pick = _picker.next()),
              icon: const Icon(Icons.casino_rounded, size: 18),
              label: Text(context.l10n.pickAnother),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              onPressed: pick == null ? null : () => _play(pick),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(context.l10n.playIt),
            ),
          ),
        ]),
      ]),
    );
  }
}

class _PickCard extends StatelessWidget {
  const _PickCard({required this.game});
  final Game game;

  @override
  Widget build(BuildContext context) {
    final details = [
      game.status!.label,
      if (game.hasReleaseYear) '${game.releaseYear}',
      if (game.hoursPlayed > 0) L10n.current.hoursShortPlayed(fmtHours(game.hoursPlayed)),
      if (game.genres.isNotEmpty) game.genres.first,
    ].join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => openGame(context, game.id),
      child: Row(children: [
        SizedBox(width: 92, child: CoverArt(game: game, radius: 10, showTitle: false)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(game.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.15)),
            const SizedBox(height: 6),
            Text(details, style: TextStyle(color: context.palette.muted, height: 1.35)),
          ]),
        ),
      ]),
    );
  }
}
