import 'dart:async';

import 'package:checkpoint/models/admin_moderation.dart';
import 'package:checkpoint/services/admin_api_service.dart';
import 'package:checkpoint/services/admin_failure.dart';
import 'package:checkpoint/state/account_scoped_store.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/load_status.dart';

/// Moderating from the app, for the members who may (`moderation.admins`): the
/// open reports, the suspended members, and suspending, reinstating and closing
/// reports through the `admin-moderation` Edge Function.
///
/// [isAdmin] only decides whether the app shows its admin screens: the function
/// asks the database again on every request. Everything is a live question kept
/// in memory and dropped when the account changes; nothing is asked for a member
/// who is not an admin, or signed out.
class AdminStore extends AccountScopedStore {
  AdminStore({required AuthStore auth, AdminApiService? api})
    : _api = api ?? AdminApiService(),
      super(auth);

  final AdminApiService _api;

  bool _isAdmin = false;

  LoadStatus _reportsStatus = LoadStatus.idle;
  List<AdminReport> _reports = const [];
  AdminFailure? _reportsFailure;

  LoadStatus _suspendedStatus = LoadStatus.idle;
  List<SuspendedMember> _suspended = const [];
  AdminFailure? _suspendedFailure;

  /// Whether the signed-in member is an admin, as far as the app has asked.
  bool get isAdmin => _isAdmin;

  /// Of the queue: idle until [loadReports] is first called.
  LoadStatus get reportsStatus => _reportsStatus;

  /// The open reports, oldest first.
  List<AdminReport> get reports => _reports;

  /// Why the queue could not be read, while [reportsStatus] is failed.
  AdminFailure? get reportsFailure => _reportsFailure;

  /// Of the suspended list: idle until [loadSuspended] is first called.
  LoadStatus get suspendedStatus => _suspendedStatus;

  /// The members suspended right now, the newest suspension first.
  List<SuspendedMember> get suspended => _suspended;

  AdminFailure? get suspendedFailure => _suspendedFailure;

  @override
  void initialize() {
    super.initialize();
    unawaited(checkAdmin());
  }

  @override
  void resetForAccount() {
    _isAdmin = false;
    _reportsStatus = LoadStatus.idle;
    _reports = const [];
    _reportsFailure = null;
    _suspendedStatus = LoadStatus.idle;
    _suspended = const [];
    _suspendedFailure = null;
    // A new account: ask again once the reset is done.
    if (accountId != null) unawaited(Future.microtask(checkAdmin));
  }

  /// Asks whether the signed-in member is an admin. Does nothing when signed out.
  Future<void> checkAdmin() async {
    if (accountId == null) return;
    final epoch = this.epoch;
    final admin = await _api.isAdmin();
    if (isStale(epoch) || admin == _isAdmin) return;
    _isAdmin = admin;
    notifyIfAlive();
  }

  /// Reads the open reports. The queue on screen stays if a refresh fails.
  Future<void> loadReports() async {
    if (!_isAdmin) return;
    final epoch = this.epoch;
    if (_reportsStatus != LoadStatus.ready) {
      _reportsStatus = LoadStatus.loading;
      notifyIfAlive();
    }
    try {
      final reports = await _api.reports();
      if (isStale(epoch)) return;
      _reports = List.unmodifiable(reports);
      _reportsStatus = LoadStatus.ready;
      _reportsFailure = null;
    } catch (e) {
      if (isStale(epoch)) return;
      _reportsFailure = AdminFailure.from(e);
      if (_reportsStatus != LoadStatus.ready) {
        _reportsStatus = LoadStatus.failed;
      }
    }
    notifyIfAlive();
  }

  /// Reads the suspended members. The list on screen stays if a refresh fails.
  Future<void> loadSuspended() async {
    if (!_isAdmin) return;
    final epoch = this.epoch;
    if (_suspendedStatus != LoadStatus.ready) {
      _suspendedStatus = LoadStatus.loading;
      notifyIfAlive();
    }
    try {
      final members = await _api.suspended();
      if (isStale(epoch)) return;
      _suspended = List.unmodifiable(members);
      _suspendedStatus = LoadStatus.ready;
      _suspendedFailure = null;
    } catch (e) {
      if (isStale(epoch)) return;
      _suspendedFailure = AdminFailure.from(e);
      if (_suspendedStatus != LoadStatus.ready) {
        _suspendedStatus = LoadStatus.failed;
      }
    }
    notifyIfAlive();
  }

  /// Suspends [memberId] for [days] days (null: until reinstated). The server
  /// closes the open reports about them. Throws an [AdminFailure] when it could
  /// not be done, and then changes nothing.
  Future<void> suspend({
    required String memberId,
    required String reason,
    int? days,
  }) async {
    final epoch = this.epoch;
    await _api.suspend(memberId: memberId, reason: reason, days: days);
    if (isStale(epoch)) return;
    _reports = List.unmodifiable(
      _reports.where((r) => r.member.id != memberId),
    );
    notifyIfAlive();
    // They now belong in the suspended list, which only the server can tell.
    if (_suspendedStatus == LoadStatus.ready) unawaited(loadSuspended());
  }

  /// Lifts the suspension of [memberId]. Throws an [AdminFailure] when it could
  /// not be done.
  Future<void> reinstate(String memberId) async {
    final epoch = this.epoch;
    await _api.reinstate(memberId);
    if (isStale(epoch)) return;
    _suspended = List.unmodifiable(
      _suspended.where((s) => s.member.id != memberId),
    );
    notifyIfAlive();
    // Reports about them no longer say "suspended".
    if (_reportsStatus == LoadStatus.ready) unawaited(loadReports());
  }

  /// Takes down what [report] is about (see [AdminApiService.removeContent]), and
  /// takes it, and any other report of the same thing, off the queue. Throws an
  /// [AdminFailure] when it could not be done; when it was gone already the queue
  /// is read again, since it is out of date.
  Future<void> removeContent(AdminReport report) async {
    final epoch = this.epoch;
    try {
      await _api.removeContent(
        kind: report.source,
        memberId: report.member.id,
        reference: report.reference,
      );
    } on AdminFailure catch (e) {
      if (e.code == AdminFailureCode.notFound && !isStale(epoch)) {
        unawaited(loadReports());
      }
      rethrow;
    }
    if (isStale(epoch)) return;
    _reports = List.unmodifiable(
      _reports.where(
        (r) =>
            r.source != report.source ||
            r.member.id != report.member.id ||
            r.reference != report.reference,
      ),
    );
    notifyIfAlive();
  }

  /// Closes the open reports about [memberId]: [dismissed] when nothing was
  /// wrong, otherwise as actioned. Throws an [AdminFailure] when it could not be
  /// done.
  Future<void> closeReports(String memberId, {required bool dismissed}) async {
    final epoch = this.epoch;
    await _api.closeReports(memberId, dismissed: dismissed);
    if (isStale(epoch)) return;
    _reports = List.unmodifiable(
      _reports.where((r) => r.member.id != memberId),
    );
    notifyIfAlive();
  }
}
