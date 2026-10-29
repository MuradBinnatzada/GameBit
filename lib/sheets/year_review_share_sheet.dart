import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/year_review.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/image_share.dart';
import 'package:checkpoint/widgets/sheet_frame.dart';
import 'package:checkpoint/widgets/year_review_card.dart';

/// The year's share cards to swipe through, and "Share" for the one on screen:
/// it goes out as an image.
Future<void> showYearReviewShareSheet(BuildContext context, YearReview review) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => YearReviewShareSheet(review: review),
);

class YearReviewShareSheet extends StatefulWidget {
  const YearReviewShareSheet({super.key, required this.review, this.saveImage = shareOrSaveImage});
  final YearReview review;

  /// Hands the picture on. Replaced in tests.
  final SaveImage saveImage;

  @override
  State<YearReviewShareSheet> createState() => _YearReviewShareSheetState();
}

class _YearReviewShareSheetState extends State<YearReviewShareSheet> {
  final _controller = PageController();
  int _page = 0;
  bool _busy = false;
  String? _error;

  /// The cards, each with the file name its picture is shared under.
  late final _cards = <({String name, Widget card})>[
    (name: 'gamebit-${widget.review.year}-overview', card: YearOverviewCard(review: widget.review)),
    if (widget.review.topGames.isNotEmpty)
      (name: 'gamebit-${widget.review.year}-most-played', card: YearTopGamesCard(review: widget.review)),
  ];
  late final _keys = [for (final _ in _cards) GlobalKey()];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _share(BuildContext buttonContext) async {
    final text = context.l10n.yearShareText(widget.review.year);
    final failed = context.l10n.fileSaveFailed;
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      final bytes = await capturePng(_keys[_page]);
      if (bytes == null) {
        error = failed;
      } else {
        await widget.saveImage('${_cards[_page].name}.png', bytes, text, origin);
      }
    } catch (e) {
      debugPrint('Sharing a year card failed: $e');
      error = failed;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    return SheetFrame(
      title: l10n.shareYear,
      child: Column(children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: AspectRatio(
              aspectRatio: yearCardSize.width / yearCardSize.height,
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() {
                  _page = i;
                  _error = null;
                }),
                children: [
                  for (var i = 0; i < _cards.length; i++)
                    // Rounded here, outside the boundary: the picture is square.
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: FittedBox(
                        child: RepaintBoundary(key: _keys[i], child: _cards[i].card),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (_cards.length > 1)
          ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < _cards.length; i++)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: i == _page ? palette.accent : palette.faint),
                  ),
              ]),
            ),
          ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: Builder(
            builder: (buttonContext) => FilledButton.icon(
              onPressed: _busy ? null : () => _share(buttonContext),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.ios_share_rounded),
              label: Text(l10n.share),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Semantics(
              liveRegion: true,
              child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: palette.danger)),
            ),
          ),
      ]),
    );
  }
}
