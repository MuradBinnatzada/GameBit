-- The profile's trophies from the overview, not from the lists.
--
-- 20261106120000 stored a game's whole trophy list and made the profile add up
-- from the lists, so a game whose list had not been read (the sync reads a limited
-- number, the rest when they are opened) was missing from the profile. PlayStation's
-- overview of the member's games, which every sync reads whole, already says for
-- every game how many trophies of each grade the member earned out of how many
-- there are, and which trophy set it is. The app now stores that for every game:
--
--   user_games.trophy_meta   jsonb {"s": Sony's id of the trophy set, "v": which
--                            trophy service holds it, "e": [bronze, silver, gold,
--                            platinum] earned, "t": the same, in all}. NULL: the
--                            game never came from PlayStation. Written by the
--                            member's app (see lib/models/trophy.dart).
--
-- `public_trophy_summary` now takes a game's counts from there, and from its stored
-- list only for a game that has no trophy_meta (a sync from before this migration),
-- so every game the member earned a trophy in is on the profile after one sync.
-- The rules are those of 20261106120000: another member gets rows only when the
-- member shares their trophies, never a hidden game, never a blocked member.
--
-- A member could write any numbers; that only changes what their own profile shows.
-- The check keeps it the shape the function reads.
--
-- Deploy order: apply this migration, then ship the app (it writes the column).

