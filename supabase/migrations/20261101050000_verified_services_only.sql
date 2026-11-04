-- Only accounts the app can prove: Steam.
--
-- A member could type a PSN ID, an Xbox gamertag, a Discord, Instagram or Twitch
-- name, or tick Nintendo, and the profile showed it. None of it was checked, so
-- anyone could claim someone else's account, and none of these services lets a
-- third-party app verify an account in a way its terms allow. Steam is verified
-- (the steam-link Edge Function saves the Steam ID that Steam's own sign-in
-- confirmed), so it is the only connected service left.
--
-- This migration removes what the typed-in services stored:
--
--   profiles.psn_id, xbox_id, discord_id, instagram_id, twitch_id   the typed names
--   profiles.connected_services                                      which were ticked
--   (and their check constraints, profiles_account_names_length and
--   profiles_connected_services_known, which go with the columns)
--
-- and every place that read or wrote them:
--
--   private.public_profiles / public.public_profiles   lose the six columns
--   private.profiles_check_public_text()                no longer checks the names
--   moderation.clear_profile()                          no longer clears them
--   public.award_milestones_for()                       "Plugged In" (steam_connected)
--                                                       is earned by a Steam ID only
--
-- Members who already earned Plugged In through PSN, Xbox or Nintendo keep it:
-- milestones are never taken back. The typed names are deleted for good, which
-- is the point; there is nothing to migrate.
--
-- Deploy order: ship the app build that no longer selects these columns first.
-- Until it is out, an older build fails to load a profile (it asks the view for
-- columns that are gone). Update docs/privacy.html together with this migration.

-- 1. Functions that named the columns ----------------------------------------
-- Replaced before the columns go: a SQL function is checked when it is created.

-- As in 20261028235500_moderation_and_blocking.sql, without the five names.
create or replace function private.profiles_check_public_text()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  field text;
  changed boolean;
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if private.breaks_chat_rules(new.display_name) then
      new.display_name := 'Player';
    end if;
    if private.breaks_chat_rules(new.handle::text) then
      new.handle := 'player_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
    end if;
    if private.breaks_chat_rules(new.bio) then
      new.bio := '';
    end if;
    return new;
  end if;

  if new.display_name is distinct from old.display_name then
    perform private.refuse_chat_text('display_name', new.display_name);
  end if;
  if new.handle is distinct from old.handle then
    perform private.refuse_chat_text('handle', new.handle::text);
  end if;
  if new.bio is distinct from old.bio then
    perform private.refuse_chat_text('bio', new.bio);
  end if;
  return new;
end;
$$;

