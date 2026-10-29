// supabase/functions/igdb-handler/index.ts
//
// Proxies game searches and browse lists to IGDB so the Twitch credentials never
// ship in the app. Only logged-in Supabase users may call it.
//
// Request  (POST, JSON): { "query": "zelda", "limit": 20, "offset": 0 }
//                        optionally narrowed by the Discover tab's filters:
//                        { "query": "zelda", "filters": { "genres": [12],
//                          "themes": [19], "game_modes": [1, 3], "platforms": [6, 14],
//                          "year": { "from": 2010, "to": 2019 } }, ... }
//                          IGDB ids per kind (genres, themes, game_modes,
//                          platforms), every kind optional; a game needs any id of
//                          a kind, and every kind picked. `year` is an inclusive
//                          range of release years, either end optional.
//                        A text search lists first the rated games whose title has
//                        a word starting with every typed word ("elden rin": Elden
//                        Ring), most ratings first, then IGDB's relevance search
//                        for the rest (_shared/game_search.ts). `offset` counts
//                        positions in that joined list.
//                        or, to browse by filters with no text (`query` empty or
//                        left out; at least one filter needed):
//                        { "filters": { "themes": [19] }, "sort": "popular",
//                          "limit": 30, "offset": 0 }
//                          sort optional, one of popular (most ratings first),
//                          top_rated, newest (released up to now), oldest. Only
//                          main games with a cover, like the browse lists.
//                        (the queries live in _shared/game_filters.ts)
//                        or, to browse instead of search:
//                        { "mode": "popular" | "top_rated" | "new_releases",
//                          "limit": 20, "offset": 0 }
//                        limit optional, 1-50; offset optional, for paging.
//                        With a `mode` the `query`, `filters` and `sort` are
//                        ignored. Modes:
//                          popular       most popular first (IGDB visits)
//                          top_rated     best total_rating, with more than 50 ratings
//                          new_releases  released in the last 90 days, newest first
//                        (the queries live in _shared/browse_queries.ts)
//          Header:       Authorization: Bearer <user access token>
//                        or, for one game's whole page (the details screen):
//                        { "mode": "details", "igdb_id": 472, "lang": "ru" }
//                          answers { "game": <the IGDB game, with platforms, genres,
//                          themes, game modes, perspectives, engines, companies,
//                          storyline and similar games>,
//                          "translations"?: { lang, summary?, storyline? } }.
//                          `lang` is optional: the app's language when it is not
//                          English. The summary and storyline are then translated
//                          into it too (DeepL, stored per text; _shared/deepl.ts);
//                          `translations` is left out when nothing was (English,
//                          a language DeepL lacks, no DEEPL_API_KEY, DeepL down).
//                          The stable part (exact platforms, genres, themes, modes,
//                          perspectives, engines, developers, publishers) is also
//                          written to the game's shared `games` row, at most once a
//                          week (_shared/game_details.ts), so a library shows the
//                          game's real platforms and filters can use the rest. That
//                          write needs the service role (RLS lets a member edit only
//                          the catalog rows they created) and only ever touches those
//                          columns, from IGDB's own answer, never from the caller.
//                        or, for the art a member can pick for a game's backdrop
//                        (the game screen's "Change backdrop" sheet):
//                        { "mode": "media", "igdb_id": 472 }
//                          answers { "artworks": [...], "screenshots": [...] },
//                          each picture as { image_id, width, height }
//                          (_shared/game_media.ts). The app builds each URL from
//                          `image_id`.
//                        or, to fill in many games' catalog rows at once (the app
//                        sends its library's never-filled-in games in the
//                        background, so every game shows its exact platforms
//                        without its screen being opened first):
//                        { "mode": "backfill", "igdb_ids": [472, 1942, ...] }
//                          1 to 50 ids, each a positive whole number (one bad id
//                          refuses the request). Makes ONE IGDB /games request for
//                          the ids whose rows are due (the same weekly rule as
//                          `details`; none due, no IGDB request), asking only for
//                          what the catalog keeps (no storyline or similar games),
//                          and writes each due row the way
//                          `details` does. Answers what each row holds afterwards:
//                          { "games": [{ "igdb_id": 472, "platforms": ["pc",
//                          "ps3", "xbox360"], "genres": [...] }, ...],
//                          "unknown": [ids with no catalog row] }. A row IGDB has
//                          no game for is stamped anyway (asked again when due);
//                          a row whose write failed is in neither list, so the
//                          app asks again later. Errors as for any request: on
//                          IGDB_RATE_LIMITED / IGDB_UNAVAILABLE the app waits
//                          `retry_after` seconds and goes on where it stopped.
//                        or, to add games to the shared catalog (a search result
//                        added to the library or to a list; members can't write
//                        the catalog themselves):
//                        { "mode": "add", "igdb_ids": [472, 1942, ...] }
//                          1 to 50 ids, as for `backfill`. Makes ONE IGDB /games
//                          request for the ids with no catalog row yet (none
//                          missing, no IGDB request) and inserts each row built
//                          from IGDB's answer alone (_shared/catalog_add.ts):
//                          title, cover, summary and everything `details` keeps.
//                          Answers { "added": [ids], "existing": [ids already
//                          there], "unknown": [ids IGDB has no game for] }.
//                        or, for a company's page (a publisher or developer
//                        tapped on a game's screen, or found by the studio search):
//                        { "mode": "company", "company_id": 56, "lang": "ru" }
//                          answers { "company": { id, name, description, country
//                          (ISO 3166-1 number), start_date (Unix seconds),
//                          logo_image_id, parent: { id, name } | null, websites:
//                          [{ url, type }], published_count, developed_count },
//                          "translations"?: { lang, description } }, `lang` as for
//                          `details`.
//                        or, for the games of a company:
//                        { "mode": "company_games", "company_id": 56,
//                          "role": "any" | "publisher" | "developer",
//                          "sort": "popular", "limit": 30, "offset": 0 }
//                          role and sort optional (any, popular), sorts as for a
//                          filtered browse. Only main games with a cover. Answers
//                          the raw IGDB games, each with its involved companies'
//                          `developer` / `publisher` flags: IGDB may match the
//                          company and the role on two different involved
//                          companies, so the app checks the company's own entry.
//                        or, to search or browse the companies (the Discover tab's Studios):
//                        { "mode": "companies", "query": "valve", "limit": 20, "offset": 0,
//                          "filters": { "role": "developer", "countries": [840, 392],
//                          "founded": { "from": 1990, "to": 1999 } },
//                          "sort": "popular" }
//                          `query` and `filters` are both optional but one of them
//                          is needed. `role` is any (the default), developer or
//                          publisher; `countries` are ISO 3166-1 numbers, a company
//                          needs to be in any of them; `founded` is an inclusive
//                          range of founding years from 1970, either end optional.
//                          `sort` is popular (the default), name, oldest or newest
//                          (by founding date; companies with none are left out).
//                          Answers up to `limit` companies with a game, with a word
//                          of their name starting with every typed word: [{ id, name,
//                          logo_image_id, country, start_date (Unix seconds),
//                          published_count, developed_count }]. `popular` puts the
//                          exact name first, then names starting with it, then most
//                          games, among the earliest-added companies (IGDB can't
//                          sort by how many games a company has: 50 candidates for
//                          a text, 500 to browse by filters alone); the other sorts
//                          are IGDB's own. `offset` pages the list, like a search.
//                        (the queries live in _shared/companies.ts)
// Response (JSON):       the raw IGDB /v4/games array, or
//                        { "error": "...", "code": "...", "retry_after"?: seconds }
//                        An offset at or past MAX_RESULTS answers `[]`.
//                        Failures carry a `Retry-After` header when a retry makes
//                        sense. A 429 from IGDB / Twitch is first retried with a
//                        short exponential backoff (_shared/backoff.ts); only a
//                        limit that outlasts that is reported, and then this
//                        instance answers further searches IGDB_RATE_LIMITED
//                        without calling IGDB for up to a minute. Codes:
//                          IGDB_RATE_LIMITED (429)  IGDB / Twitch is limiting requests
//                          IGDB_UNAVAILABLE  (503)  IGDB / Twitch is down or unreachable
//                          IGDB_ERROR        (502)  IGDB / Twitch refused our request
//                          UNAUTHENTICATED   (401)  no valid user session
//                          MFA_REQUIRED      (403)  two-factor is on and this session has
//                                                   not entered its code (_shared/mfa.ts)
//                          RATE_LIMITED      (429)  this member made too many requests
//                                                   (_shared/rate_limit.ts); `retry_after`
//                          NOT_FOUND         (404)  `details` / `media` for an IGDB id with no game,
//                                                   `company` for one with no company
//                          BAD_REQUEST       (400 / 405)
//                          NOT_CONFIGURED    (500)  missing secrets
//                          INTERNAL          (500)  anything else
//
// Secrets (set with `supabase secrets set`):
//   TWITCH_CLIENT_ID
//   TWITCH_CLIENT_SECRET
//   DEEPL_API_KEY    optional: translates game summaries, storylines and company
//                    descriptions for the app's other languages (_shared/deepl.ts)
//   ALLOWED_ORIGINS  optional, the web app's origins (_shared/cors.ts)
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected
// automatically by Supabase.

