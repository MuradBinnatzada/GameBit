-- Games Steam stops listing go to Hidden.
--
-- Steam lets a member mark a game "private": to everyone else, apps and sites included,
-- it then looks as if they did not own it (help.steampowered.com, "Steam Private Games").
-- Gamebit reads a library as an outside app, with its own API key and the member's Steam
-- ID, so a private game is not in what Steam sends back, and a game that was private
-- from the start is never imported. Nothing in that answer says "private": the game is
-- just missing.
--
-- What the sync CAN see is a game it listed before and that is no longer in the list.
-- That is what a game made private looks like (a refund, or a game taken off the
-- account, looks the same, and is as well off hidden). The sync calls
-- `mark_unlisted_steam_games` after it saved the library, with the Steam apps it was
-- just sent, and:
--
--   * a game imported from Steam (it has a Steam playtime) whose app is not in the list
--     is hidden from other members (20261031230000_hidden_games.sql) and stamped in
--     `steam_unlisted_at`. Only the first sync that misses it does that: a member who
--     shows the game again is not overruled by the next sync;
--   * a game that is in the list again loses its stamp, so that a later disappearance
--     is noticed again. It stays hidden: showing a game to others is the member's
--     decision, never a sync's.
--
-- An empty list does nothing: the sync only calls this with a list Steam sent whole,
-- but a list with no app in it can't tell a library from a failure.

alter table public.user_games
  add column if not exists steam_unlisted_at timestamptz;

comment on column public.user_games.steam_unlisted_at is
  'When a Steam sync first found the game no longer in the member''s Steam library '
  '(made private on Steam, most likely) and hid it. NULL while Steam lists it. Written '
  'by public.mark_unlisted_steam_games only.';

-- The columns only the server writes: the member's own requests can't change them.
-- (The earlier definition is 20261019132900_security_hardening.sql's, plus
-- the new column.)
create or replace function public.user_games_keep_server_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.achievements := null;
      new.achievements_unlocked := null;
      new.achievements_total := null;
      new.achievements_playtime := null;
      new.achievements_synced_at := null;
      new.steam_playtime_minutes := null;
      new.steam_unlisted_at := null;
    else
      new.achievements := old.achievements;
      new.achievements_unlocked := old.achievements_unlocked;
      new.achievements_total := old.achievements_total;
      new.achievements_playtime := old.achievements_playtime;
      new.achievements_synced_at := old.achievements_synced_at;
      new.steam_playtime_minutes := old.steam_playtime_minutes;
      new.steam_unlisted_at := old.steam_unlisted_at;
    end if;
  end if;
  return new;
end;
$$;

-- [listed_appids] are all the apps Steam listed for [target_user] in this sync. Returns
-- how many games were hidden, and how many are listed again.
create or replace function public.mark_unlisted_steam_games(target_user uuid, listed_appids bigint[])
returns table (hidden integer, relisted integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  hidden_count integer;
  relisted_count integer;
begin
  if target_user is null or coalesce(array_length(listed_appids, 1), 0) = 0 then
    return query select 0, 0;
    return;
  end if;

  with gone as (
    update public.user_games ug
       set steam_unlisted_at = now(),
           is_hidden = true
      from public.games g
     where ug.user_id = target_user
       and g.id = ug.game_id
       and g.steam_app_id is not null
       and g.steam_app_id <> all (listed_appids)
       -- imported from Steam (a game the member added themselves has no Steam playtime)
       and ug.steam_playtime_minutes is not null
       and ug.steam_unlisted_at is null
    returning 1
  )
  select count(*)::integer into hidden_count from gone;

  with back as (
    update public.user_games ug
       set steam_unlisted_at = null
      from public.games g
     where ug.user_id = target_user
       and g.id = ug.game_id
       and g.steam_app_id = any (listed_appids)
       and ug.steam_unlisted_at is not null
    returning 1
  )
  select count(*)::integer into relisted_count from back;

  return query select hidden_count, relisted_count;
end;
$$;

-- Only the sync (the service role) calls it: it hides a member's games.
revoke all on function public.mark_unlisted_steam_games(uuid, bigint[]) from public, anon, authenticated;
grant execute on function public.mark_unlisted_steam_games(uuid, bigint[]) to service_role;
