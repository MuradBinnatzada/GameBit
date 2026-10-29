part of '../checkpoint_repository.dart';

/// What the members wrote about a game and how they rated it.
mixin _ReviewQueries on _RepositoryBase {
  /// One page of the reviews of [gameId], from every member, in the order and
  /// narrowed as [filter] says; a full page means there may be another. One
  /// request, paged by [offset]. Empty without a session.
  Future<ResultsPage<GameReview>> fetchGameReviews(
    String gameId, {
    ReviewFilter filter = ReviewFilter.standard,
    int offset = 0,
    int limit = CheckpointRepository.reviewsPageSize,
  }) async {
    final data = await _client.rpc(
      Db.rpcGameReviews,
      params: {
        'target_game': gameId,
        'only_following': filter.onlyFollowing,
        'sort_by': filter.sort.wireName,
        'page_size': limit,
        'page_offset': offset,
      },
    );
    if (data is! List) return ResultsPage(const [], hasMore: false);
    final reviews = <GameReview>[];
    for (final raw in data) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final text = _firstText([row[Db.review]]);
      if (text == null) continue;
      reviews.add(
        GameReview(
          member: _socialUserFromProfile(row),
          text: text,
          status: gameStatusFromDb(row[Db.status]),
          rating: _double(row[Db.rating]),
          hours: _double(row[Db.hoursPlayed]),
          writtenAt: _date(row[Db.reviewedAt]),
          isFollowing: row['is_following'] == true,
        ),
      );
    }
    return ResultsPage(
      List.unmodifiable(reviews),
      hasMore: data.length >= limit,
      fetched: data.length,
    );
  }

  /// How the members rated [gameId]: how many did, the average, how many wrote
  /// a review and how many gave each half star. One request, counted in the
  /// database. Empty without a session.
  Future<CommunityRatings> fetchReviewStats(String gameId) async {
    final data = await _client.rpc(
      Db.rpcGameReviewStats,
      params: {'target_game': gameId},
    );
    return CommunityRatings.fromRow(data is List && data.isNotEmpty ? data.first : null) ??
        const CommunityRatings();
  }
}
