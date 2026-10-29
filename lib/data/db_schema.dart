abstract final class Db {
  static const profiles = 'profiles';

  /// View over `profiles` with only the public columns (id, handle,
  /// display_name, avatar_url). Use it for any query that reads OTHER members;
  /// `profiles` itself is readable only for the signed-in user's own row.
  static const publicProfiles = 'public_profiles';

  /// What other members may see of a library: tracking fields plus catalog data
  /// in one row, without `purchase_price` or `achievements`.
  static const publicUserGames = 'public_user_games';

  /// Follow edges joined to the other member's public fields: `public_followers`
  /// are the members who follow `user_id`, `public_following` those they follow.
  static const publicFollowers = 'public_followers';
  static const publicFollowing = 'public_following';

  /// A member's play sessions (game, hours, platform, when) with the catalog data
  /// of the game. No notes.
  static const publicRecentActivity = 'public_recent_activity';

  /// Functions (called with `rpc`). Achievements of another member are only
  /// reachable through the last three; no table or view carries them.
  static const rpcProfileStats = 'public_profile_stats';
  static const rpcAchievementTotals = 'public_achievement_totals';
  static const rpcAchievementSummary = 'public_achievement_summary';
  static const rpcGameAchievements = 'public_game_achievements';

  /// The members the signed-in one follows who have a game, with their status
  /// and rating: the Friends panel on a game's screen.
  static const rpcFollowingGameActivity = 'following_game_activity';

  /// One page of the reviews of a game, from every member, and the game's
  /// community rating: the Reviews panel on a game's screen
  /// (20261022120000_game_reviews.sql).
  static const rpcGameReviews = 'game_reviews';
  static const rpcGameReviewStats = 'game_review_stats';

  /// The discussions (20261022165000_discussions.sql): boards, one page of
  /// threads, one thread, a page of its replies and the members the caller
  /// blocked are read through functions; a member deletes their own thread or
  /// reply with two more. Threads and replies are written by the `discussions`
  /// Edge Function only.
  static const rpcDiscussionBoards = 'discussion_boards_overview';
  static const rpcDiscussionThreads = 'discussion_threads_page';
  static const rpcDiscussionThread = 'discussion_thread';
  static const rpcDiscussionPosts = 'discussion_posts_page';
  static const rpcDeleteDiscussionThread = 'delete_discussion_thread';
  static const rpcDeleteDiscussionPost = 'delete_discussion_post';

  /// A member's report of a thread or a reply: own rows only.
  static const discussionReports = 'discussion_reports';
  static const threadId = 'thread_id';
  static const postId = 'post_id';

  /// A member blocking another one, for the whole app (20261028235500_moderation_and_blocking.sql):
  /// own rows only. [rpcMyBlockedMembers] lists the blocked members with their
  /// profile fields. The server leaves a blocked member's profile, library,
  /// activity, reviews, public lists and discussion posts out of every read.
  static const userBlocks = 'user_blocks';
  static const rpcMyBlockedMembers = 'my_blocked_members';
  static const blockerId = 'blocker_id';
  static const blockedId = 'blocked_id';

  /// A member's report of another's profile, photo or public list (`subject`:
  /// `profile`, `avatar` or `list`): write only, like the other report tables.
  static const userReports = 'user_reports';
  static const reportedId = 'reported_id';
  static const subject = 'subject';

  /// A member's report of another's review: write only
  /// (20261022120000_game_reviews.sql).
  static const reviewReports = 'review_reports';
  static const reviewUserId = 'review_user_id';
  static const reason = 'reason';

  /// The newest sessions, completions and ratings of the members the signed-in
  /// one follows: "From people you follow" on Home.
  static const rpcFollowingRecentActivity = 'following_recent_activity';

  /// Take one game out of the signed-in member's library with its play sessions,
  /// or empty the whole library: each in one transaction, so a failure part way
  /// can't keep the game and lose its sessions.
  static const rpcRemoveLibraryGame = 'remove_library_game';
  static const rpcClearLibrary = 'clear_library';

  /// Per category of one game: the median of the members' completion times and
  /// how many there are (`category`, `median_minutes`, `submissions`).
  static const rpcCompletionTimeStats = 'completion_time_stats';

  /// Records every milestone the signed-in member has reached and returns the
  /// new ones (`milestone_id`, `unlocked_at`). Takes the device's
  /// `utc_offset_minutes`, for streaks (20261020120100_milestones.sql).
  static const rpcAwardMilestones = 'award_milestones';

  /// The milestones each member has earned (`user_id`, `milestone_id`,
  /// `unlocked_at`), readable by every signed-in member; written only by
  /// [rpcAwardMilestones].
  static const userMilestones = 'user_milestones';
  static const milestoneId = 'milestone_id';
  static const unlockedAt = 'unlocked_at';

  static const games = 'games';
  static const userGames = 'user_games';
  static const logEntries = 'log_entries';
  static const socialFollows = 'social_follows';

  static const id = 'id';
  static const createdAt = 'created_at';
  static const updatedAt = 'updated_at';

  static const handle = 'handle';
  static const email = 'email';
  static const displayName = 'display_name';
  static const bio = 'bio';
  static const avatarUrl = 'avatar_url';
  static const steamId = 'steam_id';

  /// `public_profiles` only: whether a Steam ID is set.
  static const steamConnected = 'steam_connected';

  /// Names of the services connected besides Steam (`psn`, `xbox`, `nintendo`,
  /// `discord`, `instagram`, `twitch`). Readable in `public_profiles` and
  /// writable on your own `profiles` row.
  static const connectedServices = 'connected_services';

  /// The account names behind the services: PSN id, Xbox gamertag, Discord,
  /// Instagram and Twitch usernames. Public to signed-in members (the profile
  /// links open them).
  static const psnId = 'psn_id';
  static const xboxId = 'xbox_id';
  static const discordId = 'discord_id';
  static const instagramId = 'instagram_id';
  static const twitchId = 'twitch_id';

  /// `public_profiles` only: `profiles.created_at`, the member's join date.
  static const joinedAt = 'joined_at';

  /// `public_profiles` only: how many games the member has, how many members
  /// follow them, and whether the signed-in member is one of those.
  static const gamesCount = 'games_count';
  static const followersCount = 'followers_count';
  static const viewerFollows = 'viewer_follows';

  /// Whether other members may see the member's Steam achievements (Settings >
  /// Privacy). Written on your own `profiles` row, readable in `public_profiles`.
  static const showSteamAchievements = 'show_steam_achievements';

  /// What the member shows off: a frame id, the milestone whose title shows
  /// under their name, and up to three milestones. Written on your own
  /// `profiles` row (a trigger refuses what you haven't unlocked), readable in
  /// `public_profiles`; the follower lists have the frame and the showcase.
  static const avatarFrame = 'avatar_frame';
  static const titleMilestone = 'title_milestone';
  static const showcasedMilestones = 'showcased_milestones';

  static const weeklyGoalHours = 'weekly_goal_hours';

  static const igdbId = 'igdb_id';
  static const steamAppId = 'steam_app_id';
  static const slug = 'slug';
  static const title = 'title';
  static const publisher = 'publisher';
  static const developer = 'developer';
  static const releaseYear = 'release_year';
  static const platforms = 'platforms';
  static const genres = 'genres';
  static const summary = 'summary';
  static const coverUrl = 'cover_url';
  static const createdBy = 'created_by';

  /// When `igdb-handler` last filled the row in from IGDB; NULL: never.
  static const igdbSyncedAt = 'igdb_synced_at';

  /// What `igdb-handler` keeps of a game besides `platforms` and `genres`: text
  /// arrays on `games`, empty until the row was filled in.
  static const developers = 'developers';
  static const publishers = 'publishers';
  static const themes = 'themes';
  static const gameModes = 'game_modes';
  static const playerPerspectives = 'player_perspectives';
  static const gameEngines = 'game_engines';

  static const userId = 'user_id';
  static const gameId = 'game_id';
  static const status = 'status';
  static const rating = 'rating';
  static const hoursPlayed = 'hours_played';
  static const playedOn = 'played_on';
  static const purchasePrice = 'purchase_price';
  static const dateAdded = 'date_added';

  static const loggedAt = 'logged_at';
  static const hours = 'hours';
  static const platform = 'platform';
  static const note = 'note';

  /// `log_entries`: NULL for a session the member logged, `steam` for one the
  /// Steam sync logged from a rise in playtime.
  static const source = 'source';
  static const isFavorite = 'is_favorite';

  /// `user_games` (and `public_user_games`): the member's own backdrop for the
  /// game, an IGDB image URL; NULL: the blurred cover.
  static const customBackdropUrl = 'custom_backdrop_url';

  /// `user_games`: when the member last marked the game completed (kept by a
  /// trigger; the app never sends it), and their review (at most
  /// [reviewMaxLength] characters, '' = none). Both are in `public_user_games`.
  /// When the review was written (`reviewed_at`, also kept by a trigger) comes
  /// with [rpcGameReviews] only.
  static const completedAt = 'completed_at';
  static const review = 'review';
  static const reviewedAt = 'reviewed_at';

  /// `user_games`: a completed game the member still plays, listed under
  /// Playing too. Cleared by the same trigger whenever the status isn't
  /// completed. Not in `public_user_games`.
  static const stillPlaying = 'still_playing';

  /// `user_games` (and `public_user_games`): the member got everything out of
  /// the game, a Platinum trophy, every achievement or 100% (`PerfectMark`).
  static const perfected = 'perfected';
  static const reviewMaxLength = 2000;

  /// `games`: the day the game first came out, from IGDB; NULL when unknown.
  static const releaseDate = 'release_date';

  /// How long each member took to finish a game in their library, at most one
  /// per member and game (20261019221500_completion_times.sql). Readable for
  /// your own rows only; [rpcCompletionTimeStats] sums up everyone's.
  static const completionTimes = 'completion_times';

  /// `completion_times`: `main`, `main_extra` or `completionist`
  /// (`CompletionCategory.wire`), and the time in whole minutes.
  static const category = 'category';
  static const minutes = 'minutes';

  /// A member's lists of games and their games (20261019115300_game_lists.sql).
  static const gameLists = 'game_lists';
  static const gameListItems = 'game_list_items';
  static const listId = 'list_id';
  static const description = 'description';
  static const isPublic = 'is_public';
  static const position = 'position';

  static const followerId = 'follower_id';
  static const followeeId = 'followee_id';

  /// `public_followers` / `public_following`: when the follow happened.
  static const followedAt = 'followed_at';
}