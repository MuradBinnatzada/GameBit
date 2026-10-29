/**
 * sync-steam — bulk Steam → Supabase library sync.
 *
 * POST (no body needed). The caller is identified by their Supabase JWT, and
 * their Steam ID64 is read from `profiles.steam_id` for that user. A `steam_id`
 * sent in the request body is ignored.
 *
 * Pipeline (all heavy lifting server-side, no per-game round trips):
 *   0. Profile     look up the caller's `profiles.steam_id`
 *   1. Steam       fetch owned games, drop software junk and test/beta/server
 *                  builds, keep each game's Steam app id
 *   2. Known apps  which of those apps does the catalog already know? A `games`
 *                  row with the app id in `steam_app_id` and an `igdb_id` is
 *                  resolved. A row with an app id but no `igdb_id` is a legacy
 *                  Steam-keyed row (adopted in step 5).
 *                  IGDB's own Steam links (`/external_games`, source Steam, uid =
 *                  app id) are read for every app. A known app whose game is not
 *                  among its links was matched wrongly by title before: it is
 *                  resolved again (step 3) and moved (step 5).
 *   3. IGDB        IGDB's Steam links resolve an unresolved app exactly
 *                  (`resolveBySteamLinks`); a title can name several games, an
 *                  app id names one. Only apps IGDB has no link for go on to the
 *                  multi-pass title match (`resolveMissingGames`). The Steam
 *                  title is cleaned first (™/®, edition + "Test Server"/"Open
 *                  Beta" junk), then:
 *                    Pass 1  cleaned title  → bulk case-insensitive exact match,
 *                                             then a fuzzy search
 *                    Pass 2  publisher prefix stripped ("Tom Clancy's ", "Sid Meier's ")
 *                    Pass 3  primary title only (text before ":" / " - ": "ARK", "PUBG")
 *                  Every IGDB hit is validated against the Steam title; the top
 *                  search hit is never accepted blindly.
 *                  Fuzzy searches are one `/games` request per term. They must
 *                  NOT go through `/multiquery`: IGDB answers a `search` block
 *                  there with bare ids (or nothing), so no hit has a name to validate.
 *   4. Base games  bulk insert the games the catalog doesn't have yet. A game's id
 *                  is derived from its IGDB id (`igdbGameUuid`), the same id the
 *                  app's search uses, so a game is one row however it was added.
 *   5. Link        `relink_steam_apps` (database function) moves a wrongly matched
 *                  app to its right game and this user's library row with it, and
 *                  records the move so other owners' next syncs move theirs.
 *                  `link_steam_apps` records every other Steam app on its game and
 *                  folds any legacy Steam-keyed row into it, for every user at
 *                  once. This is what merges the old duplicates.
 *   6. Library     bulk upsert `user_games`, one row per game (new rows get
 *                  defaults; existing rows only ever get a higher `hours_played`)
 *                  and log a play session for every library game Steam reports
 *                  more playtime for than at the last sync (`steam_playtime_minutes`,
 *                  _shared/steam_sessions.ts)
 *   7. Achievements count the achievements of every game played since it was
 *                  last counted (ISteamUserStats/GetPlayerAchievements, one small
 *                  request per game, a few at a time, most recently played first)
 *                  into `achievements_unlocked` / `achievements_total`, so profiles
 *                  can list every game's progress (`set_achievement_counts`). Has a
 *                  budget of games and time; what is left is counted on the next
 *                  sync. Never fails the sync.
 *
 * Response: `{ success: true, delayed, summary, … }` on success. `delayed` is null
 * for a complete sync, or `{ code, message, retry_after, deferred }` when IGDB
 * rate limiting / downtime left some games unmatched (the rest of the sync is
 * saved; they are matched on a later one). A failed sync is
 * `{ error, code, retry_after? }` with a matching HTTP status and `Retry-After`
 * header; see `ErrorCode` for the codes.
 *
 * Rate limits: a 429 from Steam, IGDB or Twitch is retried with exponential backoff
 * and jitter (_shared/backoff.ts), honouring `Retry-After` when it is short enough.
 * A limit that outlasts the retries is reported (`STEAM_RATE_LIMITED`,
 * `IGDB_RATE_LIMITED` + `retry_after`), or for IGDB leaves the rest of the games for
 * the next sync (`delayed`).
 *
 * Background mode: a request carrying the `x-cron-secret` header (pg_cron, through
 * `invoke_steam_background_sync`) does not sync the caller. It refreshes the libraries
 * of the users `steam_sync_due` returns: ones who synced by hand before, were active
 * lately and whose `steam_sync_state.next_attempt_at` has passed. Answers
 * `{ success: true, background: { due, synced, delayed, failed, stopped } }`.
 * Each successful sync, manual or background, is recorded in `steam_sync_state`.
 *
 * Secrets (set with `supabase secrets set`):
 *   STEAM_API_KEY, TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET
 *   CRON_SECRET   only for the background run; the same value as the `cron_secret`
 *                 Vault secret the database sends (see 20261017130000_...)
 *   (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)
 *
 * Requires the 20261016120000_unify_game_ids_on_igdb_id.sql migration
 * (`games.igdb_id` unique, `games.steam_app_id`, `link_steam_apps`) and, for the
 * sync state and the background run, 20261017130000_background_steam_sync.sql
 * (a sync still works without it; it just is not recorded), and for step 7
 * 20261018160000_steam_achievement_counts.sql (without it the counts are skipped),
 * and for moving wrongly matched games 20261018200000_steam_app_relinks.sql (without
 * it they stay where they are).
 *
 * ── SCHEMA NOTES ──────────────────────────────────────────────────────────────
 * Column names follow checkpoint_repository.dart (`upsertBaseGame`,
 * `upsertUserGame`, `Db.*`). If a name in data/db_schema.dart differs from the
 * snake_case used here, fix it in `toGameRow` / `newUserGameRow`. The games'
 * cover colours and icon are computed in the app, not stored, so nothing is
 * written for them.
 */
import { createClient, type SupabaseClient } from "../_shared/supabase.ts"
import { type BackoffOptions, fetchWithBackoff, parseRetryAfter } from '../_shared/backoff.ts'
import { steamGamePlatformsToDb } from '../_shared/platforms.ts'
import {
  achievementCountTargets,
  type CountableApp,
  countFromPlayerAchievements,
  type CountResult,
  type CountTarget,
} from '../_shared/achievement_counts.ts'
import { failureDelayMs, shouldStopBatch, successDelayMs } from '../_shared/sync_schedule.ts'
import { type PlaytimeSeen, playtimeUpdates, steamSessionPlatform } from '../_shared/steam_sessions.ts'
import { releaseDate } from '../_shared/game_details.ts'
import {
  pickLinkedGame,
  type SourceField,
  STEAM_LINK_BATCH,
  steamLinksByApp,
  steamLinksQuery,
} from '../_shared/steam_links.ts'
import { withCors } from '../_shared/cors.ts'
import { secondFactorMissing } from '../_shared/mfa.ts'
import { RATE_LIMITS, rateLimitWait } from '../_shared/rate_limit.ts'

// ---- Tuning ----------------------------------------------------------------
const STEAM_UUID_PREFIX = '57e40000-0000-0000-0000-'
const DB_IN_CHUNK = 150          // ids per `.in()` query (keeps the PostgREST URL short)
const DB_WRITE_CHUNK = 1000      // rows per upsert call
const LINK_CHUNK = 100           // Steam apps per `link_steam_apps` call (each call is one transaction)
const IGDB_TITLE_BATCH = 50      // titles per bulk exact-name request
const IGDB_SEARCH_LIMIT = 30     // hits per fuzzy search (the real game can sit behind DLC / mods)
const IGDB_SEARCH_BUDGET = 300   // max fuzzy-search requests per sync, shared by passes 1b-3.
                                 // Games are searched most-played first; the rest wait for the next sync.
const IGDB_SEARCH_CONCURRENCY = 4 // searches in flight at once (IGDB allows 8 open requests)
const IGDB_MAX_CONSECUTIVE_FAILURES = 2 // stop the bulk exact pass early when IGDB keeps erroring
const IGDB_MAX_CONSECUTIVE_SEARCH_FAILURES = 5 // same for the search passes (one request per term)
const IGDB_PACING_MS = 260       // IGDB allows ~4 req/s: requests start at least this far apart
const IGDB_TIME_BUDGET_MS = 100_000 // stop *starting* fuzzy searches after this long, so the
                                    // sync always reaches its database writes before the
                                    // edge function's wall-clock limit (150 s on the free plan)
const PREFIX_MIN_RATIO = 0.8     // see `matchScore`
const LOOSE_MAX_EXTRA_WORDS = 3  // see `matchScore`

// ---- Rate-limit backoff ----------------------------------------------------
// A 429 is retried with exponential backoff (see _shared/backoff.ts) before it is
// reported. The waits are short on purpose: a sync has a wall-clock limit, and the
// consecutive-failure counters above already end a run once a limit sticks.
const STEAM_BACKOFF: BackoffOptions = { retries: 2, baseDelayMs: 1_500, maxDelayMs: 5_000, budgetMs: 8_000 }
// One achievement count is worth little on its own: a 429 gets one short retry, then
// the counting stops and the rest waits for the next sync.
const STEAM_COUNT_BACKOFF: BackoffOptions = { retries: 1, baseDelayMs: 1_000, maxDelayMs: 3_000, budgetMs: 3_000 }

// ---- Achievement counts (step 7) ---------------------------------------------
const ACHIEVEMENT_COUNT_CONCURRENCY = 6   // GetPlayerAchievements requests in flight at once
const ACHIEVEMENT_COUNT_TIMEOUT_MS = 8_000 // per request; a hung one must not hold the sync
const ACHIEVEMENT_COUNT_MAX_FAILURES = 5  // errors in a row (not rate limits) before giving up
const ACHIEVEMENT_COUNT_WRITE_CHUNK = 500 // games per `set_achievement_counts` call
const IGDB_BACKOFF: BackoffOptions = { retries: 3, baseDelayMs: 1_000, maxDelayMs: 6_000, budgetMs: 10_000 }

// ---- Background sync (cron) ------------------------------------------------
// pg_cron calls this function every few minutes with the CRON_SECRET (see
// 20261017130000_background_steam_sync.sql). Each call refreshes the library of the
// BACKGROUND_BATCH_SIZE most overdue users (`steam_sync_due`), one after the other.
const BACKGROUND_BATCH_SIZE = 10
const BACKGROUND_ACTIVE_DAYS = 30        // only users who used the app within this many days
const BACKGROUND_TIME_BUDGET_MS = 90_000 // stop *starting* users after this long (150 s limit)

