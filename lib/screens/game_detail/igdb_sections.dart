import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/completion_time.dart';
import 'package:checkpoint/models/filter_options.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_attributes.dart';
import 'package:checkpoint/models/game_details.dart';
import 'package:checkpoint/state/community_times_store.dart';
import 'package:checkpoint/state/game_details_store.dart';
import 'package:checkpoint/state/store_scope.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/utils/formatters.dart';
import 'package:checkpoint/utils/navigation.dart';
import 'package:checkpoint/widgets/expandable_text.dart';
import 'package:checkpoint/widgets/game_poster_card.dart';
import 'package:checkpoint/widgets/panel.dart';
import 'package:checkpoint/widgets/translation_note.dart';

/// Everything there is to read about a game, in one panel: its description,
/// IGDB's story and the game info (genres, main developers, publishers, themes,
/// game modes, player perspectives, engine). The description, genres and
/// developer come with the library, so they show at once; the rest joins them
/// when IGDB answers (see [GameInfoSections], which asks). A genre, theme or game
/// mode the Discover tab can filter by is a button: it opens Discover on it. So
/// is a developer or publisher IGDB gave an id for: it opens its page.
///
/// In another language than English, the description and story show in it when
/// the server translated them (see [IgdbTranslation]), with a note and a button
/// for the original.
class AboutPanel extends StatefulWidget {
  const AboutPanel({super.key, required this.game});

  final Game game;

  @override
  State<AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<AboutPanel> {
  /// The English texts show, though there is a translation.
  bool _original = false;

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final details = context
        .watch<GameDetailsStore>()
        .viewOf(game.id)
        .details;
    final hasInfo = details?.hasInfo ?? false;
    final companyIds = details?.companyIds ?? const <String, int>{};
    // (label, values, as chips, what a chip filters Discover by, chips are companies)
    final l10n = context.l10n;
    final rows = <(String, List<String>, bool, GameAttribute?, bool)>[
      (l10n.attributeGenres, game.genres, true, GameAttribute.genre, false),
      if (hasInfo) ...[
        (l10n.mainDevelopers, details!.developers, true, null, true),
        (l10n.attributePublishers, details.publishers, true, null, true),
        (l10n.attributeThemes, details.themes, true, GameAttribute.theme, false),
        (l10n.attributeGameModes, details.gameModes, true, GameAttribute.gameMode, false),
        (l10n.playerPerspectives, details.perspectives, true, null, false),
        (l10n.gameEngine, details.engines, true, null, false),
      ] else
        (l10n.attributeDeveloper, [game.developer], false, null, false),
    ].where((row) => row.$2.any((v) => v.trim().isNotEmpty)).toList();
    final translation = details?.translation;
    final translated = translation != null && translation.language == L10n.languageCode;
    final shown = translated && !_original ? translation : null;
    final synopsis = shown?.summary ?? game.synopsis.trim();
    final storyline = shown?.storyline ?? details?.storyline?.trim() ?? '';

    final text = <Widget>[
      if (synopsis.isNotEmpty) ExpandableText(synopsis, collapsedLines: 6),
      if (storyline.isNotEmpty) ...[
        if (synopsis.isNotEmpty) const SizedBox(height: 14),
        _Label(l10n.story),
        const SizedBox(height: 6),
        ExpandableText(storyline, collapsedLines: 4),
      ],
      if (translated && (synopsis.isNotEmpty || storyline.isNotEmpty)) ...[
        const SizedBox(height: 4),
        TranslationNote(
          showingOriginal: _original,
          onToggle: () => setState(() => _original = !_original),
        ),
      ],
    ];

    return Panel(
      title: l10n.about,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...text,
          if (text.isNotEmpty && rows.isNotEmpty)
            Divider(height: 28, color: context.palette.hairline),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            _Label(rows[i].$1),
            const SizedBox(height: 6),
            if (rows[i].$3)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final v in rows[i].$2)
                    if (rows[i].$5)
                      _CompanyChip(name: v, companyId: companyIds[v])
                    else
                      _TagChip(value: v, attribute: rows[i].$4),
                ],
              )
            else
              Text(rows[i].$2.join(', '), style: const TextStyle(height: 1.4)),
          ],
        ],
      ),
    );
  }
}

/// One genre, theme or game mode of a game. When the Discover tab can filter by
/// it (it is in [CatalogTags]), tapping it opens Discover on the games that have
/// it; anything else is only a label.
class _TagChip extends StatelessWidget {
  const _TagChip({required this.value, this.attribute});

  final String value;
  final GameAttribute? attribute;

  @override
  Widget build(BuildContext context) {
    final a = attribute;
    final tag = a == null ? null : CatalogTags.find(a, value);
    if (a == null || tag == null) return Chip(label: Text(tagName(value)));
    return ActionChip(
      label: Text(tagName(value)),
      tooltip: context.l10n.browseTagGames(tag.label),
      onPressed: () => openDiscover(context, FilterOptions.only(a, tag.name)),
    );
  }
}

/// A developer or publisher of a game. With an IGDB id, tapping it opens the
/// company's page; without, it is only a label.
class _CompanyChip extends StatelessWidget {
  const _CompanyChip({required this.name, this.companyId});

  final String name;
  final int? companyId;

