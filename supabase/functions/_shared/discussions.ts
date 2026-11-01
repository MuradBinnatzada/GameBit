// supabase/functions/_shared/discussions.ts
//
// What the `discussions` function accepts: a new thread or a reply, tidied and
// checked before anything is written. Pure functions with no I/O, so they can be
// tested. The word filter is in discussion_filter.ts.

import { breaksChatRules } from './discussion_filter.ts'

export const TITLE_MIN = 3
export const TITLE_MAX = 120
/** The opening text of a thread, and a reply: also the limits of the tables. */
export const THREAD_BODY_MAX = 3000
export const POST_MAX = 2000
/** Most web addresses one text may have: more is advertising. */
export const MAX_LINKS = 3

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const BOARD_ID = /^[a-z0-9-]{2,30}$/

export type DiscussionRequest =
  | { mode: 'thread'; board: string; title: string; body: string; gameId: string | null }
  | { mode: 'reply'; thread: string; body: string }

/** Why a post is refused. `code` is what the app is sent; the app words the message itself. */
export type Refusal = { code: 'BAD_REQUEST' | 'CONTENT_NOT_ALLOWED' | 'TOO_MANY_LINKS'; message: string }

/**
 * [value] as a title: one line, white space squeezed, control characters and
 * invisible direction marks gone. Empty when it is not text.
 */
export function tidyTitle(value: unknown): string {
  if (typeof value !== 'string') return ''
  return value
    .normalize('NFC')
    // deno-lint-ignore no-control-regex
    .replace(/[\u0000-\u001f\u007f​-‏‪-‮⁦-⁩﻿]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

/**
 * [value] as a text: line breaks kept (at most one empty line in a row), white
 * space on a line squeezed, control characters and invisible direction marks gone.
 * Empty when it is not text.
 */
export function tidyBody(value: unknown): string {
  if (typeof value !== 'string') return ''
  return value
    .normalize('NFC')
    .replace(/\r\n?/g, '\n')
    // deno-lint-ignore no-control-regex
    .replace(/[\u0000-\u0009\u000b-\u001f\u007f​-‏‪-‮⁦-⁩﻿]/g, ' ')
    .split('\n')
    .map((line) => line.replace(/[ \t]+/g, ' ').trim())
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

/** How many web addresses [text] has. */
export function countLinks(text: string): number {
  return (text.match(/https?:\/\/|www\./gi) ?? []).length
}

/**
 * The request body as a [DiscussionRequest], or the [Refusal] saying what is
 * wrong with it. A thread needs a board, a title of TITLE_MIN to TITLE_MAX
 * characters and a text of up to THREAD_BODY_MAX; it may name a game by its
 * catalog id. A reply needs a thread and a text of up to POST_MAX.
 */
export function parseDiscussionRequest(payload: unknown): DiscussionRequest | Refusal {
  const bad = (message: string): Refusal => ({ code: 'BAD_REQUEST', message })
  const body = (payload ?? {}) as Record<string, unknown>

  if (body.mode === 'thread') {
    const board = body.board
    if (typeof board !== 'string' || !BOARD_ID.test(board)) return bad('`board` must be the id of a board')
    const title = tidyTitle(body.title)
    if (title.length < TITLE_MIN || title.length > TITLE_MAX) {
      return bad(`\`title\` must be ${TITLE_MIN} to ${TITLE_MAX} characters`)
    }
    const text = tidyBody(body.body)
    if (text.length < 1 || text.length > THREAD_BODY_MAX) {
      return bad(`\`body\` must be 1 to ${THREAD_BODY_MAX} characters`)
    }
    const game = body.game_id ?? null
    if (game !== null && (typeof game !== 'string' || !UUID.test(game))) return bad('`game_id` must be a game id')
    return { mode: 'thread', board, title, body: text, gameId: game === null ? null : game.toLowerCase() }
  }

  if (body.mode === 'reply') {
    const thread = body.thread
    if (typeof thread !== 'string' || !UUID.test(thread)) return bad('`thread` must be a thread id')
    const text = tidyBody(body.body)
    if (text.length < 1 || text.length > POST_MAX) return bad(`\`body\` must be 1 to ${POST_MAX} characters`)
    return { mode: 'reply', thread: thread.toLowerCase(), body: text }
  }

  return bad('`mode` must be one of: thread, reply')
}

/** Whether [value] is a [Refusal] and not a request. */
export function isRefusal(value: DiscussionRequest | Refusal): value is Refusal {
  return 'code' in value
}

/**
 * The reason [texts] (a thread's title and text, or a reply) can't be posted, or
 * null when they can: a word the chat rules refuse, or too many links.
 */
export function refuseContent(...texts: string[]): Refusal | null {
  if (texts.some(breaksChatRules)) {
    return { code: 'CONTENT_NOT_ALLOWED', message: 'This breaks the chat rules' }
  }
  if (countLinks(texts.join('\n')) > MAX_LINKS) {
    return { code: 'TOO_MANY_LINKS', message: `At most ${MAX_LINKS} links in a post` }
  }
  return null
}
