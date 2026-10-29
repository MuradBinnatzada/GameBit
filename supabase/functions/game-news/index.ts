// supabase/functions/game-news/index.ts
//
// Game news for the app's News screen: the latest from the gaming outlets' public
// RSS feeds, and Steam's news for the games a member has. Only logged-in Supabase
// users may call it, and each may make 60 calls a minute (_shared/rate_limit.ts).
//
// Request  (POST, JSON): { "mode": "feed", "lang": "en", "source": "ign",
//                          "limit": 20, "offset": 0 }
//                          the latest articles of the outlets of `lang` (en, the
//                          default, or ru), newest first, merged from their feeds;
//                          `source` (optional) keeps one outlet's. `limit` 1-50
//                          (20), `offset` for paging, up to 100 articles in all.
//                          or { "mode": "steam", "app_ids": [570, 1145360],
//                          "limit": 20, "offset": 0 }
//                          Steam's news for 1 to 10 Steam apps, newest first.
//          Header:       Authorization: Bearer <user access token>
// Response (JSON):       { "articles": [ { id, title, summary, url, image_url,
//                          source_id, source_name, published_at (Unix seconds),
//                          app_id? } ], "sources"?: [ { id, name } ] }
//                        `sources` (feed mode) lists the outlets of `lang`, for the
//                        app's filter, whether or not each answered just now.
//                        or { "error": "...", "code": "...", "retry_after"?: seconds }
//                          UNAUTHENTICATED  (401)  no valid user session
//                          MFA_REQUIRED     (403)  two-factor is on and this session
//                                                  has not entered its code
//                          RATE_LIMITED     (429)  too many requests; `retry_after`
//                          BAD_REQUEST      (400 / 405)
//                          NEWS_UNAVAILABLE (503)  no outlet answered (and none is
//                                                  held from before); `retry_after`
//                          NOT_CONFIGURED   (500)  missing secrets
//                          INTERNAL         (500)  anything else
//
// What an article is, and how a feed is cleaned up, is in _shared/news.ts. The
// function never republishes an article: it sends a headline, a short summary, a
// link and a picture, and the app opens the outlet's own page.
//
// Every feed is fetched at most every 10 minutes by a warm instance (Steam's news
// of an app every 15), however many members ask; a feed that fails is asked again
// after a minute, and the articles held from before are served meanwhile. The
// addresses fetched are the fixed ones of NEWS_SOURCES and Steam's news API, never
// anything the caller sends.
//
// Secrets: none to set. (SUPABASE_URL and SUPABASE_ANON_KEY are injected
// automatically, and SUPABASE_SERVICE_ROLE_KEY for the rate limit.)

import { createClient } from '../_shared/supabase.ts'
import { withCors } from '../_shared/cors.ts'
import { secondFactorMissing } from '../_shared/mfa.ts'
import {
  mergeArticles,
  type NewsArticle,
  type NewsLanguage,
  type NewsSource,
  parseFeed,
  parseNewsRequest,
  sourcesIn,
  steamArticles,
} from '../_shared/news.ts'
import { RATE_LIMITS, rateLimitWait } from '../_shared/rate_limit.ts'

const FEED_TTL_MS = 10 * 60_000
const STEAM_TTL_MS = 15 * 60_000
/** A feed or app that failed is asked again after this long. */
const RETRY_AFTER_FAILURE_MS = 60_000
const FETCH_TIMEOUT_MS = 8_000
/** A feed bigger than this is not read (the biggest of the outlets is under 1 MB). */
const MAX_FEED_BYTES = 3_000_000
const STEAM_NEWS_URL = 'https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/'
const USER_AGENT = 'Mozilla/5.0 (compatible; CheckpointNews/1.0; +https://github.com/)'

type ErrorCode =
  | 'UNAUTHENTICATED'
  | 'MFA_REQUIRED'
  | 'RATE_LIMITED'
  | 'BAD_REQUEST'
  | 'NEWS_UNAVAILABLE'
  | 'NOT_CONFIGURED'
  | 'INTERNAL'

class HttpError extends Error {
  constructor(
    public status: number,
    public code: ErrorCode,
    message: string,
    public retryAfter?: number, // seconds
  ) {
    super(message)
  }
}

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  })
}

function errorResponse(err: HttpError): Response {
  const retryAfter = err.retryAfter
  return jsonResponse(
    { error: err.message, code: err.code, ...(retryAfter ? { retry_after: retryAfter } : {}) },
    err.status,
    retryAfter ? { 'Retry-After': String(retryAfter) } : {},
  )
}

// ---------------------------------------------------------------------------
// Fetching, with a cache that outlives a request (warm instances share it)
// ---------------------------------------------------------------------------

type Held = { at: number; articles: NewsArticle[] }
const held = new Map<string, Held>()
const running = new Map<string, Promise<NewsArticle[] | null>>()

/**
 * The articles of [key], from [fetcher] unless they were fetched less than
 * [ttlMs] ago. A fetch that fails (null) is held as what it was before, and
 * asked again in RETRY_AFTER_FAILURE_MS; the articles held from before are
 * served meanwhile. Concurrent calls share one fetch.
 */
