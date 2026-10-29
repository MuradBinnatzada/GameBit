// supabase/functions/discussions/index.ts
//
// Posts to the discussions: a new thread, or a reply. The only way to write them
// (members have no privileges on the tables, see 20261022165000_discussions.sql),
// so everything that must hold for every post holds here: the member is signed in
// and past two-factor, within their rate limit, the text is the right length, has
// none of the words the chat rules refuse and not too many links, and is not the
// post they just made. Reading, reporting, blocking and deleting your own are
// done by the app through the database.
//
// Request  (POST, JSON): { "mode": "thread", "board": "general", "title": "Best
//                          soulslike?", "body": "...", "game_id": "<catalog id>" }
//                          `game_id` (optional) is the `games.id` the thread is about.
//                          or { "mode": "reply", "thread": "<thread id>", "body": "..." }
//          Header:       Authorization: Bearer <user access token>
// Response (JSON):       { "thread": { "id" } } or { "post": { "id", "created_at" } }
//                        or { "error": "...", "code": "...", "retry_after"?: seconds }
//                          UNAUTHENTICATED     (401)  no valid user session
//                          MFA_REQUIRED        (403)  two-factor is on and this session
//                                                     has not entered its code
//                          SUSPENDED           (403)  a moderator suspended the member
//                                                     (_shared/standing.ts)
//                          RATE_LIMITED        (429)  too many posts; `retry_after`.
//                                                     5 threads an hour, 20 replies in
//                                                     10 minutes (_shared/rate_limit.ts)
//                          BAD_REQUEST         (400 / 405)
//                          CONTENT_NOT_ALLOWED (422)  a word the chat rules refuse
//                                                     (_shared/discussion_filter.ts)
//                          TOO_MANY_LINKS      (422)  more than 3 web addresses
//                          NOT_FOUND           (404)  no such board, thread or game
//                          LOCKED              (409)  the thread takes no more replies
//                          DUPLICATE           (409)  the member posted this just now
//                          NOT_CONFIGURED      (500)  missing secrets
//                          INTERNAL            (500)  anything else
//
// The app words every message itself from `code`, so the error text here is for
// the logs. The rate limit counts a post before it is checked, so a refused post
// uses one up too.
//
// Secrets: none to set. (SUPABASE_URL, SUPABASE_ANON_KEY and
// SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient, type SupabaseClient } from '../_shared/supabase.ts'
import { withCors } from '../_shared/cors.ts'
import { isRefusal, parseDiscussionRequest, refuseContent } from '../_shared/discussions.ts'
import { secondFactorMissing } from '../_shared/mfa.ts'
import { RATE_LIMITS, rateLimitWait } from '../_shared/rate_limit.ts'
import { isSuspended } from '../_shared/standing.ts'

type ErrorCode =
  | 'UNAUTHENTICATED'
  | 'MFA_REQUIRED'
  | 'SUSPENDED'
  | 'RATE_LIMITED'
  | 'BAD_REQUEST'
  | 'CONTENT_NOT_ALLOWED'
  | 'TOO_MANY_LINKS'
  | 'NOT_FOUND'
  | 'LOCKED'
  | 'DUPLICATE'
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

const STATUS: Record<string, number> = { BAD_REQUEST: 400, CONTENT_NOT_ALLOWED: 422, TOO_MANY_LINKS: 422 }

/** The same reply or thread by the same member within this long is a double tap or a spam script. */
const DUPLICATE_REPLY_MS = 10 * 60_000
const DUPLICATE_THREAD_MS = 24 * 60 * 60_000

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

// A client with the service role. It bypasses RLS and is the only thing that may
// write the discussion tables: every statement below is scoped to the verified
// member and to rows found by id.
function serviceClient(): SupabaseClient {
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceKey) {
    console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set')
    throw new HttpError(500, 'NOT_CONFIGURED', 'Server is not configured')
  }
  return createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
}

function failed(what: string, error: unknown): never {
  console.error(`discussions: ${what} failed:`, error)
  throw new HttpError(500, 'INTERNAL', 'Internal error')
}

