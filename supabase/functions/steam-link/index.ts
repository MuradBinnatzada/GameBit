/**
 * steam-link — connects a member's Steam account by having them sign in through
 * Steam (OpenID 2.0), so a profile only ever holds a Steam ID its member proved
 * is theirs. Members can't write `profiles.steam_id` themselves (they may only
 * clear it, 20261019134937_steam_id_from_steam_only.sql): this function is the
 * only writer, and sync-steam / sync-achievements read the ID from there.
 *
 * POST: start. Needs the member's Supabase JWT. Body `{ return_to? }`: where the
 * browser goes when it is done (the web app, or the desktop app listening on a
 * loopback address; see `returnUrlAllowed`). Answers `{ url }`, Steam's sign-in
 * page, for the app to open in a browser. The address Steam sends the browser
 * back to carries a state signed here: the member's id, `return_to` and when it
 * stops being accepted (10 minutes).
 *
 * GET: Steam sends the browser back. It has no Supabase token, so the gateway
 * lets it through (`verify_jwt = false` in supabase/config.toml) and the state
 * is what says who it is for:
 *   1. The state must be one this function signed, and not expired.
 *   2. The answer must be a positive assertion from Steam's endpoint for exactly
 *      this return address (Steam signs it, state included), with the claimed id
 *      among the signed fields.
 *   3. Steam must confirm it: the answer is posted back with
 *      `openid.mode=check_authentication` to Steam's fixed endpoint, never to an
 *      address taken from the request. Steam confirms each answer once, so a
 *      copied return address can't be used again.
 *   4. With STEAM_LINK_CONFIRM_URL set, nothing is saved yet. The browser goes
 *      to the confirm page (web/steam-link.html) with a token signed here over
 *      the state and the SteamID64 from `openid.claimed_id`, valid for 5
 *      minutes and never past the state. Whoever finishes Steam's sign-in owns
 *      the Steam account, but the state belongs to whoever started the link:
 *      without this step, someone could start a link and get another person to
 *      finish it, and that person's Steam account would land on their profile.
 *      The page names the member it links to, and has it saved (POST below)
 *      only when the person who signed in to Steam says so.
 *      Without it (`supabase start`, a backend without the web app), the ID is
 *      saved right away, as described under POST `{ token, confirm: true }`,
 *      and the browser goes to `return_to` with `steam_link=ok`.
 * On a failure the browser goes to `return_to` with the error code as
 * `steam_link`. Without `return_to` (the phone apps, which watch the profile
 * instead) it gets a short page in plain text: Supabase serves a function's
 * HTML as plain text, which is why the confirm page lives with the web app.
 *
 * POST `{ token }`: the confirm page asks who the token links to. No Supabase
 * token: the confirmation token is what says who it is for. Answers
 * `{ handle, name, cancel_to }`, the member's handle and display name (either
 * may be null) and where the browser goes if the person cancels (`return_to`
 * with STEAM_LINK_CANCELLED, or null).
 * POST `{ token, confirm: true }`: the person confirmed. The SteamID64 is saved
 * on the member's profile with the service role, and removed from every other
 * profile: a Steam account belongs to the member who proved it is theirs. (IDs
 * typed in before this function existed were never proved; one on someone
 * else's account ends when its owner connects it.) Steam isn't asked again: it
 * confirms an answer once, and the token says this one was confirmed. Answers
 * `{ return_to }`: `return_to` with `steam_link=ok`, or null.
 *
 * Errors. Start answers `{ error, code, retry_after? }` with a matching HTTP
 * status: UNAUTHENTICATED, MFA_REQUIRED (two-factor is on and this session has
 * not entered its code, _shared/mfa.ts), BAD_REQUEST, RATE_LIMITED,
 * NOT_CONFIGURED, INTERNAL.
 * The return gives one of STEAM_LINK_CANCELLED, STEAM_LINK_EXPIRED,
 * STEAM_LINK_INVALID, STEAM_UNAVAILABLE, RATE_LIMITED, NOT_CONFIGURED, INTERNAL
 * as `steam_link`. The confirm page's requests answer `{ error, code,
 * return_to }` with BAD_REQUEST (not a token of ours), STEAM_LINK_EXPIRED,
 * NOT_CONFIGURED or INTERNAL; `return_to` carries the code when the token is
 * genuine, and the page sends the browser there.
 * Keep in sync with `SyncFailureCode` in lib/services/sync_failure.dart.
 *
 * STEAM_LINK_CONFIRM_URL: the confirm page's address, web/steam-link.html where
 * the web app is served, e.g. https://checkpoint.example.com/steam-link.html
 * (https, or http on a loopback address). Set it wherever the web app is
 * public: unset, Steam IDs are saved without the confirm step (step 4). Set
 * to anything else, start answers NOT_CONFIGURED. The page calls this function
 * from the browser, so with ALLOWED_ORIGINS set its origin must be listed
 * (cors.ts).
 * The state and the confirmation are signed with a key derived from
 * SUPABASE_SERVICE_ROLE_KEY (injected, as SUPABASE_URL is).
 * STEAM_LINK_CALLBACK_URL (optional): this function's public address, when it is
 * not SUPABASE_URL + /functions/v1/steam-link: behind a custom domain, or under
 * `supabase start`, whose SUPABASE_URL is internal (there it is
 * http://127.0.0.1:54321/functions/v1/steam-link).
 */
