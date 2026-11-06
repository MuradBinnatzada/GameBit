// supabase/functions/_shared/game_prices.ts
//
// What the game-prices function asks IsThereAnyDeal (ITAD) and sends back: which
// ITAD game a catalog game is, and the best current price of it with its lowest
// price ever. Pure functions with no I/O, so they can be tested.
//
// The shapes read here are those of ITAD's OpenAPI document (https://docs.isthereanydeal.com),
// read 2026-11-06:
//   POST /lookup/id/shop/61/v1      ["app/220"]  ->  { "app/220": "<uuid>" | null }
//   GET  /games/lookup/v1?title=…   ->  { found, game?: { id, slug, title, type, … } }
//   GET  /games/search/v1?title=…   ->  [ { id, slug, title, type, … } ]
//   POST /games/prices/v3?country=US&shops=61,35  [<uuid>, …]
//        ->  [ { id, historyLow: { all, y1, m3 }, deals: [ { shop: { id, name },
//              price, regular, cut, url, expiry, … } ] } ]      (a price is { amount, amountInt, currency })
// ITAD's terms (same document): prices and links are shown as they come (no
// price is changed, no affiliate tag removed from a link) and ITAD is credited.

/** ITAD's id for Steam among its shops (`/service/shops/v1`). */
export const STEAM_SHOP_ID = 61

/**
 * The stores a price is taken from: Steam, GOG, Epic, Humble, GreenManGaming and
 * Fanatical. ITAD tracks many more, key resellers among them; the best price of
 * those is not one to send a member to.
 */
export const PRICE_SHOPS: readonly number[] = [61, 35, 16, 37, 36, 6]

/** Most games one request may ask about. */
export const MAX_GAMES = 50

/** Games per request that may need an ITAD lookup by title (one request each). */
export const MAX_TITLE_LOOKUPS = 12

/** A game ITAD doesn't know is asked about again after this many days. */
export const RETRY_UNKNOWN_DAYS = 7

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export type PriceRequest = { gameIds: string[]; country: string }

/** The request body as a [PriceRequest], or the reason it is refused. */
export function parsePriceRequest(body: unknown): PriceRequest | string {
  if (typeof body !== 'object' || body === null) return 'Send a JSON object'
  const { game_ids, country } = body as { game_ids?: unknown; country?: unknown }
  if (!Array.isArray(game_ids) || game_ids.length === 0) return 'game_ids must be a list of game ids'
  const ids = new Set<string>()
  for (const id of game_ids) {
    if (typeof id !== 'string' || !UUID.test(id)) return 'game_ids must be game ids'
    ids.add(id.toLowerCase())
  }
  if (ids.size > MAX_GAMES) return `Ask about at most ${MAX_GAMES} games at a time`
  let code = 'US'
  if (country !== undefined && country !== null) {
    if (typeof country !== 'string' || !/^[A-Za-z]{2}$/.test(country)) return 'country must be a two-letter code'
    code = country.toUpperCase()
  }
  return { gameIds: [...ids], country: code }
}

/**
 * A title with everything that doesn't tell two games apart taken out (case,
 * accents, ™ and ®, punctuation, "&" versus "and"), so "Marvel's Spider-Man" and
 * "MARVEL’S SPIDER-MAN™" are the same. Nothing is guessed beyond that: two titles
 * that differ by a word, a number or a subtitle are two games.
 */
export function normalizeTitle(title: string): string {
  return title
    // Before the Unicode normalization below, which would turn ™ into the letters "TM".
    .replace(/[™®©]/g, '')
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim()
}

/** An ITAD game, as far as matching needs it. */
export type ItadGame = { id: string; title: string; type: string | null }

function readGame(raw: unknown): ItadGame | null {
  const g = raw as { id?: unknown; title?: unknown; type?: unknown } | null
  if (typeof g?.id !== 'string' || !UUID.test(g.id) || typeof g.title !== 'string') return null
  return { id: g.id.toLowerCase(), title: g.title, type: typeof g.type === 'string' ? g.type : null }
}

/** The game ITAD found for a title or Steam app id (`found: true`), or null. */
export function parseLookup(raw: unknown): ItadGame | null {
  const r = raw as { found?: unknown; game?: unknown } | null
  return r?.found === true ? readGame(r.game) : null
}

/**
 * The search result that is [title] itself, or null: the first whose normalized
 * title is the same, a plain game before a DLC or a package. A "closest match" is
 * never taken, because a price of the wrong game is worse than none.
 */
