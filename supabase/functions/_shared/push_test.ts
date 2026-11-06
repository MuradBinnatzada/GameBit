import { assertEquals, assertNotEquals } from 'jsr:@std/assert@1'
import {
  accessToken,
  assertionClaims,
  base64Url,
  classifyResponse,
  fcmBody,
  parseServiceAccount,
  pemToDer,
  signAssertion,
} from './fcm.ts'
import type { GamePrice } from './game_prices.ts'
import { decide, FURTHER_DROP, isLowestEver, MIN_CUT } from './price_alerts.ts'
import {
  CHANNELS,
  formatMoney,
  languageOf,
  readPriceDrop,
  readThreadReply,
  render,
  renderPriceDrop,
  renderThreadReply,
} from './push_messages.ts'

// ---- FCM ---------------------------------------------------------------------------

async function testAccount() {
  const pair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  )
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey))
  let binary = ''
  for (const b of der) binary += String.fromCharCode(b)
  const lines = btoa(binary).match(/.{1,64}/g)!.join('\n')
  const pem = `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`
  return { pair, pem, json: JSON.stringify({ client_email: 'push@demo.iam.gserviceaccount.com', private_key: pem, project_id: 'demo-app' }) }
}

Deno.test('a service account is read from its JSON, and nothing else is one', async () => {
  const { json, pem } = await testAccount()
  assertEquals(parseServiceAccount(json), {
    client_email: 'push@demo.iam.gserviceaccount.com',
    private_key: pem,
    project_id: 'demo-app',
    token_uri: 'https://oauth2.googleapis.com/token',
  })
  assertEquals(parseServiceAccount(undefined), null)
  assertEquals(parseServiceAccount(''), null)
  assertEquals(parseServiceAccount('not json'), null)
  assertEquals(parseServiceAccount('{}'), null)
  assertEquals(parseServiceAccount(JSON.stringify({ client_email: 'a', private_key: 'x', project_id: 'p' })), null)
  assertEquals(parseServiceAccount(JSON.stringify({ client_email: 'a', private_key: 'PRIVATE KEY', project_id: 'Bad Id' })), null)
})

Deno.test('a token address that is not https is ignored', async () => {
  const { pem } = await testAccount()
  const base = { client_email: 'a@b', private_key: pem, project_id: 'p' }
  assertEquals(parseServiceAccount(JSON.stringify({ ...base, token_uri: 'http://evil.example/t' }))!.token_uri, 'https://oauth2.googleapis.com/token')
  assertEquals(parseServiceAccount(JSON.stringify({ ...base, token_uri: 'https://auth.example/t' }))!.token_uri, 'https://auth.example/t')
})

Deno.test('base64url has no padding or the characters + and /', () => {
  assertEquals(base64Url('any carnal pleas'), 'YW55IGNhcm5hbCBwbGVhcw')
  assertEquals(base64Url(new Uint8Array([251, 255, 254])), '-__-')
})

Deno.test('a PEM key is read to its DER bytes', async () => {
  const { pem } = await testAccount()
  const der = pemToDer(pem)
  assertEquals(der[0], 0x30) // an ASN.1 sequence
  assertEquals(der.length > 1000, true)
})

Deno.test('the assertion is signed with the key and asks for the messaging scope', async () => {
  const { json, pair } = await testAccount()
  const account = parseServiceAccount(json)!
  const jwt = await signAssertion(account, 1_800_000_000)
  const [header, claims, signature] = jwt.split('.')
  assertEquals(JSON.parse(atob(header.replace(/-/g, '+').replace(/_/g, '/'))), { alg: 'RS256', typ: 'JWT' })
  assertEquals(
    JSON.parse(atob(claims.replace(/-/g, '+').replace(/_/g, '/'))),
    assertionClaims(account, 1_800_000_000),
  )
  assertEquals(assertionClaims(account, 10).exp, 3610)
  assertEquals(assertionClaims(account, 10).scope, 'https://www.googleapis.com/auth/firebase.messaging')

  const raw = atob(signature.replace(/-/g, '+').replace(/_/g, '/'))
  const bytes = Uint8Array.from(raw, (c) => c.charCodeAt(0))
  const ok = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    pair.publicKey,
    bytes,
    new TextEncoder().encode(`${header}.${claims}`),
  )
  assertEquals(ok, true)
})