import { createClient, type SupabaseClient } from "../_shared/supabase.ts"
import { parseAllowedOrigins, withCors } from '../_shared/cors.ts'
import { secondFactorMissing } from '../_shared/mfa.ts'
import { RATE_LIMITS, rateLimitWait } from '../_shared/rate_limit.ts'
import {
  afterSteamConfirmed,
  checkAuthenticationForm,
  confirmedBySteam,
  confirmPageSetting,
  type LinkState,
  openConfirmation,
  openState,
  readAssertion,
  returnUrlAllowed,
  signState,
  STATE_LIFETIME_SECONDS,
  stateKey,
  STEAM_OPENID_ENDPOINT,
  steamLoginUrl,
  withLinkResult,
} from '../_shared/steam_openid.ts'

const STEAM_TIMEOUT_MS = 10_000

/**
 * Machine-readable failure codes; see the header. Keep in sync with
 * `SyncFailureCode` in lib/services/sync_failure.dart.
 */
type ErrorCode =
  | 'UNAUTHENTICATED'
  | 'MFA_REQUIRED'
  | 'BAD_REQUEST'
  | 'RATE_LIMITED'
  | 'NOT_CONFIGURED'
  | 'INTERNAL'
  | 'STEAM_LINK_CANCELLED'
  | 'STEAM_LINK_EXPIRED'
  | 'STEAM_LINK_INVALID'
  | 'STEAM_UNAVAILABLE'

class HttpError extends Error {
  status: number
  code: ErrorCode
  retryAfter?: number // seconds
  constructor(status: number, code: ErrorCode, message: string, retryAfter?: number) {
    super(message)
    this.status = status
    this.code = code
    this.retryAfter = retryAfter
  }
}

/** What the plain-text page says for each outcome (no `return_to`). */
const PAGE_TEXT: Record<ErrorCode | 'ok', string> = {
  ok: 'Steam is connected to Gamebit. You can close this page and go back to the app.',
  STEAM_LINK_CANCELLED: 'Steam sign-in was cancelled, so Steam is not connected. Go back to Gamebit to try again.',
  STEAM_LINK_EXPIRED: 'This Steam sign-in took too long. Go back to Gamebit and connect Steam again.',
  STEAM_LINK_INVALID: 'Steam could not confirm this sign-in. Go back to Gamebit and connect Steam again.',
  STEAM_UNAVAILABLE: 'Steam is not responding right now. Go back to Gamebit and try again later.',
  RATE_LIMITED: 'Too many Steam sign-ins from your account. Try again later.',
  UNAUTHENTICATED: 'Sign in to Gamebit, then connect Steam again.',
  MFA_REQUIRED: 'Enter your two-factor code in Gamebit, then connect Steam again.',
  BAD_REQUEST: 'This Steam sign-in link is not valid. Go back to Gamebit and connect Steam again.',
  NOT_CONFIGURED: 'Connecting Steam is not available right now.',
  INTERNAL: 'Something went wrong on our side. Go back to Gamebit and try again later.',
}

