// supabase/functions/_shared/itad.ts
//
// The calls to IsThereAnyDeal (https://isthereanydeal.com) that game-prices (a member's
// own wishlist, on demand) and check-prices (every wishlist, on a schedule) share: which
// ITAD game a catalog game is, and the best price of it. What the answers mean is in
// game_prices.ts, which has no I/O; this has the requests, the cache that outlives one
// (a warm instance keeps a price 2 hours) and the answer saved on `games.itad_id`.

import type { SupabaseClient } from './supabase.ts'
import {
  type GamePrice,
  type ItadGame,
  lookupDue,
  MAX_TITLE_LOOKUPS,
  normalizeTitle,
  parseLookup,
  parsePrices,
  parseShopLookup,
  pickSearchMatch,
  PRICE_SHOPS,
  STEAM_SHOP_ID,
  steamShopIds,
} from './game_prices.ts'

const ITAD_API = 'https://api.isthereanydeal.com'
const FETCH_TIMEOUT_MS = 8_000
const PRICE_TTL_MS = 2 * 3_600_000
const MAX_HELD_PRICES = 5_000
const TITLE_LOOKUP_CONCURRENCY = 4
const USER_AGENT = 'Gamebit/1.0 (game prices)'

// ---------------------------------------------------------------------------
// ITAD
// ---------------------------------------------------------------------------

/** ITAD answered with [status] (429: too many requests, wait [retryAfter] seconds). */
export class ItadError extends Error {
  constructor(public status: number, public retryAfter = 60) {
    super(`ITAD answered ${status}`)
  }
}

export async function itad(
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
export async function resolveGames(
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
export async function pricesFor(
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
