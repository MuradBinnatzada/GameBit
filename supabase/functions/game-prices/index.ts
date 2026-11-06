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

import { createClient } from '../_shared/supabase.ts'
import { withCors } from '../_shared/cors.ts'
import { secondFactorMissing } from '../_shared/mfa.ts'
import { RATE_LIMITS, rateLimitWait } from '../_shared/rate_limit.ts'
import { type GamePrice, parsePriceRequest } from '../_shared/game_prices.ts'
import { ItadError, pricesFor, resolveGames } from '../_shared/itad.ts'

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