type Config = {
  admin: SupabaseClient
  key: CryptoKey
  callbackUrl: string
  /** STEAM_LINK_CONFIRM_URL: see `confirmPageSetting`. */
  confirmPage: string | null | 'invalid'
}

let config: Promise<Config> | null = null

/** The service-role client, the state key, this function's public address and the confirm page's. */
function loadConfig(): Promise<Config> {
  if (config === null) {
    config = buildConfig()
    // A failure is not kept: the next request tries again.
    config.catch(() => (config = null))
  }
  return config
}

async function buildConfig(): Promise<Config> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceKey) {
    console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not set')
    throw new HttpError(500, 'NOT_CONFIGURED', 'Server is not configured')
  }
  // Service-role client: it writes `steam_id`, which members can't, so every
  // statement below is scoped to the member the JWT or the signed state names.
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const callbackUrl = (Deno.env.get('STEAM_LINK_CALLBACK_URL')?.trim() ||
    `${supabaseUrl.replace(/\/+$/, '')}/functions/v1/steam-link`)
  const confirmPage = confirmPageSetting(Deno.env.get('STEAM_LINK_CONFIRM_URL'))
  if (confirmPage === 'invalid') {
    console.error('STEAM_LINK_CONFIRM_URL is not an https (or loopback http) address')
  }
  return { admin, key: await stateKey(serviceKey), callbackUrl, confirmPage }
}

const nowSeconds = () => Math.floor(Date.now() / 1000)

/** The address Steam sends the browser back to, for [state]. */
const returnAddress = (callbackUrl: string, state: string) => `${callbackUrl}?state=${state}`

// ---- Start (POST) -------------------------------------------------------------

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

type Body = { return_to?: unknown; token?: unknown; confirm?: unknown } | null

/** The JSON body: null when there is none, BAD_REQUEST when it isn't JSON. */
async function readBody(req: Request): Promise<Body> {
  const text = await req.text()
  if (text.trim() === '') return null
  try {
    return JSON.parse(text)
  } catch {
    throw new HttpError(400, 'BAD_REQUEST', 'The body must be JSON')
  }
}

/** `return_to` from [body]: null when there is none, BAD_REQUEST when it isn't allowed. */
function requestedReturn(body: Body): string | null {
  const returnTo = body?.return_to
  if (returnTo === undefined || returnTo === null) return null
  if (typeof returnTo !== 'string' ||
      !returnUrlAllowed(returnTo, parseAllowedOrigins(Deno.env.get('ALLOWED_ORIGINS')))) {
    throw new HttpError(400, 'BAD_REQUEST', 'return_to is not an address of this app')
  }
  return returnTo
}

async function start(req: Request, body: Body): Promise<Response> {
  const { admin, key, callbackUrl, confirmPage } = await loadConfig()
  const userId = await authenticate(req, admin)
  // A sign-in could never be saved: say so before Steam.
  if (confirmPage === 'invalid') {
    throw new HttpError(503, 'NOT_CONFIGURED', 'Connecting Steam is not available right now')
  }
  const wait = await rateLimitWait(admin, userId, RATE_LIMITS.steamLink)
  if (wait > 0) throw new HttpError(429, 'RATE_LIMITED', 'Too many Steam sign-ins, try again later', wait)

  const state = await signState({
    userId,
    returnTo: requestedReturn(body),
    expiresAt: nowSeconds() + STATE_LIFETIME_SECONDS,
  }, key)
  return json({ url: steamLoginUrl(returnAddress(callbackUrl, state)) })
}

// ---- Steam's return (GET) -------------------------------------------------------

