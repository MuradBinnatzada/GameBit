import 'package:flutter/material.dart';

import 'package:checkpoint/app/nav_tab.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/screens/onboarding/onboarding_steps.dart';
import 'package:checkpoint/state/nav_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';

/// The first run of a member with no games: connect where they play, bring their
/// games in, pick the Top 4. Every step can be left for later (Skip, or the back
/// button of the device); the app shell records that it was shown when it closes
/// (see [OnboardingStore]).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _steps = 3;

  int _step = 0;

  void _close() => Navigator.of(context).pop();

  /// With nothing to pick from, ends the walk-through on the Search tab.
  void _findGames() {
    context.read<NavStore>().select(NavTab.search);
    _close();
  }

  Widget _content() => switch (_step) {
    0 => const OnboardingConnectStep(),
    1 => const OnboardingImportStep(),
    _ => OnboardingFavoritesStep(onFindGames: _findGames),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final last = _step == _steps - 1;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(l10n.onboardingWelcome),
        actions: [
          if (!last) TextButton(onPressed: _close, child: Text(l10n.skip)),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Row(children: [
                  ExcludeSemantics(
                    child: Row(children: [
                      for (var i = 0; i < _steps; i++)
                        Container(
                          width: i == _step ? 22 : 8,
                          height: 8,
                          margin: const EdgeInsetsDirectional.only(end: 6),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: i == _step ? palette.accent : palette.faint,
                          ),
                        ),
                    ]),
                  ),
                  const Spacer(),
                  Text(l10n.onboardingStepOf(_step + 1, _steps), style: TextStyle(color: palette.muted, fontSize: 13)),
                ]),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: KeyedSubtree(key: ValueKey(_step), child: _content()),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Row(children: [
                  if (_step > 0) ...[
                    OutlinedButton(
                      onPressed: () => setState(() => _step--),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                      child: Text(l10n.back),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: FilledButton(
                      onPressed: last ? _close : () => setState(() => _step++),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      child: Text(last ? l10n.done : l10n.next),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
