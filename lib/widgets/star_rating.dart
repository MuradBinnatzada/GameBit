import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';

/// The most stars a game can be given; 0 is not rated.
const int maxRating = 10;

class StarRating extends StatelessWidget {
  const StarRating({super.key, required this.rating, this.size = 16, this.onChanged});
  final double rating;

  /// Of one star. A read-only row narrower than [maxRating] stars of this size
  /// (a poster card, a table column) shrinks to fit; an editable one does too.
  final double size;
  final ValueChanged<double>? onChanged; // null → read-only

  /// The left half of a star is half a star, the right half the whole one.
  double _valueAt(double dx, double starSize) {
    final raw = dx / starSize;
    return (raw * 2).ceil().clamp(1, maxRating * 2) / 2;
  }

  void _emit(double dx, double starSize) {
    final v = _valueAt(dx, starSize);
    if (v != rating) {
      HapticFeedback.selectionClick();
      onChanged!(v);
    }
  }

  static const double _max = 10;

  Widget _stars(BuildContext context, double starSize) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(maxRating, (i) {
        // A half rating ends on a half star; so can an average.
        final v = rating - i;
        final icon = v >= 1
            ? Icons.star_rounded
            : (v >= 0.5 ? Icons.star_half_rounded : Icons.star_outline_rounded);
        return Icon(icon, size: starSize, color: v > 0 ? context.palette.star : context.palette.faint);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (onChanged == null) {
      return Semantics(
        label: context.l10n.outOf10Stars(fmtHours(rating)),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: _stars(context, size),
        ),
      );
    }
    // An adjustable control for screen readers: swiping up or down (or the
    // volume keys) moves it half a star, since they can't drag across it.
    String spoken(double v) => context.l10n.outOf10Stars(fmtHours(v));
    return Semantics(
      slider: true,
      label: context.l10n.sortRating,
      value: rating > 0 ? spoken(rating) : context.l10n.notRated,
      increasedValue: spoken(math.min(_max, rating + 0.5)),
      decreasedValue: spoken(math.max(0.5, rating - 0.5)),
      onIncrease: rating < _max ? () => onChanged!(math.min(_max, rating + 0.5)) : null,
      onDecrease: rating > 0.5 ? () => onChanged!(math.max(0.5, rating - 0.5)) : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Ten stars of [size] may not fit the screen: the stars shrink instead.
          final starSize = constraints.hasBoundedWidth ? math.min(size, constraints.maxWidth / maxRating) : size;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _emit(d.localPosition.dx, starSize),
            onHorizontalDragUpdate: (d) => _emit(d.localPosition.dx, starSize),
            // At least 48 px tall to tap, however small the stars.
            child: SizedBox(
              width: starSize * maxRating,
              height: math.max(starSize, 48),
              child: Center(child: _stars(context, starSize)),
            ),
          );
        },
      ),
    );
  }
}
