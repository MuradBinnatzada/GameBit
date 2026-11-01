// supabase/functions/_shared/steam_unlisted.ts
//
// A game Steam stops listing is one the member made private there: to an outside
// app, a private game looks as if they did not own it (help.steampowered.com, "Steam
// Private Games"). sync-steam hands the apps Steam listed to
// `mark_unlisted_steam_games` (20261101000000_steam_private_games.sql), which hides
// the games it listed before and that are no longer in them.
//
// That is only safe when the list is the whole library: a list cut short, or empty by
// a failure, would hide games that are all still there. Pure functions, so the rules
// can be tested without Steam or a database.

/**
 * Whether Steam's answer can be read as the member's whole library: it has games in it,
 * and as many as Steam says (`game_count`). An empty library, a missing count or a list
 * of another length is left alone, whatever the reason.
 */
export function listIsWhole(listed: number, claimed: unknown): boolean {
  return listed > 0 && typeof claimed === 'number' && Number.isFinite(claimed) && claimed === listed
}

/** The distinct Steam app ids of a GetOwnedGames list, ignoring entries without one. */
export function listedAppIds(games: readonly { appid?: unknown }[]): number[] {
  const ids = new Set<number>()
  for (const g of games) {
    const id = g.appid
    if (typeof id === 'number' && Number.isSafeInteger(id) && id > 0) ids.add(id)
  }
  return [...ids]
}
