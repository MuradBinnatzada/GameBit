import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:checkpoint/app/app_config.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/theme/palette.dart';
import 'package:checkpoint/widgets/legal_links.dart';
import 'package:checkpoint/widgets/link_row.dart';
import 'package:checkpoint/widgets/panel.dart';

/// Where the data of the app comes from, who it belongs to, the terms, the
/// licenses of the libraries it is built with (their notices, not a license of
/// the app's own, which is proprietary: see LICENSE) and the version: what the
/// stores ask an app to show, and what a member writing to us is asked for first.
/// The credits mirror the sources the Edge Functions read (igdb-handler,
/// sync-steam, game-prices, game-news); a new source belongs here too.
class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  static final igdbUri = Uri.parse('https://www.igdb.com');
  static final steamUri = Uri.parse('https://store.steampowered.com');
  static final pricesUri = Uri.parse('https://isthereanydeal.com');

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    unawaited(_readVersion());
  }

  Future<void> _readVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _info = info);
    } catch (e) {
      // The page is still worth showing without its version.
      debugPrint('Reading the app version failed: $e');
    }
  }

  /// "1.0.0 (1)", and the backend of a build that is not the production one.
  String? get _version {
    final info = _info;
    if (info == null) return null;
    final build = info.buildNumber.isEmpty ? '' : ' (${info.buildNumber})';
    final environment = AppConfig.environment == 'production' ? '' : ' · ${AppConfig.environment}';
    return '${info.version}$build$environment';
  }

  void _showLicenses() => showLicensePage(
    context: context,
    applicationName: AppConfig.appName,
    applicationVersion: _version,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final version = _version;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Panel(
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: palette.surfaceHigh, shape: BoxShape.circle),
                child: Icon(Icons.sports_esports_rounded, color: palette.accent, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: const Text(
                        AppConfig.appName,
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.aboutTagline,
                      style: TextStyle(color: palette.muted, fontSize: 13.5, height: 1.35),
                    ),
                    if (version != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        l10n.aboutVersion(version),
                        style: TextStyle(color: palette.muted, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Panel(
          title: l10n.aboutCreditsTitle,
          child: Column(
            children: [
              LinkRow(
                icon: Icons.sports_esports_outlined,
                title: 'IGDB',
                subtitle: l10n.aboutCreditIgdb,
                external: true,
                onTap: () => openLegalLink(AboutSection.igdbUri),
              ),
              LinkRow(
                brandIcon: FontAwesomeIcons.steam,
                title: 'Steam',
                subtitle: l10n.aboutCreditSteam,
                external: true,
                onTap: () => openLegalLink(AboutSection.steamUri),
              ),
              LinkRow(
                icon: Icons.sell_outlined,
                title: 'IsThereAnyDeal',
                subtitle: l10n.aboutCreditPrices,
                external: true,
                onTap: () => openLegalLink(AboutSection.pricesUri),
              ),
              LinkRow(
                icon: Icons.newspaper_rounded,
                title: l10n.gameNews,
                subtitle: l10n.aboutCreditNews,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(
            l10n.aboutTrademarks,
            style: TextStyle(color: palette.muted, fontSize: 12.5, height: 1.4),
          ),
        ),
        const SizedBox(height: 14),
        Panel(
          title: l10n.legalTitle,
          child: Column(
            children: [
              LinkRow(
                icon: Icons.description_outlined,
                title: l10n.termsOfUse,
                external: true,
                onTap: () => openLegalLink(AppConfig.termsUri),
              ),
              LinkRow(
                icon: Icons.privacy_tip_outlined,
                title: l10n.privacyPolicy,
                external: true,
                onTap: () => openLegalLink(AppConfig.privacyUri),
              ),
              LinkRow(
                icon: Icons.code_rounded,
                title: l10n.thirdPartyLicenses,
                subtitle: l10n.thirdPartyLicensesSubtitle,
                onTap: _showLicenses,
              ),
              LinkRow(
                icon: Icons.mail_outline_rounded,
                title: l10n.contactUs,
                subtitle: l10n.contactUsSubtitle,
                external: true,
                onTap: () => openLegalLink(AppConfig.contactUri),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
