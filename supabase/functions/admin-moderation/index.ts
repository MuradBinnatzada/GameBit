// supabase/functions/admin-moderation/index.ts
//
// Moderating from the app: the queue of open reports, the suspended members, and
// suspending, reinstating and closing reports. The same tools the owner uses in the
// SQL editor (supabase/MODERATION.md), for the members listed in `moderation.admins`.
//
// The `moderation` schema is out of reach of the API, so this calls the public.admin_*
// wrappers (20261101020000_admin_moderation.sql): the service role only, each given
// the verified caller's id and each asking the database again whether that member is
// an admin. This function checks the session and two-factor and counts the rate limit;
// who is an admin is decided in the database and nowhere else.
//
// Request  (POST, JSON): { "action": "reports" }
//                        { "action": "suspended" }
//                        { "action": "suspend", "member": "<id>", "reason": "Spam", "days": 7 }
//                          (`days` left out: until reinstated)
//                        { "action": "reinstate", "member": "<id>" }
//                        { "action": "close", "member": "<id>", "result": "actioned" | "dismissed",
//                          "note": "..." }
//          Header:       Authorization: Bearer <user access token>
// Response (JSON):       { "reports": [...] }         reports (see _shared/admin_moderation.ts)
//                        { "members": [...] }         suspended
//                        { "closed": 3 }              suspend, close: how many reports it closed
//                        { "success": true }          reinstate
//                        or { "error": "...", "code": "...", "retry_after"?: seconds }
//                          UNAUTHENTICATED  (401)  no valid user session
//                          MFA_REQUIRED     (403)  two-factor is on and this session has not
//                                                  entered its code
//                          FORBIDDEN        (403)  the caller is not an admin
//                          RATE_LIMITED     (429)  too many requests; `retry_after`
//                          BAD_REQUEST      (400 / 405)
//                          NOT_FOUND        (404)  no such member
//                          MEMBER_IS_ADMIN  (409)  admins are not suspended from the app
//                          NOT_CONFIGURED   (500)  missing secrets
//                          INTERNAL         (500)  anything else
//
// The app words every message itself from `code`, so the error text here is for the
// logs. Secrets: none to set. (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected
// automatically.)

import { createClient, type SupabaseClient } from '../_shared/supabase.ts'
import { withCors } from '../_shared/cors.ts'
import {
  type AdminErrorCode,
  type AdminRequest,
  isRefusal,
  parseAdminRequest,
  refusalFor,
  reportsFromRows,
  suspendedFromRows,
} from '../_shared/admin_moderation.ts'
import { secondFactorMissing } from '../_shared/mfa.ts'
import { RATE_LIMITS, rateLimitWait } from '../_shared/rate_limit.ts'

type ErrorCode = AdminErrorCode | 'UNAUTHENTICATED' | 'MFA_REQUIRED' | 'RATE_LIMITED' | 'NOT_CONFIGURED' | 'INTERNAL'

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

/** The service-role client: it bypasses RLS, so everything below acts for the verified caller only. */
function serviceClient(): SupabaseClient {
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceKey) {
    console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set')
    throw new HttpError(500, 'NOT_CONFIGURED', 'Server is not configured')
  }
  return createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
}

/** The verified id of the member the request's token belongs to; a 401 without a user token, a 403 before two-factor. */
async function requireUser(req: Request, client: SupabaseClient): Promise<string> {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim()
  if (!token) throw new HttpError(401, 'UNAUTHENTICATED', 'Unauthorized')
  const { data, error } = await client.auth.getUser(token)
  if (error || !data?.user) throw new HttpError(401, 'UNAUTHENTICATED', 'Unauthorized')
  if (secondFactorMissing(data.user, token)) {
    throw new HttpError(403, 'MFA_REQUIRED', 'Enter your two-factor code to finish signing in')
  }
  return data.user.id
}

/** Calls one admin_* function. A refusal of the database becomes its code; anything else is logged and is INTERNAL. */
async function call(client: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error } = await client.rpc(fn, args)
  if (!error) return data
  const refusal = refusalFor(error)
  if (refusal) throw new HttpError(refusal.status, refusal.code, `${fn} refused: ${refusal.code}`)
  console.error(`admin-moderation: ${fn} failed:`, error)
  throw new HttpError(500, 'INTERNAL', 'Internal error')
}

async function handle(client: SupabaseClient, actor: string, request: AdminRequest): Promise<Response> {
  switch (request.action) {
    case 'reports':
      return jsonResponse({ reports: reportsFromRows(await call(client, 'admin_open_reports', { actor })) })
    case 'suspended':
      return jsonResponse({ members: suspendedFromRows(await call(client, 'admin_suspended_members', { actor })) })
    case 'suspend': {
      const closed = await call(client, 'admin_suspend_member', {
        actor,
        target: request.member,
        why: request.reason,
        days: request.days,
      })
      console.log(`admin-moderation: ${actor} suspended ${request.member}`)
      return jsonResponse({ closed: Number(closed) || 0 })
    }
    case 'reinstate':
      await call(client, 'admin_reinstate_member', { actor, target: request.member })
      console.log(`admin-moderation: ${actor} reinstated ${request.member}`)
      return jsonResponse({ success: true })
    case 'close': {
      const closed = await call(client, 'admin_close_reports', {
        actor,
        target: request.member,
        result: request.result,
        note: request.note,
      })
      return jsonResponse({ closed: Number(closed) || 0 })
    }
  }
}

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed', code: 'BAD_REQUEST' }, 405)
  }
  try {
    const client = serviceClient()
    const actor = await requireUser(req, client)

    const wait = await rateLimitWait(client, actor, RATE_LIMITS.adminModeration)
    if (wait > 0) throw new HttpError(429, 'RATE_LIMITED', 'Too many requests, try again shortly', wait)

    const request = parseAdminRequest(await req.json().catch(() => null))
    if (isRefusal(request)) throw new HttpError(400, request.code, request.message)

    return await handle(client, actor, request)
  } catch (err) {
    if (err instanceof HttpError) return errorResponse(err)
    console.error('Unhandled error in admin-moderation:', err)
    return jsonResponse({ error: 'Internal error', code: 'INTERNAL' }, 500)
  }
}))