/**
 * What one sync may spend on IGDB. A person waiting on a sync gets the whole
 * budget; a background sync is a top-up, so it spends little and leaves the
 * rest of the unmatched games to the next one.
 */
interface SyncLimits {
  igdbSearchBudget: number
  igdbTimeBudgetMs: number
  /** Most games whose achievements one sync counts (step 7). */
  achievementCountBudget: number
  /** Stop *starting* achievement counts this long after the sync began. */
  achievementDeadlineMs: number
}
const INTERACTIVE_LIMITS: SyncLimits = {
  igdbSearchBudget: IGDB_SEARCH_BUDGET,
  igdbTimeBudgetMs: IGDB_TIME_BUDGET_MS,
  achievementCountBudget: 400,
  achievementDeadlineMs: 125_000, // the IGDB passes end by ~100 s; 150 s is the limit
}
const BACKGROUND_LIMITS: SyncLimits = {
  igdbSearchBudget: 30,
  igdbTimeBudgetMs: 20_000,
  achievementCountBudget: 60,
  achievementDeadlineMs: 40_000,
}

/**
 * Columns of an existing user_games row that are never re-sent when we rewrite
 * it, because another feature owns them. `achievements` is a (potentially large)
 * JSONB blob written by sync-achievements: re-sending a stale copy could wipe a
 * concurrent load, and would ship the blob for nothing. The counts are written by
 * step 7 and by the trigger that keeps them in step with that blob.
 */
const NOT_RESENT_COLUMNS = [
  'achievements',
  'achievements_unlocked',
  'achievements_total',
  'achievements_playtime',
  'achievements_synced_at',
]

/**
 * Machine-readable failure codes. The app keys its messages and its "Sync Delayed"
 * state off `code`, never off the (human) `error` text. Keep in sync with
 * `SyncFailureCode` in lib/services/sync_failure.dart.
 *
 *   Retry later (`retry_after` seconds when known):
 *     STEAM_RATE_LIMITED, STEAM_UNAVAILABLE, IGDB_RATE_LIMITED, IGDB_UNAVAILABLE,
 *     SYNC_PARTIAL (success response only: some games wait for the next sync),
 *     RATE_LIMITED (this member synced too often by hand, _shared/rate_limit.ts)
 *   Needs the user:  UNAUTHENTICATED, MFA_REQUIRED (_shared/mfa.ts), NO_STEAM_ID,
 *                    STEAM_PROFILE_PRIVATE
 *   Needs the owner: NOT_CONFIGURED, STEAM_ERROR, IGDB_ERROR, INTERNAL
 */
type ErrorCode =
  | 'UNAUTHENTICATED'
  | 'MFA_REQUIRED'
  | 'NO_STEAM_ID'
  | 'STEAM_PROFILE_PRIVATE'
  | 'STEAM_RATE_LIMITED'
  | 'STEAM_UNAVAILABLE'
  | 'STEAM_ERROR'
  | 'IGDB_RATE_LIMITED'
  | 'IGDB_UNAVAILABLE'
  | 'IGDB_ERROR'
  | 'RATE_LIMITED'
  | 'NOT_CONFIGURED'
  | 'INTERNAL'

class HttpError extends Error {
  status: number
  code: ErrorCode
  retryAfter?: number // seconds
  constructor(status: number, code: ErrorCode, message: string, retryAfter?: number) {
    super(message)
    this.status = status
    this.code = code
    this.retryAfter = retryAfter
  }
}

const DEFAULT_RETRY_AFTER_S = 120

// ---- BEGIN PURE HELPERS ----------------------------------------------------

interface SteamGame {
  appid?: number
  name?: string
  playtime_forever?: number
  rtime_last_played?: number
  has_community_visible_stats?: boolean
}

interface SteamEntry {
  id: string // Steam-derived key (57e40000-…); also the id a legacy catalog row has
  appid: number
  title: string
  hours: number
  minutes: number // playtime_forever, for the achievement counts
  lastPlayed: number // rtime_last_played (UNIX seconds), 0 when unknown
  hasStats: boolean // has_community_visible_stats
}

interface IgdbGame {
  id: number
  name?: string
  cover?: { url?: string }
  first_release_date?: number
  platforms?: { id?: number; name?: string }[]
  genres?: { name?: string }[]
  summary?: string
  involved_companies?: { company?: { name?: string } }[]
  version_parent?: number | null
  total_rating_count?: number
}

const IGDB_FIELDS =
  'name, cover.url, first_release_date, platforms.id, platforms.name, genres.name, summary, involved_companies.company.name, version_parent, total_rating_count'

// Non-game software Steam lists alongside games. Word boundaries keep short
// terms like "obs" from matching titles such as "Observer". (No `g` flag: .test() stays stateless.)
const JUNK_RE = /\b(?:blender|wallpaper engine|soundpad|aseprite|obs|3dmark)\b/i

// Steam also lists test / beta / server / demo builds as separate apps next to the
// real game ("… - Test Server", "… Dedicated Server", "… Open Beta", "… Playtest",
// "… - Unstable", "… - Public Test", "…: Free Sample", "… Demo").
// They are not games, and matching them to the base game would add a duplicate
// row to the library, so they are dropped before any IGDB lookup. The patterns
// are deliberately narrow: a bare "Beta" or "Server" inside a longer word, or as
// the whole title ("Server"), is left alone.
const SERVER_BUILD_RE = new RegExp(
  [
    String.raw`\b(?:dedicated|test(?:ing)?|public\s+test|ptr|ptb|experimental|staging|beta)\s+server\b`,
    String.raw`[\s\-–—:(\[]server\s*[)\]]?$`, // "<Game> Server", "<Game> - Server"
  ].join('|'),
  'i',
)
const BETA_BUILD_RE = new RegExp(
  [
    String.raw`\b(?:open|closed|public|private|technical|stress)\s+beta\b`, // "Open Beta"
    String.raw`\bbeta\s+(?:test|build|branch|client)\b`, // "Beta Test"
    String.raw`[\s\-–—:(\[]beta\s*[)\]]?$`, // trailing "Beta" / "(Beta)" / "- Beta"
    String.raw`\bplaytest\b`,
  ].join('|'),
  'i',
)

// Public-test-realm / unstable-branch apps. A bare tag ("Unstable", "Test") only counts
// after a dash, colon or bracket, so real titles like "The Turing Test" or
// "Unstable Unicorns" are never touched.
const TEST_BUILD_RE = new RegExp(
  [
    String.raw`\bpublic\s+test\b`, // "For Honor - Public Test", "… Public Test Realm"
    String.raw`\btest\s+(?:realm|client|branch)\b`,
    String.raw`\bunstable\s+(?:branch|build)\b`,
    String.raw`[\-–—:(\[]\s*(?:unstable|experimental|testing|test|nightly|pts|ptr|ptb)\s*[)\]]?$`, // "Starbound - Unstable"
  ].join('|'),
  'i',
)

// Demo apps. Matching one to the base game would add a duplicate row, and it has no
// IGDB entry of its own. "Prologue" is NOT here: some standalone games use it.
const DEMO_BUILD_RE = new RegExp(
  [
    String.raw`\bfree\s+sample\b`, // "Schedule I: Free Sample"
    String.raw`\bdemo\s+(?:version|build)\b`,
    String.raw`[\s\-–—:(\[]\s*demo\s*[)\]]?$`, // "Foo Demo", "Foo - Demo", "Foo (Demo)"
  ].join('|'),
  'i',
)

/** True for a Steam app that is a test / beta / server / demo build rather than a game. (No `g` flag: stateless.) */
const isNonGameBuild = (title: string): boolean =>
  SERVER_BUILD_RE.test(title) ||
  BETA_BUILD_RE.test(title) ||
  TEST_BUILD_RE.test(title) ||
  DEMO_BUILD_RE.test(title)

const chunk = <T>(arr: T[], size: number): T[][] => {
  const out: T[][] = []
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size))
  return out
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

/** Quote a string for IGDB's Apicalypse query language. */
const quote = (s: string) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`

const steamUuid = (appid: number) => `${STEAM_UUID_PREFIX}${String(appid).padStart(12, '0')}`

/**
 * The `games.id` for an IGDB game: a pure function of its IGDB id, so Steam sync,
 * the app's search and the database (`igdb_game_uuid`, enforced by the
 * `games_id_matches_igdb_id` constraint) always agree. Must match `gameIdForIgdb`
 * in lib/models/game.dart.
 */
const igdbGameUuid = (igdbId: number) => `00000000-0000-4000-8000-${String(igdbId).padStart(12, '0')}`

// ---- Steam title cleanup so IGDB can match the base game (port of Dart) ----
const TRADEMARK_RE = /[™®©℠]/g
const COLON_NO_SPACE_RE = /:(?=\p{L})/gu
const APOSTROPHE_RE = /['’]/g

// "Title (Deluxe Edition)" / "Title [Director's Cut]"
const BRACKETED_EDITION_RE =
  /\s*[\(\[][^\)\]]*\b(?:edition|director['’]?s\s+cut)\b[^\)\]]*[\)\]]/gi

// "Title - Complete Edition"
const DASHED_EDITION_RE = /\s+[-–—]\s+[^-–—]*\b(?:edition|director['’]?s\s+cut)\b.*$/gi

// "Title - Remastered", "Title — Definitive": a qualifier after a spaced dash with no
// "Edition" behind it. Only after a dash: a bare trailing "Remastered" can be the real
// name ("Crysis Remastered" is its own IGDB entry), so that form is left alone.
const DASHED_QUALIFIER_RE = new RegExp(
  String.raw`\s+[-–—]\s+(?:remastered|remaster|reloaded|definitive|complete|deluxe|ultimate|enhanced|goty|game\s+of\s+the\s+year|anniversary)\s*$`,
  'i',
)

// "Title Special Edition", "Title: Game of the Year Edition", "Title: Reloaded Edition".
// Only these known qualifiers are stripped. A subtitle that merely ends in
// "Edition" ("The Elder Scrolls V: Skyrim Special Edition") must keep its subtitle.
const EDITION_QUALIFIERS = [
  String.raw`game\s+of\s+the\s+year`,
  'goty',
  String.raw`day\s+one`,
  'definitive',
  'complete',
  'enhanced',
  'deluxe',
  'ultimate',
  'super',
  'gold',
  'platinum',
  'special',
  'anniversary',
  String.raw`collector['’]?s`,
  String.raw`founder['’]?s`,
  'legendary',
  'standard',
  'premium',
  'extended',
  'expanded',
  'digital',
  'reloaded',
  'remastered',
  'remaster',
  'royal',
  'limited',
  'launch',
  'classic',
  'bonus',
  'steam',
  'pc',
].join('|')
const TRAILING_EDITION_RE = new RegExp(
  String.raw`\s*:?\s*(?:(?:${EDITION_QUALIFIERS})\s+)*(?:edition|director['’]?s\s+cut)\b.*$`,
  'gi',
)