-- 1. The column ---------------------------------------------------------------
create or replace function public.trophy_meta_valid(m jsonb)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(
    jsonb_typeof(m) = 'object'
    and jsonb_typeof(m -> 's') = 'string'
    and length(m ->> 's') between 1 and 40
    and jsonb_typeof(m -> 'v') = 'string'
    and length(m ->> 'v') <= 20
    and jsonb_typeof(m -> 'e') = 'array' and jsonb_array_length(m -> 'e') = 4
    and jsonb_typeof(m -> 't') = 'array' and jsonb_array_length(m -> 't') = 4
    and jsonb_typeof(m #> '{e,0}') = 'number' and (m #>> '{e,0}') ~ '^[0-9]{1,5}$'
    and jsonb_typeof(m #> '{e,1}') = 'number' and (m #>> '{e,1}') ~ '^[0-9]{1,5}$'
    and jsonb_typeof(m #> '{e,2}') = 'number' and (m #>> '{e,2}') ~ '^[0-9]{1,5}$'
    and jsonb_typeof(m #> '{e,3}') = 'number' and (m #>> '{e,3}') ~ '^[0-9]{1,5}$'
    and jsonb_typeof(m #> '{t,0}') = 'number' and (m #>> '{t,0}') ~ '^[0-9]{1,5}$'
    and jsonb_typeof(m #> '{t,1}') = 'number' and (m #>> '{t,1}') ~ '^[0-9]{1,5}$'
    and jsonb_typeof(m #> '{t,2}') = 'number' and (m #>> '{t,2}') ~ '^[0-9]{1,5}$'
    and jsonb_typeof(m #> '{t,3}') = 'number' and (m #>> '{t,3}') ~ '^[0-9]{1,5}$',
    false
  )
$$;

comment on function public.trophy_meta_valid(jsonb) is
  'Whether a value is a user_games.trophy_meta: {s, v, e[4], t[4]} with whole numbers. False for NULL.';

alter table public.user_games
  add column if not exists trophy_meta jsonb;

alter table public.user_games
  drop constraint if exists user_games_trophy_meta_valid;
alter table public.user_games
  add constraint user_games_trophy_meta_valid check (
    trophy_meta is null or public.trophy_meta_valid(trophy_meta)
  );

comment on column public.user_games.trophy_meta is
  'The PlayStation trophy set of this game and the trophies earned out of all, by grade: {s, v, e[4], t[4]} (see lib/models/trophy.dart), written for every game of a sync. Other members get counts only, through public_trophy_summary, and only when profiles.show_trophies.';

-- 2. The summary reads the counts -------------------------------------------------
create or replace function public.public_trophy_summary(target_user uuid)
returns table (
  game_id uuid, title text, cover_url text,
  earned integer, total integer,
  bronze integer, silver integer, gold integer, platinum integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select x.game_id, g.title, g.cover_url,
         (x.bronze + x.silver + x.gold + x.platinum)::integer as earned,
         x.total::integer as total,
         x.bronze::integer, x.silver::integer, x.gold::integer, x.platinum::integer
  from (
    select ug.game_id,
           coalesce(m.b, l.b) as bronze,
           coalesce(m.s, l.s) as silver,
           coalesce(m.g, l.g) as gold,
           coalesce(m.p, l.p) as platinum,
           coalesce(m.total, l.total) as total
    from public.user_games ug
    cross join lateral (
      select case when v.ok then (ug.trophy_meta #>> '{e,0}')::integer end as b,
             case when v.ok then (ug.trophy_meta #>> '{e,1}')::integer end as s,
             case when v.ok then (ug.trophy_meta #>> '{e,2}')::integer end as g,
             case when v.ok then (ug.trophy_meta #>> '{e,3}')::integer end as p,
             case when v.ok then (ug.trophy_meta #>> '{t,0}')::integer + (ug.trophy_meta #>> '{t,1}')::integer
                               + (ug.trophy_meta #>> '{t,2}')::integer + (ug.trophy_meta #>> '{t,3}')::integer end as total
      from (select public.trophy_meta_valid(ug.trophy_meta) as ok) v
    ) m
    cross join lateral (
      select (count(*) filter (where t ->> 'e' = '1' and t ->> 'g' = 'b'))::integer as b,
             (count(*) filter (where t ->> 'e' = '1' and t ->> 'g' = 's'))::integer as s,
             (count(*) filter (where t ->> 'e' = '1' and t ->> 'g' = 'g'))::integer as g,
             (count(*) filter (where t ->> 'e' = '1' and t ->> 'g' = 'p'))::integer as p,
             count(*)::integer as total
      from jsonb_array_elements(
        case when jsonb_typeof(ug.trophies) = 'array' then ug.trophies else '[]'::jsonb end
      ) as t
    ) l
    where ug.user_id = target_user
      and (select auth.uid()) is not null
      and (not ug.is_hidden or target_user = (select auth.uid()))
      and (
        target_user = (select auth.uid())
        or (
          target_user not in (select h from private.hidden_members() h)
          and exists (
            select 1 from public.profiles p
            where p.id = target_user and p.show_trophies
          )
        )
      )
  ) x
  join public.games g on g.id = x.game_id
  where x.total > 0
    and (x.bronze + x.silver + x.gold + x.platinum) > 0
  order by (x.bronze + x.silver + x.gold + x.platinum)::numeric / x.total desc,
           (x.bronze + x.silver + x.gold + x.platinum) desc,
           g.title,
           x.game_id
  limit 500
$$;

comment on function public.public_trophy_summary(uuid) is
  'Which of a member''s games have trophies earned, and how many of each grade, from the counts the sync stores (trophy_meta), else from the stored list. Counts only, never the trophies themselves. Nothing for another member who does not share their trophies.';

-- Functions are executable by PUBLIC unless revoked (unchanged by create or replace
-- with the same signature, restated so the file stands alone).
revoke all on function public.public_trophy_summary(uuid) from public, anon, authenticated;
grant execute on function public.public_trophy_summary(uuid) to authenticated;

notify pgrst, 'reload schema';

-- Fail loudly if the result is not what this file promises.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'user_games'
      and column_name = 'trophy_meta' and data_type = 'jsonb'
  ) then
    raise exception 'user_games.trophy_meta is missing';
  end if;

  -- Not part of any public view.
  if exists (
    select 1 from information_schema.columns
    where table_schema in ('public', 'private')
      and table_name in (
        'public_profiles', 'public_followers', 'public_following',
        'public_user_games', 'public_recent_activity'
      )
      and column_name in ('trophy_meta', 'trophies', 'trophies_earned', 'trophies_total')
  ) then
    raise exception 'a public view exposes trophy data';
  end if;

  if has_function_privilege('anon', 'public.public_trophy_summary(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.public_trophy_summary(uuid)', 'execute') then
    raise exception 'public_trophy_summary has the wrong grants';
  end if;
end;
$$;