import { createClient } from "../_shared/supabase.ts";
import { addQuery, newCatalogRow } from "../_shared/catalog_add.ts";
import { withCors } from "../_shared/cors.ts";
import { secondFactorMissing } from "../_shared/mfa.ts";
import { RATE_LIMITS, rateLimitWait } from "../_shared/rate_limit.ts";
import {
  type CompanyFilters,
  companiesQuery,
  companyGamesQuery,
  companyInfo,
  companyQuery,
  type CompanyRole,
  type CompanySort,
  hasCompanyFilters,
  isCompanySort,
  listCompanies,
  parseCompanyFilters,
  parseCompanyRole,
  rankCompanies,
} from "../_shared/companies.ts";
import {
  type BackoffOptions,
  fetchWithBackoff,
  parseRetryAfter,
} from "../_shared/backoff.ts";
import {
  type BackfillGame,
  backfillGame,
  backfillQuery,
  CATALOG_ROW_COLUMNS,
  type CatalogRow,
  catalogPatch,
  detailsQuery,
  firstRow,
  gamesById,
  isDue,
  MAX_BACKFILL_IDS,
  parseIgdbId,
  parseIgdbIds,
  planBackfill,
} from "../_shared/game_details.ts";
import {
  type DiscoverSort,
  discoverQuery,
  filteredSearchQuery,
  type GameFilters,
  hasFilters,
  isDiscoverSort,
  NO_FILTERS,
  parseGameFilters,
} from "../_shared/game_filters.ts";
import { gameMedia, mediaQuery } from "../_shared/game_media.ts";
import {
  translatable,
  translateTexts,
  translationLanguage,
  type TranslationStore,
} from "../_shared/deepl.ts";
import {
  joinSearchPage,
  searchPagePlan,
  titleIds,
  titleMatchQuery,
  titleWords,
} from "../_shared/game_search.ts";
import {
  type BrowseMode,
  gamesByIdQuery,
  inRankOrder,
  isBrowseMode,
  newReleasesQuery,
  popularityQuery,
  rankedGameIds,
  topRatedQuery,
} from "../_shared/browse_queries.ts";

