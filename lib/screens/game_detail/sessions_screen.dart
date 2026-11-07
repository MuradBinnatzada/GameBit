import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/sheets/edit_session_sheet.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/empty_state.dart';

/// Every play session of one game, newest first. Tapping one edits it.
class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key, required this.gameId});
  final String gameId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LibraryStore>();
    final game = store.maybeGame(gameId);
    final logs = store.logsFor(gameId);
    final total = logs.fold<double>(0, (sum, l) => sum + l.hours);
    return Scaffold(
      appBar: AppBar(title: Text(game == null ? context.l10n.sessions : context.l10n.gameSessions(game.title))),
      body: logs.isEmpty
          ? EmptyState(
              icon: Icons.timer_outlined,
              title: context.l10n.noSessions,
              message: context.l10n.noSessionsMessage,
              onRefresh: store.refresh,
            )
          : RefreshIndicator(
              onRefresh: store.refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Text(
                      '${context.l10n.sessionCount(logs.length)} · ${context.l10n.hoursLogged(fmtHours(total))}',
                      style: TextStyle(color: context.palette.muted),
                    ),
                  ),
                  for (final l in logs) SessionTile(session: l, showDay: true),
                ],
              ),
            ),
    );
  }
}

/// One play session: platform, hours, note and when. Tapping it edits it.
class SessionTile extends StatelessWidget {
  const SessionTile({super.key, required this.session, this.showDay = false});
  final LogEntry session;

  /// The day and time it was played, instead of how long ago.
  final bool showDay;

  @override
  Widget build(BuildContext context) {
    final l = session;
    final when = showDay
        ? '${fmtDay(l.timestamp)}, ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(l.timestamp))}'
        : timeAgo(l.timestamp);
    final color = context.palette.legible(l.platform.color);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showEditSessionSheet(context, l.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: Icon(l.platform.icon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.l10n.sessionHoursOn(fmtHours(l.hours), l.platform.label), style: const TextStyle(fontWeight: FontWeight.w600)),
              if (l.isSynced)
                Row(children: [
                  FaIcon(l.fromSteam ? FontAwesomeIcons.steam : FontAwesomeIcons.playstation, size: 11, color: context.palette.muted),
                  SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      '${l.fromSteam ? context.l10n.fromSteamPlaytime : context.l10n.fromPlayStationPlaytime} · ${fmtDateTime(l.timestamp)}',
                      style: TextStyle(fontSize: 12, color: context.palette.muted),
                    ),
                  ),
                ]),
              if (l.note.isNotEmpty)
                Text(l.note, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: context.palette.muted)),
            ]),
          ),
          const SizedBox(width: 8),
          // Narrow enough that large text wraps it instead of pushing the row
          // off the edge.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 110),
            child: Text(when, textAlign: TextAlign.end, style: TextStyle(fontSize: 12, color: context.palette.muted)),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded, size: 18, color: context.palette.muted),
        ]),
      ),
    );
  }
}
