// supabase/functions/_shared/rate_limit.ts
//
// Per-member rate limits for the Edge Functions, so one account (or a script
// with its token) can't use up the shared IGDB and Steam quotas or keep the
// functions busy for everyone else. Counted in the database by
// `consume_rate_limit` (20261019132900_security_hardening.sql): a fixed window
// per member and function, gone with the account.
//
// The limits are far above what the app does: a member typing a search, paging
// the Discover tab and opening games makes a few IGDB requests a minute; a
// library import (a search and an add per game) up to about two a second.

/**
 * At most [maxHits] calls in [windowSeconds], per member. [failClosed]: when
 * the limiter can't be reached, refuse the call instead of letting it through.
 */
export type RateLimit = { bucket: string; maxHits: number; windowSeconds: number; failClosed?: boolean }

export const RATE_LIMITS = {
  igdb: { bucket: 'igdb-handler', maxHits: 200, windowSeconds: 60 },
  // The news screen: a list and a page or two of it a minute at most.
  news: { bucket: 'game-news', maxHits: 60, windowSeconds: 60 },
  // Discussions: a few new threads an hour, and a reply every half minute or so
  // (a burst of 20, then the window rolls over). Counted before the word filter, so
  // refused posts count too.
  discussionThread: { bucket: 'discussion-thread', maxHits: 5, windowSeconds: 3600 },
  discussionPost: { bucket: 'discussion-post', maxHits: 20, windowSeconds: 600 },
  steamSync: { bucket: 'sync-steam', maxHits: 10, windowSeconds: 3600 },
  achievements: { bucket: 'sync-achievements', maxHits: 100, windowSeconds: 600 },
  deleteAccount: { bucket: 'delete-account', maxHits: 10, windowSeconds: 3600 },
  // The in-app moderation screens (admin-moderation): a list a few times a minute and an
  // action now and then. Counted for every caller, admin or not, before the admin check.
  adminModeration: { bucket: 'admin-moderation', maxHits: 300, windowSeconds: 600 },
  // Counted when a link starts and again when Steam sends the browser back:
  // ten Steam sign-ins an hour.
  steamLink: { bucket: 'steam-link', maxHits: 20, windowSeconds: 3600 },
  // Two-factor backup codes (mfa-recovery). Using one is a guess at a secret
  // from a session that only knows the password, so it is kept tight and
  // refused while the limiter can't count it. Making new ones has its own
  // bucket, so it never uses up the tries.
  backupCodeRedeem: { bucket: 'mfa-recovery-redeem', maxHits: 5, windowSeconds: 3600, failClosed: true },
  backupCodeGenerate: { bucket: 'mfa-recovery-generate', maxHits: 10, windowSeconds: 3600 },
} as const satisfies Record<string, RateLimit>

/** What a function needs of its service-role client: one RPC. */
export type RpcClient = {
  // deno-lint-ignore no-explicit-any
  rpc(fn: string, args?: Record<string, unknown>): PromiseLike<{ data: any; error: unknown }>
}

/**
 * Counts one call of [userId] against [limit]. Answers 0 to go ahead, or the
 * seconds until the member may call again. A limiter that can't be reached never
 * blocks anyone: the failure is logged and the call goes ahead. Unless the limit
 * is [RateLimit.failClosed]: then the member waits its whole window.
 */
export async function rateLimitWait(client: RpcClient, userId: string, limit: RateLimit): Promise<number> {
  try {
    const { data, error } = await client.rpc('consume_rate_limit', {
      target_user: userId,
      bucket_name: limit.bucket,
      max_hits: limit.maxHits,
      window_seconds: limit.windowSeconds,
    })
    if (error) throw error
    return waitSeconds(data)
  } catch (err) {
    console.error(`rate limit check for ${limit.bucket} failed:`, err)
    return limit.failClosed ? limit.windowSeconds : 0
  }
}

/** consume_rate_limit's answer as whole seconds to wait (0: go ahead). */
export function waitSeconds(answer: unknown): number {
  const n = Number(answer)
  return Number.isFinite(n) && n > 0 ? Math.ceil(n) : 0
}