// Steam junk strings left on a title: "(Open Beta)", "- Test Server", "Dedicated Server".
// Titles carrying them are normally dropped as non-games (`isNonGameBuild`); this
// strips them anyway so the cleaned title is never searched with them attached.
const JUNK_TAIL_RE = new RegExp(
  String.raw`\s*[-–—:]?\s*[(\[]?\s*\b(?:(?:public\s+)?test(?:ing)?\s+server|dedicated\s+server|(?:(?:open|closed|public|private|technical|stress)\s+)?beta(?:\s+test)?|playtest|server)\s*[)\]]?\s*$`,
  'i',
)

const SPACES_RE = /\s+/g
const DANGLING_RE = /[\s\-–—:]+$/g

/** Strips junk strings off the end of a title; repeated for "Foo - Test Server (Open Beta)". */
function stripJunkTail(s: string): string {
  let out = s
  for (let i = 0; i < 3; i++) {
    const next = out.replace(JUNK_TAIL_RE, '')
    if (next === out) break
    out = next
  }
  return out
}

function cleanSteamTitle(raw: string): string {
  const stripped = raw
    .replace(TRADEMARK_RE, '')
    .replace(COLON_NO_SPACE_RE, ': ')
    .replace(SPACES_RE, ' ')
    .trim()
  const cleaned = stripJunkTail(stripped)
    .replace(BRACKETED_EDITION_RE, '')
    .replace(DASHED_EDITION_RE, '')
    .replace(DASHED_QUALIFIER_RE, '')
    .replace(TRAILING_EDITION_RE, '')
    .replace(DANGLING_RE, '')
    .trim()
  // Never search for an empty string (e.g. a game literally named "Edition").
  return cleaned === '' ? stripped : cleaned
}

// ---- Pass 2 / Pass 3 search terms ------------------------------------------

// Possessive "author / publisher" prefixes that IGDB and Steam often disagree on.
// The possessive is required, so "Marvel Rivals" or "Disney Dreamlight Valley" are untouched.
const PUBLISHER_PREFIX_RE = new RegExp(
  String.raw`^(?:${[
    'tom clancy',
    'sid meier',
    'marvel',
    'disney',
    'clive barker',
    'stephen king',
    'peter jackson',
    'ken follett',
    'frank herbert',
    'terry pratchett',
    'michael crichton',
    'bram stoker',
  ].join('|')})['’]?s\s+`,
  'i',
)

/** Pass 2 term: "Tom Clancy's Rainbow Six Siege" -> "Rainbow Six Siege". Null when there is no prefix. */
function stripPublisherPrefix(title: string): string | null {
  const stripped = title.replace(PUBLISHER_PREFIX_RE, '').trim()
  return stripped !== title && stripped.length >= 3 ? stripped : null
}

// Colon, or a *spaced* dash. An in-word hyphen ("Half-Life", "Spider-Man", "Counter-Strike") is not a split point.
const SUBTITLE_SPLIT_RE = /\s*:\s*|\s+[-–—]\s+/

/** Pass 3 term: "ARK: Survival Evolved" -> "ARK". Null when there is no subtitle to drop. */
function primaryTitle(title: string): string | null {
  const head = (title.split(SUBTITLE_SPLIT_RE)[0] ?? '').trim()
  return head.length >= 2 && head.length < title.length ? head : null
}

// ---- Validating IGDB hits --------------------------------------------------

const COMBINING_MARKS_RE = /[̀-ͯ]/g
const LEADING_THE_RE = /^the /

/** Comparison key: case, punctuation, apostrophes, accents, ™/® and a leading "the" don't matter. */
function normalizeTitle(s: string): string {
  return s
    .replace(TRADEMARK_RE, '')
    .normalize('NFKD')
    .replace(COMBINING_MARKS_RE, '')
    .toLowerCase()
    .replace(APOSTROPHE_RE, '') // "Clancy's" -> "clancys", not "clancy s"
    .replace(/&/g, ' and ')
    .replace(/[^\p{L}\p{N}]+/gu, ' ') // "Need for Speed: Heat" == "Need for Speed Heat"
    .trim()
    .replace(LEADING_THE_RE, '')
}

// Sequel markers (2, VI, XIII…). A bare "X" is excluded: "Rainbow Six Siege X" is the same game.
const SEQUEL_TOKEN_RE = /^(?:\d+|i{1,3}|iv|vi{0,3}|ix|xi{1,3}|xiv|xvi{0,3}|xix|xx)$/
// Words that mean "this is something other than the base game".
const NON_BASE_TOKENS = new Set([
  'soundtrack', 'ost', 'dlc', 'demo', 'bundle', 'pack', 'artbook', 'expansion',
  'upgrade', 'sdk', 'editor', 'wallpaper', 'skin', 'skins',
])

/**
 * How well does an IGDB name match a Steam title? 0 = reject, 1 = same name.
 *   1      names are identical once case / punctuation / accents are ignored
 *   <1     one name is the other plus trailing words ("… Siege" vs "… Siege X"),
 *          accepted only when the shorter has 2+ words, makes up at least
 *          PREFIX_MIN_RATIO of the longer, and the extra words are not a sequel
 *          number or "soundtrack"/"dlc"/…. With the ratio at 0.8 a single extra
 *          word is tolerated only after 4+ shared words, so "Need for Speed
 *          Payback" can never resolve to "Need for Speed", nor "Far Cry 3 Blood
 *          Dragon" to "Far Cry 3".
 *   <0.4   loose tier: a *numbered* Steam title that IGDB has given a subtitle
 *          ("Dying Light 2" -> "Dying Light 2 Stay Human"). The Steam title must be
 *          the shorter side, end in a sequel number, and IGDB may add at most
 *          LOOSE_MAX_EXTRA_WORDS plain words. Always scores below the 0.8 tier, so it
 *          only wins when no better candidate is among the search results, and the
 *          candidate with the fewest extra words wins among loose ones.
 *   0      anything else
 */
function matchScore(title: string, candidate: string): number {
  const a = normalizeTitle(title)
  const b = normalizeTitle(candidate)
  if (!a || !b) return 0
  if (a === b) return 1

  const ta = a.split(' ')
  const tb = b.split(' ')
  const [short, long] = ta.length <= tb.length ? [ta, tb] : [tb, ta]
  if (short.length < 2 || !short.every((t, i) => t === long[i])) return 0
  const extra = long.slice(short.length)
  if (extra.some((t) => SEQUEL_TOKEN_RE.test(t) || NON_BASE_TOKENS.has(t))) return 0
  const ratio = short.length / long.length
  if (ratio >= PREFIX_MIN_RATIO) return ratio

  const steamIsShort = short === ta
  if (
    steamIsShort &&
    SEQUEL_TOKEN_RE.test(short[short.length - 1]) &&
    extra.length <= LOOSE_MAX_EXTRA_WORDS
  ) {
    return ratio / 2
  }
  return 0
}

/**
 * Choose the IGDB result for a Steam title, or null when none is trustworthy.
 * `targets` are the spellings the hit may match: the cleaned title, plus the
 * prefix-stripped one in Pass 2 (IGDB may list "Civilization VI" for Steam's
 * "Sid Meier's Civilization VI"). Test/beta/server entries are never accepted.
 * Best score wins; ties prefer a PC release, then one with a cover, then the one
 * more people rated (two games can share a name exactly: "Tomb Raider" is a 1996
 * game and its 2013 reboot) — so sequels can't override the original and the top
 * search hit is never taken blindly. Most games never get here: IGDB's own Steam
 * links resolve them first (`resolveBySteamLinks`).
 */
function pickBest(results: IgdbGame[], targets: string[]): IgdbGame | null {
  let best: IgdbGame | null = null
  let bestRank: number[] = []
  for (const g of results) {
    if (!g.name || isNonGameBuild(g.name)) continue
    const name = g.name
    const score = Math.max(...targets.map((t) => matchScore(t, name)))
    if (score === 0) continue
    const rank = [
      score,
      g.platforms?.some((p) => p.name?.includes('PC (Microsoft Windows)')) ? 1 : 0,
      g.cover?.url ? 1 : 0,
      g.total_rating_count ?? 0,
    ]
    if (!best || outranks(rank, bestRank)) {
      best = g
      bestRank = rank
    }
  }
  return best
}

/** Lexicographic: is rank `a` strictly better than rank `b`? */
function outranks(a: number[], b: number[]): boolean {
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return a[i] > b[i]
  }
  return false
}

/**
 * Junk-filter, dedupe, and translate Steam's list into our UUID format.
 * `nonGames` lists the test / beta / server builds that were dropped.
 */
function toSteamEntries(raw: SteamGame[]): {
  entries: SteamEntry[]
  junk: number
  nonGames: string[]
} {
  const byId = new Map<string, SteamEntry>()
  const nonGames: string[] = []
  let junk = 0
  for (const g of raw) {
    const title = (g.name ?? '').trim()
    if (!title || typeof g.appid !== 'number') continue
    if (JUNK_RE.test(title)) {
      junk++
      continue
    }
    if (isNonGameBuild(title)) {
      nonGames.push(title)
      continue
    }
    const id = steamUuid(g.appid)
    byId.set(id, {
      id,
      appid: g.appid,
      title,
      hours: Math.round(((g.playtime_forever ?? 0) / 60) * 100) / 100,
      minutes: Math.max(0, Math.round(g.playtime_forever ?? 0)),
      lastPlayed: typeof g.rtime_last_played === 'number' ? g.rtime_last_played : 0,
      hasStats: g.has_community_visible_stats === true,
    })
  }
  return { entries: [...byId.values()], junk, nonGames }
}

/** `games.release_year` must be NULL or 1950-2100 (`games_release_year_check`). */
function sanitizeReleaseYear(year: unknown): number | null {
  return typeof year === 'number' && Number.isInteger(year) && year >= 1950 && year <= 2100
    ? year
    : null
}

/**
 * IGDB `first_release_date` (UNIX seconds, UTC) -> 4-digit year, or null when the
 * value is missing, malformed, or falls outside 1950-2100.
 */