const TWITCH_TOKEN_URL = "https://id.twitch.tv/oauth2/token";
const IGDB_GAMES_URL = "https://api.igdb.com/v4/games";
const IGDB_POPULARITY_URL = "https://api.igdb.com/v4/popularity_primitives";
const IGDB_COMPANIES_URL = "https://api.igdb.com/v4/companies";

// The Apicalypse query is built here, not by the client, so this function can't
// be used as an open proxy to spend your IGDB quota on arbitrary queries.
const GAME_FIELDS = [
  "name",
  "cover.url",
  "first_release_date",
  "total_rating",
  "total_rating_count",
  "platforms.id",
  "platforms.name",
  "genres.name",
  "summary",
  "involved_companies.company.name",
].join(", ");

// A company's games also say what each involved company did, so the app can tell
// what the company did on each game.
const COMPANY_GAME_FIELDS = [
  GAME_FIELDS,
  "involved_companies.developer",
  "involved_companies.publisher",
].join(", ");

const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 50;
const MAX_QUERY_LENGTH = 100;
// How deep a search may be paged. IGDB's relevance ranking is noise long before
// this, and every page costs requests (two for a text search) against the
// Twitch/IGDB quota.
const MAX_RESULTS = 200;

type ErrorCode =
  | "IGDB_RATE_LIMITED"
  | "IGDB_UNAVAILABLE"
  | "IGDB_ERROR"
  | "UNAUTHENTICATED"
  | "MFA_REQUIRED"
  | "RATE_LIMITED"
  | "NOT_FOUND"
  | "BAD_REQUEST"
  | "NOT_CONFIGURED"
  | "INTERNAL";

class HttpError extends Error {
  constructor(
    public status: number,
    public code: ErrorCode,
    message: string,
    public retryAfter?: number, // seconds
  ) {
    super(message);
  }
}

const DEFAULT_RETRY_AFTER_S = 60;

// A search is something a person is waiting on, so a 429 is retried only briefly:
// two retries, about 3.5 s of waiting at most. Past that the 429 is reported
// (IGDB_RATE_LIMITED + retry_after) and the app shows its own "try again" state.
const BACKOFF: BackoffOptions = {
  retries: 2,
  baseDelayMs: 400,
  maxDelayMs: 2_000,
  budgetMs: 3_500,
};

// While IGDB is limiting us, every further request from this instance would only
// be limited again (and count against us). After a 429 that retrying did not clear,
// answer IGDB_RATE_LIMITED straight away for a short while instead of calling out.
const COOLDOWN_MAX_S = 60;
let rateLimitedUntil = 0; // ms since epoch

function throwIfCoolingDown(): void {
  const remainingMs = rateLimitedUntil - Date.now();
  if (remainingMs > 0) {
    throw new HttpError(
      429,
      "IGDB_RATE_LIMITED",
      "IGDB rate limit reached, try again shortly",
      Math.ceil(remainingMs / 1000),
    );
  }
}

// The error for a non-OK Twitch / IGDB reply: rate limited, down, or our fault.
function upstreamError(res: Response, what: string): HttpError {
  if (res.status === 429) {
    const retryAfter = parseRetryAfter(
      res.headers.get("Retry-After"),
      DEFAULT_RETRY_AFTER_S,
    );
    rateLimitedUntil = Date.now() + Math.min(retryAfter, COOLDOWN_MAX_S) * 1000;
    return new HttpError(
      429,
      "IGDB_RATE_LIMITED",
      "IGDB rate limit reached, try again shortly",
      retryAfter,
    );
  }
  if (res.status >= 500) {
    return new HttpError(
      503,
      "IGDB_UNAVAILABLE",
      "IGDB is unavailable right now",
      parseRetryAfter(res.headers.get("Retry-After"), 120),
    );
  }
  // Another 4xx is our request or credentials being wrong; a retry won't fix it.
  console.error(`${what} failed with status ${res.status}`);
  return new HttpError(502, "IGDB_ERROR", `${what} failed`);
}

