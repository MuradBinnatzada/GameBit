// supabase/functions/send-notifications/index.ts
//
// Sends the push notifications waiting in `notification_outbox` through Firebase Cloud
// Messaging. Called by pg_cron every minute (migration 20261107120000_push_notifications.sql)
// with the CRON_SECRET; there is no member to call it.
//
// Request  (POST): header `x-cron-secret: <CRON_SECRET>`, body ignored.
// Response (JSON): { claimed, sent, dropped, retry, removed_tokens }
//                    or { error, code }: UNAUTHENTICATED (401), NOT_CONFIGURED (500), INTERNAL (500)
//
// Each waiting notification is written in the language of each of the member's phones
// (_shared/push_messages.ts) and sent to all of them. It is dropped (marked sent, nothing
// sent) when the member turned that kind off, has no phone any more or the row is not
// what its kind needs; it stays for a retry (5 minutes, 5 tries) when FCM could not be
// reached or asked to try later. A token FCM says is dead is removed from push_devices.
//
// Secrets: FCM_SERVICE_ACCOUNT (the service account key's JSON), CRON_SECRET (the same
//          as the Vault `cron_secret`). SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
//          injected automatically.

import { createClient, type SupabaseClient } from '../_shared/supabase.ts'
import { withCors } from '../_shared/cors.ts'
import { cronSecretMatches } from '../_shared/cron.ts'
import { parseServiceAccount, type SendResult, sendMessage, type ServiceAccount } from '../_shared/fcm.ts'
import { languageOf, render } from '../_shared/push_messages.ts'

const BATCH_SIZE = 200
const CONCURRENCY = 10
/** No new notification is started after this long; the edge function limit is 150 s. */
const TIME_BUDGET_MS = 100_000

type Row = { id: number; user_id: string; kind: string; data: unknown; attempts: number }
type Device = { token: string; user_id: string; language: string }
type Settings = { user_id: string; price_drops: boolean; thread_replies: boolean }

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

/** Reads every row of a query that may be longer than the API's page. */
async function readAll<T>(page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: unknown }>): Promise<T[]> {
  const rows: T[] = []
  for (let from = 0;; from += 1000) {
    const { data, error } = await page(from, from + 999)
    if (error) throw error
    rows.push(...(data ?? []))
    if (!data || data.length < 1000) return rows
  }
}

const chunks = <T>(items: T[], size: number): T[][] => {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size))
  return out
}

/** Whether [settings] let a notification of [kind] through (no row: yes). */
function wants(settings: Settings | undefined, kind: string): boolean {
  if (!settings) return true
  return kind === 'price_drop' ? settings.price_drops : kind === 'thread_reply' ? settings.thread_replies : false
}

async function run(admin: SupabaseClient, account: ServiceAccount) {
  const started = Date.now()
  const summary = { claimed: 0, sent: 0, dropped: 0, retry: 0, removed_tokens: 0 }

  const { data: claimed, error } = await admin.rpc('claim_notifications', { batch_size: BATCH_SIZE })
  if (error) throw error
  const rows = (claimed ?? []) as Row[]
  summary.claimed = rows.length
  if (rows.length === 0) return summary

  const userIds = [...new Set(rows.map((r) => r.user_id))]
  const devices = new Map<string, Device[]>()
  const settings = new Map<string, Settings>()
  for (const ids of chunks(userIds, 100)) {
    const d = await readAll<Device>((from, to) =>
      admin.from('push_devices').select('token, user_id, language').in('user_id', ids).order('token').range(from, to)
    )
    for (const device of d) devices.set(device.user_id, [...(devices.get(device.user_id) ?? []), device])
    const { data: s, error: se } = await admin
      .from('notification_settings')
      .select('user_id, price_drops, thread_replies')
      .in('user_id', ids)
    if (se) throw se
    for (const row of (s ?? []) as Settings[]) settings.set(row.user_id, row)
  }

  // Who replied, for the words of a reply notification.
  const fromIds = new Set<string>()
  for (const r of rows) {
    const from = (r.data as { from_id?: unknown } | null)?.from_id
    if (r.kind === 'thread_reply' && typeof from === 'string') fromIds.add(from)
  }
  const names = new Map<string, string>()
  for (const ids of chunks([...fromIds], 100)) {
    const { data, error: pe } = await admin.from('profiles').select('id, display_name, handle').in('id', ids)
    if (pe) throw pe
    for (const p of (data ?? []) as { id: string; display_name: string | null; handle: string | null }[]) {
      const name = p.display_name?.trim() || (p.handle ? `@${p.handle}` : '')
      if (name) names.set(p.id, name)
    }
  }

  const done: number[] = []
  const dead = new Set<string>()

  async function deliver(row: Row): Promise<void> {
    const own = devices.get(row.user_id) ?? []
    if (!wants(settings.get(row.user_id), row.kind) || own.length === 0) {
      summary.dropped++
      done.push(row.id)
      return
    }
    const results: SendResult[] = []
    let wrote = false
    for (const device of own) {
      const text = render(row.kind, row.data, languageOf(device.language), (id) => names.get(id) ?? null)
      if (text === null) continue
      wrote = true
      const result = await sendMessage(account, { token: device.token, ...text })
      results.push(result)
      if (result === 'invalid_token') dead.add(device.token)
    }
    if (!wrote) {
      // A row that is not what its kind needs would never be sent: drop it.
      summary.dropped++
      done.push(row.id)
    } else if (results.includes('sent')) {
      summary.sent++
      done.push(row.id)
    } else if (results.includes('retry')) {
      summary.retry++
    } else {
      // Every phone's token was dead, or FCM refused the message itself: no retry helps.
      summary.dropped++
      done.push(row.id)
    }
  }

  for (const batch of chunks(rows, CONCURRENCY)) {
    if (Date.now() - started > TIME_BUDGET_MS) break
    await Promise.all(batch.map((row) => deliver(row)))
  }

  if (done.length > 0) {
    const { error: ue } = await admin
      .from('notification_outbox')
      .update({ sent_at: new Date().toISOString() })
      .in('id', done)
    if (ue) console.error('could not mark notifications sent:', ue)
  }
  if (dead.size > 0) {
    const { error: de } = await admin.from('push_devices').delete().in('token', [...dead])
    if (de) console.error('could not remove dead tokens:', de)
    else summary.removed_tokens = dead.size
  }
  return summary
}

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed', code: 'BAD_REQUEST' }, 405)
  if (!(await cronSecretMatches(req.headers.get('x-cron-secret'), Deno.env.get('CRON_SECRET')))) {
    return json({ error: 'Unauthorized', code: 'UNAUTHENTICATED' }, 401)
  }
  const account = parseServiceAccount(Deno.env.get('FCM_SERVICE_ACCOUNT'))
  const url = Deno.env.get('SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!account || !url || !key) {
    console.error('FCM_SERVICE_ACCOUNT / SUPABASE_SERVICE_ROLE_KEY are not set (or the service account is not valid)')
    return json({ error: 'Push is not set up', code: 'NOT_CONFIGURED' }, 500)
  }
  try {
    const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
    return json(await run(admin, account))
  } catch (err) {
    console.error('Unhandled error in send-notifications:', err)
    return json({ error: 'Internal error', code: 'INTERNAL' }, 500)
  }
}))
