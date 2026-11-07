// supabase/functions/_shared/push_messages.ts
//
// What a notification of the outbox says, in the language of the phone it goes to, and
// what it carries so that a tap opens the right screen. Pure functions with no I/O, so
// they can be tested. The words are written here, not stored: the queue holds only ids
// and the few words a message quotes (a game's title, a thread's title).

export type Lang = 'en' | 'ru'

/** The channel (Android) a kind of notification is shown in; the app creates them. */
export const CHANNELS = { price_drop: 'price_drops', thread_reply: 'thread_replies' } as const

/** The language to write in: Russian for a Russian phone, English for anything else. */
export function languageOf(code: string | null | undefined): Lang {
  return code?.toLowerCase().startsWith('ru') ? 'ru' : 'en'
}

/** "$12.50", "12,50 €": [amount] as [lang] writes [currency]. */
export function formatMoney(amount: number, currency: string, lang: Lang): string {
  try {
    return new Intl.NumberFormat(lang === 'ru' ? 'ru-RU' : 'en-US', { style: 'currency', currency }).format(amount)
  } catch {
    return `${amount.toFixed(2)} ${currency}`
  }
}

function clip(text: string, max: number): string {
  const t = text.replace(/\s+/g, ' ').trim()
  return t.length <= max ? t : `${t.slice(0, max - 1).trimEnd()}…`
}

export type PriceDropData = {
  gameId: string
  igdbId: number | null
  title: string
  amount: number
  currency: string
  cut: number
  shop: string
  lowest: boolean
}

/** The `data` of a `price_drop` row, or null when it is not one. */
export function readPriceDrop(data: unknown): PriceDropData | null {
  const d = data as Record<string, unknown> | null
  const price = d?.price as { amount?: unknown; currency?: unknown } | undefined
  if (typeof d?.game_id !== 'string' || typeof d.title !== 'string' || typeof d.shop !== 'string') return null
  if (typeof price?.amount !== 'number' || typeof price.currency !== 'string') return null
  return {
    gameId: d.game_id,
    igdbId: typeof d.igdb_id === 'number' && Number.isSafeInteger(d.igdb_id) ? d.igdb_id : null,
    title: d.title,
    amount: price.amount,
    currency: price.currency,
    cut: typeof d.cut === 'number' ? Math.round(d.cut) : 0,
    shop: d.shop,
    lowest: d.lowest === true,
  }
}

export type ThreadReplyData = {
  threadId: string
  threadTitle: string
  fromId: string | null
  /** A reply to the member's own post, not only to a thread they started. */
  direct: boolean
  /** The member follows the thread (did not start it): not "your thread". */
  follower: boolean
}

/** The `data` of a `thread_reply` row, or null when it is not one. */
export function readThreadReply(data: unknown): ThreadReplyData | null {
  const d = data as Record<string, unknown> | null
  if (typeof d?.thread_id !== 'string' || typeof d.thread_title !== 'string') return null
  return {
    threadId: d.thread_id,
    threadTitle: d.thread_title,
    fromId: typeof d.from_id === 'string' ? d.from_id : null,
    direct: d.direct === true,
    follower: d.follower === true,
  }
}

/** A notification as it goes to a phone. */
export type Rendered = { title: string; body: string; data: Record<string, string>; channelId: string }

export function renderPriceDrop(d: PriceDropData, lang: Lang): Rendered {
  const game = clip(d.title, 60)
  const price = formatMoney(d.amount, d.currency, lang)
  const cut = d.cut > 0 ? ` (−${d.cut}%)` : ''
  const ru = lang === 'ru'
  return {
    title: d.lowest
      ? (ru ? `«${game}» по самой низкой цене` : `${game} is at its lowest price ever`)
      : (ru ? `«${game}» со скидкой` : `${game} is on sale`),
    body: ru ? `${price} в ${clip(d.shop, 30)}${cut}` : `${price} at ${clip(d.shop, 30)}${cut}`,
    data: { kind: 'price_drop', ...(d.igdbId !== null ? { igdb_id: String(d.igdbId) } : {}) },
    channelId: CHANNELS.price_drop,
  }
}

/** [fromName] is the member who replied (null: unknown, left out). */
export function renderThreadReply(d: ThreadReplyData, fromName: string | null, lang: Lang): Rendered {
  const thread = clip(d.threadTitle, 70)
  const name = fromName ? clip(fromName, 40) : null
  const ru = lang === 'ru'
  const data = { kind: 'thread_reply', thread_id: d.threadId }
  if (d.direct) {
    return {
      title: ru ? 'Вам ответили' : 'New reply to you',
      body: name
        ? (ru ? `Ответ от ${name} в «${thread}»` : `${name} replied to you in “${thread}”`)
        : (ru ? `Вам ответили в «${thread}»` : `Someone replied to you in “${thread}”`),
      data,
      channelId: CHANNELS.thread_reply,
    }
  }
  return {
    title: ru ? `Новый ответ в «${thread}»` : `New reply in “${thread}”`,
    body: d.follower
      ? (name ? (ru ? `Ответ от ${name}` : `${name} replied`) : (ru ? 'Появился новый ответ' : 'There is a new reply'))
      : name
      ? (ru ? `Ответ от ${name}` : `${name} replied to your thread`)
      : (ru ? 'Вам ответили в вашей теме' : 'Someone replied to your thread'),
    data,
    channelId: CHANNELS.thread_reply,
  }
}

/** One outbox row as a notification, or null when its `data` is not what [kind] needs. */
export function render(
  kind: string,
  data: unknown,
  lang: Lang,
  nameOf: (memberId: string) => string | null,
): Rendered | null {
  if (kind === 'price_drop') {
    const d = readPriceDrop(data)
    return d === null ? null : renderPriceDrop(d, lang)
  }
  if (kind === 'thread_reply') {
    const d = readThreadReply(data)
    return d === null ? null : renderThreadReply(d, d.fromId === null ? null : nameOf(d.fromId), lang)
  }
  return null
}