function jsonResponse(
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

function errorResponse(err: HttpError): Response {
  const retryAfter = err.retryAfter;
  return jsonResponse(
    {
      error: err.message,
      code: err.code,
      ...(retryAfter ? { retry_after: retryAfter } : {}),
    },
    err.status,
    retryAfter ? { "Retry-After": String(retryAfter) } : {},
  );
}

// ---------------------------------------------------------------------------
// Twitch app-access token: cached in module scope, so warm instances reuse it.
// ---------------------------------------------------------------------------

type CachedToken = { value: string; expiresAt: number };

let cachedToken: CachedToken | null = null;
let inflightToken: Promise<string> | null = null;

// Refresh a minute early so we never send a token that's about to expire.
const EXPIRY_BUFFER_MS = 60_000;

async function requestNewToken(): Promise<string> {
  const clientId = Deno.env.get("TWITCH_CLIENT_ID");
  const clientSecret = Deno.env.get("TWITCH_CLIENT_SECRET");
  if (!clientId || !clientSecret) {
    console.error("TWITCH_CLIENT_ID / TWITCH_CLIENT_SECRET are not set");
    throw new HttpError(500, "NOT_CONFIGURED", "Server is not configured");
  }

  let res: Response;
  try {
    res = await fetchWithBackoff(() =>
      fetch(TWITCH_TOKEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          client_id: clientId,
          client_secret: clientSecret,
          grant_type: "client_credentials",
        }),
      }), BACKOFF);
  } catch (err) {
    console.error("Twitch token request failed:", err);
    throw new HttpError(503, "IGDB_UNAVAILABLE", "Could not reach Twitch", 120);
  }

  if (!res.ok) throw upstreamError(res, "Twitch authentication");

  const data = await res.json().catch(() => null);
  if (typeof data?.access_token !== "string") {
    throw new HttpError(502, "IGDB_ERROR", "Unexpected response from Twitch");
  }

  const ttlSeconds = typeof data.expires_in === "number" ? data.expires_in : 3600;
  cachedToken = {
    value: data.access_token,
    expiresAt: Date.now() + ttlSeconds * 1000,
  };
  return cachedToken.value;
}

async function getToken(forceRefresh = false): Promise<string> {
  if (
    !forceRefresh &&
    cachedToken &&
    Date.now() < cachedToken.expiresAt - EXPIRY_BUFFER_MS
  ) {
    return cachedToken.value;
  }

  // Concurrent requests share a single token request.
  inflightToken ??= requestNewToken().finally(() => {
    inflightToken = null;
  });
  return await inflightToken;
}

// ---------------------------------------------------------------------------
// IGDB
// ---------------------------------------------------------------------------

async function igdbRequest(
  url: string,
  apicalypse: string,
  token: string,
): Promise<Response> {
  try {
    return await fetchWithBackoff(() =>
      fetch(url, {
        method: "POST",
        headers: {
          "Client-ID": Deno.env.get("TWITCH_CLIENT_ID")!,
          "Authorization": `Bearer ${token}`,
          "Accept": "application/json",
          "Content-Type": "text/plain",
        },
        body: apicalypse,
      }), BACKOFF);
  } catch (err) {
    console.error("IGDB request failed:", err);
    throw new HttpError(503, "IGDB_UNAVAILABLE", "Could not reach IGDB", 120);
  }
}

// Strip control characters, squeeze runs of spaces into one, and escape what
// would break out of the quoted Apicalypse string.
function sanitizeSearchTerm(term: string): string {
  return term
    // deno-lint-ignore no-control-regex
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .trim();
}

function parseLimit(value: unknown): number {
  const n = Math.floor(Number(value));
  if (!Number.isFinite(n) || n < 1) return DEFAULT_LIMIT;
  return Math.min(n, MAX_LIMIT);
}

function parseOffset(value: unknown): number {
  const n = Math.floor(Number(value));
  return Number.isFinite(n) && n > 0 ? n : 0;
}

// Runs one Apicalypse query against an IGDB endpoint and returns the parsed body.
async function queryIgdb(url: string, apicalypse: string): Promise<unknown> {
  throwIfCoolingDown();
  let token = await getToken();
  let res = await igdbRequest(url, apicalypse, token);

  // Token revoked or expired early: refresh once and retry.
  if (res.status === 401) {
    token = await getToken(true);
    res = await igdbRequest(url, apicalypse, token);
  }

  if (!res.ok) throw upstreamError(res, "IGDB request");

  return await res.json().catch(() => {
    throw new HttpError(502, "IGDB_ERROR", "Unexpected response from IGDB");
  });
}

function asList(body: unknown): unknown[] {
  return Array.isArray(body) ? body : [];
}

// The rated games whose title has a word starting with every word of [term]:
// what was meant while the last word is still being typed. Only an extra on top
// of IGDB's search, so a failure here leaves the search to answer alone.
async function titleMatches(
  term: string,
  filters: GameFilters,
): Promise<unknown[]> {
  const words = titleWords(term);
  if (words.length === 0) return [];
  try {
    return asList(
      await queryIgdb(
        IGDB_GAMES_URL,
        titleMatchQuery(GAME_FIELDS, words, filters),
      ),
    );
  } catch (err) {
    console.error("IGDB title match failed:", err);
    return [];
  }
}

// One page of a text search: the title matches, then IGDB's relevance search
// without them (_shared/game_search.ts). The first page, the one waited on while
// typing, asks for both at once and drops the title matches from the search
// itself; a later page needs the title matches' ids to ask the search for the
// right hits.
async function searchGames(
  term: string,
  filters: GameFilters,
  limit: number,
  offset: number,
): Promise<unknown[]> {
  const search = (searchLimit: number, searchOffset: number, exclude: number[]) =>
    queryIgdb(
      IGDB_GAMES_URL,
      filteredSearchQuery(
        GAME_FIELDS,
        term,
        filters,
        searchLimit,
        searchOffset,
        exclude,
      ),
    ).then(asList);

  if (offset === 0) {
    const [titles, hits] = await Promise.all([
      titleMatches(term, filters),
      search(limit, 0, []),
    ]);
    return joinSearchPage(titles, hits, 0, limit);
  }

  const titles = await titleMatches(term, filters);
  const { searchOffset, searchLimit } = searchPagePlan(
    offset,
    limit,
    titles.length,
  );
  const hits = searchLimit > 0
    ? await search(searchLimit, searchOffset, titleIds(titles))
    : [];
  return joinSearchPage(titles, hits, offset, limit);
}

