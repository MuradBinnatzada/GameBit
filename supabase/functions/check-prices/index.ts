// supabase/functions/check-prices/index.ts
//
// Looks at the price of every wishlist game of the members who have a phone registered
// for push and price drops on, and queues a notification (`notification_outbox`, sent by
// send-notifications) for each sale worth telling them of. Called by pg_cron every 3 hours
// (migration 20261107120000_push_notifications.sql) with the CRON_SECRET; there is no
// member to call it.
//
// Request  (POST): header `x-cron-secret: <CRON_SECRET>`, body ignored.
// Response (JSON): { candidates, games, notified, cleared, skipped }
//                    or { error, code }: UNAUTHENTICATED (401), NOT_CONFIGURED (500), INTERNAL (500)
//
// The prices are the ones game-prices shows (_shared/itad.ts), in the region of the
// member's latest phone. What a member was last told is in `price_alert_state`; whether a
// price is worth another message is _shared/price_alerts.ts. A game IsThereAnyDeal has no
// id for is skipped (not "no sale": nothing is forgotten), and when IsThereAnyDeal does
// not answer for a region nothing is queued, announced or forgotten for it.
//
// Secrets: ITAD_API_KEY, CRON_SECRET. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
//          injected automatically.

import { createClient, type SupabaseClient } from '../_shared/supabase.ts'
import { withCors } from '../_shared/cors.ts'
import { cronSecretMatches } from '../_shared/cron.ts'
import { type AlertState, decide, isLowestEver } from '../_shared/price_alerts.ts'
import { ItadError, pricesFor, resolveGames } from '../_shared/itad.ts'

const MAX_CANDIDATES = 20_000
const GAMES_PER_CALL = 50
/** Nothing new is started after this long; the edge function limit is 150 s. */
const TIME_BUDGET_MS = 110_000

type Candidate = { user_id: string; game_id: string; country: string }
type StateRow = AlertState & { user_id: string; game_id: string }

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

const chunks = <T>(items: T[], size: number): T[][] => {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size))
  return out
}

async function readAll<T>(page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: unknown }>): Promise<T[]> {
  const rows: T[] = []
  for (let from = 0;; from += 1000) {
    const { data, error } = await page(from, from + 999)
    if (error) throw error
    rows.push(...(data ?? []))
    if (!data || data.length < 1000) return rows
  }
}

