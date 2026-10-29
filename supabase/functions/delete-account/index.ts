/**
 * delete-account — permanently deletes the caller's account and everything
 * that belongs to them.
 *
 * POST (no body). The caller is identified by their Supabase JWT; a user id sent
 * in the request body is ignored, so nobody can delete anyone but themselves.
 *
 * Steps, in this order (the auth identity goes last, so a failure part way
 * leaves an account the user can still sign in to and retry; every step is safe
 * to run again):
 *   1. Avatars     remove the files under `avatars/<user id>/`
 *   2. Log         delete the user's `log_entries`, then their discussions: replies,
 *                  threads (with the replies of others to them), reports and blocks,
 *                  and the reports about them. A moderation suspension of the account
 *                  goes with the identity (its foreign key cascades)
 *   3. Library     delete the user's `user_games`
 *   4. Follows     delete the follows in both directions (`social_follows`)
 *   5. Catalog     games the user added to the shared catalog stay for other
 *                  members, but `created_by` is cleared so they are no longer
 *                  linked to the user (this is what the privacy policy promises)
 *   6. Profile     delete the `profiles` row
 *   7. Identity    delete the Supabase auth user (their sign-in)
 *
 * The rows are removed explicitly instead of relying on `on delete cascade`, so
 * the function works whichever foreign keys the project's tables were created
 * with.
 *
 * Response: `{ success: true }`. A failure is `{ error, code }` with a matching
 * HTTP status; see `ErrorCode`. The app keys its messages off `code`.
 *
 * Secrets: none to set. (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected
 * automatically.)
 */
import { createClient, type SupabaseClient } from "../_shared/supabase.ts"
import { withCors } from '../_shared/cors.ts'
import { secondFactorMissing } from '../_shared/mfa.ts'
import { RATE_LIMITS, rateLimitWait } from '../_shared/rate_limit.ts'

const AVATAR_BUCKET = 'avatars'
const AVATAR_PAGE = 100          // files listed and removed per round trip
const AVATAR_MAX_ROUNDS = 100    // 10 000 files: far more than any user uploads; stops a runaway loop

/**
 * Machine-readable failure codes. Keep in sync with `deleteAccountMessage` in
 * lib/services/delete_account_failure.dart.
 *
 *   Needs the user:  UNAUTHENTICATED (the session expired: sign in again),
 *                    MFA_REQUIRED (two-factor is on and this session has not
 *                    entered its code, _shared/mfa.ts),
 *                    RATE_LIMITED (too many attempts: try again later)
 *   Needs the owner: NOT_CONFIGURED, INTERNAL
 */
type ErrorCode = 'UNAUTHENTICATED' | 'MFA_REQUIRED' | 'RATE_LIMITED' | 'NOT_CONFIGURED' | 'INTERNAL'

class HttpError extends Error {
  status: number
  code: ErrorCode
  constructor(status: number, code: ErrorCode, message: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })

/** The verified id of the user the request's JWT belongs to. */
async function authenticate(req: Request, admin: SupabaseClient): Promise<string> {
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim()
  if (!token) throw new HttpError(401, 'UNAUTHENTICATED', 'Missing authorization')
  const { data, error } = await admin.auth.getUser(token)
  if (error || !data.user) throw new HttpError(401, 'UNAUTHENTICATED', 'Invalid or expired session')
  if (secondFactorMissing(data.user, token)) {
    throw new HttpError(403, 'MFA_REQUIRED', 'Enter your two-factor code to finish signing in')
  }
  return data.user.id
}

/** Removes every file the user uploaded. Their files all live under `<user id>/`. */
async function deleteAvatars(admin: SupabaseClient, userId: string): Promise<void> {
  const bucket = admin.storage.from(AVATAR_BUCKET)
  for (let round = 0; round < AVATAR_MAX_ROUNDS; round++) {
    // Always the first page: what was listed last time has been removed.
    const { data: files, error: listError } = await bucket.list(userId, { limit: AVATAR_PAGE })
    if (listError) throw listError
    if (!files || files.length === 0) return

    const { error: removeError } = await bucket.remove(files.map((f) => `${userId}/${f.name}`))
    if (removeError) throw removeError
    if (files.length < AVATAR_PAGE) return
  }
}

/** Deletes every row of `table` whose `column` equals the user's id. */
async function deleteRows(admin: SupabaseClient, table: string, column: string, userId: string): Promise<void> {
  const { error } = await admin.from(table).delete().eq(column, userId)
  if (error) throw error
}

async function deleteAccount(admin: SupabaseClient, userId: string): Promise<void> {
  await deleteAvatars(admin, userId)

  await deleteRows(admin, 'log_entries', 'user_id', userId)
  // Their discussions: replies, then threads (which take other members' replies
  // to them along), then what they reported and blocked, who blocked them and the
  // reports about them (20261028235500_moderation_and_blocking.sql).
  await deleteRows(admin, 'discussion_posts', 'author_id', userId)
  await deleteRows(admin, 'discussion_threads', 'author_id', userId)
  await deleteRows(admin, 'discussion_reports', 'reporter_id', userId)
  await deleteRows(admin, 'user_blocks', 'blocker_id', userId)
  await deleteRows(admin, 'user_blocks', 'blocked_id', userId)
  await deleteRows(admin, 'user_reports', 'reporter_id', userId)
  await deleteRows(admin, 'user_reports', 'reported_id', userId)
  await deleteRows(admin, 'review_reports', 'reporter_id', userId)
  await deleteRows(admin, 'user_games', 'user_id', userId)
  await deleteRows(admin, 'social_follows', 'follower_id', userId)
  await deleteRows(admin, 'social_follows', 'followee_id', userId)

  // Best effort: if `created_by` can't be cleared (a NOT NULL column), the next
  // step is what tells us whether the user can be removed at all.
  const { error: catalogError } = await admin.from('games').update({ created_by: null }).eq('created_by', userId)
  if (catalogError) console.error('delete-account: could not unlink catalog games:', catalogError)

  await deleteRows(admin, 'profiles', 'id', userId)

  const { error: authError } = await admin.auth.admin.deleteUser(userId)
  // Already gone (an earlier attempt got this far, and the reply was lost): done.
  if (authError && authError.status !== 404) throw authError
}

/**
 * `{ error, code }`. Anything that is not an `HttpError` is logged and answered
 * with a generic message, so database / library error text never reaches the client.
 */
function errorResponse(error: unknown): Response {
  if (error instanceof HttpError) {
    return json({ error: error.message, code: error.code }, error.status)
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

    // Service-role client: bypasses RLS and may delete auth users, so every
    // statement below is scoped to the verified user id.
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    const userId = await authenticate(req, admin)
    if (await rateLimitWait(admin, userId, RATE_LIMITS.deleteAccount) > 0) {
      throw new HttpError(429, 'RATE_LIMITED', 'Too many attempts, try again later')
    }
    await deleteAccount(admin, userId)
    return json({ success: true })
  } catch (error) {
    console.error('delete-account failed:', error)
    return errorResponse(error)
  }
}))