// Games matching [filters], with no search term, in [sort] order.
function discoverGames(
  filters: GameFilters,
  sort: DiscoverSort,
  limit: number,
  offset: number,
): Promise<unknown> {
  return queryIgdb(
    IGDB_GAMES_URL,
    discoverQuery(
      GAME_FIELDS,
      filters,
      sort,
      limit,
      offset,
      Math.floor(Date.now() / 1000),
    ),
  );
}

async function browseGames(
  mode: BrowseMode,
  limit: number,
  offset: number,
): Promise<unknown> {
  switch (mode) {
    case "top_rated":
      return await queryIgdb(
        IGDB_GAMES_URL,
        topRatedQuery(GAME_FIELDS, limit, offset),
      );
    case "new_releases":
      return await queryIgdb(
        IGDB_GAMES_URL,
        newReleasesQuery(GAME_FIELDS, limit, offset, Math.floor(Date.now() / 1000)),
      );
    case "popular": {
      // IGDB ranks game ids on one endpoint and describes games on another.
      const primitives = await queryIgdb(
        IGDB_POPULARITY_URL,
        popularityQuery(limit, offset),
      );
      if (!Array.isArray(primitives)) {
        throw new HttpError(502, "IGDB_ERROR", "Unexpected response from IGDB");
      }
      const ids = rankedGameIds(primitives);
      if (ids.length === 0) return [];
      const games = await queryIgdb(
        IGDB_GAMES_URL,
        gamesByIdQuery(GAME_FIELDS, ids),
      );
      return inRankOrder(ids, games);
    }
  }
}

// ---------------------------------------------------------------------------
// Details: one game's whole page
// ---------------------------------------------------------------------------

// One game with everything the details screen shows.
async function gameDetails(
  igdbId: number,
  lang: string | null,
): Promise<unknown> {
  const game = firstRow(await queryIgdb(IGDB_GAMES_URL, detailsQuery(igdbId)));
  if (!game) throw new HttpError(404, "NOT_FOUND", "No such game");

  const [, translations] = await Promise.all([
    saveCatalogRow(igdbId, game),
    translateFields({ summary: game.summary, storyline: game.storyline }, lang),
  ]);
  return {
    game,
    ...(translations ? { translations } : {}),
  };
}

// ---------------------------------------------------------------------------
// Translations: IGDB's texts in the app's language
// ---------------------------------------------------------------------------

// `text_translations`, read and written with the service role.
function translationStore(
  admin: NonNullable<ReturnType<typeof serviceClient>>,
): TranslationStore {
  return {
    async lookup(hashes, lang) {
      const { data, error } = await admin
        .from("text_translations")
        .select("source_hash, translation")
        .eq("lang", lang)
        .in("source_hash", hashes);
      if (error) throw error;
      return new Map(
        (data ?? []).map((r) => [String(r.source_hash), String(r.translation)]),
      );
    },
    async save(rows) {
      const { error } = await admin
        .from("text_translations")
        .upsert(rows, { onConflict: "source_hash,lang", ignoreDuplicates: true });
      if (error) throw error;
    },
  };
}

// [fields] (a name and the IGDB text under it) translated into [lang], as
// { lang, <name>: <translation> }; null when nothing was: no [lang] (English),
// no DEEPL_API_KEY, no text, or DeepL could not be reached. Never throws.
async function translateFields(
  fields: Record<string, unknown>,
  lang: string | null,
): Promise<Record<string, string> | null> {
  if (!lang) return null;
  const key = Deno.env.get("DEEPL_API_KEY");
  const admin = serviceClient();
  if (!key || !admin) return null;
  const texts: [string, string][] = [];
  for (const [name, value] of Object.entries(fields)) {
    const text = translatable(value);
    if (text) texts.push([name, text]);
  }
  if (texts.length === 0) return null;
  const translated = await translateTexts(texts.map(([, t]) => t), lang, {
    key,
    store: translationStore(admin),
  });
  const result: Record<string, string> = {};
  for (const [name, text] of texts) {
    const translation = translated.get(text);
    if (translation) result[name] = translation;
  }
  return Object.keys(result).length === 0 ? null : { lang, ...result };
}

// ---------------------------------------------------------------------------
// Media: the art a member can pick for a game's backdrop
// ---------------------------------------------------------------------------

// One game's artworks and screenshots.
async function gameMediaFor(igdbId: number): Promise<unknown> {
  const game = firstRow(await queryIgdb(IGDB_GAMES_URL, mediaQuery(igdbId)));
  if (!game) throw new HttpError(404, "NOT_FOUND", "No such game");
  return gameMedia(game);
}

// A client with the service role, or null when its secrets are missing. It
// bypasses RLS: every statement made with it must be scoped to the rows meant.
function serviceClient() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return null;
  return createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// Fills in the shared `games` row of [igdbId] from IGDB's answer, unless it was
