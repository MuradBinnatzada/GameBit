import 'package:flutter/foundation.dart';

/// What a shared link opens.
sealed class LinkTarget {
  const LinkTarget();

  /// The path after `#`: `/game/1942`, `/u/<member id>`, `/list/<list id>`.
  String get path;

  /// Reads a link's fragment (`/game/1942`), or null when it is none of these.
  static LinkTarget? parse(String fragment) {
    final parts = fragment.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length != 2) return null;
    final [kind, id] = parts;
    if (kind == 'game') {
      final igdbId = int.tryParse(id);
      return igdbId != null && igdbId > 0 ? GameLink(igdbId) : null;
    }
    if (!_uuid.hasMatch(id)) return null;
    return switch (kind) {
      'u' => MemberLink(id),
      'list' => ListLink(id),
      'thread' => ThreadLink(id),
      _ => null,
    };
  }

  static final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
}

@immutable
class GameLink extends LinkTarget {
  const GameLink(this.igdbId);
  final int igdbId;
  @override
  String get path => '/game/$igdbId';
  @override
  bool operator ==(Object other) => other is GameLink && other.igdbId == igdbId;
  @override
  int get hashCode => igdbId.hashCode;
}

@immutable
class MemberLink extends LinkTarget {
  const MemberLink(this.userId);
  final String userId;
  @override
  String get path => '/u/$userId';
  @override
  bool operator ==(Object other) => other is MemberLink && other.userId == userId;
  @override
  int get hashCode => userId.hashCode;
}

@immutable
class ListLink extends LinkTarget {
  const ListLink(this.listId);
  final String listId;
  @override
  String get path => '/list/$listId';
  @override
  bool operator ==(Object other) => other is ListLink && other.listId == listId;
  @override
  int get hashCode => listId.hashCode;
}

/// A discussion thread: what a push notification of a reply opens.
@immutable
class ThreadLink extends LinkTarget {
  const ThreadLink(this.threadId);
  final String threadId;
  @override
  String get path => '/thread/$threadId';
  @override
  bool operator ==(Object other) => other is ThreadLink && other.threadId == threadId;
  @override
  int get hashCode => threadId.hashCode;
}

/// Where the web app is served, for links that open it. Set it for the native
/// builds with `--dart-define=CHECKPOINT_WEB_URL=https://...`; the web app uses
/// the address it was opened at.
const _configuredWebUrl = String.fromEnvironment('CHECKPOINT_WEB_URL');

/// The web app's address, or null when this build doesn't know it.
String? webAppUrl({bool isWeb = kIsWeb, String configured = _configuredWebUrl, Uri? base}) {
  if (configured.isNotEmpty) return configured.replaceAll(RegExp(r'/+$'), '');
  if (!isWeb) return null;
  final page = base ?? Uri.base;
  // The app may be served from a folder: keep its path, not its fragment.
  return '${page.origin}${page.path}'.replaceAll(RegExp(r'/+$'), '');
}

/// The link to [target] (`https://example.app/#/game/1942`), or null when this
/// build doesn't know where the web app is.
String? shareUrl(LinkTarget target, {String? base}) {
  final root = base ?? webAppUrl();
  return root == null ? null : '$root/#${target.path}';
}
