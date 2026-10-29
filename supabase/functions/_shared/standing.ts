// supabase/functions/_shared/standing.ts
//
// Whether a member is suspended (moderation.suspend_member, see
// 20261028235500_moderation_and_blocking.sql). The database refuses a suspended
// member's own token everywhere (public.mfa_satisfied()), but the Edge Functions
// write with the service role and so ask for themselves, right after getUser()
// accepted the token: the function that takes a member's words in, `discussions`,
// answers SUSPENDED (403).

import type { RpcClient } from './rate_limit.ts'

/**
 * Whether [userId] is suspended right now. A check that can't be made never
 * blocks anyone (the failure is logged): the account's token stops working at the
 * database either way, and a post is not worth an outage.
 */
export async function isSuspended(client: RpcClient, userId: string): Promise<boolean> {
  try {
    const { data, error } = await client.rpc('is_member_suspended', { target: userId })
    if (error) throw error
    return data === true
  } catch (err) {
    console.error('suspension check failed:', err)
    return false
  }
}
