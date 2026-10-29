import 'dart:async';
import 'dart:math' as math;

import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:checkpoint/data/db_schema.dart';
import 'package:checkpoint/l10n/l10n.dart';
import 'package:checkpoint/models/achievement.dart';
import 'package:checkpoint/models/achievement_summary.dart';
import 'package:checkpoint/models/activity_entry.dart';
import 'package:checkpoint/models/completion_time.dart';
import 'package:checkpoint/models/connected_service.dart';
import 'package:checkpoint/models/discussion.dart';
import 'package:checkpoint/models/friend_activity.dart';
import 'package:checkpoint/models/game.dart';
import 'package:checkpoint/models/game_attributes.dart';
import 'package:checkpoint/models/game_cover.dart';
import 'package:checkpoint/models/game_friends.dart';
import 'package:checkpoint/models/game_list.dart';
import 'package:checkpoint/models/game_reviews.dart';
import 'package:checkpoint/models/library_stats.dart';
import 'package:checkpoint/models/log_entry.dart';
import 'package:checkpoint/models/milestone.dart';
import 'package:checkpoint/models/public_profile.dart';
import 'package:checkpoint/models/results_page.dart';
import 'package:checkpoint/models/social_user.dart';
import 'package:checkpoint/models/user_profile.dart';

part 'repository/profile_queries.dart';
part 'repository/library_queries.dart';
part 'repository/progress_queries.dart';
part 'repository/social_queries.dart';
part 'repository/public_member_queries.dart';
part 'repository/review_queries.dart';
part 'repository/discussion_queries.dart';
part 'repository/moderation_queries.dart';
part 'repository/list_queries.dart';
part 'repository/row_mappers.dart';

/// `user_games.achievements`, added by 20261016120000_unify_game_ids_on_igdb_id.sql.
/// (20261012120000_add_achievements_to_user_games.sql holds the steam_id migration
/// by mistake, so it never created this column.)
/// Only read through [CheckpointRepository.fetchGameAchievements]; the library
/// queries leave it out on purpose.
/// Move into `Db` in data/db_schema.dart if you'd rather keep column names there.
const _achievementsColumn = 'achievements';

/// Rows per request for the paged reads below ([_readAllPages]). It has to stay
/// under the API's row cap (`max_rows` in supabase/config.toml and in the
/// project's API settings, 1000 by default): a request for more is silently cut
/// to the cap, and a library past it would load incomplete.
const int _pageSize = 500;

/// The catalog columns of a game, as `games`, `public_user_games` and
/// `public_recent_activity` all have them.
final List<String> _catalogColumns = [
  Db.igdbId,
  Db.steamAppId,
  Db.title,
  Db.publisher,
  Db.developer,
  Db.releaseYear,
  Db.platforms,
  Db.genres,
  Db.summary,
  Db.coverUrl,
];

/// The app's language for an Edge Function that translates what it sends
/// (`lang`); nothing for English, which is what they send anyway.
Map<String, String> get _language =>
    L10n.languageCode == 'en' ? const {} : {'lang': L10n.languageCode};

/// Columns of a member row: `public_profiles`, `public_followers` and
/// `public_following` all have them, under the same names.
const String _memberColumns =
    'id, handle, display_name, avatar_url, ${Db.avatarFrame}, ${Db.showcasedMilestones}';

/// [_memberColumns] plus the counts under each member in the Users tab; only
/// `public_profiles` has them (20261018180000_member_list_counts.sql).
const String _memberWithCountsColumns =
    '$_memberColumns, ${Db.gamesCount}, ${Db.followersCount}, ${Db.viewerFollows}';

/// Orders games by when they were added, the newest first, those with no date last.
int _newestFirst(Game a, Game b) {
  final x = a.dateAdded;
  final y = b.dateAdded;
  if (x == null || y == null) {
    return x == null ? (y == null ? 0 : 1) : -1;
  }
  return y.compareTo(x);
}

/// What every group of queries needs: the Supabase client and a few helpers.
abstract class _RepositoryBase {
  _RepositoryBase(this._client);

  final SupabaseClient _client;

  String _requireUserId() {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw StateError('Not signed in.');
    return id;
  }

  /// Reads every row a query matches. [readPage] must return the page of up to
  /// [_pageSize] rows that follows the cursor `after` (null for the first page),
  /// ordered by [cursorColumn], a column whose values are unique within the query.
  /// Stops at the first page that comes back short.
  Future<List<Map<String, dynamic>>> _readAllPages(
    String cursorColumn,
    Future<List<Map<String, dynamic>>> Function(Object? after) readPage,
  ) async {
    final all = <Map<String, dynamic>>[];
    Object? after;
    while (true) {
      final rows = await readPage(after);
      all.addAll(rows);
      if (rows.length < _pageSize) return all;
      after = rows.last[cursorColumn];
      if (after == null) return all; // can't continue without a cursor
    }
  }
}

/// Everything the app reads from and writes to the database, as one object the
/// stores are given (and the tests replace). The queries are grouped by what they
/// are about, one file each in `repository/`: a place to add what a feature needs
/// (a limit, an entitlement check) beside the queries it concerns, not across a
/// 2000-line class. Each group is a mixin of this class, so the interface the
/// stores and fakes see is unchanged.
class CheckpointRepository extends _RepositoryBase
    with
        _ProfileQueries,
        _LibraryQueries,
        _ProgressQueries,
        _SocialQueries,
        _PublicMemberQueries,
        _ReviewQueries,
        _DiscussionQueries,
        _ModerationQueries,
        _ListQueries {
  CheckpointRepository(super._client);

  /// Followers and following per request.
  static const int followListPageSize = 30;

  /// Favorites on a profile: the app lets a member pick four.
  static const int publicFavoritesLimit = 4;

  /// Recent sessions on a profile.
  static const int publicActivityLimit = 4;

  /// Members per status the Friends panel of a game's screen is sent; the
  /// counts cover all of them.
  static const int friendsPerStatus = 20;

  /// Reviews per page of a game's reviews.
  static const int reviewsPageSize = 20;

  /// Threads per page of a board, and replies per page of a thread.
  static const int discussionThreadsPageSize = 20;

  static const int discussionPostsPageSize = 30;

  /// Items of "From people you follow" on Home. The server caps it at 100.
  static const int friendsFeedLimit = 30;
}
