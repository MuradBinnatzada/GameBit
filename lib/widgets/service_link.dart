import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/connected_service.dart';

/// Where tapping a connected account leads: a page to open.
class ServiceLink {
  const ServiceLink({required this.tooltip, required this.url});

  final String tooltip;
  final Uri url;
}

/// The link for [service] once its [id] is known, or null when there is nothing
/// to open yet.
ServiceLink? serviceLink(ConnectedService service, String? id) {
  final account = id?.trim();
  if (account == null || account.isEmpty) return null;
  switch (service) {
    case ConnectedService.steam:
      return ServiceLink(
        tooltip: L10n.current.openServiceProfile(service.label),
        url: Uri.https('steamcommunity.com', '/profiles/$account'),
      );
  }
}

/// Follows [link]: opens its page outside the app.
Future<void> openServiceLink(BuildContext context, ServiceLink link) =>
    launchUrl(link.url, mode: LaunchMode.externalApplication);
