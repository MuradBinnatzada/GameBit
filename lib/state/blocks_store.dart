import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';

/// The members the signed-in one blocked, for the whole app: blocking is done from
/// a profile, a review, a discussion post. The server then leaves the member out
/// of every read (their profile, library, activity, reviews, public lists and
/// discussion posts), ends any follow between the two, and stops them following
/// back; this store only keeps the list for the Blocked members screen and tells
/// [onChanged] so the stores that hold what was fetched about members drop (or
/// ask again for) that member.
///
/// Kept in memory only, dropped when the account changes.
class BlocksStore extends AccountScopedStore {
  BlocksStore({
    required this._repository,
    required AuthStore auth,
    this.onChanged,
  }) : super(auth);

  final CheckpointRepository _repository;

  /// Called after a block ([blocked] true) or an unblock, with the member's id.
  final void Function(String memberId, {required bool blocked})? onChanged;

  LoadStatus _status = LoadStatus.idle;
  List<SocialUser> _blocked = const [];
  Future<void>? _loading;

  /// Of the list: idle until [load] is first called.
  LoadStatus get status => _status;

  /// The blocked members, the newest block first. Only what [load] and the
  /// blocks made since then know of.
  List<SocialUser> get blocked => _blocked;

  /// Whether [memberId] is known to be blocked.
  bool isBlocked(String memberId) => _blocked.any((m) => m.id == memberId);

  @override
  void resetForAccount() {
    _status = LoadStatus.idle;
    _blocked = const [];
    _loading = null;
  }

  /// Fetches the blocked members. Does nothing when signed out; a call while
  /// another is running joins it. The list on screen stays if a refresh fails.
  Future<void> load() {
    if (accountId == null) return Future.value();
    return _loading ??= _fetch().whenComplete(() => _loading = null);
  }

  Future<void> _fetch() async {
    final epoch = this.epoch;
    if (_status != LoadStatus.ready) {
      _status = LoadStatus.loading;
      notifyIfAlive();
    }
    try {
      final members = await _repository.fetchBlockedMembers();
      if (isStale(epoch)) return;
      _blocked = members;
      _status = LoadStatus.ready;
    } catch (e, st) {
      debugPrint('Loading the blocked members failed: $e\n$st');
      if (isStale(epoch)) return;
      if (_status != LoadStatus.ready) _status = LoadStatus.failed;
    }
    notifyIfAlive();
  }

  /// Blocks [member]. Throws when it could not be sent.
  Future<void> block(SocialUser member) async {
    await _repository.blockMember(member.id);
    _blocked = [member, ..._blocked.where((m) => m.id != member.id)];
    if (_status == LoadStatus.idle) _status = LoadStatus.ready;
    onChanged?.call(member.id, blocked: true);
    notifyIfAlive();
  }

  /// Unblocks [memberId]. Throws when it could not be sent.
  Future<void> unblock(String memberId) async {
    await _repository.unblockMember(memberId);
    _blocked = [
      for (final m in _blocked)
        if (m.id != memberId) m,
    ];
    onChanged?.call(memberId, blocked: false);
    notifyIfAlive();
  }
}