/** Has Steam confirm the answer in [params]. Throws STEAM_UNAVAILABLE when it can't be asked. */
async function confirmWithSteam(params: URLSearchParams): Promise<boolean> {
  let res: Response
  try {
    res = await fetch(STEAM_OPENID_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: checkAuthenticationForm(params),
      signal: AbortSignal.timeout(STEAM_TIMEOUT_MS),
    })
  } catch (e) {
    console.error('steam-link: Steam could not be reached:', e)
    throw new HttpError(503, 'STEAM_UNAVAILABLE', 'Steam is not responding')
  }
  const reply = await res.text()
  if (!res.ok) {
    console.error(`steam-link: check_authentication answered ${res.status}`)
    throw new HttpError(503, 'STEAM_UNAVAILABLE', 'Steam is not responding')
  }
  return confirmedBySteam(reply)
}

/**
 * Saves [steamId] on [userId]'s profile, and takes it off any other profile
 * first: the account is the member's who proved it is theirs.
 */
async function saveSteamId(admin: SupabaseClient, userId: string, steamId: string): Promise<void> {
  const { error: releaseError } = await admin
    .from('profiles')
    .update({ steam_id: null })
    .eq('steam_id', steamId)
    .neq('id', userId)
  if (releaseError) throw releaseError

  const { data, error } = await admin
    .from('profiles')
    .update({ steam_id: steamId })
    .eq('id', userId)
    .select('id')
  if (error) throw error
  if (!data || data.length === 0) throw new Error(`no profile row for ${userId}`)
}

/** Checks Steam's answer for [state], and answers the Steam ID it proves. */
async function checkAnswer(
  params: URLSearchParams,
  state: LinkState,
  stateToken: string,
  config: Config,
): Promise<string> {
  if (state.expiresAt < nowSeconds()) {
    throw new HttpError(400, 'STEAM_LINK_EXPIRED', 'The sign-in took too long')
  }
  const assertion = readAssertion(params, returnAddress(config.callbackUrl, stateToken))
  if (assertion.kind === 'cancelled') {
    throw new HttpError(400, 'STEAM_LINK_CANCELLED', 'Steam sign-in was cancelled')
  }
  if (assertion.kind === 'invalid') {
    console.error(`steam-link: refused an answer (${assertion.reason})`)
    throw new HttpError(400, 'STEAM_LINK_INVALID', 'Steam could not confirm the sign-in')
  }

  const wait = await rateLimitWait(config.admin, state.userId, RATE_LIMITS.steamLink)
  if (wait > 0) throw new HttpError(429, 'RATE_LIMITED', 'Too many Steam sign-ins, try again later', wait)

  if (!await confirmWithSteam(params)) {
    console.error('steam-link: Steam did not confirm an answer')
    throw new HttpError(400, 'STEAM_LINK_INVALID', 'Steam could not confirm the sign-in')
  }
  return assertion.steamId
}

async function steamReturn(req: Request): Promise<Response> {
  const params = new URL(req.url).searchParams
  const config = await loadConfig()
  const stateToken = params.get('state') ?? ''
  const state = await openState(stateToken, config.key)
  // Not a state of ours: where it says to go can't be trusted either.
  if (state === null) return page('BAD_REQUEST', 400)

  let outcome: ErrorCode | 'ok' = 'ok'
  let status = 200
  try {
    const steamId = await checkAnswer(params, state, stateToken, config)
    const next = await afterSteamConfirmed(
      config.confirmPage,
      { stateToken, state, steamId },
      nowSeconds(),
      config.key,
      config.callbackUrl,
    )
    if (next.kind === 'confirm') return redirect(next.page)
    if (next.kind === 'not_configured') {
      throw new HttpError(503, 'NOT_CONFIGURED', 'STEAM_LINK_CONFIRM_URL is not valid')
    }
    await saveSteamId(config.admin, state.userId, steamId)
  } catch (error) {
    console.error('steam-link: linking failed:', error)
    outcome = error instanceof HttpError ? error.code : 'INTERNAL'
    status = error instanceof HttpError ? error.status : 500
  }
  return state.returnTo === null
    ? page(outcome, status)
    : redirect(withLinkResult(state.returnTo, outcome))
}

