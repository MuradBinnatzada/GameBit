import { assertEquals } from 'jsr:@std/assert@1'
import {
  DAYS_MAX,
  isRefusal,
  NOTE_MAX,
  parseAdminRequest,
  REASON_MAX,
  refusalFor,
  reportsFromRows,
  suspendedFromRows,
} from './admin_moderation.ts'

const MEMBER = '0f8fad5b-d9cb-469f-a165-70867728950e'

Deno.test('the two listings need nothing else', () => {
  assertEquals(parseAdminRequest({ action: 'reports' }), { action: 'reports' })
  assertEquals(parseAdminRequest({ action: 'suspended', junk: 1 }), { action: 'suspended' })
})

Deno.test('anything but a JSON object, or an unknown action, is refused', () => {
  for (const body of [null, undefined, 'suspend', 4, [], [{ action: 'reports' }], {}, { action: 'delete_everything' }]) {
    const parsed = parseAdminRequest(body)
    assertEquals(isRefusal(parsed), true, JSON.stringify(body))
  }
})

Deno.test('a suspension needs a member and a reason; days are optional', () => {
  assertEquals(parseAdminRequest({ action: 'suspend', member: MEMBER, reason: 'Spam', days: 7 }), {
    action: 'suspend',
    member: MEMBER,
    reason: 'Spam',
    days: 7,
  })
  // No days (or null): until a moderator lifts it.
  assertEquals(parseAdminRequest({ action: 'suspend', member: MEMBER, reason: 'Spam' }), {
    action: 'suspend',
    member: MEMBER,
    reason: 'Spam',
    days: null,
  })
  assertEquals(parseAdminRequest({ action: 'suspend', member: MEMBER, reason: 'Spam', days: null }), {
    action: 'suspend',
    member: MEMBER,
    reason: 'Spam',
    days: null,
  })
})

Deno.test('the reason is tidied to one line and must not be empty or too long', () => {
  assertEquals(
    parseAdminRequest({ action: 'suspend', member: MEMBER, reason: '  Harassment \n in   the discussions ' }),
    { action: 'suspend', member: MEMBER, reason: 'Harassment in the discussions', days: null },
  )
  for (const reason of ['', '   ', '\n', undefined, 7, 'x'.repeat(REASON_MAX + 1)]) {
    assertEquals(isRefusal(parseAdminRequest({ action: 'suspend', member: MEMBER, reason })), true, String(reason))
  }
  assertEquals(
    isRefusal(parseAdminRequest({ action: 'suspend', member: MEMBER, reason: 'x'.repeat(REASON_MAX) })),
    false,
  )
})

Deno.test('days are whole numbers from 1 to ten years', () => {
  for (const days of [0, -1, 1.5, DAYS_MAX + 1, '7', NaN, Infinity, true]) {
    assertEquals(
      isRefusal(parseAdminRequest({ action: 'suspend', member: MEMBER, reason: 'Spam', days })),
      true,
      String(days),
    )
  }
  for (const days of [1, 30, DAYS_MAX]) {
    assertEquals(
      isRefusal(parseAdminRequest({ action: 'suspend', member: MEMBER, reason: 'Spam', days })),
      false,
      String(days),
    )
  }
})

Deno.test('the member has to be an id, written in lower case', () => {
  for (const member of [undefined, null, '', 'someone', MEMBER + 'x', 12, "0f8fad5b'; drop table x;--"]) {
    assertEquals(isRefusal(parseAdminRequest({ action: 'reinstate', member })), true, String(member))
    assertEquals(isRefusal(parseAdminRequest({ action: 'suspend', member, reason: 'Spam' })), true, String(member))
  }
  assertEquals(parseAdminRequest({ action: 'reinstate', member: MEMBER.toUpperCase() }), {
    action: 'reinstate',
    member: MEMBER,
  })
})

Deno.test('closing reports takes actioned or dismissed and a short note', () => {
  assertEquals(parseAdminRequest({ action: 'close', member: MEMBER, result: 'dismissed', note: ' ordinary  disagreement ' }), {
    action: 'close',
    member: MEMBER,
    result: 'dismissed',
    note: 'ordinary disagreement',
  })
  assertEquals(parseAdminRequest({ action: 'close', member: MEMBER, result: 'actioned' }), {
    action: 'close',
    member: MEMBER,
    result: 'actioned',
    note: '',
  })
  const long = parseAdminRequest({ action: 'close', member: MEMBER, result: 'actioned', note: 'n'.repeat(NOTE_MAX + 50) })
  assertEquals(!isRefusal(long) && long.action === 'close' && long.note.length, NOTE_MAX)
  for (const result of ['open', 'handled', '', undefined, null]) {
    assertEquals(isRefusal(parseAdminRequest({ action: 'close', member: MEMBER, result })), true, String(result))
  }
})

