import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/discussion.dart';
import 'package:checkpoint/screens/discussions/board_screen.dart';
import 'package:checkpoint/services/discussion_failure.dart';
import 'package:checkpoint/sheets/chat_rules_sheet.dart';
import 'package:checkpoint/sheets/discussion_actions.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/discussions_store.dart';
import 'package:checkpoint/state/load_status.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/discussion_post_card.dart';
import 'package:checkpoint/widgets/empty_state.dart';
import 'package:checkpoint/widgets/load_more_footer.dart';

/// Opens the thread [id].
void openDiscussionThread(BuildContext context, String id) => unawaited(
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => ThreadScreen(threadId: id))),
);

/// A thread: its title and who started it, the opening text, then the replies,
/// oldest first and paged as the list is scrolled, with a box to reply at the
/// bottom (the chat rules are agreed to before the first post).
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({super.key, required this.threadId});

  final String threadId;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  final _scroll = ScrollController();
  final _composerFocus = FocusNode();

  /// The post the reply being written answers; null: the thread itself.
  DiscussionPost? _replyTo;

  @override
  void initState() {
    super.initState();
    // After the frame: loading notifies, which isn't allowed during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final store = context.read<DiscussionsStore>();
        unawaited(store.loadThread(widget.threadId));
        if (context.read<AuthStore>().isLoggedIn) unawaited(store.loadNotifications(widget.threadId));
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  /// Starts a reply to [post] (the thread itself when null): the box says to whom,
  /// and takes the keyboard.
  void _startReply(DiscussionPost? post) {
    setState(() => _replyTo = post);
    _composerFocus.requestFocus();
  }

  Future<void> _onAction(
    DiscussionPostAction action,
    DiscussionThread thread, {
    DiscussionPost? post,
  }) async {
    final author = post?.author ?? thread.author;
    switch (action) {
      case DiscussionPostAction.report:
        final sent = await reportDiscussionPost(
          context,
          threadId: thread.id,
          postId: post?.id,
          authorName: author.name,
        );
        if (sent && post == null && mounted) Navigator.of(context).maybePop();
      case DiscussionPostAction.block:
        final blocked = await blockDiscussionAuthor(context, author);
        if (blocked && post == null && mounted) {
          Navigator.of(context).maybePop();
        }
      case DiscussionPostAction.delete:
        final deleted = await deleteDiscussionPost(
          context,
          threadId: thread.id,
          postId: post?.id,
        );
        if (deleted && post == null && mounted) {
          Navigator.of(context).maybePop();
        }
    }
  }

  /// After a reply, down to it.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        unawaited(
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final store = context.watch<DiscussionsStore>();
    final view = store.viewOf(widget.threadId);
    final thread = view.thread;
    final me = context.watch<AuthStore>().user?.id;
    final board = thread == null ? null : store.boardById(thread.boardId);
    // A reply can be made by a signed-in member, in a thread that is not locked.
    final canReply = me != null && thread != null && !thread.locked;
    // The post being answered may have left the list (deleted) since it was chosen.
    final answering = _replyTo != null && view.posts.any((p) => p.id == _replyTo!.id) ? _replyTo : null;

    Widget body;
    if (view.status == LoadStatus.failed) {
      body = EmptyState(
        icon: Icons.cloud_off_rounded,
        title: l10n.discussionLoadFailed,
        message: l10n.checkConnection,
        actionLabel: l10n.tryAgain,
        onAction: () => unawaited(store.loadThread(widget.threadId)),
      );
    } else if (view.status == LoadStatus.ready && thread == null) {
      body = EmptyState(
        icon: Icons.chat_bubble_outline_rounded,
        title: l10n.discussionGone,
        message: l10n.discussionGoneMessage,
      );
    } else if (thread == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final palette = context.palette;
      body = Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => store.loadThread(widget.threadId),
              child: ListView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                children: [
                  _Header(thread: thread, boardTitle: board?.title),
                  DiscussionPostCard(
                    author: thread.author,
                    createdAt: thread.createdAt,
                    text: thread.text,
                    isOwn: thread.author.id == me,
                    onAction: (a) => unawaited(_onAction(a, thread)),
                    onReply: canReply ? () => _startReply(null) : null,
                  ),
                  Divider(height: 1, color: palette.hairline),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 14, 0, 2),
                    child: Text(
                      thread.replyCount == 0
                          ? l10n.noRepliesYet
                          : l10n.repliesCount(thread.replyCount),
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final post in view.posts) ...[
                    DiscussionPostCard(
                      key: ValueKey(post.id),
                      author: post.author,
                      createdAt: post.createdAt,
                      text: post.text,
                      isOwn: post.author.id == me,
                      byThreadAuthor: post.author.id == thread.author.id,
                      quote: post.replyTo,
                      onReply: canReply ? () => _startReply(post) : null,
                      onAction: (a) =>
                          unawaited(_onAction(a, thread, post: post)),
                    ),
                    Divider(height: 1, color: palette.hairline),
                  ],
                  if (view.hasMore || view.loadingMore || view.loadMoreFailed)
                    LoadMoreFooter(
                      loading: view.loadingMore,
                      failed: view.loadMoreFailed,
                      onLoadMore: () =>
                          unawaited(store.loadMorePosts(widget.threadId)),
                    ),
                ],
              ),
            ),
          ),
          _Composer(
            thread: thread,
            onPosted: _scrollToEnd,
            focus: _composerFocus,
            replyTo: answering,
            onClearReply: () => setState(() => _replyTo = null),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(board?.title ?? l10n.discussion),
        actions: [
          if (thread != null && me != null)
            _NotificationsMenu(threadId: thread.id, isOwner: thread.author.id == me),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: body,
          ),
        ),
      ),
    );
  }
}

