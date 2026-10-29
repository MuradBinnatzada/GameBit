import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/theme/palette.dart';

// Numbers and dates follow the app's language (L10n.use sets intl's locale):
// "1,280" and "Oct 14" in English, "1 280" and "14 окт." in Russian.

/// "." in English, "," in Russian.
String get _decimalSeparator => NumberFormat.decimalPattern().symbols.DECIMAL_SEP;

/// [fixed] (made with toStringAsFixed) with the language's decimal separator.
String _decimal(String fixed) => fixed.replaceFirst('.', _decimalSeparator);

/// 980 -> "980", 1280 -> "1.3k", 12800 -> "13k": a count in little room.
String fmtCount(int n) =>
    n < 1000 ? '$n' : L10n.current.countThousands(_decimal((n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)));

/// 1280 -> "1,280": the exact number, for places that have room for it.
String fmtThousands(int n) => NumberFormat.decimalPattern().format(n);

String fmtHours(double h) =>
    (h - h.roundToDouble()).abs() < 0.05 ? h.round().toString() : _decimal(h.toStringAsFixed(1));

/// 12.5 -> "$12.50": a price in US dollars, written the language's way.
String fmtMoney(double v) => NumberFormat.simpleCurrency(name: 'USD').format(v);

/// 40.9 -> "40.9%", 100 -> "100%", 0.04 -> "<0.1%": a share out of 100, one decimal.
String fmtPercent(double p) {
  if (p > 0 && p < 0.05) return '<${_decimal('0.1')}%';
  final rounded = (p * 10).round() / 10;
  return rounded == rounded.roundToDouble() ? '${rounded.round()}%' : '${_decimal(rounded.toStringAsFixed(1))}%';
}

double? parseNum(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  final l10n = L10n.current;
  if (d.inMinutes < 60) return l10n.timeAgoMinutes(math.max(1, d.inMinutes));
  if (d.inHours < 24) return l10n.timeAgoHours(d.inHours);
  if (d.inDays < 7) return l10n.timeAgoDays(d.inDays);
  if (d.inDays < 60) return l10n.timeAgoWeeks(d.inDays ~/ 7);
  return l10n.timeAgoMonths(d.inDays ~/ 30);
}

/// "Oct 14": the calendar day of [d] as stored, without shifting it to local time.
String fmtMonthDay(DateTime d) => DateFormat.MMMd().format(d);

/// "Oct": the month of [d], short.
String fmtMonthShort(DateTime d) => DateFormat.MMM().format(d);

/// "J" (0) to "D" (11): the month's initial, in the app's language.
String fmtMonthLetter(int month) => DateFormat.LLL().format(DateTime(2000, month + 1)).substring(0, 1).toUpperCase();

String initials(String name) => name
    .trim()
    .split(RegExp(r'\s+'))
    .where((p) => p.isNotEmpty)
    .take(2)
    .map((p) => p[0].toUpperCase())
    .join();

String greeting() {
  final h = DateTime.now().hour;
  final l10n = L10n.current;
  if (h < 5) return l10n.greetingLateNight;
  if (h < 12) return l10n.greetingMorning;
  if (h < 18) return l10n.greetingAfternoon;
  return l10n.greetingEvening;
}

/// The largest text size the app follows from the device's setting: twice the
/// normal size, what low-vision settings reach on most phones.
const maxTextScale = 2.0;

double textScale(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1).clamp(1.0, maxTextScale).toDouble();

double posterCardHeight(BuildContext context, double width, {required bool subtitle}) =>
    width * 1.5 + 14 + (18 + 6 + 16 + (subtitle ? 18 : 0)) * textScale(context);

InputDecoration fieldDecoration(
  BuildContext context,
  String label, {
  String? prefix,
  String? suffix,
  String? hint,
  Widget? prefixIcon,
  Widget? suffixIcon,
}) =>
    InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: prefix,
      suffixText: suffix,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: context.palette.surfaceHigh,
      labelStyle: TextStyle(color: context.palette.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: context.palette.accent, width: 1.5),
      ),
    );

final decimalFormatter = FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'));
const decimalKeyboard = TextInputType.numberWithOptions(decimal: true);

/// "Oct 2026": the month and year of [d], as stored, without shifting it to local time.
String fmtMonthYear(DateTime d) => DateFormat.yMMM().format(d);

/// "Today", "Yesterday", "Oct 14", or "Oct 14, 2025" in another year: the day of
/// [d] as the device sees it, relative to [now].
String fmtDay(DateTime d, {DateTime? now}) {
  final today = now ?? DateTime.now();
  // Calendar days in UTC, so a daylight saving change can't make a day 23 hours.
  final daysAgo = DateTime.utc(today.year, today.month, today.day)
      .difference(DateTime.utc(d.year, d.month, d.day))
      .inDays;
  if (daysAgo == 0) return L10n.current.today;
  if (daysAgo == 1) return L10n.current.yesterday;
  return d.year == today.year ? DateFormat.MMMd().format(d) : DateFormat.yMMMd().format(d);
}

/// 0:04:09, 1:02:33: a running timer, hours first.
String fmtElapsed(Duration d) {
  final seconds = d.isNegative ? 0 : d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${seconds ~/ 3600}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
}
