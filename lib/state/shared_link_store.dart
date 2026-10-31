import 'package:flutter/foundation.dart';

import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/share_link.dart';
import 'package:checkpoint/services/checkpoint_repository.dart';

/// A shared link the app was opened with (the web app: `.../#/game/1942`),
/// until the app shell has opened what it points at, and the games such links
/// brought in, so the game screen finds them.
class SharedLinkStore extends ChangeNotifier {
  SharedLinkStore({required this._repository, LinkTarget? initial}) : _pending = initial;

  final CheckpointRepository _repository;
  LinkTarget? _pending;
  final Map<String, Game> _games = {};

  /// What is still to be opened.
  LinkTarget? get pending => _pending;

  /// Something to open that didn't come with the app's address: a tapped
  /// notification. The app shell opens it like a link.
  void open(LinkTarget target) {
    _pending = target;
    notifyListeners();
  }

  /// Done with [pending] (opened, or found to point at nothing).
  void clear() {
    if (_pending == null) return;
    _pending = null;
    notifyListeners();
  }

  /// A game a link brought in, by id.
  Game? gameById(String id) => _games[id];

  /// The catalog's game with [igdbId] (anyone may read the catalog), or null
  /// when it isn't there or can't be read now.
  Future<Game?> loadGame(int igdbId) async {
    try {
      final game = await _repository.fetchCatalogGame(igdbId);
      if (game != null) _games[game.id] = game;
      return game;
    } catch (e, st) {
      debugPrint('Opening the shared game failed: $e\n$st');
      return null;
    }
  }
}
