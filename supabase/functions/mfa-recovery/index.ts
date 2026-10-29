/**
 * mfa-recovery — two-factor backup codes: one-time codes that sign a member in
 * without their authenticator app, which turns two-factor authentication off.
 *
 * POST with the member's Supabase JWT. Body `{ mode, code? }`:
 *
 *   generate  Needs an account with two-factor on and a session that entered its
 *             code (aal2). Replaces the member's backup codes with CODE_COUNT new
 *             random ones and answers `{ codes }`, formatted (`7K3QD-M9XHT`).
 *             This is the only time they leave the server: the table keeps their
 *             SHA-256 hashes (20261019204652_mfa_recovery_codes.sql), so the
 *             earlier codes stop working.
 *   redeem    `{ code }`. For the session that signed in and still owes its
 *             two-factor code (aal1), so it never asks for aal2: that is the
 *             point. The account must have two-factor on. Counted against a
 *             strict rate limit before anything else (RATE_LIMITS.backupCodeRedeem,
 *             refused while the limiter can't count). A code that matches an
 *             unused one of the member's, made since their authenticator app was
 *             added, is marked used, every MFA factor of the member is deleted
 *             (two-factor is off) and their other codes go. Answers
 *             `{ success: true }`; the app refreshes its session, which then owes
 *             no code, and suggests turning two-factor on again.
 *
 * Redeem claims the code with one UPDATE (`used_at is null`), so two requests
 * with the same code can't both use it. If the factors can't all be deleted, the
 * code is given back and the member can try it again; a factor already gone
 * counts as deleted.
 *
 * The codes come from crypto.getRandomValues (_shared/recovery_codes.ts). A
 * code is never logged.
 *
 * Response on failure: `{ error, code, retry_after? }` with a matching HTTP
 * status; see `ErrorCode`. The app keys its messages off `code`.
 *
 * Secrets: none to set. (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected
 * automatically.)
 */
import { createClient, type SupabaseClient, type User } from "../_shared/supabase.ts"
import { withCors } from '../_shared/cors.ts'
import { secondFactorMissing, twoFactorOn } from '../_shared/mfa.ts'
import { RATE_LIMITS, rateLimitWait } from '../_shared/rate_limit.ts'
import { codesValidSince, formatCode, generateCodes, hashCode, normalizeCode } from '../_shared/recovery_codes.ts'

const TABLE = 'mfa_recovery_codes'

/**
 * Machine-readable failure codes. Keep in sync with
 * lib/services/mfa_recovery_failure.dart.
 *
 *   Needs the user:  UNAUTHENTICATED (the session expired: sign in again),
 *                    MFA_REQUIRED (generate: this session has not entered its
 *                    two-factor code, _shared/mfa.ts),
 *                    TWO_FACTOR_OFF (the account has no verified factor),
 *                    INVALID_CODE (redeem: no unused code of the member's matches),
 *                    RATE_LIMITED (too many attempts: wait `retry_after` seconds)
 *   A bug:           BAD_REQUEST (not a POST, or no known mode)
 *   Needs the owner: NOT_CONFIGURED, INTERNAL
 */
type ErrorCode =
  | 'UNAUTHENTICATED'
  | 'MFA_REQUIRED'
  | 'TWO_FACTOR_OFF'
  | 'INVALID_CODE'
  | 'RATE_LIMITED'
  | 'BAD_REQUEST'
  | 'NOT_CONFIGURED'
  | 'INTERNAL'

class HttpError extends Error {
  status: number
  code: ErrorCode
  retryAfter?: number
  constructor(status: number, code: ErrorCode, message: string, retryAfter?: number) {
    super(message)
    this.status = status
    this.code = code
    this.retryAfter = retryAfter
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })

/**
 * The user the request's JWT belongs to (getUser() lists their factors) and the
 * token. Whether the token is aal2 is up to the mode: redeem must work without.
 */
async function authenticate(req: Request, admin: SupabaseClient): Promise<{ user: User; token: string }> {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim()
  if (!token) throw new HttpError(401, 'UNAUTHENTICATED', 'Missing authorization')
  const { data, error } = await admin.auth.getUser(token)
  if (error || !data.user) throw new HttpError(401, 'UNAUTHENTICATED', 'Invalid or expired session')
  return { user: data.user, token }
}

async function readBody(req: Request): Promise<{ mode: 'generate' | 'redeem'; code: unknown }> {
  if (req.method !== 'POST') throw new HttpError(405, 'BAD_REQUEST', 'Use POST')
  let body: unknown
  try {
    body = await req.json()
  } catch {
    throw new HttpError(400, 'BAD_REQUEST', 'The body must be JSON')
  }
  const fields = (body ?? {}) as Record<string, unknown>
  const mode = fields.mode
  if (mode !== 'generate' && mode !== 'redeem') {
    throw new HttpError(400, 'BAD_REQUEST', 'mode must be "generate" or "redeem"')
  }
  return { mode, code: fields.code }
}