// ---- The confirm page (POST with a token) ------------------------------------------

/** The handle and display name of [userId], for the confirm page to show. */
async function memberNames(admin: SupabaseClient, userId: string) {
  const { data, error } = await admin
    .from('profiles')
    .select('handle, display_name')
    .eq('id', userId)
    .maybeSingle()
  if (error) throw error
  if (!data) throw new Error(`no profile row for ${userId}`)
  return { handle: data.handle ?? null, name: data.display_name ?? null }
}

/**
 * The confirm page's requests: who [body]'s token links to, or (`confirm: true`)
 * saving it. A failure answers where the browser goes with it when the token is
 * genuine, so the app that started the link hears how it ended.
 */
async function confirmStep(body: { token: string; confirm?: unknown }): Promise<Response> {
  const { admin, key } = await loadConfig()
  const confirmation = await openConfirmation(body.token, key)
  if (confirmation === null) throw new HttpError(400, 'BAD_REQUEST', 'This Steam sign-in link is not valid')
  const { state, steamId } = confirmation
  const backWith = (result: string) => state.returnTo === null ? null : withLinkResult(state.returnTo, result)
  try {
    if (confirmation.expiresAt < nowSeconds()) {
      throw new HttpError(400, 'STEAM_LINK_EXPIRED', 'The sign-in took too long')
    }
    if (body.confirm === true) {
      await saveSteamId(admin, state.userId, steamId)
      return json({ return_to: backWith('ok') }, 200, NO_TRACE)
    }
    const names = await memberNames(admin, state.userId)
    return json({ ...names, cancel_to: backWith('STEAM_LINK_CANCELLED') }, 200, NO_TRACE)
  } catch (error) {
    console.error('steam-link: confirming failed:', error)
    return errorResponse(error, { return_to: backWith(error instanceof HttpError ? error.code : 'INTERNAL') })
  }
}

async function post(req: Request): Promise<Response> {
  const body = await readBody(req)
  if (typeof body?.token === 'string') return await confirmStep({ token: body.token, confirm: body.confirm })
  return await start(req, body)
}

// ---- Answers --------------------------------------------------------------------

// The return address holds Steam's answer and the state: never pass it on in a
// Referer, and never keep a copy.
const NO_TRACE = { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' }

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  })

const page = (outcome: ErrorCode | 'ok', status: number) =>
  new Response(`Gamebit\n\n${PAGE_TEXT[outcome]}\n`, {
    status,
    headers: { 'Content-Type': 'text/plain; charset=utf-8', ...NO_TRACE },
  })

const redirect = (location: string) =>
  new Response(null, { status: 303, headers: { Location: location, ...NO_TRACE } })

/**
 * `{ error, code, retry_after? }` (and [extra]) plus a `Retry-After` header when
 * a retry makes sense. Anything that is not an `HttpError` is logged and answered
 * with a generic message, so database / library error text never reaches the
 * client.
 */
function errorResponse(error: unknown, extra: Record<string, unknown> = {}): Response {
  if (error instanceof HttpError) {
    const retryAfter = error.retryAfter
    return json(
      { error: error.message, code: error.code, ...(retryAfter ? { retry_after: retryAfter } : {}), ...extra },
      error.status,
      retryAfter ? { 'Retry-After': String(retryAfter) } : {},
    )
  }
  return json({ error: 'Something went wrong on our side. Try again later.', code: 'INTERNAL', ...extra }, 500)
}

Deno.serve(withCors(async (req) => {
  try {
    if (req.method === 'POST') return await post(req)
    if (req.method === 'GET') return await steamReturn(req)
    return json({ error: 'Use POST', code: 'BAD_REQUEST' }, 405)
  } catch (error) {
    console.error('steam-link failed:', error)
    if (req.method === 'GET') {
      return page(error instanceof HttpError ? error.code : 'INTERNAL', error instanceof HttpError ? error.status : 500)
    }
    return errorResponse(error)
  }
}))
