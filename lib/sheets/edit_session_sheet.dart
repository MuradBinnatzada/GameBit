import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/limits.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/platform_widgets.dart';
import 'package:checkpoint/widgets/session_time_field.dart';
import 'package:checkpoint/widgets/sheet_frame.dart';

/// How long a snack bar with an Undo stays (see game_detail_screen.dart).
const _undoDuration = Duration(seconds: 5);

/// Opens the sheet that edits or deletes the play session [sessionId].
Future<void> showEditSessionSheet(BuildContext context, String sessionId) async {
  final session = context.read<LibraryStore>().sessionById(sessionId);
  if (session == null) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => EditSessionSheet(session: session),
  );
}

/// Deletes [session], with an Undo that logs it again as it was.
Future<void> deleteSessionWithUndo(BuildContext context, LogEntry session) async {
  final store = context.read<LibraryStore>();
  final messenger = ScaffoldMessenger.of(context);
  final l10n = context.l10n;
  final removed = await store.deleteSession(session.id);
  if (removed == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(l10n.deletedSession(fmtHours(removed.hours))),
      duration: _undoDuration,
      persist: false,
      action: SnackBarAction(label: l10n.undo, onPressed: () => store.restoreSession(removed)),
    ));
}

/// A play session's hours, platform, day and note, for fixing one logged wrong;
/// or deleting it. The game's total follows the change in hours.
class EditSessionSheet extends StatefulWidget {
  const EditSessionSheet({super.key, required this.session});
  final LogEntry session;

  @override
  State<EditSessionSheet> createState() => _EditSessionSheetState();
}

class _EditSessionSheetState extends State<EditSessionSheet> {
  late final _hours = TextEditingController(text: fmtHours(widget.session.hours));
  late final _note = TextEditingController(text: widget.session.note);
  late GamePlatform _platform = widget.session.platform;
  late DateTime _at = widget.session.timestamp;

  @override
  void dispose() {
    _hours.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<LibraryStore>();
    final game = store.maybeGame(widget.session.gameId);
    final platforms = <GamePlatform>{
      ...?game?.playedOnOptions,
      widget.session.platform,
    }.toList();
    final hours = parseNum(_hours.text);
    final valid = hours != null && hours > 0 && (hours <= maxManualHours || hours <= widget.session.hours);

    return SheetFrame(
      title: context.l10n.editSession,
      subtitle: game?.title ?? '',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _hours,
          keyboardType: decimalKeyboard,
          inputFormatters: [decimalFormatter],
          onChanged: (_) => setState(() {}),
          decoration: fieldDecoration(context, context.l10n.hoursPlayed, suffix: context.l10n.hrsUnit).copyWith(
            errorText: hours == null || valid
                ? null
                : hours > 0
                ? context.l10n.sessionHoursMax(fmtThousands(maxManualHours.round()))
                : context.l10n.enterMoreThanZeroHours,
          ),
        ),
        const SizedBox(height: 18),
        Text(context.l10n.playedOn, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        PlatformChips(
          platforms: platforms,
          selected: _platform,
          onSelected: (p) => setState(() => _platform = p),
        ),
        const SizedBox(height: 18),
        SessionTimeField(
          value: _at,
          allowNow: false,
          onChanged: (at) => setState(() => _at = at ?? DateTime.now()),
        ),
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
            onPressed: !valid
                ? null
                : () {
                    store.editSession(
                      widget.session.id,
                      hours: hours,
                      platform: _platform,
                      at: _at,
                      note: _note.text,
                    );
                    Navigator.pop(context);
                  },
            child: Text(context.l10n.saveChanges),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: context.palette.danger),
            onPressed: () {
              // Reads what it needs from the sheet before it closes.
              deleteSessionWithUndo(context, widget.session);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: Text(context.l10n.deleteSession),
          ),
        ),
      ]),
    );
  }
}
