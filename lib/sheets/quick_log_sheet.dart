import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/limits.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/platform_widgets.dart';
import 'package:checkpoint/widgets/session_time_field.dart';
import 'package:checkpoint/widgets/sheet_frame.dart';

/// Read-only guard: returns true (and shows a hint) when logged out.
bool _blockedByReadOnly(BuildContext context) {
  if (context.read<AuthStore>().isLoggedIn) return false;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(context.l10n.logInToTrackGames)));
  return true;
}

Future<void> showQuickLogSheet(BuildContext context, {String? gameId}) async {
  if (_blockedByReadOnly(context)) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => QuickLogSheet(initialGameId: gameId),
  );
}

/// FAB sheet: pick a game, pick the platform you played on, add a session.
class QuickLogSheet extends StatefulWidget {
  const QuickLogSheet({super.key, this.initialGameId});
  final String? initialGameId;

  @override
  State<QuickLogSheet> createState() => _QuickLogSheetState();
}

class _QuickLogSheetState extends State<QuickLogSheet> {
  late final _hours = TextEditingController(text: fmtHours(1));
  final _note = TextEditingController();
  String? _gameId;
  GamePlatform? _platform;

  /// When it was played; null is now.
  DateTime? _at;

  @override
  void initState() {
    super.initState();
    _gameId = widget.initialGameId;
    if (_gameId != null) _platform = _defaultPlatform(context.read<LibraryStore>().gameById(_gameId!));
  }

  @override
  void dispose() {
    _hours.dispose();
    _note.dispose();
    super.dispose();
  }

  // `playedOnOptions` is never empty, so `.first` is safe.
  GamePlatform _defaultPlatform(Game g) => g.playedOn ?? g.playedOnOptions.first;

  void _save(Game game, double hours) {
    final messenger = ScaffoldMessenger.of(context);
    final logged = _platform == null
        ? context.l10n.loggedHoursOf(fmtHours(hours), game.title)
        : context.l10n.loggedHoursOfOn(fmtHours(hours), game.title, _platform!.label);
    context.read<LibraryStore>().logSession(gameId: game.id, hours: hours, platform: _platform, note: _note.text, at: _at);
    Navigator.pop(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(logged)));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final game = _gameId == null ? null : store.maybeGame(_gameId!);
    final hours = parseNum(_hours.text);
    final tooLong = hours != null && hours > maxSessionHours;
    final canSave = game != null && hours != null && hours > 0 && !tooLong;

    final sorted = [...store.games]..sort((a, b) {
        int rank(Game g) => g.isPlaying ? 0 : (g.inLibrary ? 1 : 2);
        final c = rank(a).compareTo(rank(b));
        return c != 0 ? c : a.title.compareTo(b.title);
      });

    return SheetFrame(
      title: context.l10n.logASession,
      subtitle: context.l10n.logSessionSubtitle,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DropdownMenu<String>(
          initialSelection: _gameId,
          expandedInsets: EdgeInsets.zero,
          enableFilter: true,
          requestFocusOnTap: true,
          menuHeight: 280,
          label: Text(context.l10n.game),
          leadingIcon: const Icon(Icons.sports_esports_rounded),
          // The arrow is a button of its own: screen readers say what it does.
          trailingIcon: Icon(Icons.arrow_drop_down, semanticLabel: context.l10n.showGames),
          selectedTrailingIcon: Icon(Icons.arrow_drop_up, semanticLabel: context.l10n.hideGames),
          dropdownMenuEntries: [
            for (final g in sorted)
              DropdownMenuEntry<String>(value: g.id, label: g.title, leadingIcon: Icon(g.coverIcon, color: g.coverColors.first, size: 20)),
          ],
          onSelected: (id) => setState(() {
            _gameId = id;
            _platform = id == null ? null : _defaultPlatform(store.gameById(id));
          }),
        ),
        if (game != null) ...[
          const SizedBox(height: 18),
          Text(context.l10n.playedOn, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          PlatformChips(platforms: game.playedOnOptions, selected: _platform, onSelected: (p) => setState(() => _platform = p)),
        ],
        const SizedBox(height: 18),
        TextField(
          controller: _hours,
          keyboardType: decimalKeyboard,
          inputFormatters: [decimalFormatter],
          onChanged: (_) => setState(() {}),
          decoration: fieldDecoration(context, context.l10n.hoursThisSession, suffix: context.l10n.hrsUnit).copyWith(
            errorText: tooLong
                ? context.l10n.sessionTooLong(fmtHours(maxSessionHours))
                : null,
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          for (final h in const <double>[0.5, 1, 2, 4])
            ActionChip(
              label: Text('+${context.l10n.hoursCompact(fmtHours(h))}'),
              onPressed: () => setState(() => _hours.text = fmtHours((parseNum(_hours.text) ?? 0) + h)),
            ),
        ]),
        const SizedBox(height: 14),
        SessionTimeField(value: _at, onChanged: (at) => setState(() => _at = at)),
        const SizedBox(height: 14),
        TextField(
          controller: _note,
          maxLength: maxNoteLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: fieldDecoration(context, context.l10n.noteOptional).copyWith(counterText: ''),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: canSave ? () => _save(game, hours) : null,
            child: Text(context.l10n.saveSession),
          ),
        ),
      ]),
    );
  }
}