async function newThread(
  admin: SupabaseClient,
  userId: string,
  request: { board: string; title: string; body: string; gameId: string | null },
): Promise<Response> {
  const { data: board, error: boardError } = await admin
    .from('discussion_boards').select('id').eq('id', request.board).maybeSingle()
  if (boardError) failed('reading the board', boardError)
  if (!board) throw new HttpError(404, 'NOT_FOUND', 'No such board')

  if (request.gameId !== null) {
    const { data: game, error: gameError } = await admin
      .from('games').select('id').eq('id', request.gameId).maybeSingle()
    if (gameError) failed('reading the game', gameError)
    if (!game) throw new HttpError(404, 'NOT_FOUND', 'No such game')
  }

  const since = new Date(Date.now() - DUPLICATE_THREAD_MS).toISOString()
  const { data: same, error: sameError } = await admin
    .from('discussion_threads').select('id')
    .eq('author_id', userId).eq('board_id', request.board).eq('title', request.title)
    .gte('created_at', since).limit(1)
  if (sameError) failed('looking for a repeat', sameError)
  if (same && same.length > 0) throw new HttpError(409, 'DUPLICATE', 'You started this discussion already')

  const { data, error } = await admin
    .from('discussion_threads')
    .insert({
      board_id: request.board,
      game_id: request.gameId,
      author_id: userId,
      title: request.title,
      body: request.body,
    })
    .select('id')
    .single()
  if (error || !data) failed('inserting the thread', error)
  return jsonResponse({ thread: { id: data.id } })
}

async function newReply(
  admin: SupabaseClient,
  userId: string,
  request: { thread: string; body: string },
): Promise<Response> {
  const { data: thread, error: threadError } = await admin
    .from('discussion_threads').select('id, locked').eq('id', request.thread).maybeSingle()
  if (threadError) failed('reading the thread', threadError)
  if (!thread) throw new HttpError(404, 'NOT_FOUND', 'No such thread')
  if (thread.locked) throw new HttpError(409, 'LOCKED', 'This thread takes no more replies')

  const since = new Date(Date.now() - DUPLICATE_REPLY_MS).toISOString()
  const { data: same, error: sameError } = await admin
    .from('discussion_posts').select('id')
    .eq('thread_id', request.thread).eq('author_id', userId).eq('body', request.body)
    .gte('created_at', since).limit(1)
  if (sameError) failed('looking for a repeat', sameError)
  if (same && same.length > 0) throw new HttpError(409, 'DUPLICATE', 'You posted this just now')

  const { data, error } = await admin
    .from('discussion_posts')
    .insert({ thread_id: request.thread, author_id: userId, body: request.body })
    .select('id, created_at')
    .single()
  if (error || !data) failed('inserting the reply', error)
  return jsonResponse({ post: { id: data.id, created_at: data.created_at } })
}

Deno.serve(withCors(async (req: Request) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed', code: 'BAD_REQUEST' }, 405)
  }
  try {
    const userId = await requireUser(req)

    const request = parseDiscussionRequest(await req.json().catch(() => null))
    if (isRefusal(request)) throw new HttpError(STATUS[request.code] ?? 400, request.code, request.message)

    const admin = serviceClient()
    if (await isSuspended(admin, userId)) {
      throw new HttpError(403, 'SUSPENDED', 'This account is suspended')
    }
    const limit = request.mode === 'thread' ? RATE_LIMITS.discussionThread : RATE_LIMITS.discussionPost
    const wait = await rateLimitWait(admin, userId, limit)
    if (wait > 0) throw new HttpError(429, 'RATE_LIMITED', 'Too many posts, try again shortly', wait)

    const refusal = request.mode === 'thread'
      ? refuseContent(request.title, request.body)
      : refuseContent(request.body)
    if (refusal) throw new HttpError(STATUS[refusal.code] ?? 422, refusal.code, refusal.message)

    return request.mode === 'thread' ? await newThread(admin, userId, request) : await newReply(admin, userId, request)
  } catch (err) {
    if (err instanceof HttpError) return errorResponse(err)
    console.error('Unhandled error in discussions:', err)
    return jsonResponse({ error: 'Internal error', code: 'INTERNAL' }, 500)
  }
}))
