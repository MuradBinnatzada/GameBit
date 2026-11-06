import { assertEquals } from 'jsr:@std/assert@1'
import {
  bestPrice,
  lookupDue,
  MAX_GAMES,
  normalizeTitle,
  parseLookup,
  parsePriceRequest,
  parsePrices,
  parseShopLookup,
  pickSearchMatch,
  PRICE_SHOPS,
  RETRY_UNKNOWN_DAYS,
  STEAM_SHOP_ID,
  steamShopIds,
} from './game_prices.ts'

const ID_A = '018d937f-012f-73b8-ab2c-898516969e6a'
const ID_B = '018d937f-590c-728b-ac35-38bcff85f086'
const GAME_ID = '00000000-0000-4000-8000-000000001942'

const money = (amount: number, currency = 'EUR') => ({ amount, amountInt: Math.round(amount * 100), currency })
const deal = (shop: string, price: number, regular: number, cut: number, extra: Record<string, unknown> = {}) => ({
  shop: { id: shop.length, name: shop },
  price: money(price),
  regular: money(regular),
  cut,
  voucher: null,
  storeLow: null,
  flag: null,
  drm: [],
  platforms: [],
  timestamp: '2026-11-06T12:00:00+01:00',
  expiry: null,
  url: `https://itad.link/${shop}?aff=gamebit`,
  ...extra,
})

Deno.test('Steam is among the stores prices are taken from', () => {
  assertEquals(PRICE_SHOPS.includes(STEAM_SHOP_ID), true)
  assertEquals(new Set(PRICE_SHOPS).size, PRICE_SHOPS.length)
})

Deno.test('a request names game ids and a country', () => {
  assertEquals(parsePriceRequest({ game_ids: [GAME_ID] }), { gameIds: [GAME_ID], country: 'US' })
  assertEquals(parsePriceRequest({ game_ids: [GAME_ID.toUpperCase(), GAME_ID], country: 'de' }), {
    gameIds: [GAME_ID],
    country: 'DE',
  })
})

