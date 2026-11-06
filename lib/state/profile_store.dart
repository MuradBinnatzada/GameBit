import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/models/user_profile.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/services/connection_failure.dart';
import 'package:checkpoint/services/content_refusal.dart';
import 'package:checkpoint/services/connectivity_service.dart';
import 'package:checkpoint/services/delete_account_failure.dart';
import 'package:checkpoint/services/local_cache.dart';
import 'package:checkpoint/services/pending_edits.dart';
import 'package:checkpoint/services/steam_link_service.dart';
import 'package:checkpoint/services/sync_failure.dart';
import 'package:checkpoint/state/auth_store.dart';

/// The signed-in user as a person: their profile, who they follow, and the
/// game account they have connected (Steam). Reloads when the account changes,
/// shows the copy saved on the device first, and keeps it when the network is down.
///
/// Follows and unfollows made while the server can't be reached are kept on the
/// device ([PendingEdits.follows]), shown as if saved, and sent when the
/// connection is back ([flushPending]). One the server refuses is reverted
/// instead.
///
/// Steam is the only connected service: it is connected exactly when the profile
/// has a Steam ID, which only the `steam-link` Edge Function can write, after
/// Steam itself confirmed the sign-in.
class ProfileStore extends ChangeNotifier {
  ProfileStore({
    required this._repository,
    required this._auth,
    this._connectivity,
    LocalCache? cache,
    PendingEditsStorage? pendingStorage,
    SteamLinkFlow? steamLink,
    this._steamLinkResult,
    this._steamLinkPoll = const Duration(seconds: 3),
    this._steamLinkWait = const Duration(minutes: 10),
  }) : _cache = cache ?? LocalCache(),
       _pendingStorage =
           pendingStorage ?? PendingEditsStorage(PendingScope.follows),
       _steamLink = steamLink ?? SteamLinkFlow(),
       _profile = _guestProfile();

  final CheckpointRepository _repository;
  final AuthStore _auth;
  final LocalCache _cache;
  final PendingEditsStorage _pendingStorage;
  final ConnectivityService? _connectivity;

  /// Opens "Sign in through Steam" for [connectSteam].
  final SteamLinkFlow _steamLink;

  /// How often, and for how long, [connectSteam] reads the profile while Steam's
  /// page is open on a phone (see [SteamLinkOpened]).
  final Duration _steamLinkPoll;
  final Duration _steamLinkWait;

  /// What Steam's return brought the web app back with (`ok` or an error code),
  /// told once the signed-in user is known.
  String? _steamLinkResult;

  User? _user;

  /// Whether the saved copy of the account's profile and follows has been read.
  /// Tracked as state rather than inferred from "a different user signed in": a
  /// load that was overtaken by a second auth event never got to read it, and the
  /// load that overtook it sees the same user.
  bool _hydrated = false;

  UserProfile _profile;

  /// Who the user follows as shown: what the server (or the saved copy) says,
  /// with the follows that haven't reached the server applied on top.
  Set<String> _followingIds = {};
  int _followersCount = 0;

  /// Follows the server hasn't accepted yet, for the account in [_pendingFor].
  PendingEdits _pending = PendingEdits();
  String? _pendingFor;

  /// The replay of [_pending] that is running, if any. A new follow waits for it,
  /// so the two can't cross on their way to the server.
  Future<void>? _replay;

  String? _notice;

  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<bool>? _connectivitySubscription;

  /// The last load did not finish (the server could not be reached), so what is
  /// shown may be the saved copy.
  bool _incomplete = false;
  final List<StreamSubscription<dynamic>> _dataSubscriptions = [];

  /// Bumped by every account event, so a load that was overtaken (another
  /// account signed in, or a retry started) can tell and stop.
  int _loadSeq = 0;

  static UserProfile _guestProfile() => UserProfile(
    name: L10n.current.defaultPlayerName,
    handle: '@guest',
    bio: '',
    joined: DateTime.now(),
    followers: 0,
    following: 0,
  );