async function cached(
  key: string,
  ttlMs: number,
  fetcher: () => Promise<NewsArticle[] | null>,
): Promise<NewsArticle[]> {
  const now = Date.now()
  const before = held.get(key)
  if (before && now - before.at < ttlMs) return before.articles

  let request = running.get(key)
  if (!request) {
    request = fetcher().finally(() => running.delete(key))
    running.set(key, request)
  }
  const fresh = await request
  if (fresh) {
    held.set(key, { at: Date.now(), articles: fresh })
    return fresh
  }
  held.set(key, { at: Date.now() - ttlMs + RETRY_AFTER_FAILURE_MS, articles: before?.articles ?? [] })
  return before?.articles ?? []
}

/** The body of [url] as text, or null when it can't be had (down, slow, an error page, too big). */
async function fetchText(url: string, accept: string): Promise<string | null> {
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': USER_AGENT, Accept: accept },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    })
    if (!res.ok) {
      console.error(`${url} answered ${res.status}`)
      return null
    }
    const length = Number(res.headers.get('Content-Length') ?? 0)
    if (length > MAX_FEED_BYTES) {
      console.error(`${url} is too big (${length} bytes)`)
      return null
    }
    const text = await res.text()
    return text.length > MAX_FEED_BYTES ? null : text
  } catch (err) {
    console.error(`${url} could not be fetched:`, err)
    return null
  }
}

function feedArticles(source: NewsSource): Promise<NewsArticle[]> {
  return cached(`feed:${source.id}`, FEED_TTL_MS, async () => {
    const xml = await fetchText(source.url, 'application/rss+xml, application/xml, text/xml')
    return xml === null ? null : parseFeed(xml, source, Math.floor(Date.now() / 1000))
  })
}

function steamAppArticles(appId: number): Promise<NewsArticle[]> {
  return cached(`steam:${appId}`, STEAM_TTL_MS, async () => {
    const url = `${STEAM_NEWS_URL}?appid=${appId}&count=5&maxlength=400&format=json`
    const text = await fetchText(url, 'application/json')
    if (text === null) return null
    try {
      return steamArticles(appId, JSON.parse(text), Math.floor(Date.now() / 1000))
    } catch {
      return null
    }
  })
}

/**
 * The merged latest articles of the outlets of [lang] (or just [sourceId]). A
 * language none of whose outlets answered falls back to English, so a member never
 * gets an empty list because a Russian site blocks this server.
 */
async function latest(lang: NewsLanguage, sourceId: string | null): Promise<NewsArticle[]> {
  const sources = sourcesIn(lang).filter((s) => sourceId === null || s.id === sourceId)
  const articles = mergeArticles(await Promise.all(sources.map(feedArticles)))
  if (articles.length > 0 || lang === 'en' || sourceId !== null) return articles
  return mergeArticles(await Promise.all(sourcesIn('en').map(feedArticles)))
}

// ---------------------------------------------------------------------------
// Authentication and rate limit
// ---------------------------------------------------------------------------

function serviceClient() {
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceKey) return null
  return createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
}

// The caller's user id. Throws a 401 unless the request carries a valid *user*
// access token (the anon key is a valid JWT but has no user behind it).
async function requireUser(req: Request): Promise<string> {
  const authHeader = req.headers.get('Authorization')
  const token = authHeader ? /^Bearer\s+(.+)$/i.exec(authHeader)?.[1] : undefined
  if (!authHeader || !token) throw new HttpError(401, 'UNAUTHENTICATED', 'Unauthorized')

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')
  if (!supabaseUrl || !supabaseAnonKey) {
    console.error('SUPABASE_URL / SUPABASE_ANON_KEY are not set')
    throw new HttpError(500, 'NOT_CONFIGURED', 'Server is not configured')
  }
  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data, error } = await supabase.auth.getUser(token)
  if (error || !data?.user) throw new HttpError(401, 'UNAUTHENTICATED', 'Unauthorized')
  if (secondFactorMissing(data.user, token)) {
    throw new HttpError(403, 'MFA_REQUIRED', 'Enter your two-factor code to finish signing in')
  }
  return data.user.id
}

async function requireUnderRateLimit(userId: string): Promise<void> {
  const admin = serviceClient()
  if (!admin) return
  const wait = await rateLimitWait(admin, userId, RATE_LIMITS.news)
  if (wait > 0) throw new HttpError(429, 'RATE_LIMITED', 'Too many requests, try again shortly', wait)
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed', code: 'BAD_REQUEST' }, 405)
  }
  try {
    const userId = await requireUser(req)
    await requireUnderRateLimit(userId)

    const request = parseNewsRequest(await req.json().catch(() => null))
    if (typeof request === 'string') {
      return jsonResponse({ error: request, code: 'BAD_REQUEST' }, 400)
    }

    if (request.mode === 'feed') {
      const all = await latest(request.lang, request.source)
      if (all.length === 0 && request.source === null && request.offset === 0) {
        throw new HttpError(503, 'NEWS_UNAVAILABLE', 'No news right now, try again shortly', 60)
      }
      return jsonResponse({
        articles: all.slice(request.offset, request.offset + request.limit),
        sources: sourcesIn(request.lang).map(({ id, name }) => ({ id, name })),
      })
    }

    const articles = mergeArticles(await Promise.all(request.appIds.map(steamAppArticles)))
    return jsonResponse({ articles: articles.slice(request.offset, request.offset + request.limit) })
  } catch (err) {
    if (err instanceof HttpError) return errorResponse(err)
    console.error('Unhandled error in game-news:', err)
    return jsonResponse({ error: 'Internal error', code: 'INTERNAL' }, 500)
  }
}))