Deno.test('removing content names the kind, the author and the thing', () => {
  const THING = '7c9e6679-7425-40de-944b-e07fc1f90ae7'
  for (const kind of ['review', 'thread', 'reply', 'list']) {
    assertEquals<unknown>(parseAdminRequest({ action: 'remove', kind, member: MEMBER, reference: THING.toUpperCase() }), {
      action: 'remove',
      kind,
      member: MEMBER,
      reference: THING,
    })
  }
})

Deno.test('a profile is cleared as a whole, whatever reference comes with it', () => {
  const expected = { action: 'remove', kind: 'profile', member: MEMBER, reference: null }
  assertEquals<unknown>(parseAdminRequest({ action: 'remove', kind: 'profile', member: MEMBER }), expected)
  assertEquals<unknown>(parseAdminRequest({ action: 'remove', kind: 'profile', member: MEMBER, reference: 'junk' }), expected)
})

Deno.test('removing needs a known kind, a member and, but for a profile, a real reference', () => {
  const THING = '7c9e6679-7425-40de-944b-e07fc1f90ae7'
  for (const kind of [undefined, null, '', 'comment', 'avatar', 'other', 7, ['list']]) {
    assertEquals(isRefusal(parseAdminRequest({ action: 'remove', kind, member: MEMBER, reference: THING })), true, String(kind))
  }
  for (const member of [undefined, '', 'someone', 5]) {
    assertEquals(isRefusal(parseAdminRequest({ action: 'remove', kind: 'list', member, reference: THING })), true, String(member))
  }
  for (const reference of [undefined, null, '', 'not-an-id', 5, THING + 'x']) {
    assertEquals(isRefusal(parseAdminRequest({ action: 'remove', kind: 'thread', member: MEMBER, reference })), true, String(reference))
  }
})

Deno.test('report rows become reports, and leave out who reported', () => {
  const rows = [{
    source: 'review',
    reported_at: '2026-11-01T10:00:00Z',
    hours_open: 3.5,
    overdue: false,
    reason: 'abuse',
    reporter_id: 'must-not-be-sent',
    reported_id: MEMBER,
    reported_handle: 'rude_player',
    reported_name: 'Rude Player',
    content: 'a bad review',
    reference: 'game-1',
    suspended: false,
  }]
  const reports = reportsFromRows(rows)
  assertEquals(reports, [{
    source: 'review',
    reported_at: '2026-11-01T10:00:00Z',
    hours_open: 3.5,
    overdue: false,
    reason: 'abuse',
    member: { id: MEMBER, handle: 'rude_player', name: 'Rude Player', suspended: false },
    content: 'a bad review',
    reference: 'game-1',
  }])
  assertEquals(JSON.stringify(reports).includes('must-not-be-sent'), false)
})

Deno.test('odd report rows are tidied or dropped', () => {
  assertEquals(reportsFromRows(null), [])
  assertEquals(reportsFromRows('x'), [])
  assertEquals(reportsFromRows([null, 4, 'x', {}, { reported_id: '' }]), [])
  const [report] = reportsFromRows([{ reported_id: MEMBER, hours_open: '26.5', overdue: true, suspended: true }])
  assertEquals(report.hours_open, 26.5)
  assertEquals(report.overdue, true)
  assertEquals(report.member, { id: MEMBER, handle: '', name: '', suspended: true })
  assertEquals(report.content, '')
  assertEquals(report.reference, null)
})

Deno.test('suspended members keep their reason and end, not who suspended them', () => {
  const members = suspendedFromRows([
    {
      user_id: MEMBER,
      handle: 'spammer',
      display_name: 'Spammer',
      reason: 'Spam',
      suspended_at: '2026-11-01T10:00:00Z',
      until: null,
      suspended_by: 'admin:someone',
    },
    { user_id: 'u2', handle: null, display_name: null, reason: 'Abuse', suspended_at: 'x', until: '2026-12-01T00:00:00Z' },
    { handle: 'no id' },
  ])
  assertEquals(members, [
    { id: MEMBER, handle: 'spammer', name: 'Spammer', reason: 'Spam', suspended_at: '2026-11-01T10:00:00Z', until: null },
    { id: 'u2', handle: '', name: '', reason: 'Abuse', suspended_at: 'x', until: '2026-12-01T00:00:00Z' },
  ])
  assertEquals(JSON.stringify(members).includes('admin:'), false)
  assertEquals(suspendedFromRows(undefined), [])
})

Deno.test('the database refusals have codes, other errors have none', () => {
  assertEquals(refusalFor({ code: 'CP403', message: 'not_admin' }), { code: 'FORBIDDEN', status: 403 })
  assertEquals(refusalFor({ code: 'CP400' }), { code: 'BAD_REQUEST', status: 400 })
  assertEquals(refusalFor({ code: 'CP404' }), { code: 'NOT_FOUND', status: 404 })
  assertEquals(refusalFor({ code: 'CP409' }), { code: 'MEMBER_IS_ADMIN', status: 409 })
  assertEquals(refusalFor({ code: '42501' }), null)
  assertEquals(refusalFor(new Error('boom')), null)
  assertEquals(refusalFor(null), null)
  assertEquals(refusalFor('CP403'), null)
})
