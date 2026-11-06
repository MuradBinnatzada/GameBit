// supabase/functions/_shared/cron.ts
//
// The check of the functions that pg_cron calls (send-notifications, check-prices):
// the call carries the CRON_SECRET in `x-cron-secret`, and nothing else proves it is
// the schedule and not a member.

/**
 * Whether [provided] is [expected]. Compared as SHA-256 digests, so the check takes the
 * same time wherever the two strings first differ. False when either is empty.
 */
export async function cronSecretMatches(provided: string | null, expected: string | undefined): Promise<boolean> {
  if (!provided || !expected) return false
  const encoder = new TextEncoder()
  const [a, b] = await Promise.all(
    [provided, expected].map(async (s) => new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(s)))),
  )
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i]
  return diff === 0
}
