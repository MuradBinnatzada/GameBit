// supabase/functions/game-prices/index.ts
//
// Prices for the wishlist: the best current price of a game in the main PC stores
// and the lowest price it has ever had, from IsThereAnyDeal (https://isthereanydeal.com).
// Only logged-in Supabase users may call it, and each may make 30 calls in 10
// minutes (_shared/rate_limit.ts).
//
// Request  (POST, JSON): { "game_ids": ["<games.id>", …], "country": "DE" }
//                          1 to 50 catalog games; `country` (two letters, "US" by
//                          default) picks the currency and the stores' prices.
//          Header:       Authorization: Bearer <user access token>
// Response (JSON):       { "prices": { "<games.id>": {
//                            shop: { id, name }, price: { amount, currency },
//                            regular: { amount, currency }, cut (percent off),
//                            url (the store's page), expiry (ISO time | null),
//                            history_low: { amount, currency } | null } | null } }
//                        A game with no price (not on sale anywhere, not a PC
//                        game, or one ITAD doesn't know yet) is null.
//                        or { "error": "...", "code": "...", "retry_after"?: seconds }
//                          UNAUTHENTICATED     (401)  no valid user session
//                          MFA_REQUIRED        (403)  two-factor is on and this session
//                                                     has not entered its code
//                          RATE_LIMITED        (429)  too many requests; `retry_after`
//                          BAD_REQUEST         (400 / 405)
//                          PRICES_UNAVAILABLE  (503)  ITAD didn't answer; `retry_after`
//                          NOT_CONFIGURED      (500)  missing secrets
//                          INTERNAL            (500)  anything else
//
// Which ITAD game a catalog game is: the Steam app id when the game has one
// (`games.steam_app_id`, one lookup for all of them), otherwise its title, and only
// when ITAD has a game of exactly that title (_shared/game_prices.ts). The answer
// is kept in `games.itad_id`; a game ITAD didn't know is asked about again after a
// week. The title comes from the catalog row, never from the caller, so a member
// can't make a game look like another one to everybody.
//
// Prices are kept for 2 hours by a warm instance, however many members ask, and
// the copy held is served if ITAD fails. Prices and links go on exactly as ITAD
// sends them; the app credits ITAD.
//
// Secrets:  ITAD_API_KEY   an API key from https://isthereanydeal.com/apps/my/
//                          (`supabase secrets set ITAD_API_KEY=...`)
//           (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are
//           injected automatically.)

import { createClient, type SupabaseClient } from '../_shared/supabase.ts'
import { withCors } from '../_shared/cors.ts'
import { secondFactorMissing } from '../_shared/mfa.ts'
import { RATE_LIMITS, rateLimitWait } from '../_shared/rate_limit.ts'
import {
  type GamePrice,
  type ItadGame,
  lookupDue,
  MAX_TITLE_LOOKUPS,
  normalizeTitle,
  parseLookup,
  parsePriceRequest,
  parsePrices,
  parseShopLookup,
  pickSearchMatch,
  PRICE_SHOPS,
  STEAM_SHOP_ID,
  steamShopIds,
} from '../_shared/game_prices.ts'

const ITAD_API = 'https://api.isthereanydeal.com'
const FETCH_TIMEOUT_MS = 8_000
const PRICE_TTL_MS = 2 * 3_600_000
const MAX_HELD_PRICES = 5_000
const TITLE_LOOKUP_CONCURRENCY = 4
const USER_AGENT = 'Gamebit/1.0 (game prices)'

type ErrorCode =
  | 'UNAUTHENTICATED'
  | 'MFA_REQUIRED'
  | 'RATE_LIMITED'
  | 'BAD_REQUEST'
  | 'PRICES_UNAVAILABLE'
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
// ITAD
// ---------------------------------------------------------------------------

/** ITAD answered with [status] (429: too many requests, wait [retryAfter] seconds). */
class ItadError extends Error {
  constructor(public status: number, public retryAfter = 60) {
    super(`ITAD answered ${status}`)
  }
}

