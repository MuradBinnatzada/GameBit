-- PlayStation trophy lists, and who may see them.
--
-- 20261105120000 stored how many trophies a member earned in a game. The import
-- from PlayStation now also reads the list itself (what each trophy is called and
-- asks for, its grade and icon, how rare it is, and whether and when the member
-- earned it) and the profile shows it like the Steam achievements.
--
--   user_games.trophies   jsonb array, one object per trophy, written by the member's
--                         app (see lib/models/trophy.dart): {"i": id, "g": "b|s|g|p",
--                         "n": name, "d": what it asks for, "u": icon link, "e": 1 when
--                         earned, "a": when, "r": rarity 0-3, "p": percent of players,
--                         "h": 1 for a secret trophy}. NULL: no list stored.
--   profiles.show_trophies   Settings > Privacy > "Show Trophies" (default true, like
--                         show_steam_achievements). Written by the member on their own row.
--
-- Turned off, other members get nothing:
--
--   public_trophy_summary   returns no rows
--   public_game_trophies    returns NULL
--
-- The member themselves always gets everything. The flag is also on `public_profiles`,
-- so the app leaves the Trophies card off the page instead of showing it empty.
--
-- No table or view of `public_*` carries `trophies`: other members reach it only
-- through the two functions below, which check the flag, hidden games (as the Steam
-- achievement functions do, 20261031230000) and blocked or suspended members.
--
-- A member could write any list; that only changes what their own profile shows. The
-- check keeps it a list of sensible size.
--
-- Deploy order: apply this migration, then ship the app (the profile page selects
-- show_trophies from public_profiles and fails to load until it exists).

-- 1. The columns ---------------------------------------------------------------
alter table public.user_games
  add column if not exists trophies jsonb;

alter table public.user_games
  drop constraint if exists user_games_trophies_is_list;
alter table public.user_games
  add constraint user_games_trophies_is_list check (
    trophies is null
    or (jsonb_typeof(trophies) = 'array'
        and jsonb_array_length(trophies) <= 2000
        and octet_length(trophies::text) <= 1000000)
  );

comment on column public.user_games.trophies is
  'The PlayStation trophies of this game as the app''s import last read them: a jsonb array of {i, g, n, d, u, e, a, r, p, h} (see lib/models/trophy.dart). NULL: none stored. Other members read it only through public_game_trophies, and only when profiles.show_trophies.';

alter table public.profiles
  add column if not exists show_trophies boolean not null default true;

comment on column public.profiles.show_trophies is
  'Whether other members may see this member''s PlayStation trophies (Settings > Privacy). The member always sees their own.';

-- 2. The public profile view ------------------------------------------------------
-- Same shape as 20261101050000_verified_services_only.sql (a definer view in
-- `private` that the API cannot reach, and a thin invoker view over it that leaves
-- out blocked and suspended members), with show_trophies at the end.
drop view if exists public.public_profiles;
drop view if exists private.public_profiles;

create view private.public_profiles
  with (security_invoker = false) as
  select p.id,
         p.handle,
         p.display_name,
         p.avatar_url,
         nullif(btrim(p.steam_id), '') is not null as steam_connected,
         p.bio,
         p.steam_id,
         p.created_at as joined_at,
         (
           select count(*)::integer
           from public.user_games ug
           where ug.user_id = p.id
             and (not ug.is_hidden or ug.user_id = (select auth.uid()))
         ) as games_count,
         (
           select count(*)::integer
           from public.social_follows f
           where f.followee_id = p.id
         ) as followers_count,
         exists (
           select 1 from public.social_follows f
           where f.follower_id = (select auth.uid()) and f.followee_id = p.id
         ) as viewer_follows,
         p.show_steam_achievements,
         p.avatar_frame,
         p.title_milestone,
         p.showcased_milestones,
         p.show_trophies
  from public.profiles p;

create view public.public_profiles
  with (security_invoker = true) as
  select * from private.public_profiles v
  where v.id not in (select h from private.hidden_members() h);

comment on view private.public_profiles is
  'Public fields of every profile, readable by any signed-in user through public.public_profiles: name, handle, avatar, bio, Steam ID (only ever one Steam confirmed), member since, counts, frame and milestones, and whether they share their Steam achievements and PlayStation trophies. Never add email, or a name a member can type in as an account.';