// filled in within the last week or the game is not in the catalog (the app adds
// it when someone adds the game). Best effort: the screen needs the answer, not
// this, so a failure is logged and swallowed.
async function saveCatalogRow(
  igdbId: number,
  game: Record<string, unknown>,
): Promise<void> {
  try {
    // Every statement below is scoped to this one IGDB id.
    const admin = serviceClient();
    if (!admin) return;

    const { data: row, error } = await admin
      .from("games")
      .select("id, steam_app_id, igdb_synced_at")
      .eq("igdb_id", igdbId)
      .maybeSingle();
    if (error) throw error;
    if (!row || !isDue(row.igdb_synced_at, Date.now())) return;

    const patch = catalogPatch(
      game,
      row.steam_app_id !== null && row.steam_app_id !== undefined,
      new Date().toISOString(),
    );
    const { error: updateError } = await admin
      .from("games")
      .update(patch)
      .eq("id", row.id);
    if (updateError) throw updateError;
  } catch (err) {
    console.error("could not save the game's details:", err);
  }
}

// ---------------------------------------------------------------------------
// Backfill: the catalog rows of many games at once
// ---------------------------------------------------------------------------

// Catalog rows written at the same time by one backfill request.
const BACKFILL_WRITE_CONCURRENCY = 10;

// Fills in, from ONE IGDB request, the `games` rows of [igdbIds] that are due (see
// isDue), and says what each row holds afterwards, so the app can show it without
// reading its library again. Rows filled in within the last week are answered as
// they are, without asking IGDB (nothing is asked when none is due); ids with no
// catalog row are listed as `unknown`. A row IGDB has no game for is still stamped
// `igdb_synced_at`, so it is not asked about again until it is due. A row whose
// write fails is left out of the answer, so the app asks again later.
async function backfillGames(
  igdbIds: number[],
): Promise<{ games: BackfillGame[]; unknown: number[] }> {
  // Every statement below is scoped to the requested IGDB ids, and writes only
  // the columns catalogPatch fills, from IGDB's own answer.
  const admin = serviceClient();
  if (!admin) {
    console.error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set");
    throw new HttpError(500, "NOT_CONFIGURED", "Server is not configured");
  }

  const { data: rows, error } = await admin
    .from("games")
    .select(CATALOG_ROW_COLUMNS)
    .in("igdb_id", igdbIds);
  if (error) {
    console.error("could not read the catalog rows:", error);
    throw new HttpError(500, "INTERNAL", "Internal error");
  }

  const now = Date.now();
  const { due, fresh, unknown } = planBackfill(
    igdbIds,
    (rows ?? []) as CatalogRow[],
    now,
  );
  const games = fresh.map((row) => backfillGame(row));
  if (due.length === 0) return { games, unknown };

  // A malformed answer must not stamp every row as filled in with nothing.
  const answer = gamesById(
    await queryIgdb(IGDB_GAMES_URL, backfillQuery(due.map((row) => row.igdb_id))),
  );
  if (!answer) {
    throw new HttpError(502, "IGDB_ERROR", "Unexpected response from IGDB");
  }

  const nowIso = new Date(now).toISOString();
  for (let i = 0; i < due.length; i += BACKFILL_WRITE_CONCURRENCY) {
    const saved = await Promise.all(
      due.slice(i, i + BACKFILL_WRITE_CONCURRENCY).map(async (row) => {
        const patch = catalogPatch(
          answer.get(row.igdb_id) ?? {},
          row.steam_app_id !== null && row.steam_app_id !== undefined,
          nowIso,
        );
        const { error: updateError } = await admin
          .from("games")
          .update(patch)
          .eq("id", row.id);
        if (updateError) {
          console.error(`could not fill in game ${row.igdb_id}:`, updateError);
          return null;
        }
        return backfillGame(row, patch);
      }),
    );
    for (const game of saved) if (game) games.push(game);
  }
  return { games, unknown };
}

// ---------------------------------------------------------------------------
// Add: catalog rows for games nobody has added yet
// ---------------------------------------------------------------------------

// Inserts the `games` rows [igdbIds] don't have yet, each built from IGDB's own
// answer (never from the caller), and says which ids were added, which were
// already there and which IGDB has no game for. A row another request inserts at
// the same time is left as it is (ON CONFLICT DO NOTHING).
async function addGames(
  igdbIds: number[],
  userId: string,
): Promise<{ added: number[]; existing: number[]; unknown: number[] }> {
  // Every statement below is scoped to the requested IGDB ids, and inserts only
  // rows made from IGDB's answer.
  const admin = serviceClient();
  if (!admin) {
    console.error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set");
    throw new HttpError(500, "NOT_CONFIGURED", "Server is not configured");
  }

  const { data: rows, error } = await admin
    .from("games")
    .select("igdb_id")
    .in("igdb_id", igdbIds);
  if (error) {
    console.error("could not read the catalog rows:", error);
    throw new HttpError(500, "INTERNAL", "Internal error");
  }
  const existing = new Set((rows ?? []).map((row) => Number(row.igdb_id)));
  const missing = igdbIds.filter((id) => !existing.has(id));
  if (missing.length === 0) return { added: [], existing: [...existing], unknown: [] };

  // A malformed answer must not read as "IGDB has none of these".
  const answer = gamesById(await queryIgdb(IGDB_GAMES_URL, addQuery(missing)));
  if (!answer) {
    throw new HttpError(502, "IGDB_ERROR", "Unexpected response from IGDB");
  }

  const nowIso = new Date().toISOString();
  const newRows: Record<string, unknown>[] = [];
  const unknown: number[] = [];
  for (const id of missing) {
    const row = newCatalogRow(id, answer.get(id) ?? {}, nowIso, userId);
    if (row) newRows.push(row);
    else unknown.push(id);
  }
  if (newRows.length > 0) {
    const { error: insertError } = await admin
      .from("games")
      .upsert(newRows, { onConflict: "igdb_id", ignoreDuplicates: true });
    if (insertError) {
      console.error("could not add the games:", insertError);
      throw new HttpError(500, "INTERNAL", "Internal error");
    }
  }
  return {
    added: newRows.map((row) => row.igdb_id as number),
    existing: [...existing],
    unknown,
  };
}

