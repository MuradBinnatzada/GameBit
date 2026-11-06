-- Wishlist prices (the game-prices Edge Function, IsThereAnyDeal).
--
-- Which ITAD game a catalog game is, so the function asks ITAD to find it once
-- and not at every price check.
--
--   itad_id          ITAD's id of the game; null when ITAD has no such game or it was
--                    not looked up yet.
--   itad_checked_at  when the function last looked; a game with no itad_id is looked
--                    up again after a week (_shared/game_prices.ts, RETRY_UNKNOWN_DAYS).
--
-- Only the function writes them, with the service role: members have had no
-- INSERT or UPDATE on public.games since 20261019132900_security_hardening.sql, so
-- nobody can point a game at another game's prices. They are readable like the rest
-- of the catalog row and say nothing about any member.
--
-- Deploy order: this migration, then the game-prices function, then the app. Set the
-- function's secret first: `supabase secrets set ITAD_API_KEY=...`.

alter table public.games
  add column if not exists itad_id uuid,
  add column if not exists itad_checked_at timestamptz;

comment on column public.games.itad_id is
  'IsThereAnyDeal''s id of this game, found by the game-prices function; null when it has none or was not looked up.';
comment on column public.games.itad_checked_at is
  'When game-prices last looked this game up on IsThereAnyDeal.';