async function itad(
  path: string,
  apiKey: string,
  options: { query?: Record<string, string>; body?: unknown } = {},
): Promise<unknown> {
  const url = new URL(path, ITAD_API)
  for (const [name, value] of Object.entries(options.query ?? {})) url.searchParams.set(name, value)
  const hasBody = options.body !== undefined
  let res: Response
  try {
    res = await fetch(url, {
      method: hasBody ? 'POST' : 'GET',
      // The key goes in a header, not the address, so it is not in anyone's logs.
      headers: {
        'ITAD-API-Key': apiKey,
        Accept: 'application/json',
        'User-Agent': USER_AGENT,
        ...(hasBody ? { 'Content-Type': 'application/json' } : {}),
      },
      body: hasBody ? JSON.stringify(options.body) : undefined,
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    })
  } catch (err) {
    console.error(`${path} could not be fetched:`, err)
    throw new ItadError(0)
  }
  if (res.status === 429) {
    const wait = Number(res.headers.get('Retry-After'))
    throw new ItadError(429, Number.isFinite(wait) && wait > 0 ? Math.ceil(wait) : 60)
  }
  if (!res.ok) {
    console.error(`${path} answered ${res.status}`)
    throw new ItadError(res.status)
  }
  try {
    return await res.json()
  } catch {
    throw new ItadError(502)
  }
}

// ---------------------------------------------------------------------------
// Which ITAD game a catalog game is
// ---------------------------------------------------------------------------

type CatalogRow = {
  id: string
  title: string
  steam_app_id: number | null
  itad_id: string | null
  itad_checked_at: string | null
}

/** [row]'s game by title: an exact lookup first, then a search for the same title. */
async function matchByTitle(apiKey: string, title: string): Promise<ItadGame | null> {
  const exact = parseLookup(await itad('/games/lookup/v1', apiKey, { query: { title } }))
  if (exact && normalizeTitle(exact.title) === normalizeTitle(title)) return exact
  return pickSearchMatch(title, await itad('/games/search/v1', apiKey, { query: { title, results: '20' } }))
}

/** Runs [work] for every item, [limit] at a time. */
async function inBatches<T>(items: T[], limit: number, work: (item: T) => Promise<void>): Promise<void> {
  for (let i = 0; i < items.length; i += limit) {
    await Promise.all(items.slice(i, i + limit).map(work))
  }
}

async function remember(
  admin: SupabaseClient,
  gameId: string,
  itadId: string | null,
  now: string,
): Promise<void> {
  const { error } = await admin.from('games').update({ itad_id: itadId, itad_checked_at: now }).eq('id', gameId)
  if (error) console.error('could not save the ITAD game of', gameId, error)
}

/**
 * The ITAD game of each of [gameIds] (null: ITAD has none, or it is not known yet).
 * A game ITAD answered "no such game" for is stamped so it is not asked again for
 * a week; a game whose lookup failed is not stamped and is asked again next time.
 */
async function resolveGames(
  admin: SupabaseClient,
  apiKey: string,
  gameIds: string[],
): Promise<Map<string, string | null>> {
  const { data, error } = await admin
    .from('games')
    .select('id, title, steam_app_id, itad_id, itad_checked_at')
    .in('id', gameIds)
  if (error) throw error

  const now = Date.now()
  const stamp = new Date(now).toISOString()
  const resolved = new Map<string, string | null>()
  const due: CatalogRow[] = []
  for (const row of (data ?? []) as CatalogRow[]) {
    if (row.itad_id) resolved.set(row.id, row.itad_id)
    else if (lookupDue(row.itad_checked_at, now)) due.push(row)
    else resolved.set(row.id, null)
  }

  const unmatched: CatalogRow[] = []
  const withApp = due.filter((r) => r.steam_app_id !== null)
  const byApp = withApp.length > 0
    ? parseShopLookup(
      await itad(`/lookup/id/shop/${STEAM_SHOP_ID}/v1`, apiKey, {
        body: steamShopIds(withApp.map((r) => Number(r.steam_app_id))),
      }),
    )
    : new Map<number, string>()
  for (const row of due) {
    const itadId = row.steam_app_id === null ? undefined : byApp.get(Number(row.steam_app_id))
    if (itadId) {
      resolved.set(row.id, itadId)
      await remember(admin, row.id, itadId, stamp)
    } else {
      unmatched.push(row)
    }
  }

  await inBatches(unmatched.slice(0, MAX_TITLE_LOOKUPS), TITLE_LOOKUP_CONCURRENCY, async (row) => {
    try {
      const game = await matchByTitle(apiKey, row.title)
      resolved.set(row.id, game?.id ?? null)
      await remember(admin, row.id, game?.id ?? null, stamp)
    } catch (err) {
      // Too many requests ends the whole call; any other failure leaves this one
      // game for next time.
      if (err instanceof ItadError && err.status === 429) throw err
      resolved.set(row.id, null)
    }
  })
  for (const row of unmatched.slice(MAX_TITLE_LOOKUPS)) resolved.set(row.id, null)
  return resolved
}

