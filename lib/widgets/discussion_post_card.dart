import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/discussion.dart';
import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/milestone_badge.dart';
import 'package:checkpoint/widgets/profile_avatar.dart';

enum DiscussionPostAction { report, block, delete }

/// A member's post in a discussion, an opening text or a reply: their photo (in
/// their frame, opening their profile), their name, when they wrote it, and the
/// text. A menu offers what can be done with it: delete your own, or report it or
/// block its author. [byThreadAuthor] marks a reply by whoever started the thread.
class DiscussionPostCard extends StatelessWidget {
  const DiscussionPostCard({
    super.key,
    required this.author,
    required this.createdAt,
    required this.text,
    required this.isOwn,
    required this.onAction,
    this.byThreadAuthor = false,
    this.quote,
    this.onReply,
  });

  final SocialUser author;
  final DateTime createdAt;
  final String text;
  final bool isOwn;
  final bool byThreadAuthor;
  final ValueChanged<DiscussionPostAction> onAction;

  /// The post this one answers, shown above its text ("Replying to" and the name).
  final DiscussionQuote? quote;

  /// Starts a reply to this post. Null where a reply can't be made (signed out, a
  /// locked thread): no button.
  final VoidCallback? onReply;

  static const double _photo = 44;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = context.l10n;
    final frame = author.flair.frame;
    final photo = frame == null
        ? _photo
        : _photo - 2 * FramedAvatar.inset(_photo);
    // The menu is 48 dp to tap, in the top corner over the name's row, which
    // leaves room for it.
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                button: true,
                label: l10n.openMemberProfile(author.name),
                excludeSemantics: true,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () =>
                      openProfile(context, userId: author.id, preview: author),
                  child: SizedBox.square(
                    dimension: _photo,
                    child: Center(
                      child: FramedAvatar(
                        size: photo,
                        frame: frame,
                        child: ProfileAvatar(
                          name: author.name,
                          size: photo,
                          imageUrl: author.avatarUrl,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 40),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              author.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          if (isOwn)
                            _Badge(label: l10n.you, color: palette.accent)
                          else if (byThreadAuthor)
                            _Badge(
                              label: l10n.threadAuthorBadge,
                              color: palette.muted,
                            ),
                        ],
                      ),
                    ),
                    Text(
                      timeAgo(createdAt.toLocal()),
                      style: TextStyle(color: palette.muted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 8),
                    if (quote != null) _QuoteBlock(quote: quote!),
                    Text(
                      text,
                      style: TextStyle(color: palette.textSoft, height: 1.45),
                    ),
                    if (onReply != null)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          onPressed: onReply,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            minimumSize: const Size(48, 48),
                            foregroundColor: palette.muted,
                          ),
                          icon: const Icon(Icons.reply_rounded, size: 18),
                          label: Text(
                            l10n.replyToPost,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        PositionedDirectional(
          top: 0,
          end: 0,
          child: SizedBox.square(
            dimension: 48,
            child: PopupMenuButton<DiscussionPostAction>(
              padding: EdgeInsets.zero,
              iconSize: 22,
              icon: Icon(Icons.more_horiz_rounded, color: palette.muted),
              tooltip: MaterialLocalizations.of(context).showMenuTooltip,
              onSelected: onAction,
              itemBuilder: (_) => [
                if (isOwn)
                  _item(
                    DiscussionPostAction.delete,
                    Icons.delete_outline_rounded,
                    l10n.deletePost,
                  )
                else ...[
                  _item(
                    DiscussionPostAction.report,
                    Icons.flag_outlined,
                    l10n.reportPost,
                  ),
                  _item(
                    DiscussionPostAction.block,
                    Icons.person_off_outlined,
                    l10n.blockMember(author.name),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  PopupMenuItem<DiscussionPostAction> _item(
    DiscussionPostAction action,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    value: action,
    child: Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 10),
        Flexible(child: Text(label)),
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Replying to Boris", and how the post answered starts, above a reply.
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.quote});

  final DiscussionQuote quote;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsetsDirectional.only(start: 10, top: 2, bottom: 2),
      decoration: BoxDecoration(
        border: BorderDirectional(start: BorderSide(color: palette.outline, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.replyingTo(quote.authorName),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.muted, fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          if (quote.excerpt.isNotEmpty)
            Text(
              quote.excerpt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.muted, fontSize: 12.5, height: 1.35),
            ),
        ],
      ),
    );
  }
}