comment on view public.public_profiles is
  'Read through private.public_profiles, which is the SECURITY DEFINER view; blocked and suspended members are left out.';

revoke all on private.public_profiles from public, anon, authenticated;
grant select on private.public_profiles to authenticated;
revoke all on public.public_profiles from public, anon, authenticated;
grant select on public.public_profiles to authenticated;

-- 3. The trophies, only for the member or when they share them -----------------------
-- SECURITY DEFINER, so `user_games` and `profiles` are read whatever their row
-- policies say; nothing but counts leaves the first, and the list leaves the second
-- only for the member or a viewer they share it with.

-- One row per game with an earned trophy, with how many of each grade: the profile's
-- totals are added up from these. Best first: the most complete, then the most earned.
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
  select ug.game_id, g.title, g.cover_url,
         s.earned, s.total, s.bronze, s.silver, s.gold, s.platinum
  from public.user_games ug
  join public.games g on g.id = ug.game_id
  cross join lateral (
    select (count(*) filter (where t ->> 'e' = '1'))::integer as earned,
           count(*)::integer as total,
           (count(*) filter (where t ->> 'e' = '1' and t ->> 'g' = 'b'))::integer as bronze,
           (count(*) filter (where t ->> 'e' = '1' and t ->> 'g' = 's'))::integer as silver,
           (count(*) filter (where t ->> 'e' = '1' and t ->> 'g' = 'g'))::integer as gold,
           (count(*) filter (where t ->> 'e' = '1' and t ->> 'g' = 'p'))::integer as platinum
    from jsonb_array_elements(ug.trophies) as t
  ) s
  where ug.user_id = target_user
    and (select auth.uid()) is not null
    and jsonb_typeof(ug.trophies) = 'array'
    and s.earned > 0
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
  order by s.earned::numeric / s.total desc, s.earned desc, g.title, ug.game_id
  limit 500
$$;

comment on function public.public_trophy_summary(uuid) is
  'Which of a member''s games have trophies, and how many of each grade they earned in each. Counts only, never the trophies themselves. Nothing for another member who does not share their trophies.';

create or replace function public.public_game_trophies(target_user uuid, target_game uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select ug.trophies
  from public.user_games ug
  where ug.user_id = target_user
    and ug.game_id = target_game
    and (select auth.uid()) is not null
    and jsonb_typeof(ug.trophies) = 'array'
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
$$;

comment on function public.public_game_trophies(uuid, uuid) is
  'One game''s stored trophy list of a member: their own always, another member''s only when they share their trophies.';

-- Functions are executable by PUBLIC unless revoked.
revoke all on function public.public_trophy_summary(uuid) from public, anon, authenticated;
revoke all on function public.public_game_trophies(uuid, uuid) from public, anon, authenticated;
grant execute on function public.public_trophy_summary(uuid) to authenticated;
grant execute on function public.public_game_trophies(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';

-- Fail loudly if the result is not what this file promises.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles'
      and column_name = 'show_trophies'
      and data_type = 'boolean' and is_nullable = 'NO'
      and column_default = 'true'
  ) then
    raise exception 'profiles.show_trophies is not a non-null boolean defaulting to true';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'public_profiles'
      and column_name = 'show_trophies'
  ) then
    raise exception 'public.public_profiles has no show_trophies column';
  end if;

  -- The list is not part of any public view.
  if exists (
    select 1 from information_schema.columns
    where table_schema in ('public', 'private')
      and table_name in (
        'public_profiles', 'public_followers', 'public_following',
        'public_user_games', 'public_recent_activity'
      )
      and column_name in ('trophies', 'trophies_earned', 'trophies_total')
  ) then
    raise exception 'a public view exposes trophy data';
  end if;

  if has_table_privilege('anon', 'public.public_profiles', 'select')
     or not has_table_privilege('authenticated', 'public.public_profiles', 'select') then
    raise exception 'public.public_profiles has the wrong grants';
  end if;

  if has_function_privilege('anon', 'public.public_trophy_summary(uuid)', 'execute')
     or has_function_privilege('anon', 'public.public_game_trophies(uuid, uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.public_trophy_summary(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.public_game_trophies(uuid, uuid)', 'execute') then
    raise exception 'the public trophy functions have the wrong grants';
  end if;
end;
$$;