-- As in 20261028235500_moderation_and_blocking.sql, without the five names.
create or replace function moderation.clear_profile(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
     set display_name = 'Player',
         handle = 'player_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8),
         bio = '',
         avatar_url = null
   where id = target;
end;
$$;

-- As in 20261020140337_milestones_without_steam.sql: game_account counts a Steam ID,
-- and no longer a ticked PSN, Xbox or Nintendo.
create or replace function public.award_milestones_for(target uuid, utc_offset_minutes integer)
returns table (milestone_id text, unlocked_at timestamptz)
language sql
set search_path = ''
as $$
  with
  shift as (
    select make_interval(
      mins => greatest(-840, least(840, coalesce(utc_offset_minutes, 0)))
    ) as local_offset
  ),
  library as (
    select ug.status, ug.rating, ug.hours_played, ug.played_on, ug.date_added,
           ug.completed_at, ug.review, ug.is_favorite,
           ug.achievements_unlocked, ug.achievements_total, ug.perfected,
           g.genres, g.release_year
    from public.user_games ug
    join public.games g on g.id = ug.game_id
    where ug.user_id = target
  ),
  -- The games actually played, for the variety milestones.
  played as (
    select * from library
    where status in ('playing', 'completed', 'dropped') or hours_played > 0
  ),
  -- Sessions the member logged; the Steam sync's are its own bookkeeping.
  sessions as (
    select le.logged_at,
           le.platform,
           (le.logged_at at time zone 'UTC') + (select local_offset from shift) as local_at
    from public.log_entries le
    where le.user_id = target
      and le.source is distinct from 'steam'
  ),

  -- a. Dated events: "N of them" was reached when the Nth happened. Completions
  --    from before completed_at was kept have no date: they go after the dated
  --    ones (which "N completed" can't have come later than), and one of them
  --    that is the Nth is dated now.
  events (metric, reached_at) as (
    select 'library_games', date_added from library
    union all select 'wishlist', date_added from library where status = 'wishlist'
    union all select 'completed', completed_at from library where status = 'completed'
    union all select 'sessions', logged_at from sessions
    union all select 'night_sessions', logged_at from sessions
      where extract(hour from local_at) < 4
    union all select 'completion_times', ct.created_at
      from public.completion_times ct where ct.user_id = target
    union all select 'lists', gl.created_at
      from public.game_lists gl where gl.user_id = target
    union all select 'public_lists', gl.updated_at
      from public.game_lists gl where gl.user_id = target and gl.is_public
    union all select 'following', f.created_at
      from public.social_follows f where f.follower_id = target
    union all select 'followers', f.created_at
      from public.social_follows f where f.followee_id = target
  ),
  event_unlocks as (
    select m.id,
           (array_agg(e.reached_at order by e.reached_at nulls last))[m.threshold::integer]
             as reached_at
    from public.milestones m
    join events e on e.metric = m.metric
    group by m.id, m.threshold
    having count(*) >= m.threshold
  ),

  -- b. Amounts with no date of their own: reached now.
  amounts (metric, amount) as (
    select 'hours', coalesce(sum(hours_played), 0)::numeric from library
    union all select 'game_hours', coalesce(max(hours_played), 0)::numeric from library
    union all select 'rated', count(*) filter (where rating > 0) from library
    union all select 'reviews', count(*) filter (where btrim(review) <> '') from library
    union all select 'favorites', count(*) filter (where is_favorite) from library
    union all select 'dropped', count(*) filter (where status = 'dropped') from library
    -- Marked by the member (not on a wishlisted game, which they don't have),
    -- or every Steam achievement unlocked.
    union all select 'perfect_games', count(*) filter (
        where (perfected and status <> 'wishlist')
           or (achievements_total > 0 and achievements_unlocked >= achievements_total)
      ) from library
    union all select 'genres', count(distinct genre)
      from played cross join lateral unnest(played.genres) as genre
    union all select 'retro_games', count(*) filter (where release_year < 1995) from played
    union all select 'decades', count(distinct release_year / 10) from played
    union all select 'platforms', count(distinct platform) from (
        select played_on as platform from library where played_on is not null
        union
        select platform from sessions where platform is not null
      ) as used
    union all select 'list_size', coalesce(max(items), 0) from (
        select count(*) as items
        from public.game_list_items i
        join public.game_lists gl on gl.id = i.list_id
        where gl.user_id = target
        group by i.list_id
      ) as sizes
    union all select 'profile_complete', count(*) from public.profiles p
      where p.id = target
        and nullif(btrim(p.avatar_url), '') is not null
        and btrim(p.bio) <> ''
    union all select 'game_account', count(*) from public.profiles p
      where p.id = target
        and nullif(btrim(p.steam_id), '') is not null
    union all select 'two_factor', count(*) from auth.mfa_factors f
      where f.user_id = target and f.status = 'verified'
  ),
  amount_unlocks as (
    select m.id, now() as reached_at
    from public.milestones m
    join amounts a on a.metric = m.metric
    where a.amount >= m.threshold
  ),

  -- c. Days in a row with a session, in the member's own days: reached on the
  --    Nth day of the first run that long, at that day's first session.
  session_days as (
    select local_at::date as local_day, min(logged_at) as first_at
    from sessions
    group by local_at::date
  ),
  runs as (
    select local_day,
           local_day - (row_number() over (order by local_day))::integer as run_id
    from session_days
  ),
  run_lengths as (
    select run_id, min(local_day) as first_day, count(*) as run_days
    from runs
    group by run_id
  ),
  streak_unlocks as (
    select m.id, sd.first_at as reached_at
    from public.milestones m
    cross join lateral (
      select min(r.first_day) + (m.threshold::integer - 1) as local_day
      from run_lengths r
      where r.run_days >= m.threshold
    ) as reached
    join session_days sd on sd.local_day = reached.local_day
    where m.metric = 'streak_days'
  ),

  -- d. Membership: on the anniversary itself. Founding members joined before
  --    2027.
  member_unlocks as (
    select m.id, p.created_at + make_interval(months => m.threshold::integer) as reached_at
    from public.milestones m
    join public.profiles p on p.id = target
    where m.metric = 'member_months'
      and p.created_at + make_interval(months => m.threshold::integer) <= now()
    union all
    select m.id, p.created_at
    from public.milestones m
    join public.profiles p on p.id = target
    where m.metric = 'founding_member'
      and p.created_at < timestamptz '2027-01-01 00:00:00+00'
  ),

  earned as (
    select id, reached_at from event_unlocks
    union all select id, reached_at from amount_unlocks
    union all select id, reached_at from streak_unlocks
    union all select id, reached_at from member_unlocks
  )
  insert into public.user_milestones as um (user_id, milestone_id, unlocked_at)
  select target, e.id, least(coalesce(e.reached_at, now()), now())
  from earned e
  where target is not null
  on conflict (user_id, milestone_id) do nothing
  returning um.milestone_id, um.unlocked_at;
$$;

-- 2. The public profile view ---------------------------------------------------
-- A view cannot lose columns with create or replace: drop the wrapper and the
-- definer view under it, and make them again without the six. The shape is that of
-- 20261022200000_invoker_views_over_private_schema.sql (a definer view in `private`
-- that the API cannot reach, and a thin invoker view in `public` over it) with the
-- filter of 20261028235500_moderation_and_blocking.sql (blocked and suspended
-- members are left out).

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
         p.showcased_milestones
  from public.profiles p;

create view public.public_profiles
  with (security_invoker = true) as
  select * from private.public_profiles v
  where v.id not in (select h from private.hidden_members() h);

comment on view private.public_profiles is
  'Public fields of every profile, readable by any signed-in user through public.public_profiles: name, handle, avatar, bio, Steam ID (only ever one Steam confirmed), member since, counts, frame and milestones. Never add email, or a name a member can type in as an account.';
comment on view public.public_profiles is
  'Read through private.public_profiles, which is the SECURITY DEFINER view; blocked and suspended members are left out.';

revoke all on private.public_profiles from public, anon, authenticated;
grant select on private.public_profiles to authenticated;
revoke all on public.public_profiles from public, anon, authenticated;
grant select on public.public_profiles to authenticated;

-- 3. The columns ------------------------------------------------------------------

alter table public.profiles drop constraint if exists profiles_account_names_length;
alter table public.profiles drop constraint if exists profiles_connected_services_known;

alter table public.profiles
  drop column if exists psn_id,
  drop column if exists xbox_id,
  drop column if exists discord_id,
  drop column if exists instagram_id,
  drop column if exists twitch_id,
  drop column if exists connected_services;

notify pgrst, 'reload schema';

-- Fail loudly if the result is not what this file promises.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name in ('profiles', 'public_profiles')
      and column_name in (
        'psn_id', 'xbox_id', 'discord_id', 'instagram_id', 'twitch_id',
        'connected_services'
      )
  ) then
    raise exception 'A typed-in account column is still there';
  end if;

  if (
    select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'public_profiles'
      and column_name in (
        'id', 'handle', 'display_name', 'avatar_url', 'steam_connected', 'bio',
        'steam_id', 'joined_at', 'games_count', 'followers_count', 'viewer_follows',
        'show_steam_achievements', 'avatar_frame', 'title_milestone',
        'showcased_milestones'
      )
  ) <> 15 then
    raise exception 'public.public_profiles lost a column it keeps';
  end if;

  -- Still none of the columns that stay private.
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name in (
        'public_profiles', 'public_followers', 'public_following',
        'public_user_games', 'public_recent_activity'
      )
      and column_name in ('email', 'purchase_price', 'achievements', 'note')
  ) then
    raise exception 'A public view exposes a column that must stay private';
  end if;

  -- Signed-in members read it, anonymous callers do not, and the wrapper is an
  -- invoker view (the advisor lists a definer view in an exposed schema).
  if has_table_privilege('anon', 'public.public_profiles', 'select')
     or not has_table_privilege('authenticated', 'public.public_profiles', 'select')
     or has_table_privilege('anon', 'private.public_profiles', 'select') then
    raise exception 'public.public_profiles has the wrong grants';
  end if;

  if not coalesce(
    (select 'security_invoker=true' = any (c.reloptions)
     from pg_class c where c.oid = 'public.public_profiles'::regclass),
    false
  ) then
    raise exception 'public.public_profiles is not a security_invoker view';
  end if;

  if pg_get_functiondef('public.award_milestones_for(uuid, integer)'::regprocedure) ~ 'connected_services'
     or pg_get_functiondef('private.profiles_check_public_text()'::regprocedure) ~ '(psn|xbox|discord|instagram|twitch)_id'
     or pg_get_functiondef('moderation.clear_profile(uuid)'::regprocedure) ~ '(psn|xbox|discord|instagram|twitch)_id' then
    raise exception 'A function still names a removed account column';
  end if;
end;
$$;