function releaseYearFromUnixSeconds(seconds: unknown): number | null {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds)) return null
  return sanitizeReleaseYear(new Date(seconds * 1000).getUTCFullYear())
}

/** Map an IGDB record to a `games` row. Column names live here. */
function toGameRow(g: IgdbGame): Record<string, unknown> {
  let coverUrl: string | null = null
  if (g.cover?.url) {
    const url = g.cover.url.startsWith('//') ? `https:${g.cover.url}` : g.cover.url
    coverUrl = url.replace('t_thumb', 't_cover_big')
  }
  const company = g.involved_companies?.[0]?.company?.name ?? 'Unknown Publisher'
  return {
    id: igdbGameUuid(g.id),
    igdb_id: g.id,
    title: g.name ?? 'Unknown',
    developer: company,
    publisher: company,
    release_year: releaseYearFromUnixSeconds(g.first_release_date),
    release_date: releaseDate(g.first_release_date),
    // Release platforms (never Steam Deck / Emulator, which are "played on" picks).
    platforms: steamGamePlatformsToDb(g.platforms),
    genres: (g.genres ?? []).map((x) => x.name).filter((n): n is string => !!n),
    summary: g.summary ?? '',
    cover_url: coverUrl,
  }
}

/** Defaults for a game the user doesn't have yet. Column names live here. */
function newUserGameRow(
  userId: string,
  gameId: string,
  hours: number,
  nowIso: string,
): Record<string, unknown> {
  return {
    user_id: userId,
    game_id: gameId,
    status: 'playing',
    played_on: 'pc',
    hours_played: hours,
    date_added: nowIso,
  }
}

// ---- END PURE HELPERS ------------------------------------------------------

// ---- Steam -----------------------------------------------------------------
async function fetchSteamGames(steamId: string): Promise<SteamGame[]> {
  const apiKey = Deno.env.get('STEAM_API_KEY')
  if (!apiKey) {
    console.error('STEAM_API_KEY is not set')
    throw new HttpError(500, 'NOT_CONFIGURED', 'Server is not configured')
  }

  const url = new URL('https://api.steampowered.com/IPlayerService/GetOwnedGames/v0001/')
  url.search = new URLSearchParams({
    key: apiKey,
    steamid: steamId,
    format: 'json',
    include_appinfo: 'true',
    include_played_free_games: 'true',
  }).toString()

  let res: Response
  try {
    res = await fetchWithBackoff(() => fetch(url), STEAM_BACKOFF)
  } catch {
    // Don't surface the raw fetch error: it embeds the request URL (and API key).
    throw new HttpError(503, 'STEAM_UNAVAILABLE', 'Could not reach Steam', DEFAULT_RETRY_AFTER_S)
  }
  if (res.status === 429) {
    throw new HttpError(
      429,
      'STEAM_RATE_LIMITED',
      'Steam is limiting requests right now',
      parseRetryAfter(res.headers.get('Retry-After'), 300),
    )
  }
  if (res.status >= 500) {
    throw new HttpError(
      503,
      'STEAM_UNAVAILABLE',
      `Steam is unavailable right now (${res.status})`,
      parseRetryAfter(res.headers.get('Retry-After')),
    )
  }
  if (!res.ok) throw new HttpError(502, 'STEAM_ERROR', `Steam API returned ${res.status}`)

  const data = await res.json().catch(() => null)
  const response = data?.response
  if (!response || typeof response !== 'object') {
    throw new HttpError(502, 'STEAM_ERROR', 'Steam returned an unreadable response')
  }
  // A public profile always carries `game_count` (0 for an empty library). A
  // private profile, or one with "Game details" hidden, comes back as `{}`: without
  // this check that read as an empty library and the sync "succeeded" with nothing.
  if (response.games === undefined && response.game_count === undefined) {
    throw new HttpError(
      403,
      'STEAM_PROFILE_PRIVATE',
      'Your Steam game details are private. Set "Game details" to Public in your Steam privacy settings, then try again.',
    )
  }
  return Array.isArray(response.games) ? response.games : []
}

// ---- IGDB ------------------------------------------------------------------
let igdbToken: { value: string; expiresAt: number } | null = null

async function getIgdbToken(): Promise<string> {
  if (igdbToken && Date.now() < igdbToken.expiresAt - 60_000) return igdbToken.value

  const clientId = Deno.env.get('TWITCH_CLIENT_ID')
  const clientSecret = Deno.env.get('TWITCH_CLIENT_SECRET')
  if (!clientId || !clientSecret) {
    console.error('TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET are not set')
    throw new HttpError(500, 'NOT_CONFIGURED', 'Server is not configured')
  }

  let res: Response
  try {
    res = await fetchWithBackoff(
      () =>
        fetch('https://id.twitch.tv/oauth2/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: clientId,
            client_secret: clientSecret,
            grant_type: 'client_credentials',
          }),
        }),
      IGDB_BACKOFF,
    )
  } catch {
    throw new HttpError(503, 'IGDB_UNAVAILABLE', 'Could not reach Twitch', DEFAULT_RETRY_AFTER_S)
  }
  if (!res.ok) throw igdbStatusError(res, 'Twitch auth')

  const data = await res.json().catch(() => null)
  if (typeof data?.access_token !== 'string') {
    throw new HttpError(502, 'IGDB_ERROR', 'Unexpected response from Twitch')
  }
  igdbToken = {
    value: data.access_token,
    expiresAt: Date.now() + (data.expires_in ?? 3600) * 1000,
  }
  return igdbToken.value
}

/** The error for a non-OK Twitch / IGDB reply: rate limited, down, or something we did wrong. */
function igdbStatusError(res: Response, what: string): HttpError {
  if (res.status === 429) {
    return new HttpError(
      429,
      'IGDB_RATE_LIMITED',
      `${what} is rate limited`,
      parseRetryAfter(res.headers.get('Retry-After'), 60),
    )
  }
  if (res.status >= 500) {
    return new HttpError(
      503,
      'IGDB_UNAVAILABLE',
      `${what} is unavailable (${res.status})`,
      parseRetryAfter(res.headers.get('Retry-After')),
    )
  }
  // 4xx other than 429 is our request or credentials being wrong, which no retry fixes.
  return new HttpError(502, 'IGDB_ERROR', `${what} failed (${res.status})`)
}

async function igdbFetch<T>(endpoint: string, body: string, attempt = 0): Promise<T> {
  const token = await getIgdbToken()
  let res: Response
  try {
    // A 429 is retried with backoff (IGDB_BACKOFF) before it is reported below.
    res = await fetchWithBackoff(
      () =>
        fetch(`https://api.igdb.com/v4/${endpoint}`, {
          method: 'POST',
          headers: {
            'Client-ID': Deno.env.get('TWITCH_CLIENT_ID')!,
            Authorization: `Bearer ${token}`,
            Accept: 'application/json',
          },
          body,
        }),
      IGDB_BACKOFF,
    )
  } catch {
    throw new HttpError(503, 'IGDB_UNAVAILABLE', 'Could not reach IGDB', DEFAULT_RETRY_AFTER_S)
  }

  if (res.status === 401 && attempt === 0) {
    igdbToken = null // token revoked/expired early: re-auth once
    return igdbFetch<T>(endpoint, body, 1)
  }
  if (!res.ok) throw igdbStatusError(res, `IGDB /${endpoint}`)
  return (await res.json()) as T
}

/** What went wrong with IGDB during one sync, for the response (see `syncLibrary`). */
interface SyncIssues {
  warnings: string[]
  igdb: HttpError | null // the first IGDB failure of this run
}

/** Record a warning once (a failing IGDB repeats the same message for every batch). */
const warn = (issues: SyncIssues, message: string, cause?: unknown) => {
  if (!issues.warnings.includes(message)) issues.warnings.push(message)
  if (cause instanceof HttpError && issues.igdb === null) issues.igdb = cause
}

/**
 * Exact-name lookup for a batch of titles. `~` is IGDB's case-insensitive equals,
 * which matters because Steam shouts ("FOR HONOR™", "PUBG: BATTLEGROUNDS") while
 * IGDB doesn't ("For Honor"). If IGDB rejects the OR-chained query for any reason,
 * retry once with the case-sensitive `= (...)` list form so the pass still works.
 */
async function igdbExactBatch(titles: string[]): Promise<IgdbGame[]> {
  try {
    const where = titles.map((t) => `name ~ ${quote(t)}`).join(' | ')
    return await igdbFetch<IgdbGame[]>('games', `fields ${IGDB_FIELDS}; where ${where}; limit 500;`)
  } catch (e) {
    console.warn('IGDB case-insensitive bulk lookup failed, retrying with "=":', e)
    return await igdbFetch<IgdbGame[]>(
      'games',
      `fields ${IGDB_FIELDS}; where name = (${titles.map(quote).join(',')}); limit 500;`,
    )
  }
}

/** Bulk exact lookup for many titles, indexed by normalized IGDB name. A failed batch is skipped, not fatal. */
async function igdbExactMany(titles: string[], issues: SyncIssues): Promise<Map<string, IgdbGame[]>> {
  const byName = new Map<string, IgdbGame[]>()
  let failures = 0
  for (const part of chunk(titles, IGDB_TITLE_BATCH)) {
    if (failures >= IGDB_MAX_CONSECUTIVE_FAILURES) break
    try {
      for (const g of await igdbExactBatch(part)) {
        if (!g.name) continue
        const key = normalizeTitle(g.name)
        const list = byName.get(key)
        if (list) list.push(g)
        else byName.set(key, [g])
      }
      failures = 0
    } catch (e) {
      failures++
      console.error('IGDB exact lookup failed:', e)
      warn(issues, `IGDB exact lookup incomplete: ${(e as Error).message}`, e)
    }
    await sleep(IGDB_PACING_MS)
  }
  return byName
}

/**
 * Fuzzy `search` for one term. This is a plain `/games` request on purpose:
 * inside `/multiquery` IGDB ignores `fields` for a `search` block and answers with
 * bare ids (or nothing), so there are no names to validate and every hit is lost.
 */
async function igdbSearchOne(term: string): Promise<IgdbGame[]> {
  return await igdbFetch<IgdbGame[]>(
    'games',
    `search ${quote(term)}; fields ${IGDB_FIELDS}; limit ${IGDB_SEARCH_LIMIT};`,
  )
}

