import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/sheets/member_actions.dart';
import 'package:checkpoint/sheets/report_review_sheet.dart';
import 'package:checkpoint/sheets/review_sheet.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/expandable_text.dart';
import 'package:checkpoint/widgets/milestone_badge.dart';
import 'package:checkpoint/widgets/profile_avatar.dart';
import 'package:checkpoint/widgets/star_rating.dart';

enum _ReviewAction { edit, report, block }

/// One member's review of the game [gameId]: their photo (in their frame, opening
/// their profile), their name, how they rated it and how far they got, when they
/// wrote it, and the text, cut short with "Read more" when it is long. A menu
/// reports another member's review, and edits your own.
class ReviewCard extends StatelessWidget {
  const ReviewCard({super.key, required this.gameId, required this.review});

  final String gameId;
  final GameReview review;

  static const double _photo = 44;

  @override
  Widget build(BuildContext context) {
    final member = review.member;
    final isOwn = context.watch<AuthStore>().user?.id == member.id;
    final frame = member.flair.frame;
    // A framed photo is drawn smaller, so the card keeps its layout.
    final photo = frame == null
        ? _photo
        : _photo - 2 * FramedAvatar.inset(_photo);
    final palette = context.palette;
    final l10n = context.l10n;
    final written = review.writtenAt;
    final meta = [
      if (review.status != null) review.status!.label,
      if (review.hours > 0) l10n.hoursShort(fmtHours(review.hours)),
      if (written != null) timeAgo(written),
    ];

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
                label: l10n.openMemberProfile(member.name),
                excludeSemantics: true,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => openProfile(context, userId: member.id, preview: member),
                  child: SizedBox.square(
                    dimension: _photo,
                    child: Center(
                      child: FramedAvatar(
                        size: photo,
                        frame: frame,
                        child: ProfileAvatar(name: member.name, size: photo, imageUrl: member.avatarUrl),
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
                              member.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                          ),
                          if (isOwn)
                            _Badge(label: l10n.you, color: palette.accent)
                          else if (review.isFollowing)
                            _Badge(label: l10n.followedMember, color: palette.muted),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (review.rating > 0) StarRating(rating: review.rating, size: 13),
                        if (meta.isNotEmpty)
                          Text(meta.join(' · '), style: TextStyle(color: palette.muted, fontSize: 12.5)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ExpandableText(review.text, collapsedLines: 6),
                  ],
                ),
              ),
            ],
          ),
        ),
        PositionedDirectional(
          top: 0,
          end: 0,
          child: _Menu(
            isOwn: isOwn,
            onEdit: () => showReviewSheet(context, gameId),
            onReport: () => reportReview(context, gameId, review),
            blockLabel: l10n.blockMember(member.name),
            onBlock: () => blockMemberAfterAsking(context, member),
          ),
        ),
      ],
    );
  }
}

/// "You" or "Following" next to a name.
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

class _Menu extends StatelessWidget {
  const _Menu({
    required this.isOwn,
    required this.onEdit,
    required this.onReport,
    required this.blockLabel,
    required this.onBlock,
  });

  final bool isOwn;
  final VoidCallback onEdit;
  final VoidCallback onReport;
  final String blockLabel;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox.square(
      dimension: 48,
      child: PopupMenuButton<_ReviewAction>(
        padding: EdgeInsets.zero,
        iconSize: 22,
        icon: Icon(Icons.more_horiz_rounded, color: context.palette.muted),
        tooltip: MaterialLocalizations.of(context).showMenuTooltip,
        onSelected: (action) => switch (action) {
          _ReviewAction.edit => onEdit(),
          _ReviewAction.report => onReport(),
          _ReviewAction.block => onBlock(),
        },
        itemBuilder: (_) => [
          if (isOwn)
            PopupMenuItem(
              value: _ReviewAction.edit,
              child: Row(
                children: [
                  const Icon(Icons.edit_rounded, size: 18),
                  const SizedBox(width: 10),
                  Text(l10n.editReview),
                ],
              ),
            )
          else ...[
            PopupMenuItem(
              value: _ReviewAction.report,
              child: Row(
                children: [
                  const Icon(Icons.flag_outlined, size: 18),
                  const SizedBox(width: 10),
                  Text(l10n.reportReview),
                ],
              ),
            ),
            PopupMenuItem(
              value: _ReviewAction.block,
              child: Row(
                children: [
                  const Icon(Icons.person_off_outlined, size: 18),
                  const SizedBox(width: 10),
                  Flexible(child: Text(blockLabel)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