  UserProfile get profile => _profile;

  /// How many follows and unfollows are waiting for the server (see
  /// [flushPending]).
  int get pendingCount => _pending.count;

  /// A message about something that just went wrong with a follow or with the
  /// connected services. The app shell shows it once and calls [clearNotice].
  String? get notice => _notice;

  void clearNotice() => _notice = null;

  void _setNotice(String message) {
    _notice = message;
    notifyListeners();
  }

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    // The Steam ID now lives on the `profiles` row. Delete any copy that an
    // older build left on this device; it is deliberately not read or migrated.
    await prefs.remove('steam_id');
    await _forgetTypedInAccounts(prefs);
    _authSubscription = _auth.userChanges.listen((user) {
      unawaited(_onUser(user));
    });
    _connectivitySubscription = _connectivity?.onlineChanges.listen((online) {
      if (!online || _user == null) return;
      // A reload ends with the replay; without one there is only the replay to do.
      if (_incomplete) {
        unawaited(refresh());
      } else {
        unawaited(flushPending());
      }
    });
    await _onUser(_auth.user);
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    unawaited(_connectivitySubscription?.cancel());
    unawaited(_cancelDataSubscriptions());
    _steamLinkSeq++;
    unawaited(_steamLink.cancel());
    super.dispose();
  }

  /// Loads everything again for the signed-in user (a retry after a failed load).
  Future<void> refresh() => _onUser(_user);

  Future<void> _onUser(User? user) async {
    final seq = ++_loadSeq;
    // Token refreshes and retries re-enter here for the same user; their loaded
    // data stays valid, a different user's does not.
    final previous = _user;
    final sameUser = user != null && user.id == previous?.id;
    _user = user;
    if (!sameUser) {
      // A different account (or signing out) must not inherit the previous
      // account's profile or follows.
      _hydrated = false;
      _profile = _guestProfile();
      _followingIds = {};
      _followersCount = 0;
      _pending = PendingEdits();
      _pendingFor = null;
      // A Steam sign-in the previous account started is not waited for.
      if (_linkingSteam) cancelSteamLink();
      // The previous account's saved copy goes too (it stays valid only while
      // that account stays signed in).
      if (previous != null) unawaited(_cache.clearAccount(previous.id));
      notifyListeners();
    }

    await _cancelDataSubscriptions();
    if (user == null || seq != _loadSeq) return;

    // Steam's return reloaded the web app: say how it went.
    final linkResult = _steamLinkResult;
    if (linkResult != null) {
      _steamLinkResult = null;
      _setNotice(_steamLinkMessage(linkResult));
    }

    // Their own copy, not the saved server copy: these follows exist nowhere else
    // (and stay on the device when the account signs out).
    if (_pendingFor != user.id) {
      final saved = await _pendingStorage.read(user.id);
      if (seq != _loadSeq) return;
      _pending = saved;
      _pendingFor = user.id;
    }
    if (!_hydrated) {
      await _hydrateFromCache(user.id, seq);
      if (seq != _loadSeq) return;
      _hydrated = true;
    }

    // No live session (the app started offline): the saved copy is all there is
    // until the session is restored, which announces itself as an auth event.
    if (_auth.isSessionPending) {
      _incomplete = true;
      return;
    }

    // Independent reads, started together. Each falls back to the saved copy on
    // its own, so a failed one doesn't throw away the other.
    final (profileLoaded, socialLoaded) =
        await (_loadProfile(user, seq), _loadSocial(user.id, seq)).wait;
    if (seq != _loadSeq) return;
    _incomplete = !(profileLoaded && socialLoaded);
    if (!_incomplete) _startSubscriptions(user);
    // The follows table answered, so whatever was queued while it couldn't be
    // reached goes now.
    if (socialLoaded) unawaited(flushPending());
  }

  /// Puts the copy saved on this device on screen while the network answers.
  Future<void> _hydrateFromCache(String userId, int seq) async {
    final profile = await _cache.readProfile(userId);
    final social = await _cache.readSocial(userId);
    if (seq != _loadSeq) return;
    if (profile == null && social == null && _pending.follows.isEmpty) return;
    if (profile != null) _profile = profile.value;
    if (social != null) _followersCount = social.value.followersCount;
    _followingIds = _withPendingFollows(
      social?.value.followingIds ?? _followingIds,
    );
    notifyListeners();
  }

  /// Creates the profiles row on first login. This lives only in
  /// CheckpointRepository.ensureProfile; AuthService has no copy of it, so two
  /// code paths can't race to create the same row during sign-in.
  Future<bool> _loadProfile(User user, int seq) async {
    try {
      final fetched = await _repository.ensureProfile(user);
      if (seq != _loadSeq) return true;
      _profile = fetched;
      notifyListeners();
      unawaited(_cache.writeProfile(user.id, fetched));
      return true;
    } catch (e, st) {
      // Keeps whatever is showing: the saved copy, or the guest placeholder.
      debugPrint('Profile load failed: $e\n$st');
      return false;
    }
  }

  Future<bool> _loadSocial(String userId, int seq) async {
    try {
      final (following, followers) = await (
        _repository.fetchFollowingIds(userId),
        _repository.fetchFollowersCount(userId),
      ).wait;
      if (seq != _loadSeq) return true;
      _followingIds = _withPendingFollows(following);
      _followersCount = followers;
      notifyListeners();
      unawaited(_writeSocialCache(userId, following, followers));
      return true;
    } catch (e, st) {
      debugPrint('Social load failed: $e\n$st');
      return false;
    }
  }

  /// Saves what the server returned, not what is on screen: a follow that hasn't
  /// reached the server is in [_pending], and goes on top again when this is read.
  Future<void> _writeSocialCache(
    String userId,
    Set<String> following,
    int followers,
  ) => _cache.writeSocial(
    userId,
    SocialSnapshot(followingIds: following, followersCount: followers),
  );

  void _startSubscriptions(User user) {
    void onError(Object e, StackTrace st) =>
        debugPrint('Profile realtime stream failed: $e\n$st');
    _dataSubscriptions
      ..add(
        _repository
            .watchProfile(user.id)
            .listen((_) => unawaited(_refreshProfile(user)), onError: onError),
      )
      ..add(
        _repository
            .watchFollows(user.id)
            .listen((_) => unawaited(_refreshSocial(user.id)), onError: onError),
      );
  }

  Future<void> _cancelDataSubscriptions() async {
    for (final subscription in _dataSubscriptions) {
      await subscription.cancel();
    }
    _dataSubscriptions.clear();
  }

  Future<void> _refreshProfile(User user) async {
    try {
      final fetched = await _repository.fetchProfile(user);
      if (_user?.id != user.id) return;
      _profile = fetched;
      notifyListeners();
      unawaited(_cache.writeProfile(user.id, fetched));
    } catch (e, st) {
      debugPrint('Profile refresh failed: $e\n$st');
    }
  }

  Future<void> _refreshSocial(String userId) async {
    try {
      final (following, followers) = await (
        _repository.fetchFollowingIds(userId),
        _repository.fetchFollowersCount(userId),
      ).wait;
      if (_user?.id != userId) return;
      _followingIds = _withPendingFollows(following);
      _followersCount = followers;
      notifyListeners();
      unawaited(_writeSocialCache(userId, following, followers));
    } catch (e, st) {
      debugPrint('Social refresh failed: $e\n$st');
    }
  }

  // ---- Leftovers of the typed-in accounts ----

  /// What earlier builds saved per account for the services that could be typed
  /// in (`<name>.<user id>`), and for the whole device before that (`<name>`).
  static const _typedInAccountKeys = [
    'psn_id',
    'xbox_id',
    'discord_id',
    'instagram_id',
    'twitch_id',
    'connected_services',
    'accounts_pending',
  ];

  /// Deletes those copies. Nothing reads them any more: only Steam, which Steam
  /// itself confirms, can be connected, so a name that was only ever typed in
  /// does not stay on the device.
  static Future<void> _forgetTypedInAccounts(SharedPreferences prefs) async {
    for (final key in prefs.getKeys()) {
      for (final name in _typedInAccountKeys) {
        if (key == name || key.startsWith('$name.')) {
          await prefs.remove(key);
          break;
        }
      }
    }
  }

  // ---- Following ----

  /// A follow between the signed-in member and the blocked member [memberId] is
  /// gone: the server ends it when a block is made.
  void forgetFollow(String memberId) {
    if (!_followingIds.contains(memberId)) return;
    _followingIds = {..._followingIds}..remove(memberId);
    _pending.follows.remove(memberId);
    notifyListeners();
  }

  bool isFollowing(String userId) => _followingIds.contains(userId);
  int get followersCount => _followersCount;
  int get followingCount => _followingIds.length;

  /// [fetched] with the follows and unfollows that haven't reached the server
  /// applied, so a refresh never undoes them.
  Set<String> _withPendingFollows(Set<String> fetched) {
    if (_pending.follows.isEmpty) return fetched;
    final ids = {...fetched};
    _pending.follows.forEach((id, following) {
      if (following) {
        ids.add(id);
      } else {
        ids.remove(id);
      }
    });
    return ids;
  }

  void _showFollowing(String userId, bool following) {
    _followingIds = following
        ? {..._followingIds, userId}
        : ({..._followingIds}..remove(userId));
    notifyListeners();
  }

  /// Follows [userId], or unfollows them if they are followed. Shown at once. If
  /// the server can't be reached it is kept and sent later; if it refuses, the
  /// change is undone and a [notice] says so.
  Future<void> toggleFollow(String userId) async {
    final current = _user;
    if (current == null) return;
    final following = !_followingIds.contains(userId);
    _showFollowing(userId, following);

    await _replay;
    if (_user?.id != current.id) return;

    // Already queued, so this undoes it: nothing has reached the server, and
    // sending now would jump ahead of the queue.
    if (_pending.follows.containsKey(userId)) {
      _pending.putFollow(userId, following: following);
      _savePending();
      notifyListeners();
      return;
    }

    try {
      _auth.requireSession();
      await _send(current.id, userId, following: following);
    } catch (e, st) {
      debugPrint('Follow update failed: $e\n$st');
      if (_user?.id != current.id) return;
      if (isConnectionFailure(e)) {
        _pending.putFollow(userId, following: following);
        _savePending();
        _setNotice(queuedNotice);
      } else {
        _showFollowing(userId, !following);
        _setNotice(
          following ? L10n.current.followFailed : L10n.current.unfollowFailed,
        );
        await _refreshSocial(current.id);
      }
      return;
    }
    await _refreshSocial(current.id);
  }

  Future<void> _send(
    String followerId,
    String userId, {
    required bool following,
  }) async {
    if (!following) {
      await _repository.unfollow(followerId: followerId, followeeId: userId);
      return;
    }
    try {
      await _repository.follow(followerId: followerId, followeeId: userId);
    } on PostgrestException catch (e) {
      // Already following (the table's key): what was asked for is true.
      if (e.code != '23505') rethrow;
    }
  }

  void _savePending() {
    final userId = _pendingFor;
    if (userId != null) unawaited(_pendingStorage.write(userId, _pending));
  }

  /// Sends the queued follows and unfollows. Stops at the first one the server
  /// can't be reached for (the rest stay queued); one it refuses is dropped, with
  /// a notice. Safe to call any time: it does nothing without a live session,
  /// with nothing queued, or while already running.
  Future<void> flushPending() {
    final running = _replay;
    if (running != null) return running;
    final user = _user;
    if (user == null || _pending.follows.isEmpty || _auth.isSessionPending) {
      return Future.value();
    }
    return _replay = _sendPending(user).whenComplete(() {
      _replay = null;
    });
  }

  Future<void> _sendPending(User user) async {
    var sent = 0;
    var refused = 0;
    try {
      for (final MapEntry(key: id, value: following) in [..._pending.follows.entries]) {
        if (_user?.id != user.id) return;
        try {
          await _send(user.id, id, following: following);
          sent++;
        } catch (e, st) {
          debugPrint('Sending a queued follow failed: $e\n$st');
          if (isConnectionFailure(e)) return;
          refused++;
        }
        if (_user?.id != user.id) return;
        _pending.follows.remove(id);
      }
    } finally {
      if (_user?.id == user.id) {
        _savePending();
        if (refused > 0) {
          _setNotice(L10n.current.offlineFollowsSaveFailed);
        } else {
          notifyListeners();
        }
        // Pull in what the server has now, anything still queued applied on top.
        if (sent + refused > 0) unawaited(_refreshSocial(user.id));
      }
    }
  }

  // ---- Connected services ----

  /// Steam is connected exactly when the signed-in user's profile has a Steam ID.
  bool get steamConnected =>
      _user != null && (_profile.steamId?.trim().isNotEmpty ?? false);

  Set<ConnectedService> get connectedServices => Set.unmodifiable({
    if (steamConnected) ConnectedService.steam,
  });

  /// The ID behind each connected service, for the Connected accounts box.
  Map<ConnectedService, String> get accountNames => {
    if (steamId?.trim() case final id? when steamConnected && id.isNotEmpty)
      ConnectedService.steam: id,
  };

  /// The signed-in user's Steam ID64, read from `profiles.steam_id` along with
  /// the rest of their profile. `null` when signed out or not set yet.
  String? get steamId => _profile.steamId;

  /// Bumped by every [connectSteam] and [cancelSteamLink], so a sign-in that was
  /// given up on stops waiting and says nothing.
  int _steamLinkSeq = 0;
  bool _linkingSteam = false;

  /// A [connectSteam] is waiting for the member to sign in through Steam.
  bool get linkingSteam => _linkingSteam;

  static String get _steamConnected => L10n.current.steamConnected;
  static String get _steamNotConfirmed => L10n.current.steamNotConfirmed;
  static String get _steamLinkFailed => L10n.current.steamLinkFailed;

  /// Connects Steam the only way the server accepts: the member signs in
  /// through Steam, and the `steam-link` Edge Function saves the Steam ID Steam
  /// confirms (members can't write it themselves). How Steam's page opens and
  /// comes back depends on the platform ([SteamLinkFlow]); on a phone the
  /// profile is read every few seconds until the Steam ID is on it.
  ///
  /// Returns what to tell the member: that Steam is connected, or why not. Null
  /// when there is nothing to say: [cancelSteamLink] was called, or the web app
  /// is leaving for Steam (it comes back reloaded, see [ProfileStore.new]'s
  /// `steamLinkResult`).
  Future<String?> connectSteam() async {
    final user = _user;
    if (user == null) return L10n.current.steamConnectSignIn;
    final seq = ++_steamLinkSeq;
    final before = _profile.steamId;
    _linkingSteam = true;
    notifyListeners();
    try {
      final outcome = await _steamLink.open(
        (returnTo) => _repository.startSteamLink(returnTo: returnTo),
      );
      if (seq != _steamLinkSeq) return null;
      switch (outcome) {
        case SteamLinkLeftApp():
          return null;
        case SteamLinkReturned(:final result):
          if (result != 'ok') return _steamLinkMessage(result);
          await _refreshProfile(user);
          if (seq != _steamLinkSeq) return null;
          return _isNewSteamId(before) ? _steamConnected : _steamNotConfirmed;
        case SteamLinkOpened():
          final linked = await _waitForSteamId(user, before, seq);
          if (seq != _steamLinkSeq) return null;
          if (!linked) return _steamNotConfirmed;
          unawaited(_steamLink.closeBrowser());
          return _steamConnected;
      }
    } on SteamLinkException catch (e) {
      return seq == _steamLinkSeq ? e.message : null;
    } catch (e, st) {
      debugPrint('Connecting Steam failed: $e\n$st');
      if (seq != _steamLinkSeq) return null;
      // A FormatException is an answer that made no sense, which SyncFailure
      // would take for a dropped connection.
      final failure = e is FormatException ? null : SyncFailure.from(e);
      return failure == null || failure.code == SyncFailureCode.unknown
          ? _steamLinkFailed
          : failure.message;
    } finally {
      if (seq == _steamLinkSeq && _linkingSteam) {
        _linkingSteam = false;
        notifyListeners();
      }
    }
  }

  /// Stops waiting for the Steam sign-in [connectSteam] started. (If the member
  /// finishes it anyway, the Steam ID shows up with the next profile read.)
  void cancelSteamLink() {
    _steamLinkSeq++;
    unawaited(_steamLink.cancel());
    if (!_linkingSteam) return;
    _linkingSteam = false;
    notifyListeners();
  }

  /// The profile now holds a Steam ID, and not the one it had at [before].
  bool _isNewSteamId(String? before) {
    final id = _profile.steamId?.trim() ?? '';
    return id.isNotEmpty && id != before?.trim();
  }

  /// Reads [user]'s profile every [_steamLinkPoll] until it has a new Steam ID
  /// (true), [_steamLinkWait] has passed, or the sign-in was given up on.
  Future<bool> _waitForSteamId(User user, String? before, int seq) async {
    for (
      var waited = Duration.zero;
      waited < _steamLinkWait;
      waited += _steamLinkPoll
    ) {
      await Future<void>.delayed(_steamLinkPoll);
      if (seq != _steamLinkSeq || _user?.id != user.id) return false;
      // The profile's realtime updates may have brought it already.
      if (_isNewSteamId(before)) return true;
      await _refreshProfile(user);
      if (seq != _steamLinkSeq || _user?.id != user.id) return false;
      if (_isNewSteamId(before)) return true;
    }
    return false;
  }

  /// What to say about a `steam_link` result from the server: `ok` or an error
  /// code.
  static String _steamLinkMessage(String result) {
    if (result == 'ok') return _steamConnected;
    final code = SyncFailureCode.fromWire(result);
    return code == null || code == SyncFailureCode.unknown
        ? _steamLinkFailed
        : code.message;
  }

  /// Clears the Steam ID on the profile, which is what disconnects Steam.
  /// Returns null on success, or a message that is safe to show.
  Future<String?> disconnectSteam() async {
    if (!steamConnected) return null;
    try {
      await _repository.clearSteamId();
      _profile = _profile.copyWith(clearSteamId: true);
      notifyListeners();
      unawaited(_writeProfileCache());
      return null;
    } catch (e, st) {
      debugPrint('Disconnecting Steam failed: $e\n$st');
      return L10n.current.steamDisconnectFailed;
    }
  }

  // ---- Privacy ----

  /// Whether other members see the Achievements card on the signed-in user's
  /// profile (Settings > Privacy). Their own profile always shows it.
  bool get showSteamAchievements => _profile.showSteamAchievements;

  bool _savingPrivacy = false;

  /// A [toggleSteamAchievementsPrivacy] is on its way to the server. The switch
  /// waits for it: with one save at a time, a failed one always knows what the
  /// server still has.
  bool get savingSteamAchievementsPrivacy => _savingPrivacy;

  /// Shows or hides the signed-in user's Steam achievements from other members.
  /// The switch moves at once and the choice is saved to the profile. It is not
  /// kept for later when the save fails: the server is what hides them, so the
  /// switch goes back rather than claim they are hidden when they are not. Does
  /// nothing while a save is on its way. Returns null on success, or a message
  /// that is safe to show.
  Future<String?> toggleSteamAchievementsPrivacy(bool value) async {
    final current = _user;
    if (current == null) return L10n.current.privacySignIn;
    final previous = _profile.showSteamAchievements;
    if (_savingPrivacy || value == previous) return null;

    _savingPrivacy = true;
    _profile = _profile.copyWith(showSteamAchievements: value);
    notifyListeners();
    String? error;
    try {
      _auth.requireSession();
      await _repository.setShowSteamAchievements(value);
    } catch (e, st) {
      debugPrint('Saving the achievements privacy setting failed: $e\n$st');
      error = isConnectionFailure(e)
          ? L10n.current.privacyAchievementsOffline
          : L10n.current.privacySaveFailed;
    }
    _savingPrivacy = false;
    // Another account signed in meanwhile: its own profile is loaded instead.
    if (_user?.id != current.id) return null;
    // Set again even on success: a profile read that arrived during the save may
    // hold the value from before it.
    _profile = _profile.copyWith(
      showSteamAchievements: error == null ? value : previous,
    );
    notifyListeners();
    if (error == null) unawaited(_writeProfileCache());
    return error;
  }

  /// Whether other members see the Trophies card on the signed-in user's profile
  /// (Settings > Privacy). Their own profile always shows it.
  bool get showTrophies => _profile.showTrophies;

  bool _savingTrophies = false;

  /// A [toggleTrophiesPrivacy] is on its way to the server (the switch waits).
  bool get savingTrophiesPrivacy => _savingTrophies;

  /// Shows or hides the signed-in user's PlayStation trophies from other members,
  /// the way [toggleSteamAchievementsPrivacy] does for the Steam achievements: the
  /// switch moves at once, goes back when the save fails, and the result is null on
  /// success or a message that is safe to show.
  Future<String?> toggleTrophiesPrivacy(bool value) async {
    final current = _user;
    if (current == null) return L10n.current.privacySignIn;
    final previous = _profile.showTrophies;
    if (_savingTrophies || value == previous) return null;

    _savingTrophies = true;
    _profile = _profile.copyWith(showTrophies: value);
    notifyListeners();
    String? error;
    try {
      _auth.requireSession();
      await _repository.setShowTrophies(value);
    } catch (e, st) {
      debugPrint('Saving the trophies privacy setting failed: $e\n$st');
      error = isConnectionFailure(e)
          ? L10n.current.privacyTrophiesOffline
          : L10n.current.privacySaveFailed;
    }
    _savingTrophies = false;
    // Another account signed in meanwhile: its own profile is loaded instead.
    if (_user?.id != current.id) return null;
    _profile = _profile.copyWith(showTrophies: error == null ? value : previous);
    notifyListeners();
    if (error == null) unawaited(_writeProfileCache());
    return error;
  }

  // ---- Flair ----

  /// The frame, title and showcased milestones on the signed-in user's profile.
  ProfileFlair get flair => _profile.flair;

  bool _savingFlair = false;

  /// A [setFlair] is on its way to the server.
  bool get savingFlair => _savingFlair;

  /// Saves the frame, title and showcase the signed-in user picked (Edit
  /// Profile). Shown at once; put back when the server refuses it (they haven't
  /// unlocked it) or can't be reached, since it is what other members see.
  /// Returns null on success, or a message that is safe to show.
  Future<String?> setFlair(ProfileFlair flair) async {
    final current = _user;
    if (current == null) return L10n.current.profileChangeSignIn;
    final previous = _profile.flair;
    if (_savingFlair || flair == previous) return null;

    _savingFlair = true;
    _profile = _profile.copyWith(flair: flair);
    notifyListeners();
    String? error;
    try {
      _auth.requireSession();
      await _repository.setProfileFlair(flair);
    } on PostgrestException catch (e, st) {
      debugPrint('Saving the profile flair failed: $e\n$st');
      error = e.code == '23514'
          ? L10n.current.flairNotUnlocked
          : L10n.current.profileSaveFailed;
    } catch (e, st) {
      debugPrint('Saving the profile flair failed: $e\n$st');
      error = isConnectionFailure(e)
          ? L10n.current.profileSaveOffline
          : L10n.current.profileSaveFailed;
    }
    _savingFlair = false;
    if (_user?.id != current.id) return null;
    _profile = _profile.copyWith(flair: error == null ? flair : previous);
    notifyListeners();
    if (error == null) unawaited(_writeProfileCache());
    return error;
  }

  // ---- Editing the profile ----

  static String _normalizeHandle(String handle) =>
      handle.trim().replaceFirst(RegExp(r'^@+'), '').toLowerCase();

  /// Whether [handle] (with or without the leading "@") is free for the
  /// signed-in user. Case-insensitive; the user's own current handle counts as
  /// available. Throws if signed out or if the lookup fails, so callers can
  /// decide how to degrade (the unique constraint still guards the save).
  Future<bool> isHandleAvailable(String handle) {
    final current = _user;
    if (current == null) {
      throw StateError('Sign in to check username availability.');
    }
    return _repository.isHandleAvailable(_normalizeHandle(handle), current.id);
  }

  /// Uploads [image] to the avatars bucket and returns its public URL. This
  /// doesn't touch the profile; pass the URL to [updateProfile] to save it.
  Future<String> uploadAvatar(XFile image) => _repository.uploadAvatar(image);

  /// Updates the signed-in user's display name, handle (without the leading
  /// "@"), bio and avatar. A null [bio] or [avatarUrl] leaves that field as is.
  /// Returns null on success, or a user-facing error message.
  Future<String?> updateProfile({
    required String name,
    required String handle,
    String? bio,
    String? avatarUrl,
  }) async {
    final current = _user;
    if (current == null) return L10n.current.profileEditSignIn;

    final nextName = name.trim();
    final nextHandle = _normalizeHandle(handle);
    final nextBio = bio?.trim();
    if (nextName.isEmpty || nextHandle.isEmpty) {
      return L10n.current.profileNameRequired;
    }

    final currentHandle = _profile.handle.replaceFirst(RegExp(r'^@+'), '');
    final unchanged =
        nextName == _profile.name &&
        nextHandle == currentHandle &&
        (nextBio == null || nextBio == _profile.bio) &&
        (avatarUrl == null || avatarUrl == _profile.avatarUrl);
    if (unchanged) return null;

    try {
      await _repository.updateProfile(
        name: nextName,
        handle: nextHandle,
        bio: nextBio,
        avatarUrl: avatarUrl,
      );

      // Optimistically update local profile state and trigger instant UI re-render
      _profile = _profile.copyWith(
        name: nextName,
        handle: '@$nextHandle',
        bio: nextBio,
        avatarUrl: avatarUrl ?? _profile.avatarUrl,
      );
      notifyListeners();

      await _refreshProfile(current);
      return null;
    } on PostgrestException catch (e, st) {
      debugPrint('Profile update failed: $e\n$st');
      if (e.code == '23505') return L10n.current.usernameTaken;
      if (isContentRefusal(e)) return L10n.current.contentRefused;
      return L10n.current.profileSaveFailed;
    } catch (e, st) {
      debugPrint('Profile update failed: $e\n$st');
      return L10n.current.profileSaveFailed;
    }
  }

  // ---- Deleting the account ----

  /// Permanently deletes the signed-in account: its profile, library, play logs,
  /// follows and photo on the server, then the sign-in, and then everything this
  /// device holds for it. Signs out. Returns null on success, or a message that is
  /// safe to show; the account is untouched then, and this can be tried again.
  Future<String?> deleteAccount() async {
    final current = _user;
    if (current == null) return deleteAccountMessage(StateError('Not signed in.'));
    try {
      await _auth.deleteAccount();
    } catch (e, st) {
      debugPrint('Deleting the account failed: $e\n$st');
      return deleteAccountMessage(e);
    }
    // The account is gone and the session ended; the stores have dropped what they
    // held in memory. What is left is on disk, and must not outlive the account.
    await _cache.eraseAccount(current.id);
    return null;
  }

  /// Saves the profile as it is now, after an edit the server accepted.
  Future<void> _writeProfileCache() async {
    final userId = _user?.id;
    if (userId != null) await _cache.writeProfile(userId, _profile);
  }
}
