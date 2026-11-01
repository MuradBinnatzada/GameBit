// supabase/functions/_shared/admin_moderation.ts
//
// What the `admin-moderation` function accepts and what it answers: the queue of
// open reports, the suspended members, and suspending, reinstating and closing
// reports (20261101020000_admin_moderation.sql). Pure functions with no I/O, so
// they can be tested. The database decides who is an admin; nothing here does.

import { tidyTitle, UUID } from './discussions.ts'

/** The longest reason a suspension is recorded with: also the database's limit. */
export const REASON_MAX = 500
/** The longest note kept with closed reports. */
export const NOTE_MAX = 200
/** The longest suspension in days (ten years); no days at all is "until reinstated". */
export const DAYS_MAX = 3650

export type AdminRequest =
  | { action: 'reports' }
  | { action: 'suspended' }
  | { action: 'suspend'; member: string; reason: string; days: number | null }
  | { action: 'reinstate'; member: string }
  | { action: 'close'; member: string; result: 'actioned' | 'dismissed'; note: string }

/** Why a request is refused; the app words the message itself from `code`. */
export type Refusal = { code: 'BAD_REQUEST'; message: string }

const refuse = (message: string): Refusal => ({ code: 'BAD_REQUEST', message })

export function isRefusal(parsed: AdminRequest | Refusal): parsed is Refusal {
  return 'message' in parsed
}

/**
 * The request body as an [AdminRequest], or the [Refusal] saying what is wrong
 * with it. `suspend` needs a member, a reason of up to REASON_MAX characters and
 * either no `days` (until reinstated) or a whole number from 1 to DAYS_MAX.
 */
export function parseAdminRequest(body: unknown): AdminRequest | Refusal {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return refuse('Send a JSON object')
  const raw = body as Record<string, unknown>

  switch (raw.action) {
    case 'reports':
      return { action: 'reports' }
    case 'suspended':
      return { action: 'suspended' }
    case 'suspend': {
      const member = memberId(raw.member)
      if (!member) return refuse('member must be a member id')
      const reason = tidyTitle(raw.reason)
      if (reason.length === 0 || reason.length > REASON_MAX) {
        return refuse(`reason must be 1 to ${REASON_MAX} characters`)
      }
      const days = raw.days ?? null
      if (days !== null && (typeof days !== 'number' || !Number.isInteger(days) || days < 1 || days > DAYS_MAX)) {
        return refuse(`days must be a whole number from 1 to ${DAYS_MAX}, or left out`)
      }
      return { action: 'suspend', member, reason, days }
    }
    case 'reinstate': {
      const member = memberId(raw.member)
      return member ? { action: 'reinstate', member } : refuse('member must be a member id')
    }
    case 'close': {
      const member = memberId(raw.member)
      if (!member) return refuse('member must be a member id')
      if (raw.result !== 'actioned' && raw.result !== 'dismissed') {
        return refuse('result must be actioned or dismissed')
      }
      return { action: 'close', member, result: raw.result, note: tidyTitle(raw.note).slice(0, NOTE_MAX) }
    }
    default:
      return refuse('Unknown action')
  }
}

function memberId(value: unknown): string | null {
  return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null
}

// --- What the database answers ----------------------------------------------------

/** One open report, as the app lists it. */
export type AdminReport = {
  source: string
  reported_at: string
  hours_open: number
  overdue: boolean
  reason: string
  member: { id: string; handle: string; name: string; suspended: boolean }
  content: string
  reference: string | null
}

/** One suspended member, as the app lists it. */
export type SuspendedMember = {
  id: string
  handle: string
  name: string
  reason: string
  suspended_at: string
  until: string | null
}

const records = (rows: unknown): Record<string, unknown>[] =>
  Array.isArray(rows) ? rows.filter((row): row is Record<string, unknown> => typeof row === 'object' && row !== null) : []

const text = (value: unknown): string => (typeof value === 'string' ? value : '')

/** `admin_open_reports` rows as [AdminReport]s; anything that isn't a row is left out. */
export function reportsFromRows(rows: unknown): AdminReport[] {
  return records(rows).flatMap((row) => {
    const id = text(row.reported_id)
    if (!id) return []
    return [{
      source: text(row.source),
      reported_at: text(row.reported_at),
      hours_open: Number(row.hours_open) || 0,
      overdue: row.overdue === true,
      reason: text(row.reason),
      member: {
        id,
        handle: text(row.reported_handle),
        name: text(row.reported_name),
        suspended: row.suspended === true,
      },
      content: text(row.content),
      reference: typeof row.reference === 'string' ? row.reference : null,
    }]
  })
}

/** `admin_suspended_members` rows as [SuspendedMember]s. Who suspended them is not sent. */
export function suspendedFromRows(rows: unknown): SuspendedMember[] {
  return records(rows).flatMap((row) => {
    const id = text(row.user_id)
    if (!id) return []
    return [{
      id,
      handle: text(row.handle),
      name: text(row.display_name),
      reason: text(row.reason),
      suspended_at: text(row.suspended_at),
      until: typeof row.until === 'string' ? row.until : null,
    }]
  })
}

// --- What the database refuses ------------------------------------------------------

export type AdminErrorCode = 'FORBIDDEN' | 'BAD_REQUEST' | 'NOT_FOUND' | 'MEMBER_IS_ADMIN'

/**
 * The function's code and HTTP status for an error from one of the admin_*
 * functions (the SQLSTATEs in 20261101020000_admin_moderation.sql); null for any
 * other error, which the function logs and answers as INTERNAL.
 */
export function refusalFor(error: unknown): { code: AdminErrorCode; status: number } | null {
  const sqlstate = typeof error === 'object' && error !== null ? (error as { code?: unknown }).code : undefined
  switch (sqlstate) {
    case 'CP403':
      return { code: 'FORBIDDEN', status: 403 }
    case 'CP400':
      return { code: 'BAD_REQUEST', status: 400 }
    case 'CP404':
      return { code: 'NOT_FOUND', status: 404 }
    case 'CP409':
      return { code: 'MEMBER_IS_ADMIN', status: 409 }
    default:
      return null
  }
}
