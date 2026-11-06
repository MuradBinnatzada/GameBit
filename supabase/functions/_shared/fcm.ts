// supabase/functions/_shared/fcm.ts
//
// Sending a push notification through Firebase Cloud Messaging's HTTP v1 API
// (https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages/send):
// the Google access token from the project's service account, the message, and what
// FCM's answer means. Pure functions apart from [accessToken] and [sendMessage],
// which only fetch, so the rest can be tested.
//
// FCM_SERVICE_ACCOUNT (function secret): the service account key's JSON as downloaded
// (Firebase console > Project settings > Service accounts > Generate new private key).

export type ServiceAccount = { client_email: string; private_key: string; project_id: string; token_uri: string }

const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging'
const DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token'
const FETCH_TIMEOUT_MS = 10_000

/** The service account in [raw] (the JSON text), or null when it is not one. */
export function parseServiceAccount(raw: string | undefined | null): ServiceAccount | null {
  if (!raw) return null
  try {
    const j = JSON.parse(raw) as Record<string, unknown>
    const { client_email, private_key, project_id } = j
    if (typeof client_email !== 'string' || typeof private_key !== 'string' || typeof project_id !== 'string') {
      return null
    }
    if (!private_key.includes('PRIVATE KEY') || !/^[a-z0-9-]+$/.test(project_id)) return null
    const uri = typeof j.token_uri === 'string' && j.token_uri.startsWith('https://') ? j.token_uri : DEFAULT_TOKEN_URI
    return { client_email, private_key, project_id, token_uri: uri }
  } catch {
    return null
  }
}

export function base64Url(data: string | ArrayBuffer | Uint8Array): string {
  const bytes = typeof data === 'string'
    ? new TextEncoder().encode(data)
    : data instanceof Uint8Array
    ? data
    : new Uint8Array(data)
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** The DER bytes of a PKCS#8 private key in PEM. */
export function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem.replace(/-----(BEGIN|END)[A-Z ]*-----/g, '').replace(/\s+/g, '')
  const binary = atob(body)
  const bytes = new Uint8Array(new ArrayBuffer(binary.length))
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes
}

/** The claims of the JWT that is exchanged for an access token. */
export function assertionClaims(account: ServiceAccount, nowSeconds: number) {
  return {
    iss: account.client_email,
    scope: SCOPE,
    aud: account.token_uri,
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  }
}

/** A JWT signed with the service account's key (RS256). */
export async function signAssertion(account: ServiceAccount, nowSeconds: number): Promise<string> {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(account.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const unsigned = `${base64Url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))}.${
    base64Url(JSON.stringify(assertionClaims(account, nowSeconds)))
  }`
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned))
  return `${unsigned}.${base64Url(signature)}`
}

let held: { token: string; expiresAt: number; account: string } | null = null

/** A Google access token for [account], kept until a minute before it ends. */
export async function accessToken(account: ServiceAccount, nowMs = Date.now()): Promise<string> {
  if (held && held.account === account.client_email && held.expiresAt - 60_000 > nowMs) return held.token
  const assertion = await signAssertion(account, Math.floor(nowMs / 1000))
  const res = await fetch(account.token_uri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }),
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  })
  const body = await res.json().catch(() => null) as { access_token?: unknown; expires_in?: unknown } | null
  if (!res.ok || typeof body?.access_token !== 'string') {
    throw new Error(`Google refused the service account (${res.status})`)
  }
  const seconds = typeof body.expires_in === 'number' ? body.expires_in : 3600
  held = { token: body.access_token, expiresAt: nowMs + seconds * 1000, account: account.client_email }
  return body.access_token
}

/** What goes to one phone. [data] values are strings, as FCM requires. */
export type PushMessage = {
  token: string
  title: string
  body: string
  data: Record<string, string>
  /** The Android notification channel the app made for this kind. */
  channelId: string
}

/** The body of FCM's `messages:send` for [message]. */
export function fcmBody(message: PushMessage) {
  return {
    message: {
      token: message.token,
      notification: { title: message.title, body: message.body },
      data: message.data,
      android: { priority: 'HIGH', notification: { channel_id: message.channelId } },
      apns: { payload: { aps: { sound: 'default' } } },
    },
  }
}

/**
 * How FCM answered:
 *  - `sent`: it took the message;
 *  - `invalid_token`: the phone's token is no good any more (the app was removed or
 *    reinstalled), so it is dropped;
 *  - `retry`: too many requests, an FCM error or a refused access token: try again later;
 *  - `failed`: the message itself was refused (nothing a retry changes).
 */
export type SendResult = 'sent' | 'invalid_token' | 'retry' | 'failed'

export function classifyResponse(status: number, body: unknown): SendResult {
  if (status >= 200 && status < 300) return 'sent'
  const error = (body as { error?: { status?: unknown; message?: unknown; details?: unknown } } | null)?.error
  const codes: string[] = []
  if (typeof error?.status === 'string') codes.push(error.status)
  if (Array.isArray(error?.details)) {
    for (const d of error.details) {
      const code = (d as { errorCode?: unknown } | null)?.errorCode
      if (typeof code === 'string') codes.push(code)
    }
  }
  if (status === 404 || codes.includes('UNREGISTERED') || codes.includes('NOT_FOUND')) return 'invalid_token'
  // A malformed token is INVALID_ARGUMENT, like a malformed message: only a complaint
  // about the token itself counts.
  if (status === 400 && typeof error?.message === 'string' && /registration token/i.test(error.message)) {
    return 'invalid_token'
  }
  if (status === 401 || status === 403 || status === 429 || status >= 500) return 'retry'
  if (codes.includes('QUOTA_EXCEEDED') || codes.includes('UNAVAILABLE') || codes.includes('INTERNAL')) return 'retry'
  return 'failed'
}

/** Sends [message] and says how FCM answered. */
export async function sendMessage(account: ServiceAccount, message: PushMessage): Promise<SendResult> {
  try {
    const token = await accessToken(account)
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(fcmBody(message)),
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    })
    const body = await res.json().catch(() => null)
    const result = classifyResponse(res.status, body)
    if (result !== 'sent') console.error(`FCM answered ${res.status}: ${JSON.stringify(body)?.slice(0, 300)}`)
    return result
  } catch (err) {
    console.error('FCM could not be reached:', err)
    return 'retry'
  }
}
