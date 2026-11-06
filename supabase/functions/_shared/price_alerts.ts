// supabase/functions/_shared/price_alerts.ts
//
// When a price drop is worth a notification (check-prices): a sale is announced once
// for a member and game, again only when it gets clearly better, and a game that went
// back to its regular price is forgotten so its next sale is announced. Pure
// functions, so the rules can be tested.

import type { GamePrice } from './game_prices.ts'

/** What a member was last told about a game. */
export type AlertState = { last_price: number; currency: string }

/** A sale below this cut is not worth a message unless it is the lowest price ever. */
export const MIN_CUT = 15

/** A price that falls to this share of the one last announced is announced again. */
export const FURTHER_DROP = 0.9

export type Decision = 'notify' | 'clear' | 'keep'

/** Whether [price] is the lowest the game has had (in the same currency). */
export function isLowestEver(price: GamePrice): boolean {
  const low = price.history_low
  return low !== null && low.currency === price.price.currency && price.price.amount <= low.amount + 0.005
}

/**
 * What to do about a game on a member's wishlist whose best price is [price] (null:
 * none) when they were last told [state] (null: nothing):
 *  - `clear`: it is not on sale now, and they were told of an earlier sale: forget it;
 *  - `notify`: a sale worth telling them of, not told yet or clearly better than the
 *    one they were told (a currency change counts as a new sale);
 *  - `keep`: nothing to do.
 */
export function decide(price: GamePrice | null, state: AlertState | null): Decision {
  if (price === null || price.cut <= 0) return state === null ? 'keep' : 'clear'
  if (price.cut < MIN_CUT && !isLowestEver(price)) return 'keep'
  if (state === null) return 'notify'
  if (state.currency !== price.price.currency) return 'notify'
  return price.price.amount <= state.last_price * FURTHER_DROP ? 'notify' : 'keep'
}
