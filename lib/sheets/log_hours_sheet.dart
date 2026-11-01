import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/limits.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/platform_widgets.dart';
import 'package:checkpoint/widgets/sheet_frame.dart';

/// Read-only guard: returns true (and shows a hint) when logged out.
bool _blockedByReadOnly(BuildContext context) {
  if (context.read<AuthStore>().isLoggedIn) return false;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(context.l10n.logInToTrackGames)));
  return true;
}

Future<void> showLogHoursSheet(BuildContext context, String gameId) async {
  if (_blockedByReadOnly(context)) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => LogHoursSheet(gameId: gameId),
  );
}

/// Game-detail sheet: set total time played.
class LogHoursSheet extends StatefulWidget {
  const LogHoursSheet({super.key, required this.gameId});
  final String gameId;

  @override
  State<LogHoursSheet> createState() => _LogHoursSheetState();
}

class _LogHoursSheetState extends State<LogHoursSheet> {
  late final Game _game = context.read<LibraryStore>().gameById(widget.gameId);
  late final List<GamePlatform> _availablePlatforms = _game.playedOnOptions;
  late final TextEditingController _total = TextEditingController(text: fmtHours(_game.hoursPlayed));
  final _note = TextEditingController();
  late GamePlatform? _platform = _game.playedOn ?? (_game.platforms.isEmpty ? null : _game.platforms.first);

  @override
  void dispose() {
    _total.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = parseNum(_total.text);
    final valid = total != null && total >= 0 && (total <= maxManualHours || total <= _game.hoursPlayed);
    final delta = total == null ? null : total - _game.hoursPlayed;

    final l10n = context.l10n;
    String preview;
    if (delta == null) {
      preview = l10n.hoursInvalid;
    } else if (!valid) {
      preview = l10n.totalHoursMax(fmtThousands(maxManualHours.round()));
    } else if (delta > 0.04) {
      preview = _platform == null
          ? l10n.addsSession(fmtHours(delta))
          : l10n.addsSessionOn(fmtHours(delta), _platform!.label);
    } else if (delta < -0.04) {
      preview = l10n.correctsTotal(fmtHours(delta));
    } else {
      preview = l10n.noChangeToTotal;
    }

    return SheetFrame(
      title: l10n.logHoursTitle,
      subtitle: _game.title,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _total,
          keyboardType: decimalKeyboard,
          inputFormatters: [decimalFormatter],
          onChanged: (_) => setState(() {}),
          decoration: fieldDecoration(context, l10n.totalPlayed, suffix: l10n.hrsUnit),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          for (final h in const <double>[0.5, 1, 2, 5])
            ActionChip(
              label: Text('+${l10n.hoursCompact(fmtHours(h))}'),
              onPressed: () => setState(() => _total.text = fmtHours((parseNum(_total.text) ?? 0) + h)),
            ),
        ]),
        const SizedBox(height: 6),
        Text(preview, style: TextStyle(color: valid ? context.palette.muted : context.palette.danger, fontSize: 12.5)),
        const SizedBox(height: 18),
        Text(l10n.playedOn, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        PlatformChips(platforms: _availablePlatforms, selected: _platform, onSelected: (p) => setState(() => _platform = p)),
        const SizedBox(height: 18),
        TextField(
          controller: _note,
          maxLength: maxNoteLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: fieldDecoration(context, l10n.noteOptional).copyWith(counterText: ''),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: !valid
                ? null
                : () {
                    context.read<LibraryStore>().updateTime(
                      gameId: _game.id,
                      totalHours: total,
                      platform: _platform,
                      note: _note.text,
                    );
                    Navigator.pop(context);
                  },
            child: Text(l10n.save),
          ),
        ),
      ]),
    );
  }
}