/**
 * Fuzzy search for many terms: one request each, started at most every
 * IGDB_PACING_MS (so ~3.8 req/s across all workers) with up to
 * IGDB_SEARCH_CONCURRENCY in flight.
 *
 * `results` lines up with `terms`: an array (possibly empty) means the term was
 * searched; `undefined` means it was not (its request failed, or the run stopped
 * early), so the caller can leave it for the next sync instead of treating it as
 * "IGDB has nothing". A failed request never throws. The run stops early, with
 * `stopped: true`, after IGDB_MAX_CONSECUTIVE_SEARCH_FAILURES errors in a row or
 * once `deadline` has passed.
 */
async function igdbSearchMany(
  terms: string[],
  issues: SyncIssues,
  deadline: number,
): Promise<{ results: (IgdbGame[] | undefined)[]; stopped: boolean }> {
  const results: (IgdbGame[] | undefined)[] = terms.map(() => undefined)
  let next = 0
  let nextSlot = 0 // earliest time the next request may start
  let failures = 0
  let stopped = false

  const worker = async () => {
    while (!stopped && next < terms.length) {
      const i = next++
      if (Date.now() >= deadline) {
        stopped = true
        warn(issues, 'IGDB search stopped early (time budget); the rest will be matched on the next sync')
        return
      }
      // Reserve a start slot. JS is single-threaded, so this is race-free and keeps
      // request starts IGDB_PACING_MS apart no matter how many workers there are.
      const startAt = Math.max(Date.now(), nextSlot)
      nextSlot = startAt + IGDB_PACING_MS
      await sleep(startAt - Date.now())
      if (stopped) return
      try {
        results[i] = await igdbSearchOne(terms[i])
        failures = 0
      } catch (e) {
        failures++
        console.error('IGDB search failed:', e)
        warn(issues, `IGDB search incomplete: ${(e as Error).message}`, e)
        if (failures >= IGDB_MAX_CONSECUTIVE_SEARCH_FAILURES) stopped = true
      }
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(IGDB_SEARCH_CONCURRENCY, terms.length) }, worker),
  )
  return { results, stopped }
}

/**
 * IGDB's own Steam links for these apps: app id -> the IGDB game ids IGDB says the
 * app is (see _shared/steam_links.ts). One request per STEAM_LINK_BATCH apps. An app
 * missing from the answer has no link IGDB knows of, or sat in a batch that failed:
 * either way nothing is known about it, and it is matched by title as before. A
 * failure is recorded in `issues`, never thrown.
 */
async function igdbSteamLinks(appIds: number[], issues: SyncIssues): Promise<Map<number, number[]>> {
  const byApp = new Map<number, number[]>()
  let field: SourceField = 'external_game_source'
  let failures = 0
  for (const part of chunk(appIds, STEAM_LINK_BATCH)) {
    if (failures >= IGDB_MAX_CONSECUTIVE_FAILURES) break
    try {
      let rows: unknown
      try {
        rows = await igdbFetch<unknown>('external_games', steamLinksQuery(part, field))
      } catch (e) {
        // IGDB refused the query itself: it may not know the new field name yet.
        if (!(e instanceof HttpError && e.code === 'IGDB_ERROR') || field === 'category') throw e
        console.warn('IGDB refused external_game_source, retrying with category:', e)
        field = 'category'
        rows = await igdbFetch<unknown>('external_games', steamLinksQuery(part, field))
      }
      for (const [app, games] of steamLinksByApp(rows) ?? []) byApp.set(app, games)
      failures = 0
    } catch (e) {
      failures++
      console.error('IGDB Steam link lookup failed:', e)
      warn(issues, `IGDB Steam link lookup incomplete: ${(e as Error).message}`, e)
    }
    await sleep(IGDB_PACING_MS)
  }
  return byApp
}

/** These IGDB games, by id. A failed batch is recorded in `issues` and left out. */
async function igdbGamesByIds(ids: number[], issues: SyncIssues): Promise<Map<number, IgdbGame>> {
  const byId = new Map<number, IgdbGame>()
  for (const part of chunk(ids, STEAM_LINK_BATCH)) {
    try {
      const games = await igdbFetch<IgdbGame[]>(
        'games',
        `fields ${IGDB_FIELDS}; where id = (${part.join(',')}); limit ${part.length};`,
      )
      for (const g of games) byId.set(g.id, g)
    } catch (e) {
      console.error('IGDB games-by-id lookup failed:', e)
      warn(issues, `IGDB lookup incomplete: ${(e as Error).message}`, e)
    }
    await sleep(IGDB_PACING_MS)
  }
  return byId
}

/**
 * Resolve Steam apps through IGDB's own Steam links (`steamLinks`, from
 * `igdbSteamLinks`), which name the game exactly where a title can name several.
 * Apps IGDB has no link for, or whose linked games could not be read, are left out
 * of the answer for the title passes (`resolveMissingGames`) to try.
 */
async function resolveBySteamLinks(
  entries: SteamEntry[],
  steamLinks: Map<number, number[]>,
  issues: SyncIssues,
): Promise<Map<string, IgdbGame>> {
  const matched = new Map<string, IgdbGame>()
  const linked = entries.filter((e) => (steamLinks.get(e.appid)?.length ?? 0) > 0)
  if (linked.length === 0) return matched
  const ids = [...new Set(linked.flatMap((e) => steamLinks.get(e.appid) ?? []))]
  const games = await igdbGamesByIds(ids, issues)
  for (const e of linked) {
    const candidates = (steamLinks.get(e.appid) ?? [])
      .map((id) => games.get(id))
      .filter((g): g is IgdbGame => !!g)
    const clean = cleanSteamTitle(e.title)
    const best = pickLinkedGame(candidates, (name) => matchScore(clean, name))
    if (best) matched.set(e.id, best)
  }
  return matched
}

/** Per-game state while a Steam title works its way through the passes. */
interface Pending {
  entry: SteamEntry
  clean: string // Pass 1 term
  stripped: string | null // Pass 2 term: publisher prefix removed
  primary: string | null // Pass 3 term: text before the first ":" / " - "
  tried: Set<string> // normalized search terms already sent, so a pass never repeats one
}

type PassName = 'exact' | 'search' | 'prefix_stripped' | 'subtitle_split'

/** The fuzzy-search passes, in order. Each yields the term to search, or null to skip that game. */
const SEARCH_PASSES: { name: PassName; term: (p: Pending) => string | null }[] = [
  { name: 'search', term: (p) => p.clean },
  { name: 'prefix_stripped', term: (p) => p.stripped },
  { name: 'subtitle_split', term: (p) => p.primary },
]

/**
 * Resolve Steam games missing from the cache to IGDB records.
 *
 *   Clean    Strip ™/®, edition suffixes and "Test Server"/"Open Beta" junk.
 *   Pass 1   Cleaned title. A bulk, case-insensitive exact-name query (the 1–2
 *            request happy path), then a fuzzy `search` for whatever it missed.
 *   Pass 2   Publisher prefix stripped ("Tom Clancy's Rainbow Six Siege" ->
 *            "Rainbow Six Siege"). Only for titles that have such a prefix.
 *   Pass 3   Primary title only, split at ":" or " - " ("ARK: Survival Evolved"
 *            -> "ARK"). Only for titles that have a subtitle.
 *
 * Every hit is validated with `pickBest`, always against the *full* title, so a
 * broad Pass-3 search for "ARK" can only ever resolve to the game actually named
 * "ARK: Survival Evolved" — never to an unrelated "Ark". A title that no pass can
 * validate stays unmatched instead of being saved as the wrong game.
 *
 * Games are searched most-played first and the fuzzy passes share a budget of
 * IGDB_SEARCH_BUDGET requests (identical terms are searched once), so a long tail of
 * unmatchable apps can't starve the games a user actually plays. An IGDB failure
 * never aborts the sync: whatever matched so far is kept, and games that could not
 * be searched (budget, errors or time) are counted in `deferred` for the next sync.
 */
async function resolveMissingGames(missing: SteamEntry[], issues: SyncIssues, limits: SyncLimits) {
  const matched = new Map<string, IgdbGame>()
  const byPass: Record<PassName, number> = { exact: 0, search: 0, prefix_stripped: 0, subtitle_split: 0 }
  if (missing.length === 0) return { matched, unmatched: [] as string[], deferred: 0, byPass }

  const pending: Pending[] = missing.map((entry) => {
    const clean = cleanSteamTitle(entry.title)
    return {
      entry,
      clean,
      stripped: stripPublisherPrefix(clean),
      primary: primaryTitle(clean),
      tried: new Set<string>(),
    }
  })

  const accept = (p: Pending, g: IgdbGame, pass: PassName) => {
    matched.set(p.entry.id, g)
    byPass[pass]++
  }
  const skipped = new Set<string>() // games a pass could not search (budget, error or time)
  const deadline = Date.now() + limits.igdbTimeBudgetMs

  try {
    // Pass 1a — bulk case-insensitive exact match on the cleaned title.
    const byName = await igdbExactMany([...new Set(pending.map((p) => p.clean))], issues)
    let remaining: Pending[] = []
    for (const p of pending) {
      const best = pickBest(byName.get(normalizeTitle(p.clean)) ?? [], [p.clean])
      if (best) accept(p, best, 'exact')
      else remaining.push(p)
    }

    // Most-played first, so the search budget goes to the games people care about.
    remaining.sort((a, b) => b.entry.hours - a.entry.hours)

    // Pass 1b (cleaned title), Pass 2 (prefix stripped), Pass 3 (subtitle split).
    let budget = limits.igdbSearchBudget
    for (const pass of SEARCH_PASSES) {
      // One search per distinct term; games that share a term share its results.
      const jobs = new Map<string, { term: string; games: Pending[] }>()
      for (const p of remaining) {
        const term = pass.term(p)
        if (!term) continue
        const key = normalizeTitle(term)
        if (p.tried.has(key)) continue
        const job = jobs.get(key)
        if (job) job.games.push(p)
        else jobs.set(key, { term, games: [p] })
      }
      const all = [...jobs.values()]
      const run = all.slice(0, Math.max(0, budget))
      for (const j of all.slice(run.length)) for (const p of j.games) skipped.add(p.entry.id)
      if (run.length === 0) continue
      budget -= run.length

      const { results, stopped } = await igdbSearchMany(run.map((j) => j.term), issues, deadline)
      run.forEach((j, i) => {
        const hits = results[i]
        if (!hits) {
          for (const p of j.games) skipped.add(p.entry.id) // never searched: retry next sync
          return
        }
        const key = normalizeTitle(j.term)
        for (const p of j.games) {
          p.tried.add(key)
          // Pass 2 may match the stripped spelling too; every other pass must match the full title.
          const targets = pass.name === 'prefix_stripped' ? [p.clean, j.term] : [p.clean]
          const best = pickBest(hits, targets)
          if (best) accept(p, best, pass.name)
        }
      })
      remaining = remaining.filter((p) => !matched.has(p.entry.id))
      // IGDB is failing or out of time: don't spend the next passes' requests on it.
      if (stopped) {
        for (const p of remaining) skipped.add(p.entry.id)
        break
      }
      if (remaining.length === 0) break
    }
  } catch (e) {
    console.error('IGDB lookup failed:', e)
    warn(issues, `IGDB lookup incomplete: ${(e as Error).message}`, e)
  }

  const unmatched = missing.filter((m) => !matched.has(m.id)).map((m) => m.title)
  const deferred = [...skipped].filter((id) => !matched.has(id)).length
  return { matched, unmatched, deferred, byPass }
}

