import 'dart:async';

import 'package:flutter/material.dart';

import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/app/sign_in_panel.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/discussion.dart';
import 'package:checkpoint/screens/settings/blocked_members_screen.dart';
import 'package:checkpoint/screens/discussions/board_screen.dart';
import 'package:checkpoint/screens/discussions/new_thread_screen.dart';
import 'package:checkpoint/sheets/chat_rules_sheet.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/discussions_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/nav_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/widgets/empty_state.dart';
import 'package:checkpoint/widgets/thread_tile.dart';

enum _MenuAction { rules, blocked }

/// The Discussions tab: the boards to talk on, and below them the threads written
/// in last on any of them. Members who are signed out are asked to sign in.
class DiscussionsScreen extends StatefulWidget {
  const DiscussionsScreen({super.key});

  @override
  State<DiscussionsScreen> createState() => _DiscussionsScreenState();
}

class _DiscussionsScreenState extends State<DiscussionsScreen> {
  /// Threads of the latest list shown on the tab.
  static const _latestShown = 8;

  void _loadAfterFrame({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final store = context.read<DiscussionsStore>();
      unawaited(store.loadBoards(force: force));
      unawaited(store.loadThreads(DiscussionScope.all, force: force));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final loggedIn = context.watch<AuthStore>().isLoggedIn;
    final showing = context.watch<NavStore>().index == NavTab.discussions;
    final store = context.watch<DiscussionsStore>();

    if (!loggedIn) {
      return SafeArea(
        child: SignInPanel(
          icon: Icons.forum_outlined,
          title: l10n.logInToJoinDiscussions,
          message: l10n.logInToJoinDiscussionsMessage,
        ),
      );
    }
    // Asks when the tab is shown (it is built with the others, but nobody looked
    // yet); both calls do nothing while what they hold is fresh.
    if (showing) _loadAfterFrame();

    final boards = store.boards;
    final latest = store.listOf(DiscussionScope.all);
    final failed = store.boardsStatus == LoadStatus.failed && boards.isEmpty;

    Widget body;
    if (failed) {
      body = EmptyState(
        icon: Icons.cloud_off_rounded,
        title: l10n.discussionsLoadFailed,
        message: l10n.checkConnection,
        actionLabel: l10n.tryAgain,
        onAction: () => _loadAfterFrame(force: true),
      );
    } else if (boards.isEmpty) {
      // Not while the tab is out of sight: an animation keeps running there.
      body = showing
          ? const Center(child: CircularProgressIndicator())
          : const SizedBox.shrink();
    } else {
      body = RefreshIndicator(
        onRefresh: () async {
          await store.loadBoards(force: true);
          await store.loadThreads(DiscussionScope.all, force: true);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 112),
          children: [
            _BoardGrid(boards: boards),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 22, 4, 4),
              child: Semantics(
                header: true,
                child: Text(
                  l10n.latestDiscussions.toUpperCase(),
                  style: TextStyle(
                    color: palette.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
            if (latest.status == LoadStatus.ready && latest.threads.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                child: Text(
                  l10n.noDiscussionsYetMessage,
                  style: TextStyle(color: palette.muted, height: 1.4),
                ),
              )
            else
              for (final thread in latest.threads.take(_latestShown)) ...[
                ThreadTile(
                  key: ValueKey(thread.id),
                  thread: thread,
                  showBoard: true,
                ),
                Divider(height: 1, color: palette.hairline),
              ],
          ],
        ),
      );
    }

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l10n.discussions,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.newDiscussion,
                  icon: const Icon(Icons.edit_square),
                  onPressed: () => openNewThread(context),
                ),
                PopupMenuButton<_MenuAction>(
                  tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                  onSelected: (action) => switch (action) {
                    _MenuAction.rules => unawaited(showChatRules(context)),
                    _MenuAction.blocked => openBlockedMembers(context),
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _MenuAction.rules,
                      child: Row(
                        children: [
                          const Icon(Icons.rule_rounded, size: 18),
                          const SizedBox(width: 10),
                          Text(l10n.chatRules),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: _MenuAction.blocked,
                      child: Row(
                        children: [
                          const Icon(Icons.person_off_outlined, size: 18),
                          const SizedBox(width: 10),
                          Text(l10n.blockedMembers),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: body,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The boards, two to a row so the discussions below them are in view.
class _BoardGrid extends StatelessWidget {
  const _BoardGrid({required this.boards});

  final List<DiscussionBoard> boards;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < boards.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _BoardCard(board: boards[i])),
                  const SizedBox(width: 8),
                  Expanded(
                    child: i + 1 < boards.length
                        ? _BoardCard(board: boards[i + 1])
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One board: its icon and name, and how many threads it has. What it is for is
/// said at the top of its own screen.
class _BoardCard extends StatelessWidget {
  const _BoardCard({required this.board});

  final DiscussionBoard board;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = context.l10n;
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => openBoard(context, DiscussionScope(boardId: board.id)),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.hairline),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(board.icon, size: 20, color: palette.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      board.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.threadsCount(
                        board.threadCount,
                        fmtCount(board.threadCount),
                      ),
                      style: TextStyle(color: palette.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