export function pickSearchMatch(title: string, raw: unknown): ItadGame | null {
  if (!Array.isArray(raw)) return null
  const wanted = normalizeTitle(title)
  if (wanted === '') return null
  const same = raw.map(readGame).filter((g): g is ItadGame => g !== null && normalizeTitle(g.title) === wanted)
  return same.find((g) => g.type === 'game') ?? same[0] ?? null
}

/** ITAD's shop id lookup as Steam app id -> ITAD game id; apps it doesn't know are left out. */
export function parseShopLookup(raw: unknown): Map<number, string> {
  const found = new Map<number, string>()
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return found
  for (const [key, value] of Object.entries(raw)) {
    const app = /^app\/(\d+)$/.exec(key)
    if (!app || typeof value !== 'string' || !UUID.test(value)) continue
    found.set(Number(app[1]), value.toLowerCase())
  }
  return found
}

/** The shop ids to send ITAD for [appIds]: `app/<id>`. */
export function steamShopIds(appIds: number[]): string[] {
  return appIds.filter((id) => Number.isSafeInteger(id) && id > 0).map((id) => `app/${id}`)
}

/** Whether a game ITAD didn't know (or never asked about) should be asked about now. */
export function lookupDue(checkedAt: string | null, nowMs: number): boolean {
  if (checkedAt === null) return true
  const at = Date.parse(checkedAt)
  return Number.isNaN(at) || nowMs - at >= RETRY_UNKNOWN_DAYS * 86_400_000
}

export type Money = { amount: number; currency: string }

/** The best price of a game, as the app gets it. */
export type GamePrice = {
  shop: { id: number; name: string }
  price: Money
  regular: Money
  /** Percent off the regular price, 0 when it is not on sale. */
  cut: number
  /** The store's page, exactly as ITAD gave it. */
  url: string
  /** ISO time the sale ends, when the store says. */
  expiry: string | null
  /** The lowest price the game has ever had, when ITAD knows it. */
  history_low: Money | null
}

function readMoney(raw: unknown): Money | null {
  const m = raw as { amount?: unknown; currency?: unknown } | null
  if (typeof m?.amount !== 'number' || !Number.isFinite(m.amount) || m.amount < 0) return null
  if (typeof m.currency !== 'string' || !/^[A-Z]{3}$/.test(m.currency)) return null
  return { amount: m.amount, currency: m.currency }
}

function readDeal(raw: unknown): Omit<GamePrice, 'history_low'> | null {
  const d = raw as {
    shop?: { id?: unknown; name?: unknown }
    price?: unknown
    regular?: unknown
    cut?: unknown
    url?: unknown
    expiry?: unknown
  } | null
  const price = readMoney(d?.price)
  const regular = readMoney(d?.regular)
  const shop = d?.shop
  if (!price || !regular || typeof shop?.id !== 'number' || typeof shop.name !== 'string') return null
  if (typeof d?.url !== 'string' || !d.url.startsWith('https://')) return null
  const cut = typeof d.cut === 'number' && d.cut > 0 ? Math.min(100, Math.round(d.cut)) : 0
  const expiry = typeof d.expiry === 'string' && !Number.isNaN(Date.parse(d.expiry)) ? d.expiry : null
  return { shop: { id: shop.id, name: shop.name }, price, regular, cut, url: d.url, expiry }
}

/**
 * The cheapest of a game's deals (on a tie the bigger cut, then the shop's name),
 * with the lowest price ever, or null when no store has it. Prices and links are
 * passed on as ITAD gave them.
 */
export function bestPrice(raw: unknown): GamePrice | null {
  const entry = raw as { deals?: unknown; historyLow?: { all?: unknown } } | null
  if (!Array.isArray(entry?.deals)) return null
  const deals = entry.deals.map(readDeal).filter((d): d is Omit<GamePrice, 'history_low'> => d !== null)
  if (deals.length === 0) return null
  deals.sort((a, b) =>
    a.price.amount - b.price.amount || b.cut - a.cut || a.shop.name.localeCompare(b.shop.name)
  )
  const best = deals[0]
  return { ...best, history_low: readMoney(entry.historyLow?.all) }
}

/** ITAD's prices answer as ITAD game id -> best price (null: no store has it). */
export function parsePrices(raw: unknown): Map<string, GamePrice | null> {
  const prices = new Map<string, GamePrice | null>()
  if (!Array.isArray(raw)) return prices
  for (const entry of raw) {
    const id = (entry as { id?: unknown } | null)?.id
    if (typeof id !== 'string' || !UUID.test(id)) continue
    prices.set(id.toLowerCase(), bestPrice(entry))
  }
  return prices
}