Deno.test('a request that is not that is refused with a reason', () => {
  for (const body of [null, 'x', [], {}, { game_ids: [] }, { game_ids: 'x' }, { game_ids: [1] }, { game_ids: ['1942'] }]) {
    assertEquals(typeof parsePriceRequest(body), 'string', JSON.stringify(body))
  }
  for (const country of ['', 'USA', 'U', 5, '1a', ' US']) {
    assertEquals(typeof parsePriceRequest({ game_ids: [GAME_ID], country }), 'string', String(country))
  }
  const many = Array.from({ length: MAX_GAMES + 1 }, (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`)
  assertEquals(typeof parsePriceRequest({ game_ids: many }), 'string')
  assertEquals(typeof parsePriceRequest({ game_ids: many.slice(0, MAX_GAMES) }), 'object')
})

Deno.test('titles are the same when only case, accents, marks and punctuation differ', () => {
  assertEquals(normalizeTitle('Marvel’s Spider-Man™ Remastered'), normalizeTitle("MARVEL'S SPIDER MAN remastered"))
  assertEquals(normalizeTitle('Pokémon Legends: Z-A'), 'pokemon legends z a')
  assertEquals(normalizeTitle('Dungeons & Dragons'), normalizeTitle('Dungeons and Dragons'))
  assertEquals(normalizeTitle('Ведьмак 3: Дикая Охота'), 'ведьмак 3 дикая охота')
  assertEquals(normalizeTitle('  !!!  '), '')
})

Deno.test('a trademark sign between words is a space, as the app reads PlayStation names', () => {
  assertEquals(normalizeTitle('Minecraft: PlayStation®3 Edition'), normalizeTitle('Minecraft: PlayStation 3 Edition'))
  assertEquals(normalizeTitle('Minecraft: PlayStation®3 Edition'), 'minecraft playstation 3 edition')
  assertEquals(normalizeTitle('Rocket League®'), 'rocket league')
})

Deno.test('titles that differ by a word or a number stay different', () => {
  assertEquals(normalizeTitle('Tomb Raider') === normalizeTitle('Rise of the Tomb Raider'), false)
  assertEquals(normalizeTitle('Civilization VI') === normalizeTitle('Civilization V'), false)
  assertEquals(normalizeTitle('Hades') === normalizeTitle('Hades II'), false)
})

Deno.test('a lookup that found a game gives its id and title', () => {
  const found = { found: true, game: { id: ID_A.toUpperCase(), slug: 'x', title: 'Half-Life 2', type: 'game', mature: false, assets: {} } }
  assertEquals(parseLookup(found), { id: ID_A, title: 'Half-Life 2', type: 'game' })
  assertEquals(parseLookup({ found: false }), null)
  assertEquals(parseLookup({ found: true, game: { id: 'nope', title: 'x' } }), null)
  assertEquals(parseLookup({ found: true }), null)
  assertEquals(parseLookup(null), null)
  assertEquals(parseLookup([]), null)
})

Deno.test('a search takes only the game with the same title', () => {
  const results = [
    { id: ID_B, title: 'Hades II', type: 'game' },
    { id: ID_A, title: 'Hades', type: 'game' },
  ]
  assertEquals(pickSearchMatch('HADES', results)?.id, ID_A)
  assertEquals(pickSearchMatch('Hades III', results), null)
  assertEquals(pickSearchMatch('Anything', []), null)
  assertEquals(pickSearchMatch('Anything', { not: 'a list' }), null)
  assertEquals(pickSearchMatch('!!!', [{ id: ID_A, title: '???', type: 'game' }]), null)
})

Deno.test('a search prefers the game over its DLC or package of the same name', () => {
  const results = [
    { id: ID_B, title: 'Alan Wake', type: 'dlc' },
    { id: ID_A, title: 'Alan Wake', type: 'game' },
  ]
  assertEquals(pickSearchMatch('Alan Wake', results)?.id, ID_A)
  assertEquals(pickSearchMatch('Alan Wake', [results[0]])?.id, ID_B)
})

Deno.test('the shop lookup keeps the Steam apps ITAD knows', () => {
  const answer = { 'app/220': ID_A, 'app/1245620': ID_B.toUpperCase(), 'app/137730': null, 'sub/5': ID_A, 'app/x': ID_A }
  assertEquals(parseShopLookup(answer), new Map([[220, ID_A], [1245620, ID_B]]))
  assertEquals(parseShopLookup(null).size, 0)
  assertEquals(parseShopLookup([]).size, 0)
  assertEquals(steamShopIds([220, 0, -1, 1.5, 1245620]), ['app/220', 'app/1245620'])
})

Deno.test('the cheapest deal is the price, with the lowest ever beside it', () => {
  const price = bestPrice({
    id: ID_A,
    historyLow: { all: money(9.99), y1: money(14.99), m3: null },
    deals: [
      deal('Steam', 29.99, 59.99, 50),
      deal('GOG', 24.99, 59.99, 58, { expiry: '2026-11-20T10:00:00+01:00' }),
      deal('Epic', 59.99, 59.99, 0),
    ],
  })
  assertEquals(price, {
    shop: { id: 3, name: 'GOG' },
    price: { amount: 24.99, currency: 'EUR' },
    regular: { amount: 59.99, currency: 'EUR' },
    cut: 58,
    url: 'https://itad.link/GOG?aff=gamebit',
    expiry: '2026-11-20T10:00:00+01:00',
    history_low: { amount: 9.99, currency: 'EUR' },
  })
})

Deno.test('a tie goes to the bigger cut, then to the shop name', () => {
  const same = bestPrice({ deals: [deal('Steam', 20, 40, 50), deal('GOG', 20, 40, 50), deal('Epic', 20, 25, 20)] })
  assertEquals(same?.shop.name, 'GOG')
  const bigger = bestPrice({ deals: [deal('Epic', 20, 25, 20), deal('Steam', 20, 40, 50)] })
  assertEquals(bigger?.shop.name, 'Steam')
})

Deno.test('a game at its regular price has no cut and a game with no deal no price', () => {
  assertEquals(bestPrice({ deals: [deal('Steam', 19.99, 19.99, 0)] })?.cut, 0)
  assertEquals(bestPrice({ deals: [] }), null)
  assertEquals(bestPrice({}), null)
  assertEquals(bestPrice(null), null)
  assertEquals(bestPrice({ deals: [deal('Steam', 19.99, 19.99, 0)] })?.history_low, null)
})

Deno.test('a deal that is not a whole price from an https store is skipped', () => {
  const broken = [
    deal('A', -1, 10, 0),
    { ...deal('B', 5, 10, 50), price: { amount: 5, amountInt: 500, currency: 'euro' } },
    { ...deal('C', 5, 10, 50), url: 'http://insecure.example/c' },
    { ...deal('D', 5, 10, 50), url: 'javascript:alert(1)' },
    { ...deal('E', 5, 10, 50), shop: { name: 'no id' } },
    'x',
    null,
  ]
  assertEquals(bestPrice({ deals: broken }), null)
  assertEquals(bestPrice({ deals: [...broken, deal('Steam', 8, 10, 20)] })?.shop.name, 'Steam')
})

Deno.test('a link and a price are passed on exactly as ITAD gave them', () => {
  const url = 'https://itad.link/abc?aff=xyz&x=%20y#frag'
  const price = bestPrice({ deals: [deal('Steam', 12.345, 20, 38, { url })] })
  assertEquals(price?.url, url)
  assertEquals(price?.price.amount, 12.345)
})

Deno.test('a cut is kept between 0 and 100 and an odd expiry is dropped', () => {
  assertEquals(bestPrice({ deals: [deal('Steam', 1, 2, 150)] })?.cut, 100)
  assertEquals(bestPrice({ deals: [deal('Steam', 1, 2, -5)] })?.cut, 0)
  assertEquals(bestPrice({ deals: [deal('Steam', 1, 2, 50, { expiry: 'soon' })] })?.expiry, null)
})

Deno.test('the prices answer is read per ITAD game, one without a deal being null', () => {
  const answer = [
    { id: ID_A.toUpperCase(), historyLow: { all: null, y1: null, m3: null }, deals: [deal('Steam', 5, 10, 50)] },
    { id: ID_B, historyLow: { all: null, y1: null, m3: null }, deals: [] },
    { id: 'nope', deals: [] },
  ]
  const prices = parsePrices(answer)
  assertEquals([...prices.keys()], [ID_A, ID_B])
  assertEquals(prices.get(ID_A)?.price.amount, 5)
  assertEquals(prices.get(ID_B), null)
  assertEquals(parsePrices({ not: 'a list' }).size, 0)
})

Deno.test('a game ITAD did not know is asked about again after a week', () => {
  const now = Date.UTC(2026, 10, 6)
  const ago = (days: number) => new Date(now - days * 86_400_000).toISOString()
  assertEquals(lookupDue(null, now), true)
  assertEquals(lookupDue(ago(1), now), false)
  assertEquals(lookupDue(ago(RETRY_UNKNOWN_DAYS - 1), now), false)
  assertEquals(lookupDue(ago(RETRY_UNKNOWN_DAYS), now), true)
  assertEquals(lookupDue('garbage', now), true)
})