/// The title of the thread, with what it is on: its board and, if there is one, its game.
class _Header extends StatelessWidget {
  const _Header({required this.thread, required this.boardTitle});

  final DiscussionThread thread;
  final String? boardTitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = context.l10n;
    final game = thread.game;
    Widget chip(IconData icon, String label, {VoidCallback? onTap}) =>
        ActionChip(
          avatar: Icon(icon, size: 16, color: palette.muted),
          label: Text(label, style: const TextStyle(fontSize: 12.5)),
          onPressed: onTap,
          backgroundColor: palette.surfaceHigh,
          side: BorderSide(color: palette.outline),
          shape: const StadiumBorder(),
          materialTapTargetSize: MaterialTapTargetSize.padded,
        );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              thread.title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (boardTitle != null)
                chip(
                  Icons.forum_outlined,
                  boardTitle!,
                  onTap: () => openBoard(
                    context,
                    DiscussionScope(boardId: thread.boardId),
                  ),
                ),
              if (game != null)
                chip(
                  Icons.sports_esports_rounded,
                  game.title,
                  onTap: game.igdbId == null
                      ? null
                      : () =>
                            unawaited(openGameByIgdbId(context, game.igdbId!)),
                ),
              if (thread.pinned) chip(Icons.push_pin_rounded, l10n.pinned),
              if (thread.locked)
                chip(Icons.lock_outline_rounded, l10n.threadLocked),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// The box a reply is written in. A locked thread has none. The chat rules are
/// agreed to before the first post; a post the server refuses (a word the chat
/// rules refuse, posting too fast...) stays in the box, with what to do said.
class _Composer extends StatefulWidget {
  const _Composer({
    required this.thread,
    required this.onPosted,
    required this.focus,
    required this.onClearReply,
    this.replyTo,
  });

  final DiscussionThread thread;
  final VoidCallback onPosted;
  final FocusNode focus;

