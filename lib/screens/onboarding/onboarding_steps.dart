import 'package:flutter/material.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/screens/settings/connect_account.dart';
import 'package:checkpoint/screens/settings/data_section.dart';
import 'package:checkpoint/screens/settings/sync_library.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/connected_accounts_panel.dart';
import 'package:checkpoint/widgets/cover_art.dart';

/// The heading of a step and the line under it.
class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(header: true, child: Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800))),
        const SizedBox(height: 6),
        Text(body, style: TextStyle(color: context.palette.muted, height: 1.4)),
      ]),
    );
  }
}

/// Step 1: the game service the member plays on, connected the way Settings
/// does it (Steam signs in through Steam).
class OnboardingConnectStep extends StatelessWidget {
  const OnboardingConnectStep({super.key});

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileStore>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _StepHeader(title: context.l10n.onboardingConnectTitle, body: context.l10n.onboardingConnectBody),
      ConnectedAccountsPanel(
        services: profile.connectedServices,
        names: profile.accountNames,
        editor: accountEditorFor(context),
      ),
    ]);
  }
}

/// Step 2: games brought in from Steam or from another tracker's CSV file, with
/// how many are in the library as it fills.
class OnboardingImportStep extends StatelessWidget {
  const OnboardingImportStep({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final profile = context.watch<ProfileStore>();
    final count = context.watch<LibraryStore>().libraryGames.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _StepHeader(title: l10n.onboardingImportTitle, body: l10n.onboardingImportBody),
      SizedBox(
        width: double.infinity,
        child: profile.steamConnected
            ? const SyncLibraryButton()
            : OutlinedButton.icon(
                onPressed: () => connectService(context, ConnectedService.steam),
                icon: const Icon(Icons.link_rounded),
                label: Text(l10n.connectService(ConnectedService.steam.label)),
              ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => importLibraryFile(context),
          icon: const Icon(Icons.upload_file_rounded),
          label: Text(l10n.importFromCsv),
        ),
      ),
      const SizedBox(height: 18),
      Semantics(
        liveRegion: true,
        child: Text(
          l10n.onboardingLibraryCount(count),
          style: TextStyle(color: context.palette.muted, fontWeight: FontWeight.w600),
        ),
      ),
    ]);
  }
}

/// Step 3: up to [LibraryStore.maxFavorites] games to put first on the profile,
/// picked from the most played of the library. With no games yet it says where
/// to find some ([onFindGames]).
class OnboardingFavoritesStep extends StatelessWidget {
  const OnboardingFavoritesStep({super.key, required this.onFindGames});
  final VoidCallback onFindGames;

  /// How many games are offered; a library of hundreds isn't a list to pick from.
  static const _offered = 30;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final library = context.watch<LibraryStore>();
    final games = [...library.libraryGames]
      ..sort((a, b) {
        final c = b.hoursPlayed.compareTo(a.hoursPlayed);
        return c != 0 ? c : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    if (games.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _StepHeader(title: l10n.onboardingFavoritesTitle, body: l10n.onboardingFavoritesEmpty),
        FilledButton.tonalIcon(
          onPressed: onFindGames,
          icon: const Icon(Icons.search_rounded),
          label: Text(l10n.onboardingFindGames),
        ),
      ]);
    }
    final picked = games.where((g) => g.isFavorite).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _StepHeader(title: l10n.onboardingFavoritesTitle, body: l10n.onboardingFavoritesBody),
      Semantics(
        liveRegion: true,
        child: Text(
          l10n.onboardingPicked(picked, LibraryStore.maxFavorites),
          style: TextStyle(color: context.palette.accent, fontWeight: FontWeight.w700),
        ),
      ),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        const gap = 10.0;
        final columns = (constraints.maxWidth / 84).floor().clamp(3, 6);
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(spacing: gap, runSpacing: 14, children: [
          for (final game in games.take(_offered))
            _PickTile(game: game, width: width, onTap: () => library.toggleFavorite(game.id)),
        ]);
      }),
    ]);
  }
}

/// A cover with the game's title under it; a favorite has a frame and a heart.
class _PickTile extends StatelessWidget {
  const _PickTile({required this.game, required this.width, required this.onTap});
  final Game game;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final picked = game.isFavorite;
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        selected: picked,
        label: game.title,
        excludeSemantics: true,
        onTap: onTap,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              CoverArt(game: game, radius: 10, showTitle: false),
              if (picked) ...[
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: palette.accent, width: 3),
                    ),
                  ),
                ),
                PositionedDirectional(
                  top: 6,
                  end: 6,
                  child: CircleAvatar(
                    radius: 11,
                    backgroundColor: palette.accent,
                    child: Icon(Icons.favorite_rounded, size: 14, color: palette.onAccent),
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 4),
            Text(game.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, height: 1.2)),
          ]),
        ),
      ),
    );
  }
}
