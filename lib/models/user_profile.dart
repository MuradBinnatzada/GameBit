import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/milestone.dart';

@immutable
class UserProfile {
  const UserProfile({
    required this.name,
    required this.handle,
    this.bio,
    this.avatarUrl,
    this.steamId,
    this.showSteamAchievements = true,
    this.showTrophies = true,
    this.flair = ProfileFlair.none,
    required this.joined,
    this.followers = 248,
    this.following = 120,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        name: json['name'] as String,
        handle: json['handle'] as String,
        bio: json['bio'] as String?,
        avatarUrl: json['avatarUrl'] as String?,
        steamId: json['steamId'] as String?,
        // A copy saved before the setting existed: the default.
        showSteamAchievements: json['showSteamAchievements'] as bool? ?? true,
        showTrophies: json['showTrophies'] as bool? ?? true,
        flair: profileFlairFromJson(json['flair']),
        joined: DateTime.parse(json['joined'] as String).toLocal(),
        followers: (json['followers'] as num).toInt(),
        following: (json['following'] as num).toInt(),
      );

  final String name;
  final String handle;
  final String? bio;
  final String? avatarUrl;

  /// Steam ID64 from `profiles.steam_id`. Only ever populated for the signed-in
  /// user's own profile; it is never read for other members.
  final String? steamId;

  /// Whether other members see the Achievements card on this profile
  /// (`profiles.show_steam_achievements`, Settings > Privacy). The member always
  /// sees their own.
  final bool showSteamAchievements;

  /// Whether other members see the Trophies card on this profile
  /// (`profiles.show_trophies`, Settings > Privacy). The member always sees their own.
  final bool showTrophies;

  /// The frame, title and showcased milestones they picked in Edit Profile
  /// (`profiles.avatar_frame`, `title_milestone`, `showcased_milestones`).
  final ProfileFlair flair;
  final DateTime joined;
  final int followers; // mock
  final int following; // mock base; the store adds people followed in Search

  /// What the offline cache keeps of the signed-in user's profile; read back by
  /// [UserProfile.fromJson].
  Map<String, dynamic> toJson() => {
        'name': name,
        'handle': handle,
        'bio': bio,
        'avatarUrl': avatarUrl,
        'steamId': steamId,
        'showSteamAchievements': showSteamAchievements,
        'showTrophies': showTrophies,
        'flair': profileFlairToJson(flair),
        'joined': joined.toUtc().toIso8601String(),
        'followers': followers,
        'following': following,
      };

  UserProfile copyWith({
    String? name,
    String? handle,
    String? bio,
    String? avatarUrl,
    String? steamId,
    // copyWith can't tell "leave it" from "set to null", so clearing is explicit.
    bool clearSteamId = false,
    bool? showSteamAchievements,
    bool? showTrophies,
    ProfileFlair? flair,
  }) =>
      UserProfile(
        name: name ?? this.name,
        handle: handle ?? this.handle,
        bio: bio ?? this.bio,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        steamId: clearSteamId ? null : (steamId ?? this.steamId),
        showSteamAchievements:
            showSteamAchievements ?? this.showSteamAchievements,
        showTrophies: showTrophies ?? this.showTrophies,
        flair: flair ?? this.flair,
        joined: joined,
        followers: followers,
        following: following,
      );
}