  /// The post the reply answers, said above the box; null: the thread itself.
  final DiscussionPost? replyTo;
  final VoidCallback onClearReply;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _text = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    if (!await ensureChatRules(context) || !mounted) return;
    final store = context.read<DiscussionsStore>();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await store.reply(widget.thread.id, text, replyTo: widget.replyTo?.id);
      if (!mounted) return;
      _text.clear();
      HapticFeedback.selectionClick();
      widget.onClearReply();
      widget.onPosted();
    } on DiscussionFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = context.l10n;
    if (!context.watch<AuthStore>().isLoggedIn) return const SizedBox.shrink();
    if (widget.thread.locked) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.hairline)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline_rounded, size: 18, color: palette.muted),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l10n.threadLockedNotice,
                style: TextStyle(color: palette.muted),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: palette.background,
        border: Border(top: BorderSide(color: palette.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 8),
              child: Text(
                _error!,
                style: TextStyle(color: palette.danger, fontSize: 13),
              ),
            ),
          if (widget.replyTo != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.reply_rounded, size: 18, color: palette.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.replyingTo(widget.replyTo!.author.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.cancelReply,
                    visualDensity: VisualDensity.compact,
                    onPressed: _sending ? null : widget.onClearReply,
                    icon: Icon(Icons.close_rounded, size: 18, color: palette.muted),
                  ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: widget.focus,
                  enabled: !_sending,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: DiscussionLimits.replyMax,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() => _error = null),
                  buildCounter:
                      (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) =>
                          maxLength != null && currentLength > maxLength * 0.85
                          ? Text(
                              '$currentLength / $maxLength',
                              style: TextStyle(
                                color: palette.muted,
                                fontSize: 12,
                              ),
                            )
                          : null,
                  decoration: fieldDecoration(context, l10n.writeReply),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                tooltip: l10n.sendReply,
                onPressed: _sending || _text.text.trim().isEmpty ? null : _send,
                icon: _sending
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The bell in the top bar: what the member is told of this discussion by push
/// notification. The default (a reply to their post, and every reply in a thread they
/// started), every new reply (for a thread somebody else started), or nothing.
class _NotificationsMenu extends StatelessWidget {
  const _NotificationsMenu({required this.threadId, required this.isOwner});

  final String threadId;

  /// The member started the thread: they are told of every reply already, so there is
  /// nothing to follow.
  final bool isOwner;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final store = context.watch<DiscussionsStore>();
    final mode = store.notificationsOf(threadId);
    Future<void> choose(ThreadNotifications next) async {
      final messenger = ScaffoldMessenger.of(context);
      final failed = l10n.threadNotifyFailed;
      if (!await store.setNotifications(threadId, next)) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(failed)));
      }
    }

    PopupMenuItem<ThreadNotifications> item(ThreadNotifications value, IconData icon, String label) => PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: value == mode ? context.palette.accent : context.palette.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontWeight: value == mode ? FontWeight.w800 : FontWeight.w500),
            ),
          ),
          if (value == mode) Icon(Icons.check_rounded, size: 20, color: context.palette.accent),
        ],
      ),
    );

    return PopupMenuButton<ThreadNotifications>(
      tooltip: l10n.threadNotificationsTooltip,
      icon: Icon(switch (mode) {
        ThreadNotifications.standard => Icons.notifications_none_rounded,
        ThreadNotifications.following => Icons.notifications_active_rounded,
        ThreadNotifications.muted => Icons.notifications_off_outlined,
      }),
      onSelected: (next) => unawaited(choose(next)),
      itemBuilder: (_) => [
        item(
          ThreadNotifications.standard,
          Icons.notifications_none_rounded,
          isOwner ? l10n.threadNotifyStandardOwner : l10n.threadNotifyStandard,
        ),
        if (!isOwner) item(ThreadNotifications.following, Icons.notifications_active_rounded, l10n.threadNotifyFollowing),
        item(ThreadNotifications.muted, Icons.notifications_off_outlined, l10n.threadNotifyMuted),
      ],
    );
  }
}