// ---- Supabase --------------------------------------------------------------
async function authenticate(req: Request, admin: SupabaseClient): Promise<string> {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim()
  if (!token) throw new HttpError(401, 'UNAUTHENTICATED', 'Missing authorization')
  const { data, error } = await admin.auth.getUser(token)
  if (error || !data.user) throw new HttpError(401, 'UNAUTHENTICATED', 'Invalid or expired session')
  if (secondFactorMissing(data.user, token)) {
    throw new HttpError(403, 'MFA_REQUIRED', 'Enter your two-factor code to finish signing in')
  }
  return data.user.id
}

/**
 * The caller's Steam ID64, read from their own `profiles` row. `userId` comes
 * from the verified JWT (`authenticate`), never from the request, so a client
 * can only ever sync the Steam account saved on its own profile.
 */
async function fetchSteamId(admin: SupabaseClient, userId: string): Promise<string> {
  const { data, error } = await admin
    .from('profiles')
    .select('steam_id')
    .eq('id', userId)
    .maybeSingle()
  if (error) throw new Error(`profiles lookup failed: ${error.message}`)

  const steamId = data?.steam_id
  if (steamId === null || steamId === undefined || String(steamId).trim() === '') {
    throw new HttpError(
      400,
      'NO_STEAM_ID',
      'No Steam ID saved on your profile. Connect your Steam account first.',
    )
  }
  return String(steamId).trim()
}

interface KnownApp {
  id: string // games.id
  igdbId: number | null // null = legacy Steam-keyed row
}

/**
 * The catalog rows already linked to these Steam app ids, keyed by app id. If an
 * app has both a legacy row and an IGDB-keyed one (mid-migration), the IGDB-keyed
 * row wins.
 */
async function fetchKnownSteamApps(
  admin: SupabaseClient,
  appIds: number[],
): Promise<Map<number, KnownApp>> {
  const byApp = new Map<number, KnownApp>()
  const results = await Promise.all(
    chunk(appIds, DB_IN_CHUNK).map((part) =>
      admin.from('games').select('id, igdb_id, steam_app_id').in('steam_app_id', part),
    ),
  )
  for (const { data, error } of results) {
    if (error) throw new Error(`games lookup by steam_app_id failed: ${error.message}`)
    for (const row of data ?? []) {
      const app = Number(row.steam_app_id)
      const igdbId = row.igdb_id === null || row.igdb_id === undefined ? null : Number(row.igdb_id)
      const prev = byApp.get(app)
      if (!prev || (prev.igdbId === null && igdbId !== null)) {
        byApp.set(app, { id: row.id as string, igdbId })
      }
    }
  }
  return byApp
}

interface LinkRow {
  app_id: number
  game_id: string // the IGDB-keyed games.id
  legacy_id: string | null // the 57e40000-… row to fold into it, if there is one
}

/**
 * Records each Steam app on its IGDB-keyed game and folds the legacy row (if any)
 * into it. Runs in the database (`link_steam_apps`, service role only) because
 * folding moves every user's library and log rows for that game in one transaction.
 */
async function linkSteamApps(
  admin: SupabaseClient,
  links: LinkRow[],
): Promise<{ linked: number; merged: number }> {
  let linked = 0
  let merged = 0
  for (const part of chunk(links, LINK_CHUNK)) {
    const { data, error } = await admin.rpc('link_steam_apps', { links: part })
    if (error) throw new Error(`link_steam_apps failed: ${error.message}`)
    linked += Number(data?.linked ?? 0)
    merged += Number(data?.merged ?? 0)
  }
  return { linked, merged }
}

interface RelinkRow {
  app_id: number
  from_id: string // the game an earlier title match wrongly linked the app to
  into_id: string // the game IGDB's own Steam link says the app is
}

/**
 * The relinks earlier syncs (anyone's) recorded for these apps, so this user's
 * library row on a wrongly matched game moves too. Empty when there are none, or
 * when the table is missing (20261018200000_steam_app_relinks.sql not applied):
 * the sync works without it.
 */
async function fetchStoredRelinks(admin: SupabaseClient, appIds: number[]): Promise<RelinkRow[]> {
  const out: RelinkRow[] = []
  const results = await Promise.all(
    chunk(appIds, DB_IN_CHUNK).map((part) =>
      admin.from('steam_app_relinks').select('app_id, from_id, into_id').in('app_id', part),
    ),
  )
  for (const { data, error } of results) {
    if (error) {
      console.warn('sync-steam: steam_app_relinks lookup failed:', error.message)
      return []
    }
    for (const row of data ?? []) {
      out.push({ app_id: Number(row.app_id), from_id: row.from_id as string, into_id: row.into_id as string })
    }
  }
  return out
}

/**
 * Moves Steam apps off the games an earlier title match wrongly linked them to
 * (`relink_steam_apps`, service role only): records each relink so every other
 * owner's next sync moves theirs too, points the app at the right game, and folds
 * this user's library row and play sessions on the wrong game into the right one.
 * Only this user's rows move: someone else may have added that other game on purpose.
 */
async function relinkSteamApps(admin: SupabaseClient, userId: string, links: RelinkRow[]): Promise<number> {
  let moved = 0
  for (const part of chunk(links, LINK_CHUNK)) {
    const { data, error } = await admin.rpc('relink_steam_apps', { target_user: userId, links: part })
    if (error) throw new Error(`relink_steam_apps failed: ${error.message}`)
    moved += Number(data?.moved ?? 0)
  }
  return moved
}

/** Which of these game UUIDs already exist in the global `games` catalog? */
async function fetchExistingGameIds(admin: SupabaseClient, ids: string[]): Promise<Set<string>> {
  const found = new Set<string>()
  const results = await Promise.all(
    chunk(ids, DB_IN_CHUNK).map((part) => admin.from('games').select('id').in('id', part)),
  )
  for (const { data, error } of results) {
    if (error) throw new Error(`games cache lookup failed: ${error.message}`)
    for (const row of data ?? []) found.add(row.id as string)
  }
  return found
}

/**
 * The user's existing `user_games` rows, keyed by game_id (minus NOT_RESENT_COLUMNS),
 * and the playtime each game's achievements were last counted at (step 7).
 */
async function fetchExistingUserGames(
  admin: SupabaseClient,
  userId: string,
  ids: string[],
): Promise<{ rows: Map<string, Record<string, unknown>>; countedPlaytime: Map<string, number | null> }> {
  const byGame = new Map<string, Record<string, unknown>>()
  const countedPlaytime = new Map<string, number | null>()
  const results = await Promise.all(
    chunk(ids, DB_IN_CHUNK).map((part) =>
      admin.from('user_games').select('*').eq('user_id', userId).in('game_id', part),
    ),
  )
  for (const { data, error } of results) {
    if (error) throw new Error(`user_games lookup failed: ${error.message}`)
    for (const row of data ?? []) {
      const copy = { ...(row as Record<string, unknown>) }
      for (const col of NOT_RESENT_COLUMNS) delete copy[col]
      byGame.set(row.game_id as string, copy)
      const counted = Number(row.achievements_playtime)
      countedPlaytime.set(row.game_id as string, row.achievements_playtime == null || !Number.isFinite(counted) ? null : counted)
    }
  }
  return { rows: byGame, countedPlaytime }
}

async function upsertChunked(
  admin: SupabaseClient,
  table: string,
  rows: Record<string, unknown>[],
  onConflict: string,
  ignoreDuplicates = false,
) {
  for (const part of chunk(rows, DB_WRITE_CHUNK)) {
    // defaultToNull:false → columns missing from a row use the column default
    // instead of NULL (new rows and existing rows have different key sets).
    // ignoreDuplicates → ON CONFLICT DO NOTHING instead of DO UPDATE.
    const { error } = await admin
      .from(table)
      .upsert(part, { onConflict, defaultToNull: false, ignoreDuplicates })
    if (error) throw new Error(`${table} upsert failed: ${error.message}`)
  }
}