async function run(admin: SupabaseClient, apiKey: string) {
  const started = Date.now()
  const summary = { candidates: 0, games: 0, notified: 0, cleared: 0, skipped: 0 }

  const { data, error } = await admin.rpc('price_alert_candidates', { max_rows: MAX_CANDIDATES })
  if (error) throw error
  const candidates = (data ?? []) as Candidate[]
  summary.candidates = candidates.length
  if (candidates.length === 0) return summary

  // What each member was last told.
  const states = new Map<string, AlertState>()
  const userIds = [...new Set(candidates.map((c) => c.user_id))]
  for (const ids of chunks(userIds, 100)) {
    const rows = await readAll<StateRow>((from, to) =>
      admin
        .from('price_alert_state')
        .select('user_id, game_id, last_price, currency')
        .in('user_id', ids)
        .order('user_id')
        .order('game_id')
        .range(from, to)
    )
    for (const r of rows) states.set(`${r.user_id}:${r.game_id}`, { last_price: Number(r.last_price), currency: r.currency })
  }

  // The games' own words, for the message.
  const allGames = [...new Set(candidates.map((c) => c.game_id))]
  summary.games = allGames.length
  const gameInfo = new Map<string, { igdb_id: number | null; title: string }>()
  for (const ids of chunks(allGames, 200)) {
    const { data: rows, error: ge } = await admin.from('games').select('id, igdb_id, title').in('id', ids)
    if (ge) throw ge
    for (const g of (rows ?? []) as { id: string; igdb_id: number | null; title: string }[]) {
      gameInfo.set(g.id, { igdb_id: g.igdb_id === null ? null : Number(g.igdb_id), title: g.title })
    }
  }

  const byCountry = new Map<string, Candidate[]>()
  for (const c of candidates) byCountry.set(c.country, [...(byCountry.get(c.country) ?? []), c])

  const queue: { user_id: string; kind: 'price_drop'; data: unknown }[] = []
  const remember: { user_id: string; game_id: string; last_price: number; currency: string; notified_at: string }[] = []
  const forget = new Map<string, string[]>()

  countries:
  for (const [country, pairs] of byCountry) {
    const games = [...new Set(pairs.map((p) => p.game_id))]
    for (const batch of chunks(games, GAMES_PER_CALL)) {
      if (Date.now() - started > TIME_BUDGET_MS) {
        summary.skipped += pairs.length
        break countries
      }
      const inBatch = new Set(batch)
      try {
        const itadIds = await resolveGames(admin, apiKey, batch)
        const wanted = [...new Set([...itadIds.values()].filter((id): id is string => id !== null))]
        const prices = wanted.length > 0 ? await pricesFor(apiKey, wanted, country) : new Map()
        for (const pair of pairs) {
          if (!inBatch.has(pair.game_id)) continue
          const itadId = itadIds.get(pair.game_id) ?? null
          // No ITAD game is not "no sale": nothing is announced or forgotten.
          if (itadId === null) {
            summary.skipped++
            continue
          }
          const price = prices.get(itadId) ?? null
          const key = `${pair.user_id}:${pair.game_id}`
          const state = states.get(key) ?? null
          const decision = decide(price, state)
          if (decision === 'notify' && price !== null) {
            const info = gameInfo.get(pair.game_id)
            if (!info) continue
            queue.push({
              user_id: pair.user_id,
              kind: 'price_drop',
              data: {
                game_id: pair.game_id,
                igdb_id: info.igdb_id,
                title: info.title,
                price: price.price,
                cut: price.cut,
                shop: price.shop.name,
                lowest: isLowestEver(price),
              },
            })
            remember.push({
              user_id: pair.user_id,
              game_id: pair.game_id,
              last_price: price.price.amount,
              currency: price.price.currency,
              notified_at: new Date().toISOString(),
            })
          } else if (decision === 'clear') {
            forget.set(pair.user_id, [...(forget.get(pair.user_id) ?? []), pair.game_id])
          }
        }
      } catch (err) {
        if (err instanceof ItadError) {
          // Nothing is decided for this region now; the next run asks again.
          console.error(`ITAD did not answer for ${country}:`, err.message)
          summary.skipped += pairs.length
          break
        }
        throw err
      }
    }
  }

  // The queue first: a failure after it can only repeat a message, not lose one.
  for (const rows of chunks(queue, 500)) {
    const { error: qe } = await admin.from('notification_outbox').insert(rows)
    if (qe) throw qe
  }
  summary.notified = queue.length
  for (const rows of chunks(remember, 500)) {
    const { error: re } = await admin.from('price_alert_state').upsert(rows, { onConflict: 'user_id,game_id' })
    if (re) console.error('could not remember what was announced:', re)
  }
  for (const [userId, gameIds] of forget) {
    for (const ids of chunks(gameIds, 200)) {
      const { error: fe } = await admin.from('price_alert_state').delete().eq('user_id', userId).in('game_id', ids)
      if (fe) console.error('could not forget a sale that ended:', fe)
      else summary.cleared += ids.length
    }
  }
  return summary
}

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed', code: 'BAD_REQUEST' }, 405)
  if (!(await cronSecretMatches(req.headers.get('x-cron-secret'), Deno.env.get('CRON_SECRET')))) {
    return json({ error: 'Unauthorized', code: 'UNAUTHENTICATED' }, 401)
  }
  const apiKey = Deno.env.get('ITAD_API_KEY')
  const url = Deno.env.get('SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!apiKey || !url || !key) {
    console.error('ITAD_API_KEY / SUPABASE_SERVICE_ROLE_KEY are not set')
    return json({ error: 'Prices are not set up', code: 'NOT_CONFIGURED' }, 500)
  }
  try {
    const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
    return json(await run(admin, apiKey))
  } catch (err) {
    console.error('Unhandled error in check-prices:', err)
    return json({ error: 'Internal error', code: 'INTERNAL' }, 500)
  }
}))
