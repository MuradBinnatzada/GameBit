-- PlayStation trophy counts on a library row.
--
-- The "Import from PlayStation" in Settings reads the member's trophy list from
-- PlayStation on their phone and saves, for every game it matches:
--
--   trophies_earned / trophies_total
--       How many trophies the member has earned in the game, out of how many it
--       has (all grades together). Both NULL: never imported. A platinum, or all
--       of them earned, also sets the existing `perfected` flag (the app does that,
--       not the database).
--
-- Who writes them: the member's own app, through the same upsert as the rest of
-- the row (RLS already limits that to their own rows). A member could write any
-- numbers; that only changes what they see on their own game screen.
--
-- Who reads them: the owner only. `public_user_games` and the profile functions
-- name their columns, so these are not part of what other members get. Keep it
-- that way unless the profile is meant to show trophies (it would need a privacy
-- setting first, like the Steam achievements have).
--
-- Deploy order: apply this migration, then ship the app. An older app ignores the
-- columns; a newer app run against a database without them fails to read the
-- library, so the migration must be applied first.

alter table public.user_games
  add column if not exists trophies_earned integer,
  add column if not exists trophies_total integer;

alter table public.user_games
  drop constraint if exists user_games_trophies_check;
alter table public.user_games
  add constraint user_games_trophies_check check (
    (trophies_earned is null) = (trophies_total is null)
    and (trophies_earned is null
         or (trophies_earned >= 0
             and trophies_total >= 0
             and trophies_earned <= trophies_total
             -- No console game has anywhere near this many; it only stops nonsense.
             and trophies_total <= 10000))
  );

comment on column public.user_games.trophies_earned is
  'PlayStation trophies the member has earned in this game, as the app''s import from PlayStation last read them. NULL: never imported. Owner only.';
comment on column public.user_games.trophies_total is
  'PlayStation trophies the game has. NULL together with trophies_earned.';

notify pgrst, 'reload schema';

-- Fail loudly if the result is not what this file promises: the public view of a
-- library must not carry the columns.
do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema in ('public', 'private')
      and table_name = 'public_user_games'
      and column_name in ('trophies_earned', 'trophies_total')
  ) then
    raise exception 'public_user_games must not expose trophy counts';
  end if;
end;
$$;