  @override
  Widget build(BuildContext context) {
    final id = companyId;
    if (id == null) return Chip(label: Text(name));
    return ActionChip(
      avatar: const Icon(Icons.business_rounded, size: 16),
      label: Text(name),
      tooltip: context.l10n.seeCompany(name),
      onPressed: () => openCompany(context, id, name: name),
    );
  }
}

/// The time to beat and similar games, under About on a game's screen. Asks
/// IGDB for the game's details (see [GameDetailsStore]) and Gamebit for its
/// members' times (see [CommunityTimesStore]) when the screen opens. The time to
/// beat is the members' times and a link to HowLongToBeat, so it is there at
/// once; the similar games join it when IGDB answers, and are left out when it
/// can't be reached, as everything else on the screen works without them.
class GameInfoSections extends StatefulWidget {
  const GameInfoSections({super.key, required this.game});

  final Game game;

  @override
  State<GameInfoSections> createState() => _GameInfoSectionsState();
}

class _GameInfoSectionsState extends State<GameInfoSections> {
  @override
  void initState() {
    super.initState();
    _loadAfterFrame();
  }

  @override
  void didUpdateWidget(GameInfoSections oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.id != widget.game.id) _loadAfterFrame();
  }

  /// After the frame: loading notifies, which isn't allowed during build.
  void _loadAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<GameDetailsStore>().load(widget.game);
      context.read<CommunityTimesStore>().load(widget.game.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final details = context
        .watch<GameDetailsStore>()
        .viewOf(widget.game.id)
        .details;
    final community = context
        .watch<CommunityTimesStore>()
        .viewOf(widget.game.id)
        .times;

    final sections = <Widget>[
      _TimeToBeatPanel(title: widget.game.title, community: community),
      if (details != null && details.similarGames.isNotEmpty)
        _SimilarGames(games: details.similarGames),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in sections) ...[
          const SizedBox(height: 14),
          section,
        ],
      ],
    );
  }
}

/// A small grey heading inside a panel.
class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: context.palette.muted,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// "42 h", "12.5 h", or "45 min" for under an hour.
String fmtDuration(Duration d) => d.inMinutes < 60
    ? L10n.current.minutesShort(d.inMinutes)
    : L10n.current.hoursShort(fmtHours(d.inMinutes / 60));

/// Where HowLongToBeat lists [title]: its search page, opened in the browser.
/// Only a link: HowLongToBeat does not allow its data to be fetched by apps.
Uri howLongToBeatSearch(String title) =>
    Uri.parse('https://howlongtobeat.com/?q=${Uri.encodeComponent(title)}');

/// The time to beat in each [CompletionCategory]: Gamebit's median where
/// enough members reported a time ([CommunityTimes.shown]), labelled with how
/// many did ("37 Gamebit players"), and a link to HowLongToBeat for the rest.
class _TimeToBeatPanel extends StatelessWidget {
  const _TimeToBeatPanel({required this.title, required this.community});

  final String title;

  /// What Gamebit's members reported.
  final CommunityTimes community;

  @override
  Widget build(BuildContext context) {
    const figureStyle = TextStyle(fontSize: 22, fontWeight: FontWeight.w800);
    const sourceStyle = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      height: 1.3,
    );

    Widget figure(CompletionCategory category) {
      final ours = community.shown(category);
      return Expanded(
        child: Padding(
          // A gap between the columns, none after the last.
          padding: EdgeInsetsDirectional.only(
            end: category == CompletionCategory.values.last ? 0 : 8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  ours == null ? '–' : fmtDuration(ours.median),
                  style: figureStyle,
                ),
              ),
              // Shrinks rather than breaking "Completionist" on a narrow screen.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  category.label,
                  style: TextStyle(fontSize: 12, color: context.palette.muted),
                ),
              ),
              if (ours != null)
                Text(
                  context.l10n.checkpointPlayers(ours.count, fmtThousands(ours.count)),
                  style: sourceStyle.copyWith(color: context.palette.accent),
                ),
            ],
          ),
        ),
      );
    }

    final caption = TextStyle(color: context.palette.muted, fontSize: 12, height: 1.35);
    return Panel(
      title: context.l10n.timeToBeat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (community.hasShown) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final c in CompletionCategory.values) figure(c)],
            ),
            const SizedBox(height: 10),
            Text(context.l10n.timeToBeatOursCaption, style: caption),
            const SizedBox(height: 4),
          ],
          TextButton.icon(
            onPressed: () => launchUrl(
              howLongToBeatSearch(title),
              mode: LaunchMode.externalApplication,
            ),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              alignment: AlignmentDirectional.centerStart,
            ),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: Text(context.l10n.viewOnHowLongToBeat),
          ),
        ],
      ),
    );
  }
}

class _SimilarGames extends StatelessWidget {
  const _SimilarGames({required this.games});

  final List<Game> games;

  @override
  Widget build(BuildContext context) {
    const width = 112.0;
    // Cards run to the screen edges, past the 20 px the rest of the page is inset by.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(2, 10, 0, 12),
          child: Text(
            context.l10n.similarGames,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        SizedBox(
          height: posterCardHeight(context, width, subtitle: false),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            itemCount: games.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (_, i) => GamePosterCard(
              game: games[i],
              width: width,
              showUnrated: false,
            ),
          ),
        ),
      ],
    );
  }
}