// ---------------------------------------------------------------------------
// Companies: a publisher's or developer's page, its games, the studio search
// ---------------------------------------------------------------------------

async function companyPage(
  companyId: number,
  lang: string | null,
): Promise<unknown> {
  const company = companyInfo(
    firstRow(await queryIgdb(IGDB_COMPANIES_URL, companyQuery(companyId))),
  );
  if (!company) throw new HttpError(404, "NOT_FOUND", "No such company");
  const translations = await translateFields(
    { description: company.description },
    lang,
  );
  return { company, ...(translations ? { translations } : {}) };
}

function companyGames(
  companyId: number,
  role: CompanyRole,
  sort: DiscoverSort,
  limit: number,
  offset: number,
): Promise<unknown> {
  return queryIgdb(
    IGDB_GAMES_URL,
    companyGamesQuery(
      COMPANY_GAME_FIELDS,
      companyId,
      role,
      sort,
      limit,
      offset,
      Math.floor(Date.now() / 1000),
    ),
  );
}

// A text of nothing to match (only punctuation) lists by the filters alone, and
// with no filters either has nothing to list.
async function searchCompanies(
  term: string,
  filters: CompanyFilters,
  sort: CompanySort,
  limit: number,
  offset: number,
): Promise<unknown> {
  const words = titleWords(term);
  if (words.length === 0 && !hasCompanyFilters(filters)) return [];
  const rows = await queryIgdb(
    IGDB_COMPANIES_URL,
    companiesQuery(words, filters, sort, limit, offset),
  );
  return sort === "popular"
    ? rankCompanies(rows, words.length > 0 ? term : "", limit, offset)
    : listCompanies(rows);
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

// The caller's user id. Throws a 401 unless the request carries a valid *user*
// access token. The anon key (what logged-out clients send) is a valid JWT but
// has no user behind it, so getUser() rejects it.
async function requireUser(req: Request): Promise<string> {
  const authHeader = req.headers.get("Authorization");
  const token = authHeader ? /^Bearer\s+(.+)$/i.exec(authHeader)?.[1] : undefined;
  if (!authHeader || !token) {
    throw new HttpError(401, "UNAUTHENTICATED", "Unauthorized");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !supabaseAnonKey) {
    console.error("SUPABASE_URL / SUPABASE_ANON_KEY are not set");
    throw new HttpError(500, "NOT_CONFIGURED", "Server is not configured");
  }

  // A per-request client that acts as the caller (their Authorization header).
  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // The token is passed explicitly so verification doesn't depend on a stored session.
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data?.user) {
    throw new HttpError(401, "UNAUTHENTICATED", "Unauthorized");
  }
  if (secondFactorMissing(data.user, token)) {
    throw new HttpError(403, "MFA_REQUIRED", "Enter your two-factor code to finish signing in");
  }
  return data.user.id;
}

