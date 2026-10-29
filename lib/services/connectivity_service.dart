import 'package:connectivity_plus/connectivity_plus.dart';

/// Whether the device has a network connection. It reports the interface, not
/// that Gamebit's server is reachable, so a "connected" answer is a reason to
/// try again, not proof the next request will work.
class ConnectivityService {
  ConnectivityService([Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  /// Emits `true` when a connection appears and `false` when the last one goes.
  Stream<bool> get onlineChanges => _connectivity.onConnectivityChanged
      .map(_isOnline)
      .distinct();

  static bool _isOnline(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);
}
