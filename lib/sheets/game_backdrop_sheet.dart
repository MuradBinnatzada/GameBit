import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart' show ImageRenderMethodForWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_media.dart';
import 'package:checkpoint/state/game_details_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/app_theme.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/cover_backdrop.dart';
import 'package:checkpoint/widgets/sheet_frame.dart';

/// Whether [game]'s backdrop can be changed: it is in the library (the pick is
/// saved on its library row) and has an IGDB id (the art comes from its IGDB media).
bool canChangeBackdrop(Game game) => game.inLibrary && game.igdbId != null;

Future<void> showGameBackdropSheet(BuildContext context, String gameId) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => GameBackdropSheet(gameId: gameId),
  );
}

/// Game-detail sheet: pick the backdrop behind the game's header and its Home
/// card from the game's IGDB artworks and screenshots. A tap applies the pick at
/// once, so the screen behind the sheet shows it; "Default" goes back to the
/// blurred cover. The cover itself is always IGDB's.
class GameBackdropSheet extends StatefulWidget {
  const GameBackdropSheet({super.key, required this.gameId});
  final String gameId;

  @override
  State<GameBackdropSheet> createState() => _GameBackdropSheetState();
}

class _GameBackdropSheetState extends State<GameBackdropSheet> {
  late Future<GameMedia?> _media = _load();

  Future<GameMedia?> _load() {
    final game = context.read<LibraryStore>().gameById(widget.gameId);
    return context.read<GameDetailsStore>().media(game);
  }

  void _pick(Game game, String? url) {
    HapticFeedback.selectionClick();
    context.read<LibraryStore>().setBackdrop(game.id, url);
  }

  @override
  Widget build(BuildContext context) {
    final game = context.watch<LibraryStore>().maybeGame(widget.gameId);
    if (game == null) return const SizedBox.shrink();
    return SheetFrame(
      title: context.l10n.changeBackdrop,
      subtitle: game.title,
      child: FutureBuilder<GameMedia?>(
        future: _media,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final media = snapshot.data;
          return media == null ? _failed() : _choices(game, media);
        },
      ),
    );
  }

  Widget _failed() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Text(
            context.l10n.artLoadFailed,
            style: TextStyle(color: context.palette.muted),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => setState(() => _media = _load()),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(context.l10n.tryAgain),
          ),
        ],
      ),
    );
  }

  Widget _choices(Game game, GameMedia media) {
    final current = game.customBackdropUrl;
    Widget tile(GameMediaImage image) => _Tile(
      selected: image.isShownBy(current),
      onTap: () => _pick(game, image.backdropUrl),
      child: _Thumb(url: image.thumbnailUrl),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Grid(
          children: [
            _Tile(
              label: context.l10n.defaultBackdrop,
              selected: current == null,
              onTap: () => _pick(game, null),
              child: CoverBackdrop(game: game.withBackdrop(null)),
            ),
            for (final image in media.artworks) tile(image),
          ],
        ),
        if (media.screenshots.isNotEmpty) ...[
          _SectionTitle(context.l10n.screenshots),
          _Grid(children: [for (final image in media.screenshots) tile(image)]),
        ],
        if (media.isEmpty)
          Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text(
              context.l10n.noArtworks,
              style: TextStyle(color: context.palette.muted),
            ),
          ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 10),
    child: Text(
      text,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
    ),
  );
}

/// [children] two to a row as 16:9 tiles, inside the sheet's own scroll view
/// (so not a scrolling grid of its own).
class _Grid extends StatelessWidget {
  const _Grid({required this.children});
  final List<Widget> children;

  static const _columns = 2;
  static const _gap = 10.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final width = (c.maxWidth - _gap * (_columns - 1)) / _columns;
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (final child in children)
              SizedBox(width: width, height: width * 9 / 16, child: child),
          ],
        );
      },
    );
  }
}

/// One choice: [child] clipped to a rounded tile, outlined when [selected], with
/// [label] across its foot.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.child,
    required this.selected,
    required this.onTap,
    this.label,
  });
  final Widget child;
  final bool selected;
  final VoidCallback onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    const radius = 12.0;
    return Semantics(
      button: true,
      selected: selected,
      label: label ?? context.l10n.backdrop,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: motion(context, const Duration(milliseconds: 150)),
          padding: EdgeInsets.all(selected ? 3 : 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius + 3),
            border: Border.all(
              color: selected
                  ? context.palette.accent
                  : context.palette.text.withValues(alpha: 0.12),
              width: selected ? 2 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(selected ? radius - 2 : radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: context.palette.surfaceHigh, child: child),
                if (label != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(6, 10, 6, 5),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xCC000000)],
                        ),
                      ),
                      child: Text(
                        label!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                if (selected)
                  PositionedDirectional(
                    top: 6,
                    end: 6,
                    child: CircleAvatar(
                      radius: 11,
                      backgroundColor: context.palette.accent,
                      child: Icon(
                        Icons.check_rounded,
                        size: 15,
                        color: context.palette.onAccent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => CachedNetworkImage(
    imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
    imageUrl: url,
    fit: BoxFit.cover,
    memCacheWidth: 400,
    fadeInDuration: const Duration(milliseconds: 200),
    fadeOutDuration: Duration.zero,
    placeholder: (_, _) => const SizedBox.shrink(),
    errorWidget: (_, _, _) => Center(
      child: Icon(Icons.broken_image_outlined, color: context.palette.muted),
    ),
  );
}