/** Counts the call against [limit], or answers RATE_LIMITED. */
async function limit(admin: SupabaseClient, userId: string, which: 'backupCodeGenerate' | 'backupCodeRedeem') {
  const wait = await rateLimitWait(admin, userId, RATE_LIMITS[which])
  if (wait > 0) throw new HttpError(429, 'RATE_LIMITED', 'Too many attempts, try again later', wait)
}

/** New codes for [user], replacing theirs. Answers them formatted, once. */
async function generate(admin: SupabaseClient, user: User, token: string): Promise<string[]> {
  if (!twoFactorOn(user)) {
    throw new HttpError(409, 'TWO_FACTOR_OFF', 'Turn on two-factor authentication first')
  }
  if (secondFactorMissing(user, token)) {
    throw new HttpError(403, 'MFA_REQUIRED', 'Enter your two-factor code to finish signing in')
  }
  await limit(admin, user.id, 'backupCodeGenerate')

  const codes = generateCodes()
  const hashes = await Promise.all(codes.map((code) => hashCode(user.id, code)))

  // The new codes go in first, then everything else of the member's goes. A
  // failure in between leaves the old codes working (the new ones were never
  // shown), and the next generate clears it up.
  const { error: insertError } = await admin
    .from(TABLE)
    .insert(hashes.map((code_hash) => ({ user_id: user.id, code_hash })))
  if (insertError) throw insertError
  const { error: deleteError } = await admin
    .from(TABLE)
    .delete()
    .eq('user_id', user.id)
    .not('code_hash', 'in', `(${hashes.join(',')})`)
  if (deleteError) throw deleteError

  return codes.map(formatCode)
}

/** Deletes every MFA factor of [userId], verified or not. */
async function deleteFactors(admin: SupabaseClient, userId: string): Promise<void> {
  const { data, error } = await admin.auth.admin.mfa.listFactors({ userId })
  if (error) throw error
  for (const factor of data.factors) {
    const { error: deleteError } = await admin.auth.admin.mfa.deleteFactor({ id: factor.id, userId })
    // Already gone (an earlier attempt got this far): that is what we want.
    if (deleteError && deleteError.status !== 404) throw deleteError
  }
}

/** Uses up [typed] for [user] and turns their two-factor authentication off. */
async function redeem(admin: SupabaseClient, user: User, typed: unknown): Promise<void> {
  await limit(admin, user.id, 'backupCodeRedeem')
  if (!twoFactorOn(user)) {
    throw new HttpError(409, 'TWO_FACTOR_OFF', 'Two-factor authentication is not on for this account')
  }

  const invalid = new HttpError(400, 'INVALID_CODE', 'That backup code is not valid')
  const code = typeof typed === 'string' ? normalizeCode(typed) : null
  const since = codesValidSince(user)
  if (code === null || since === null) throw invalid
  const hash = await hashCode(user.id, code)

  const { data: claimed, error: claimError } = await admin
    .from(TABLE)
    .update({ used_at: new Date().toISOString() })
    .eq('user_id', user.id)
    .eq('code_hash', hash)
    .is('used_at', null)
    .gte('created_at', since)
    .select('code_hash')
  if (claimError) throw claimError
  if (!claimed || claimed.length === 0) throw invalid

  try {
    await deleteFactors(admin, user.id)
  } catch (error) {
    // Give the code back, so the member can try it again.
    const { error: releaseError } = await admin
      .from(TABLE)
      .update({ used_at: null })
      .eq('user_id', user.id)
      .eq('code_hash', hash)
    if (releaseError) console.error('mfa-recovery: could not give the code back:', releaseError)
    throw error
  }

  // Two-factor is off, so the other codes are of no use. Best effort: they
  // count for nothing once the factor they were made for is gone (codesValidSince),
  // and the next generate replaces them.
  const { error: cleanupError } = await admin
    .from(TABLE)
    .delete()
    .eq('user_id', user.id)
    .is('used_at', null)
  if (cleanupError) console.error('mfa-recovery: could not delete the other codes:', cleanupError)
}

/**
 * `{ error, code, retry_after? }`. Anything that is not an `HttpError` is logged
 * and answered with a generic message, so database / library error text never
 * reaches the client.
 */
function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return json(
      {
        error: error.message,
        code: error.code,
        ...(error.retryAfter ? { retry_after: error.retryAfter } : {}),
      },
      error.status,
    )
  }
  return json({ error: 'Something went wrong on our side. Try again later.', code: 'INTERNAL' }, 500)
}

Deno.serve(withCors(async (req) => {
  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    if (!supabaseUrl || !serviceKey) {
      console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set')
      throw new HttpError(500, 'NOT_CONFIGURED', 'Server is not configured')
    }

    // Service-role client: bypasses RLS and may delete MFA factors, so every
    // statement below is scoped to the verified user id.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    const { user, token } = await authenticate(req, admin)
    const { mode, code } = await readBody(req)
    if (mode === 'generate') {
      return json({ codes: await generate(admin, user, token) })
    }
    await redeem(admin, user, code)
    return json({ success: true })
  } catch (error) {
    // A wrong code or an expired session is the member's, not a failure.
    if (!(error instanceof HttpError) || error.status >= 500) console.error('mfa-recovery failed:', error)
    return errorResponse(error)
  }
}))
