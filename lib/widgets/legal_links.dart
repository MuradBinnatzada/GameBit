import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import 'package:checkpoint/app/app_config.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/theme/palette.dart';

/// Opens a page of the site (privacy policy, terms) or a mail to us, outside the
/// app. A failure to open one is not the member's to deal with.
Future<void> openLegalLink(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('Opening $uri failed: $e');
  }
}

/// "By continuing you agree to the Terms of Use and the Privacy Policy." under the
/// sign-in buttons, the two names being links. Using the app means agreeing to the
/// terms that tell members what may not be posted (docs/terms.html).
class SignInAgreement extends StatefulWidget {
  const SignInAgreement({super.key});

  @override
  State<SignInAgreement> createState() => _SignInAgreementState();
}

class _SignInAgreementState extends State<SignInAgreement> {
  late final TapGestureRecognizer _terms = TapGestureRecognizer()
    ..onTap = () => unawaited(openLegalLink(AppConfig.termsUri));
  late final TapGestureRecognizer _privacy = TapGestureRecognizer()
    ..onTap = () => unawaited(openLegalLink(AppConfig.privacyUri));

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  // The sentence is one translated message; the two names are put where its
  // placeholders were.
  static const _termsMark = '\u0001';
  static const _privacyMark = '\u0002';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final muted = TextStyle(color: palette.muted, fontSize: 12.5, height: 1.4);
    final link = muted.copyWith(
      color: palette.accent,
      decoration: TextDecoration.underline,
      decorationColor: palette.accent,
    );

    final sentence = l10n.signInAgreement(_termsMark, _privacyMark);
    final spans = <InlineSpan>[];
    var rest = sentence;
    while (rest.isNotEmpty) {
      final t = rest.indexOf(_termsMark);
      final p = rest.indexOf(_privacyMark);
      final next = [t, p].where((i) => i >= 0).fold<int>(-1, (a, b) => a < 0 || b < a ? b : a);
      if (next < 0) {
        spans.add(TextSpan(text: rest));
        break;
      }
      if (next > 0) spans.add(TextSpan(text: rest.substring(0, next)));
      final isTerms = next == t;
      spans.add(
        TextSpan(
          text: isTerms ? l10n.termsOfUse : l10n.privacyPolicy,
          style: link,
          recognizer: isTerms ? _terms : _privacy,
        ),
      );
      rest = rest.substring(next + 1);
    }

    return Text.rich(
      TextSpan(style: muted, children: spans),
      textAlign: TextAlign.center,
    );
  }
}