// ---- Orchestration ---------------------------------------------------------
async function syncLibrary(
  admin: SupabaseClient,
  userId: string,
  steamId: string,
  limits: SyncLimits = INTERACTIVE_LIMITS,
) {
  const startedAt = Date.now()
  const issues: SyncIssues = { warnings: [], igdb: null }

  // 1. Steam
  const owned = await fetchSteamGames(steamId)
  const { entries, junk, nonGames } = toSteamEntries(owned)

  // 2. What does the catalog already know about these Steam apps? An app is
  //    resolved once a `games` row carries its id in `steam_app_id` AND has an
  //    `igdb_id`. A row with an app id but no igdb_id is a legacy Steam-keyed row
  //    from before game ids were unified on IGDB: it is matched again below, then
  //    folded into the IGDB-keyed row by `link_steam_apps`.
  //    IGDB's own Steam links are read for every app: they resolve new apps
  //    exactly (step 3), and they catch an app that an earlier title match linked
  //    to the wrong game ("Tomb Raider" the 1996 game for the 2013 one). Such an
  //    app is resolved again through its links and moved in step 5.
  const appIds = entries.map((e) => e.appid)
  const [known, steamLinks, storedRelinks] = await Promise.all([
    fetchKnownSteamApps(admin, appIds),
    igdbSteamLinks(appIds, issues),
    fetchStoredRelinks(admin, appIds),
  ])
  const gameIdByEntry = new Map<string, string>() // SteamEntry.id -> games.id
  const legacyIdByEntry = new Map<string, string>() // SteamEntry.id -> legacy games.id
  const mislinkedIdByEntry = new Map<string, string>() // SteamEntry.id -> wrongly linked games.id
  const toMatch: SteamEntry[] = []
  for (const e of entries) {
    const k = known.get(e.appid)
    if (k && k.igdbId !== null) {
      const linkedTo = steamLinks.get(e.appid) ?? []
      if (linkedTo.length > 0 && !linkedTo.includes(k.igdbId)) {
        mislinkedIdByEntry.set(e.id, k.id)
        toMatch.push(e)
      } else {
        gameIdByEntry.set(e.id, k.id)
      }
      continue
    }
    if (k) legacyIdByEntry.set(e.id, k.id)
    toMatch.push(e)
  }

  // 3. Resolve the apps that aren't resolved yet: through IGDB's Steam links
  //    first, then the multi-pass title match for the ones IGDB has no link for.
  //    A mislinked app is only ever resolved through its links, since a title
  //    match is what got it wrong.
  const linkedMatches = await resolveBySteamLinks(toMatch, steamLinks, issues)
  const byTitle = toMatch.filter((e) => !linkedMatches.has(e.id) && !mislinkedIdByEntry.has(e.id))
  const {
    matched: titleMatches,
    unmatched,
    deferred,
    byPass,
  } = await resolveMissingGames(byTitle, issues, limits)
  const matched = new Map([...linkedMatches, ...titleMatches])

  // 4. Add the matched games the catalog doesn't have. A game's id comes from its
  //    IGDB id, so one that another user already added (through in-app search,
  //    say) is the same row and is simply found here.
  const matchedGameIds = [...new Set([...matched.values()].map((g) => igdbGameUuid(g.id)))]
  const existingGameIds = matchedGameIds.length
    ? await fetchExistingGameIds(admin, matchedGameIds)
    : new Set<string>()
  const newGameRows: Record<string, unknown>[] = []
  const queued = new Set<string>()
  for (const g of matched.values()) {
    const id = igdbGameUuid(g.id)
    if (existingGameIds.has(id) || queued.has(id)) continue
    queued.add(id)
    newGameRows.push(toGameRow(g))
  }
  // ON CONFLICT (igdb_id) DO NOTHING: if another sync inserted the same game a
  // moment ago, that row wins and nothing is overwritten.
  await upsertChunked(admin, 'games', newGameRows, 'igdb_id', true)

  // 5. Move the mislinked apps to their right game (`relink_steam_apps`), with the
  //    relinks other syncs recorded for this user's apps, so a library row on the
  //    wrong game follows. Then record each other matched Steam app on its game,
  //    and fold legacy rows into it.
  const entryById = new Map(entries.map((e) => [e.id, e]))
  const relinks: RelinkRow[] = []
  const links: LinkRow[] = []
  for (const [entryId, g] of matched) {
    const entry = entryById.get(entryId)
    if (!entry) continue
    const gameId = igdbGameUuid(g.id)
    gameIdByEntry.set(entryId, gameId)
    const wrongId = mislinkedIdByEntry.get(entryId)
    if (wrongId) {
      relinks.push({ app_id: entry.appid, from_id: wrongId, into_id: gameId })
      continue
    }
    links.push({
      app_id: entry.appid,
      game_id: gameId,
      legacy_id: legacyIdByEntry.get(entryId) ?? null,
    })
  }
  // A stored relink applies only while the app still resolves to the game it moved to.
  const gameIdByApp = new Map<number, string>()
  for (const e of entries) {
    const gameId = gameIdByEntry.get(e.id)
    if (gameId) gameIdByApp.set(e.appid, gameId)
  }
  for (const r of storedRelinks) {
    if (gameIdByApp.get(r.app_id) === r.into_id && !relinks.some((x) => x.app_id === r.app_id && x.from_id === r.from_id)) {
      relinks.push(r)
    }
  }
  let relinked = 0
  if (relinks.length > 0) {
    try {
      relinked = await relinkSteamApps(admin, userId, relinks)
    } catch (e) {
      // Sync on the games as they were linked; the move is tried again next time.
      console.error('sync-steam:', e)
      warn(issues, `Could not move wrongly matched games: ${(e as Error).message}`)
      for (const [entryId, wrongId] of mislinkedIdByEntry) gameIdByEntry.set(entryId, wrongId)
    }
  }
  // A mislinked app whose links could not be read this time stays on its game.
  for (const [entryId, wrongId] of mislinkedIdByEntry) {
    if (!gameIdByEntry.has(entryId)) gameIdByEntry.set(entryId, wrongId)
  }

  const { linked, merged } = await linkSteamApps(admin, links)
  // A legacy row that IGDB couldn't match this time keeps working as it did: its
  // hours still update. It is adopted on a later sync.
  for (const [entryId, legacyId] of legacyIdByEntry) {
    if (!gameIdByEntry.has(entryId)) gameIdByEntry.set(entryId, legacyId)
  }

  // 6. Smart library upsert, one row per game. Two Steam apps can resolve to the
  //    same IGDB game (a base game and its "Complete Edition"); they become one
  //    library entry with their playtime added together.
  const hoursByGame = new Map<string, number>()
  const playtimeByGame = new Map<string, PlaytimeSeen>()
  for (const e of entries) {
    const gameId = gameIdByEntry.get(e.id)
    if (!gameId) continue // no IGDB match and no legacy row → skip rather than save a stub
    hoursByGame.set(gameId, Math.round(((hoursByGame.get(gameId) ?? 0) + e.hours) * 100) / 100)
    const seen = playtimeByGame.get(gameId)
    playtimeByGame.set(gameId, {
      gameId,
      minutes: (seen?.minutes ?? 0) + e.minutes,
      lastPlayed: Math.max(seen?.lastPlayed ?? 0, e.lastPlayed),
    })
  }
  // Read AFTER step 5: folding a legacy row moves the user's library row to the new id.
  const { rows: existingByGame, countedPlaytime } = hoursByGame.size
    ? await fetchExistingUserGames(admin, userId, [...hoursByGame.keys()])
    : { rows: new Map<string, Record<string, unknown>>(), countedPlaytime: new Map<string, number | null>() }

  const nowIso = new Date().toISOString()
  const libraryRows: Record<string, unknown>[] = []
  let added = 0
  let updated = 0
  let unchanged = 0

  // What Steam playtime this sync records, and the sessions it logs: only for
  // games already in the library with a baseline (a new game's playtime is its
  // history, not a session).
  const baselineBefore = new Map<string, number | null>()
  for (const [gameId, row] of existingByGame) {
    const minutes = row.steam_playtime_minutes
    baselineBefore.set(gameId, minutes == null || !Number.isFinite(Number(minutes)) ? null : Number(minutes))
  }
  const playtime = new Map(
    playtimeUpdates([...playtimeByGame.values()], baselineBefore, Date.now()).map((u) => [u.gameId, u]),
  )

  for (const [gameId, hours] of hoursByGame) {
    const existing = existingByGame.get(gameId)
    const baseline = playtime.get(gameId)?.baseline
    if (existing) {
      // Already in the library: only ever raise hours_played. We re-send the
      // row we just read with those fields changed, so status / rating /
      // is_favorite / etc. are written back exactly as they are.
      const current = Number(existing.hours_played) || 0
      const raise = hours > current
      if (raise || baseline !== undefined) {
        libraryRows.push({
          ...existing,
          ...(raise ? { hours_played: hours } : {}),
          ...(baseline !== undefined ? { steam_playtime_minutes: baseline } : {}),
        })
      }
      if (raise) updated++
      else unchanged++
      continue
    }
    libraryRows.push({
      ...newUserGameRow(userId, gameId, hours, nowIso),
      steam_playtime_minutes: baseline ?? playtimeByGame.get(gameId)?.minutes ?? null,
    })
    added++
  }

  if (libraryRows.length > 0) {
    await upsertChunked(admin, 'user_games', libraryRows, 'user_id,game_id')
  }

  // The sessions go in after the baselines they were measured against moved on,
  // so a failure here loses a session rather than logging it twice next time.
  const sessionRows: Record<string, unknown>[] = []
  for (const u of playtime.values()) {
    if (!u.session) continue
    sessionRows.push({
      user_id: userId,
      game_id: u.gameId,
      hours: u.session.hours,
      platform: steamSessionPlatform(existingByGame.get(u.gameId)?.played_on),
      note: '',
      logged_at: u.session.loggedAt,
      source: 'steam',
    })
  }
  let sessionsLogged = 0
  for (const part of chunk(sessionRows, DB_WRITE_CHUNK)) {
    const { error } = await admin.from('log_entries').insert(part)
    if (error) {
      console.error('sync-steam: logging Steam sessions failed:', error.message)
      warn(issues, `Could not log play sessions from Steam: ${error.message}`)
      break
    }
    sessionsLogged += part.length
  }

  // 7. Achievement counts for the games played since they were last counted. Only
  //    games in the library (written just above) can take a count.
  const countable: CountableApp[] = []
  for (const e of entries) {
    const gameId = gameIdByEntry.get(e.id)
    if (!gameId) continue
    countable.push({ appid: e.appid, gameId, minutes: e.minutes, lastPlayed: e.lastPlayed, hasStats: e.hasStats })
  }
  const targets = achievementCountTargets(countable, countedPlaytime)
  let achievements: AchievementCountSummary = { due: targets.length, counted: 0, stopped: null }
  try {
    achievements = await countAchievements(admin, userId, steamId, targets, limits, startedAt)
  } catch (e) {
    // The library is saved; the counts are retried on the next sync.
    console.error('sync-steam: counting achievements failed:', e)
    achievements = { due: targets.length, counted: 0, stopped: 'INTERNAL' }
  }

  // The sync still did what it could, but IGDB could not match every game (rate
  // limited, down, or out of time/budget). Say so in a form the app can act on,
  // instead of leaving it to guess from `deferred` and the warning text.
  const delayed =
    deferred > 0
      ? {
          code: issues.igdb?.code ?? 'SYNC_PARTIAL',
          message:
            issues.igdb?.code === 'IGDB_RATE_LIMITED'
              ? 'The game database is busy. Some games will be matched on your next sync.'
              : issues.igdb
                ? 'The game database is unavailable. Some games will be matched on your next sync.'
                : 'Some games will be matched on your next sync.',
          retry_after: issues.igdb?.retryAfter ?? null,
          deferred,
        }
      : null

  return {
    delayed,
    summary: {
      steam_total: owned.length,
      junk_filtered: junk,
      non_game_filtered: nonGames.length,
      candidates: entries.length,
      cached: entries.length - toMatch.length,
      fetched_from_igdb: matched.size,
      steam_apps_linked: linked,
      steam_apps_relinked: relinked,
      legacy_rows_merged: merged,
      matched_by_pass: { steam_link: linkedMatches.size, ...byPass },
      added,
      updated,
      unchanged,
      steam_sessions_logged: sessionsLogged,
      unmatched: unmatched.length,
      deferred,
      achievements_due: achievements.due,
      achievements_counted: achievements.counted,
      achievements_stopped: achievements.stopped,
    },
    unmatched_titles: unmatched.slice(0, 50),
    non_game_titles: nonGames.slice(0, 50), // test / beta / server / demo builds that were skipped
    warnings: issues.warnings,
  }
}