// ---------------------------------------------------------------------------
// Prices, with a cache that outlives a request (warm instances share it)
// ---------------------------------------------------------------------------

type Held = { at: number; price: GamePrice | null }
const held = new Map<string, Held>()

function hold(key: string, price: GamePrice | null, now: number): void {
  held.delete(key)
  held.set(key, { at: now, price })
  // Oldest first: a Map keeps the order things went in.
  while (held.size > MAX_HELD_PRICES) held.delete(held.keys().next().value as string)
}

async function fetchPrices(apiKey: string, itadIds: string[], country: string): Promise<Map<string, GamePrice | null>> {
  const query = { country, shops: PRICE_SHOPS.join(',') }
  try {
    return parsePrices(await itad('/games/prices/v3', apiKey, { query, body: itadIds }))
  } catch (err) {
    // A country ITAD doesn't know: the prices in dollars rather than none.
    if (err instanceof ItadError && err.status === 400 && country !== 'US') {
      return parsePrices(await itad('/games/prices/v3', apiKey, { query: { ...query, country: 'US' }, body: itadIds }))
    }
    throw err
  }
}

/** The best price of each of [itadIds] in [country] (null: no store has it). */
async function pricesFor(
  apiKey: string,
  itadIds: string[],
  country: string,
): Promise<Map<string, GamePrice | null>> {
  const now = Date.now()
  const prices = new Map<string, GamePrice | null>()
  const stale = new Map<string, GamePrice | null>()
  const missing: string[] = []
  for (const id of itadIds) {
    const copy = held.get(`${country}:${id}`)
    if (copy && now - copy.at < PRICE_TTL_MS) prices.set(id, copy.price)
    else {
      missing.push(id)
      if (copy) stale.set(id, copy.price)
    }
  }
  if (missing.length === 0) return prices

  try {
    const fresh = await fetchPrices(apiKey, missing, country)
    for (const id of missing) {
      // A game ITAD left out of its answer has no price.
      const price = fresh.get(id) ?? null
      prices.set(id, price)
      hold(`${country}:${id}`, price, now)
    }
  } catch (err) {
    // The copies held from before are served; with none, the member is told.
    if (stale.size === 0) throw err
    for (const [id, price] of stale) prices.set(id, price)
  }
  return prices
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
  const wait = await rateLimitWait(admin, userId, RATE_LIMITS.gamePrices)
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

    const request = parsePriceRequest(await req.json().catch(() => null))
    if (typeof request === 'string') {
      return jsonResponse({ error: request, code: 'BAD_REQUEST' }, 400)
    }

    const apiKey = Deno.env.get('ITAD_API_KEY')
    const admin = serviceClient()
    if (!apiKey || !admin) {
      console.error('ITAD_API_KEY / SUPABASE_SERVICE_ROLE_KEY are not set')
      throw new HttpError(500, 'NOT_CONFIGURED', 'Prices are not set up')
    }

    const itadIds = await resolveGames(admin, apiKey, request.gameIds)
    const wanted = [...new Set([...itadIds.values()].filter((id): id is string => id !== null))]
    const prices = wanted.length > 0 ? await pricesFor(apiKey, wanted, request.country) : new Map()

    const answer: Record<string, GamePrice | null> = {}
    for (const gameId of request.gameIds) {
      const itadId = itadIds.get(gameId) ?? null
      answer[gameId] = itadId === null ? null : prices.get(itadId) ?? null
    }
    return jsonResponse({ prices: answer })
  } catch (err) {
    if (err instanceof HttpError) return errorResponse(err)
    if (err instanceof ItadError) {
      return errorResponse(new HttpError(503, 'PRICES_UNAVAILABLE', 'No prices right now, try again shortly', err.retryAfter))
    }
    console.error('Unhandled error in game-prices:', err)
    return jsonResponse({ error: 'Internal error', code: 'INTERNAL' }, 500)
  }
}))
