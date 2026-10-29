part of '../checkpoint_repository.dart';

/// The signed-in member's own profile: creating it on first sign-in, editing it, its photo, the Steam link, the connected accounts and what the profile shows off.
mixin _ProfileQueries on _RepositoryBase {
  Future<UserProfile> ensureProfile(User user) async {
    final existing = await _client
        .from(Db.profiles)
        .select()
        .eq(Db.id, user.id)
        .maybeSingle();
    final metadata = user.userMetadata ?? const <String, dynamic>{};
    // Google sends a name; an email sign-up sends the one typed in
    // (AuthService.signUpWithEmail), and Apple's is saved just after sign-in
    // (AuthService.signInWithApple). The name and handle are public, so they
    // are never made from the email address.
    final accountName = _firstText([
      metadata['full_name'],
      metadata['name'],
      metadata['display_name'],
    ]);
    if (existing != null) {
      // Apple's name can arrive after the row was made with the stand-in: a
      // row that still has it, untouched, takes the name.
      if (accountName != null &&
          existing[Db.displayName] == _defaultName &&
          existing[Db.handle] == _handleFrom(_defaultName, user.id)) {
        final renamed = await _client
            .from(Db.profiles)
            .update({
              Db.displayName: accountName,
              Db.handle: _handleFrom(accountName, user.id),
            })
            .eq(Db.id, user.id)
            .select()
            .single();
        return _profileFromRow(renamed, fallbackUser: user);
      }
      return _profileFromRow(existing, fallbackUser: user);
    }

    final displayName = accountName ?? _defaultName;

    await _client.from(Db.profiles).upsert({
      Db.id: user.id,
      Db.email: user.email,
      Db.displayName: displayName,
      Db.handle: _handleFrom(displayName, user.id),
      Db.bio: '',
      Db.avatarUrl: _firstText([metadata['avatar_url'], metadata['picture']]),
    });

    final inserted = await _client
        .from(Db.profiles)
        .select()
        .eq(Db.id, user.id)
        .single();
    return _profileFromRow(inserted, fallbackUser: user);
  }

  /// The name of a profile whose account came without one, as stored: the
  /// app shows a missing name in its own language (defaultPlayerName).
  static const _defaultName = 'Player';

  Future<UserProfile> fetchProfile(User user) async {
    final row = await _client
        .from(Db.profiles)
        .select()
        .eq(Db.id, user.id)
        .single();
    return _profileFromRow(row, fallbackUser: user);
  }

  static const _avatarBucket = 'avatars';

  static const _avatarMimeTypes = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };

  /// Whether [handle] is free to use. The `handle` column is citext, so the
  /// match is case-insensitive; the lookup also lowercases for clarity.
  /// [currentUserId]'s own row is excluded, so keeping your current handle
  /// counts as available.
  ///
  /// Reads `public_profiles`, not `profiles`: the table only exposes the
  /// caller's own row, so it can't see whether someone else holds a handle.
  Future<bool> isHandleAvailable(String handle, String currentUserId) async {
    final normalized = handle
        .trim()
        .replaceFirst(RegExp(r'^@+'), '')
        .toLowerCase();
    if (normalized.isEmpty) return false;

    final rows = await _client
        .from(Db.publicProfiles)
        .select(Db.id)
        .eq(Db.handle, normalized)
        .neq(Db.id, currentUserId)
        .limit(1);
    return rows.isEmpty;
  }

  /// Saves the signed-in user's display name, handle, bio and avatar.
  ///
  /// [handle] is stored lowercase and without the leading "@" (the app adds
  /// it back when reading the profile). [bio] and [avatarUrl] are only written
  /// when non-null, so passing null leaves the stored value untouched; pass an
  /// empty [bio] to clear it.
  Future<void> updateProfile({
    required String name,
    required String handle,
    String? bio,
    String? avatarUrl,
  }) async {
    final userId = _requireUserId();
    await _client
        .from(Db.profiles)
        .update({
          Db.displayName: name.trim(),
          Db.handle: handle.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase(),
          if (bio != null) Db.bio: bio.trim(),
          Db.avatarUrl: ?avatarUrl,
        })
        .eq(Db.id, userId);
  }

  /// Starts connecting the signed-in user's Steam account through the
  /// `steam-link` Edge Function, which answers the Steam sign-in page to open.
  /// When the user signs in there, the function saves the Steam ID Steam
  /// confirms on their `profiles` row (members can't write it themselves); read
  /// it back with [fetchProfile] as [UserProfile.steamId]. [returnTo] is where
  /// the browser goes when it is done, with `steam_link=ok` or an error code;
  /// null for nowhere. Throws [FunctionException] when the function answers with
  /// an error.
  Future<Uri> startSteamLink({Uri? returnTo}) async {
    final response = await _client.functions.invoke(
      'steam-link',
      body: {if (returnTo != null) 'return_to': returnTo.toString()},
    );
    final data = response.data;
    final url = data is Map ? data['url'] : null;
    final page = url is String ? Uri.tryParse(url) : null;
    // Nothing but Steam's own page is ever opened as "Sign in through Steam".
    if (page == null || page.scheme != 'https' || page.host != 'steamcommunity.com') {
      throw const FormatException('steam-link did not answer a Steam sign-in page');
    }
    return page;
  }

  /// Removes the signed-in user's Steam ID from their own `profiles` row.
  Future<void> clearSteamId() async {
    final userId = _requireUserId();
    await _client
        .from(Db.profiles)
        .update({Db.steamId: null})
        .eq(Db.id, userId);
  }

  /// Saves whether other members may see the signed-in user's Steam achievements
  /// (`profiles.show_steam_achievements`). The achievement functions and
  /// `sync-achievements` read it on every request, so it holds from the next one.
  Future<void> setShowSteamAchievements(bool show) async {
    final userId = _requireUserId();
    await _client
        .from(Db.profiles)
        .update({Db.showSteamAchievements: show})
        .eq(Db.id, userId);
  }

  /// Saves the frame, title and showcased milestones the signed-in user shows
  /// on their profile. The server refuses (a check violation) anything they
  /// have not unlocked.
  Future<void> setProfileFlair(ProfileFlair flair) async {
    final userId = _requireUserId();
    await _client
        .from(Db.profiles)
        .update({
          Db.avatarFrame: flair.frameId,
          Db.titleMilestone: flair.titleId,
          Db.showcasedMilestones: flair.showcaseIds,
        })
        .eq(Db.id, userId);
  }

  /// Saves which services the signed-in user has connected, and the account
  /// names behind PSN, Xbox, Discord, Instagram and Twitch, on their own
  /// `profiles` row. This is what
  /// other members see on the profile: the icons, and what tapping one opens.
  /// Replaces everything, so sending the same accounts twice is harmless, and a
  /// service that is not connected has its name cleared. Never Steam: it follows
  /// from the Steam ID. Read back with [fetchProfile] (as
  /// [UserProfile.connectedServices] and its account names).
  Future<void> setConnectedAccounts(ConnectedAccounts accounts) async {
    final userId = _requireUserId();
    String? name(ConnectedService s) {
      if (!accounts.services.contains(s)) return null;
      final text = accounts.nameOf(s)?.trim();
      if (text == null || text.isEmpty) return null;
      return text.length <= accountNameMaxLength
          ? text
          : text.substring(0, accountNameMaxLength);
    }

    await _client
        .from(Db.profiles)
        .update({
          Db.connectedServices: connectedServicesToDb(accounts.services),
          Db.psnId: name(ConnectedService.psn),
          Db.xboxId: name(ConnectedService.xbox),
          Db.discordId: name(ConnectedService.discord),
          Db.instagramId: name(ConnectedService.instagram),
          Db.twitchId: name(ConnectedService.twitch),
        })
        .eq(Db.id, userId);
  }

  /// Uploads [image] to the public `avatars` bucket and returns its public
  /// URL. Files go under `<userId>/` with a unique name per upload, so a new
  /// photo never collides with a cached copy of the old one.
  Future<String> uploadAvatar(XFile image) async {
    final userId = _requireUserId();
    final bytes = await image.readAsBytes();

    final name = image.name.isNotEmpty ? image.name : image.path;
    final dot = name.lastIndexOf('.');
    var ext = dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
    if (!_avatarMimeTypes.containsKey(ext)) ext = 'jpg';

    final path = '$userId/${DateTime.now().millisecondsSinceEpoch}.$ext';
    final storage = _client.storage.from(_avatarBucket);
    await storage.uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(
        contentType: _avatarMimeTypes[ext],
        cacheControl: '3600',
        upsert: false,
      ),
    );
    return storage.getPublicUrl(path);
  }

  Stream<List<Map<String, dynamic>>> watchProfile(String userId) =>
      _client.from(Db.profiles).stream(primaryKey: [Db.id]).eq(Db.id, userId);
}