// ---- Achievement counts (step 7) --------------------------------------------

interface AchievementCountSummary {
  /** Games played since they were last counted. */
  due: number
  /** Of those, the ones counted (and saved) this time. */
  counted: number
  /** Why counting stopped before the end of the budget, if it did. */
  stopped: string | null
}

/** One game's achievement count, from GetPlayerAchievements (no names: just the flags). */
async function fetchAchievementCount(apiKey: string, steamId: string, appid: number): Promise<CountResult> {
  const url = new URL('https://api.steampowered.com/ISteamUserStats/GetPlayerAchievements/v1/')
  url.search = new URLSearchParams({ key: apiKey, steamid: steamId, appid: String(appid) }).toString()
  try {
    const res = await fetchWithBackoff(
      () => fetch(url, { signal: AbortSignal.timeout(ACHIEVEMENT_COUNT_TIMEOUT_MS) }),
      STEAM_COUNT_BACKOFF,
    )
    // Steam sends useful JSON bodies on 4xx too (private profile, no stats).
    const body = await res.json().catch(() => null)
    return countFromPlayerAchievements(res.status, body)
  } catch {
    // Unreachable or timed out. Not the raw error: it embeds the URL (and API key).
    return { kind: 'error', status: 0 }
  }
}

/**
 * Counts the achievements of `targets` (most interesting first), a few requests at a
 * time, until the budget, the deadline, a rate limit or a private profile stops it,
 * and saves what it counted. A game that was not reached keeps its old count (or
 * none) and stays due, so the next sync carries on where this one stopped.
 */
async function countAchievements(
  admin: SupabaseClient,
  userId: string,
  steamId: string,
  targets: CountTarget[],
  limits: SyncLimits,
  startedAt: number,
): Promise<AchievementCountSummary> {
  const apiKey = Deno.env.get('STEAM_API_KEY')
  if (!apiKey || targets.length === 0) return { due: targets.length, counted: 0, stopped: null }

  const todo = targets.slice(0, limits.achievementCountBudget)
  const deadline = startedAt + limits.achievementDeadlineMs
  const counts: { game_id: string; unlocked: number; total: number; playtime: number }[] = []
  let next = 0
  let failuresInARow = 0
  let stopped: string | null = null

  const worker = async () => {
    while (stopped === null && next < todo.length) {
      if (Date.now() > deadline) {
        stopped = 'TIME_BUDGET'
        return
      }
      const target = todo[next++]
      const result = await fetchAchievementCount(apiKey, steamId, target.appid)
      if (result.kind === 'counted') {
        failuresInARow = 0
        counts.push({ game_id: target.gameId, unlocked: result.unlocked, total: result.total, playtime: target.minutes })
      } else if (result.kind === 'private') {
        stopped ??= 'STEAM_PROFILE_PRIVATE'
      } else if (result.status === 429) {
        stopped ??= 'STEAM_RATE_LIMITED'
      } else if (++failuresInARow >= ACHIEVEMENT_COUNT_MAX_FAILURES) {
        stopped ??= 'STEAM_ERROR'
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(ACHIEVEMENT_COUNT_CONCURRENCY, todo.length) }, worker))
  if (stopped === null && todo.length < targets.length) stopped = 'BUDGET'

  let saved = 0
  for (const part of chunk(counts, ACHIEVEMENT_COUNT_WRITE_CHUNK)) {
    const { data, error } = await admin.rpc('set_achievement_counts', { target_user: userId, counts: part })
    if (error) throw new Error(`set_achievement_counts failed: ${error.message}`)
    saved += Number(data) || 0
  }
  return { due: targets.length, counted: saved, stopped }
}

// ---- Sync state and the background run -------------------------------------

/** A row of `steam_sync_due`: a user whose library the background run should refresh. */
interface DueUser {
  user_id: string
  steam_id: string
  consecutive_failures: number
}

/**
 * Records a finished sync in `steam_sync_state` (service role only): when it ran and
 * when the background run may come back. A user's first recorded sync also enrolls
 * them in the background sync, so only people who have synced by hand are ever synced
 * unasked. Never throws: a bookkeeping problem (the migration not applied yet, say)
 * must not fail a sync that worked.
 */
async function recordSyncSuccess(
  admin: SupabaseClient,
  userId: string,
  delayed: { code: string; retry_after: number | null } | null,
): Promise<void> {
  const now = Date.now()
  const { error } = await admin.from('steam_sync_state').upsert(
    {
      user_id: userId,
      last_synced_at: new Date(now).toISOString(),
      last_attempt_at: new Date(now).toISOString(),
      next_attempt_at: new Date(now + successDelayMs(delayed !== null, delayed?.retry_after ?? null)).toISOString(),
      consecutive_failures: 0,
      last_error_code: delayed?.code ?? null,
    },
    { onConflict: 'user_id' },
  )
  if (error) console.error('sync-steam: could not record the sync state:', error)
}

/** Pushes a user's next background attempt out after a failure (see `failureDelayMs`). */
async function recordBackgroundFailure(admin: SupabaseClient, user: DueUser, error: unknown): Promise<void> {
  const code = error instanceof HttpError ? error.code : 'INTERNAL'
  const retryAfter = error instanceof HttpError ? error.retryAfter ?? null : null
  const { delayMs, countsAsFailure } = failureDelayMs(code, user.consecutive_failures, retryAfter)
  const now = Date.now()
  const { error: dbError } = await admin
    .from('steam_sync_state')
    .update({
      last_attempt_at: new Date(now).toISOString(),
      next_attempt_at: new Date(now + delayMs).toISOString(),
      consecutive_failures: user.consecutive_failures + (countsAsFailure ? 1 : 0),
      last_error_code: code,
    })
    .eq('user_id', user.user_id)
  if (dbError) console.error('sync-steam: could not record the failure:', dbError)
}

/**
 * One background run: syncs the most overdue users, one at a time, with the small
 * IGDB budget. A failure for one user is recorded against them and the run goes on;
 * a failure that every user would hit (Steam limiting us, a missing secret) ends it,
 * and the users not reached stay due for the next run.
 */
async function runBackgroundBatch(admin: SupabaseClient) {
  const startedAt = Date.now()
  const { data, error } = await admin.rpc('steam_sync_due', {
    batch_size: BACKGROUND_BATCH_SIZE,
    active_days: BACKGROUND_ACTIVE_DAYS,
  })
  if (error) throw new Error(`steam_sync_due failed: ${error.message}`)

  const due = (data ?? []) as DueUser[]
  const summary = { due: due.length, synced: 0, delayed: 0, failed: 0, stopped: null as string | null }
  for (const user of due) {
    if (Date.now() - startedAt > BACKGROUND_TIME_BUDGET_MS) {
      summary.stopped = 'TIME_BUDGET'
      break
    }
    try {
      const result = await syncLibrary(admin, user.user_id, user.steam_id, BACKGROUND_LIMITS)
      await recordSyncSuccess(admin, user.user_id, result.delayed)
      if (result.delayed) summary.delayed++
      else summary.synced++
    } catch (e) {
      summary.failed++
      console.error(`sync-steam background: sync for ${user.user_id} failed:`, e)
      await recordBackgroundFailure(admin, user, e)
      const code = e instanceof HttpError ? e.code : 'INTERNAL'
      if (shouldStopBatch(code)) {
        summary.stopped = code
        break
      }
    }
  }
  return summary
}

/**
 * Throws unless `provided` is the CRON_SECRET secret. Compared as SHA-256 digests
 * so the check takes the same time wherever the two strings first differ.
 */
async function requireCronSecret(provided: string): Promise<void> {
  const expected = Deno.env.get('CRON_SECRET')
  if (!expected) {
    console.error('CRON_SECRET is not set')
    throw new HttpError(500, 'NOT_CONFIGURED', 'Server is not configured')
  }
  const encoder = new TextEncoder()
  const [a, b] = await Promise.all(
    [provided, expected].map(async (s) => new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(s)))),
  )
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  if (diff !== 0) throw new HttpError(401, 'UNAUTHENTICATED', 'Invalid cron secret')
}

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  })

/**
 * `{ error, code, retry_after? }` plus a `Retry-After` header when a retry makes
 * sense. Anything that is not an `HttpError` is logged and answered with a generic
 * message, so database / library error text never reaches the client.
 */
function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    const retryAfter = error.retryAfter
    return json(
      { error: error.message, code: error.code, ...(retryAfter ? { retry_after: retryAfter } : {}) },
      error.status,
      retryAfter ? { 'Retry-After': String(retryAfter) } : {},
    )
  }
  return json({ error: 'Something went wrong on our side. Try again later.', code: 'INTERNAL' }, 500)
}

Deno.serve(withCors(async (req) => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    if (!supabaseUrl || !serviceKey) {
      console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set')
      throw new HttpError(500, 'NOT_CONFIGURED', 'Server is not configured')
    }

    // Service-role client: writes the global `games` catalog and bypasses RLS,
    // so every user_games query below is explicitly scoped to the verified user.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    // pg_cron's background run: no user session, so it proves itself with the
    // shared secret instead and works through the users that are due.
    const cronSecret = req.headers.get('x-cron-secret')
    if (cronSecret !== null) {
      await requireCronSecret(cronSecret)
      return json({ success: true, background: await runBackgroundBatch(admin) })
    }

    const userId = await authenticate(req, admin)
    const wait = await rateLimitWait(admin, userId, RATE_LIMITS.steamSync)
    if (wait > 0) throw new HttpError(429, 'RATE_LIMITED', 'Too many syncs, try again later', wait)

    // The request body is ignored on purpose: the Steam ID is looked up on the
    // caller's own profile, so it can't be swapped for someone else's.
    const steamId = await fetchSteamId(admin, userId)

    const result = await syncLibrary(admin, userId, steamId)
    // Only a success is recorded here: a failed manual sync says nothing about when
    // the background run should try, but a good one resets it and enrolls the user.
    await recordSyncSuccess(admin, userId, result.delayed)
    return json({ success: true, ...result })
  } catch (error) {
    console.error('sync-steam failed:', error)
    return errorResponse(error)
  }
}))