// Throws a 429 when [userId] has made more requests than RATE_LIMITS.igdb allows.
async function requireUnderRateLimit(userId: string): Promise<void> {
  const admin = serviceClient();
  if (!admin) return; // requests that need the service role fail on their own
  const wait = await rateLimitWait(admin, userId, RATE_LIMITS.igdb);
  if (wait > 0) {
    throw new HttpError(429, "RATE_LIMITED", "Too many requests, try again shortly", wait);
  }
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed", code: "BAD_REQUEST" }, 405);
  }

  try {
    const userId = await requireUser(req);
    await requireUnderRateLimit(userId);

    const payload = await req.json().catch(() => null);

    // `details`: one game's whole page, by IGDB id.
    if (payload?.mode === "details") {
      const igdbId = parseIgdbId(payload?.igdb_id);
      if (igdbId === null) {
        return jsonResponse(
          {
            error: "`igdb_id` must be a positive whole number",
            code: "BAD_REQUEST",
          },
          400,
        );
      }
      return jsonResponse(
        await gameDetails(igdbId, translationLanguage(payload?.lang)),
      );
    }

    // `media`: the art a member can pick for one game's backdrop, by IGDB id.
    if (payload?.mode === "media") {
      const igdbId = parseIgdbId(payload?.igdb_id);
      if (igdbId === null) {
        return jsonResponse(
          {
            error: "`igdb_id` must be a positive whole number",
            code: "BAD_REQUEST",
          },
          400,
        );
      }
      return jsonResponse(await gameMediaFor(igdbId));
    }

    // `backfill`: the catalog rows of up to MAX_BACKFILL_IDS games, by IGDB id.
    if (payload?.mode === "backfill") {
      const igdbIds = parseIgdbIds(payload?.igdb_ids);
      if (igdbIds === null) {
        return jsonResponse(
          {
            error:
              `\`igdb_ids\` must be a list of 1 to ${MAX_BACKFILL_IDS} positive whole numbers`,
            code: "BAD_REQUEST",
          },
          400,
        );
      }
      return jsonResponse(await backfillGames(igdbIds));
    }

    // `add`: catalog rows for up to MAX_BACKFILL_IDS games, by IGDB id.
    if (payload?.mode === "add") {
      const igdbIds = parseIgdbIds(payload?.igdb_ids);
      if (igdbIds === null) {
        return jsonResponse(
          {
            error:
              `\`igdb_ids\` must be a list of 1 to ${MAX_BACKFILL_IDS} positive whole numbers`,
            code: "BAD_REQUEST",
          },
          400,
        );
      }
      return jsonResponse(await addGames(igdbIds, userId));
    }

    // `company`: one company's page, by IGDB id.
    if (payload?.mode === "company") {
      const companyId = parseIgdbId(payload?.company_id);
      if (companyId === null) {
        return jsonResponse(
          {
            error: "`company_id` must be a positive whole number",
            code: "BAD_REQUEST",
          },
          400,
        );
      }
      return jsonResponse(
        await companyPage(companyId, translationLanguage(payload?.lang)),
      );
    }

    // `company_games`: one company's games, in a role and an order.
    if (payload?.mode === "company_games") {
      const companyId = parseIgdbId(payload?.company_id);
      const role = parseCompanyRole(payload?.role);
      const rawSort = payload?.sort ?? "popular";
      if (companyId === null || role === null || !isDiscoverSort(rawSort)) {
        return jsonResponse(
          {
            error:
              "`company_id` must be a positive whole number, `role` one of: any, publisher, developer, " +
              "and `sort` one of: popular, top_rated, newest, oldest",
            code: "BAD_REQUEST",
          },
          400,
        );
      }
      const offset = parseOffset(payload?.offset);
      if (offset >= MAX_RESULTS) return jsonResponse([]);
      return jsonResponse(
        await companyGames(
          companyId,
          role,
          rawSort,
          parseLimit(payload?.limit),
          offset,
        ),
      );
    }

    // `companies`: the studio search and browse, by name and filters.
    if (payload?.mode === "companies") {
      const raw = typeof payload?.query === "string" ? payload.query : "";
      const term = sanitizeSearchTerm(raw.slice(0, MAX_QUERY_LENGTH));
      const filters = parseCompanyFilters(payload?.filters);
      if (typeof filters === "string") {
        return jsonResponse({ error: filters, code: "BAD_REQUEST" }, 400);
      }
      const rawSort = payload?.sort ?? "popular";
      if (!isCompanySort(rawSort)) {
        return jsonResponse(
          {
            error: "`sort` must be one of: popular, name, oldest, newest",
            code: "BAD_REQUEST",
          },
          400,
        );
      }
      if (!term && !hasCompanyFilters(filters)) {
        return jsonResponse(
          {
            error: "A non-empty `query` string or at least one filter is required",
            code: "BAD_REQUEST",
          },
          400,
        );
      }
      const offset = parseOffset(payload?.offset);
      if (offset >= MAX_RESULTS) return jsonResponse([]);
      return jsonResponse(
        await searchCompanies(
          term,
          filters,
          rawSort,
          parseLimit(payload?.limit),
          offset,
        ),
      );
    }

    // A `mode` browses a list; without one the request is a text search.
    const mode = payload?.mode ?? null;
    if (mode !== null && !isBrowseMode(mode)) {
      return jsonResponse(
        {
          error:
            "`mode` must be one of: popular, top_rated, new_releases, details, media, backfill, add, " +
            "company, company_games, companies",
          code: "BAD_REQUEST",
        },
        400,
      );
    }

    const rawQuery = typeof payload?.query === "string" ? payload.query : "";
    const term = sanitizeSearchTerm(rawQuery.slice(0, MAX_QUERY_LENGTH));

    // Filters and a sort only mean something to a search or a filtered browse.
    let filters: GameFilters = NO_FILTERS;
    let sort: DiscoverSort = "popular";
    if (mode === null) {
      const parsed = parseGameFilters(payload?.filters);
      if (typeof parsed === "string") {
        return jsonResponse({ error: parsed, code: "BAD_REQUEST" }, 400);
      }
      filters = parsed;
      const rawSort = payload?.sort ?? null;
      if (rawSort !== null && !isDiscoverSort(rawSort)) {
        return jsonResponse(
          {
            error: "`sort` must be one of: popular, top_rated, newest, oldest",
            code: "BAD_REQUEST",
          },
          400,
        );
      }
      if (rawSort !== null) sort = rawSort;
      if (!term && !hasFilters(filters)) {
        return jsonResponse(
          {
            error: "A non-empty `query` string or at least one filter is required",
            code: "BAD_REQUEST",
          },
          400,
        );
      }
    }

    const offset = parseOffset(payload?.offset);
    // Past the paging ceiling there is nothing more to give; answer without
    // spending an IGDB request.
    if (offset >= MAX_RESULTS) return jsonResponse([]);

    const limit = parseLimit(payload?.limit);
    const games = mode !== null
      ? await browseGames(mode, limit, offset)
      : term
      ? await searchGames(term, filters, limit, offset)
      : await discoverGames(filters, sort, limit, offset);
    return jsonResponse(games);
  } catch (err) {
    if (err instanceof HttpError) return errorResponse(err);
    console.error("Unhandled error in igdb-handler:", err);
    return jsonResponse({ error: "Internal error", code: "INTERNAL" }, 500);
  }
}));