Deno.test('an access token is fetched once and kept until a minute before it ends', async () => {
  const { json } = await testAccount()
  const account = { ...parseServiceAccount(json)!, token_uri: 'https://auth.example/token' }
  const original = globalThis.fetch
  let calls = 0
  let sent: URLSearchParams | undefined
  globalThis.fetch = ((_url: unknown, init?: RequestInit) => {
    calls++
    sent = init?.body as URLSearchParams
    return Promise.resolve(new Response(JSON.stringify({ access_token: `tok${calls}`, expires_in: 3600 }), { status: 200 }))
  }) as typeof fetch
  try {
    const t0 = Date.UTC(2026, 10, 7)
    assertEquals(await accessToken(account, t0), 'tok1')
    assertEquals(sent!.get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer')
    assertEquals(sent!.get('assertion')!.split('.').length, 3)
    assertEquals(await accessToken(account, t0 + 3_000_000), 'tok1')
    assertEquals(calls, 1)
    assertEquals(await accessToken(account, t0 + 3_560_000), 'tok2')
    assertEquals(calls, 2)
  } finally {
    globalThis.fetch = original
  }
})

Deno.test('a refused service account is an error', async () => {
  const { json } = await testAccount()
  const account = { ...parseServiceAccount(json)!, client_email: 'other@demo.iam.gserviceaccount.com' }
  const original = globalThis.fetch
  globalThis.fetch = (() => Promise.resolve(new Response('{"error":"invalid_grant"}', { status: 400 }))) as typeof fetch
  try {
    let failed = false
    await accessToken(account, Date.UTC(2030, 0, 1)).catch(() => (failed = true))
    assertEquals(failed, true)
  } finally {
    globalThis.fetch = original
  }
})

Deno.test('the FCM body has the notification, the data and the Android channel', () => {
  assertEquals(
    fcmBody({ token: 't', title: 'Hi', body: 'There', data: { kind: 'x' }, channelId: 'price_drops' }),
    {
      message: {
        token: 't',
        notification: { title: 'Hi', body: 'There' },
        data: { kind: 'x' },
        android: { priority: 'HIGH', notification: { channel_id: 'price_drops' } },
        apns: { payload: { aps: { sound: 'default' } } },
      },
    },
  )
})

Deno.test('FCM answers are told apart: sent, a dead token, try later, refused', () => {
  assertEquals(classifyResponse(200, { name: 'projects/p/messages/1' }), 'sent')
  assertEquals(classifyResponse(404, { error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }), 'invalid_token')
  assertEquals(classifyResponse(400, { error: { status: 'INVALID_ARGUMENT', details: [{ errorCode: 'UNREGISTERED' }] } }), 'invalid_token')
  assertEquals(
    classifyResponse(400, { error: { status: 'INVALID_ARGUMENT', message: 'The registration token is not a valid FCM registration token' } }),
    'invalid_token',
  )
  // A malformed message is not the token's fault: the token stays.
  assertEquals(classifyResponse(400, { error: { status: 'INVALID_ARGUMENT', message: 'Invalid value at message.data' } }), 'failed')
  assertEquals(classifyResponse(401, { error: { status: 'UNAUTHENTICATED' } }), 'retry')
  assertEquals(classifyResponse(403, { error: { status: 'PERMISSION_DENIED' } }), 'retry')
  assertEquals(classifyResponse(429, { error: { status: 'RESOURCE_EXHAUSTED' } }), 'retry')
  assertEquals(classifyResponse(503, { error: { status: 'UNAVAILABLE' } }), 'retry')
  assertEquals(classifyResponse(500, null), 'retry')
  assertEquals(classifyResponse(418, null), 'failed')
})

// ---- Price alerts -----------------------------------------------------------------

const price = (amount: number, cut: number, low: number | null = null, currency = 'EUR'): GamePrice => ({
  shop: { id: 61, name: 'Steam' },
  price: { amount, currency },
  regular: { amount: 40, currency },
  cut,
  url: 'https://store.example/g',
  expiry: null,
  history_low: low === null ? null : { amount: low, currency },
})

Deno.test('a first sale worth a message is announced', () => {
  assertEquals(decide(price(20, 50), null), 'notify')
  assertEquals(decide(price(34, MIN_CUT), null), 'notify')
})

Deno.test('a small sale is not announced, unless it is the lowest price ever', () => {
  assertEquals(decide(price(36, MIN_CUT - 1), null), 'keep')
  assertEquals(decide(price(36, 10, 36), null), 'notify')
  assertEquals(decide(price(36, 10, 20), null), 'keep')
})

Deno.test('the lowest ever is for the same currency only', () => {
  assertEquals(isLowestEver(price(20, 50, 20)), true)
  assertEquals(isLowestEver(price(20.004, 50, 20)), true)
  assertEquals(isLowestEver(price(21, 50, 20)), false)
  assertEquals(isLowestEver(price(20, 50)), false)
  assertEquals(isLowestEver({ ...price(20, 50), history_low: { amount: 30, currency: 'USD' } }), false)
})

Deno.test('a sale already announced is not announced again, until it gets clearly better', () => {
  const told = { last_price: 20, currency: 'EUR' }
  assertEquals(decide(price(20, 50), told), 'keep')
  assertEquals(decide(price(19, 52), told), 'keep')
  assertEquals(decide(price(20 * FURTHER_DROP, 55), told), 'notify')
  assertEquals(decide(price(10, 75), told), 'notify')
  // Worse than the one announced: nothing.
  assertEquals(decide(price(30, 25), told), 'keep')
})

Deno.test('a new currency is a new sale', () => {
  assertEquals(decide(price(20, 50, null, 'USD'), { last_price: 20, currency: 'EUR' }), 'notify')
})

Deno.test('a game back at its regular price is forgotten, so its next sale is announced', () => {
  assertEquals(decide(price(40, 0), { last_price: 20, currency: 'EUR' }), 'clear')
  assertEquals(decide(null, { last_price: 20, currency: 'EUR' }), 'clear')
  assertEquals(decide(price(40, 0), null), 'keep')
  assertEquals(decide(null, null), 'keep')
})

// ---- Messages ---------------------------------------------------------------------

Deno.test('the language is Russian for a Russian phone and English for the rest', () => {
  assertEquals(languageOf('ru'), 'ru')
  assertEquals(languageOf('RU'), 'ru')
  assertEquals(languageOf('ru-RU'), 'ru')
  assertEquals(languageOf('en'), 'en')
  assertEquals(languageOf('de'), 'en')
  assertEquals(languageOf(null), 'en')
})

Deno.test('money is written the way the language writes it', () => {
  assertEquals(formatMoney(12.5, 'USD', 'en'), '$12.50')
  assertEquals(formatMoney(12.5, 'EUR', 'en'), '€12.50')
  assertEquals(formatMoney(1234.5, 'RUB', 'ru').replace(/\s/g, ' '), '1 234,50 ₽')
  assertEquals(formatMoney(5, 'XX', 'en'), '5.00 XX')
})

const drop = {
  game_id: 'g1',
  igdb_id: 1942,
  title: 'The Witcher 3: Wild Hunt',
  price: { amount: 9.99, currency: 'USD' },
  cut: 80,
  shop: 'GOG',
  lowest: false,
}

Deno.test('a price drop says the game, the price, the store and the cut', () => {
  assertEquals(renderPriceDrop(readPriceDrop(drop)!, 'en'), {
    title: 'The Witcher 3: Wild Hunt is on sale',
    body: '$9.99 at GOG (−80%)',
    data: { kind: 'price_drop', igdb_id: '1942' },
    channelId: CHANNELS.price_drop,
  })
  const ru = renderPriceDrop(readPriceDrop(drop)!, 'ru')
  assertEquals(ru.title, '«The Witcher 3: Wild Hunt» со скидкой')
  assertEquals(ru.body.endsWith('в GOG (−80%)'), true)
})

Deno.test('a price drop to the lowest ever says so', () => {
  const d = readPriceDrop({ ...drop, lowest: true })!
  assertEquals(renderPriceDrop(d, 'en').title, 'The Witcher 3: Wild Hunt is at its lowest price ever')
  assertEquals(renderPriceDrop(d, 'ru').title, '«The Witcher 3: Wild Hunt» по самой низкой цене')
})

Deno.test('a game without an IGDB id has no id to open, and a long title is cut', () => {
  const d = readPriceDrop({ ...drop, igdb_id: null, title: 'x'.repeat(200) })!
  const r = renderPriceDrop(d, 'en')
  assertEquals(r.data, { kind: 'price_drop' })
  assertEquals(r.title.length < 100, true)
})

Deno.test('a price drop that is not whole is not one', () => {
  assertEquals(readPriceDrop(null), null)
  assertEquals(readPriceDrop({ ...drop, price: null }), null)
  assertEquals(readPriceDrop({ ...drop, price: { amount: '9', currency: 'USD' } }), null)
  assertEquals(readPriceDrop({ ...drop, shop: 5 }), null)
  assertEquals(readPriceDrop({ ...drop, game_id: undefined }), null)
})

Deno.test('a reply says the thread and who replied, and carries the thread to open', () => {
  const d = readThreadReply({ thread_id: 't1', thread_title: 'Best RPG of 2026?', from_id: 'm1' })!
  assertEquals(renderThreadReply(d, 'Alex', 'en'), {
    title: 'New reply in “Best RPG of 2026?”',
    body: 'Alex replied to your thread',
    data: { kind: 'thread_reply', thread_id: 't1' },
    channelId: CHANNELS.thread_reply,
  })
  assertEquals(renderThreadReply(d, 'Alex', 'ru').title, 'Новый ответ в «Best RPG of 2026?»')
  assertEquals(renderThreadReply(d, 'Alex', 'ru').body, 'Ответ от Alex')
  assertEquals(renderThreadReply(d, null, 'en').body, 'Someone replied to your thread')
})

Deno.test('a reply that is not whole is not one', () => {
  assertEquals(readThreadReply(null), null)
  assertEquals(readThreadReply({ thread_id: 't1' }), null)
  assertEquals(readThreadReply({ thread_title: 'x' }), null)
})

Deno.test('a row is rendered by its kind, with the replier looked up, and anything else is null', () => {
  const names = (id: string) => (id === 'm1' ? 'Alex' : null)
  assertEquals(render('thread_reply', { thread_id: 't', thread_title: 'T', from_id: 'm1' }, 'en', names)!.body, 'Alex replied to your thread')
  assertEquals(render('thread_reply', { thread_id: 't', thread_title: 'T', from_id: 'm2' }, 'en', names)!.body, 'Someone replied to your thread')
  assertNotEquals(render('price_drop', drop, 'en', names), null)
  assertEquals(render('price_drop', {}, 'en', names), null)
  assertEquals(render('follower', {}, 'en', names), null)
})

// ---- The schedule's secret ----------------------------------------------------------

import { cronSecretMatches } from './cron.ts'

Deno.test('the cron secret is the one set, and nothing else, empty or missing is', async () => {
  assertEquals(await cronSecretMatches('s3cret', 's3cret'), true)
  assertEquals(await cronSecretMatches('s3cret', 's3cret '), false)
  assertEquals(await cronSecretMatches('other', 's3cret'), false)
  assertEquals(await cronSecretMatches('', ''), false)
  assertEquals(await cronSecretMatches(null, 's3cret'), false)
  assertEquals(await cronSecretMatches('s3cret', undefined), false)
})
