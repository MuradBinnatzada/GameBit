import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/models/milestone.dart';

/// Another member's profile header: what `public_profiles` exposes to signed-in
/// members. That is the name, handle, photo, bio, their Steam ID (what makes the
/// Steam icon tappable) and their frame and milestones. Never the email.
@immutable
class PublicProfile {
  const PublicProfile({
    required this.id,
    required this.name,
    required this.handle,
    this.avatarUrl,
    this.steamConnected = false,
    this.showSteamAchievements = true,
    this.showTrophies = true,
    this.bio,
    this.steamId,
    this.joined,
    this.flair = ProfileFlair.none,
  });

  final String id;
  final String name;

  /// With the leading "@".
  final String handle;
  final String? avatarUrl;
  final bool steamConnected;

  /// Whether they let other members see their Steam achievements
  /// (`show_steam_achievements`, Settings > Privacy). When false the server hands
  /// out none of them, and the profile leaves the Achievements card out.
  final bool showSteamAchievements;

  /// Whether they let other members see their PlayStation trophies
  /// (`show_trophies`, Settings > Privacy). When false the server hands out none
  /// of them, and the profile leaves the Trophies card out.
  final bool showTrophies;

  /// Null when they wrote none.
  final String? bio;

  /// Steam ID64, as Steam confirmed it when the member connected. Null when they
  /// have not connected Steam.
  final String? steamId;

  /// When they joined.
  final DateTime? joined;

  /// The frame, title and milestones they show off.
  final ProfileFlair flair;

  /// Every service the member has connected: Steam, once they have.
  Set<ConnectedService> get connectedServices => {
    if (steamConnected) ConnectedService.steam,
  };

  /// The account IDs behind [connectedServices], for the Connected accounts box.
  Map<ConnectedService, String> get accountNames => {
    if (steamId?.trim() case final id? when steamConnected && id.isNotEmpty)
      ConnectedService.steam: id,
  };
}

/// The numbers of a profile page, from one request (`public_profile_stats`).
@immutable
class PublicProfileStats {
  const PublicProfileStats({
    required this.followers,
    required this.following,
    required this.viewerFollows,
    required this.games,
  });

  final int followers;
  final int following;

  /// Whether the signed-in member followed this one when the numbers were read.
  final bool viewerFollows;

  /// Games in their library.
  final int games;
}
