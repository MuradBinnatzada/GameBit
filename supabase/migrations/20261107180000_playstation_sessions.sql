-- Play sessions from PlayStation playtime.
--
-- The PlayStation sync runs on the member's phone (Sony's sign-in never reaches our
-- servers), so unlike Steam's it cannot be logged by the service role: the app logs
-- the session as the member, and tags it 'playstation' so it is told apart from one
-- the member wrote and, like a Steam one, does not count towards the "log N
-- sessions" milestones. Its data comes from the phone, which the server cannot
-- verify: 'steam' stays what only sync-steam can write.
--
-- Deploy order: apply this migration, then ship the app build that logs them (a
-- build that sent 'playstation' before this would have it stripped to NULL by the
-- trigger below, which is harmless but loses the tag).

alter table public.log_entries
  drop constraint if exists log_entries_source_known,
  add constraint log_entries_source_known
    check (source is null or source in ('steam', 'playstation'));

comment on column public.log_entries.source is
  'NULL: logged by the member. steam: logged by sync-steam from a rise in Steam playtime. playstation: logged by the app from a rise in PlayStation playtime (read on the phone, so not verified by the server).';

-- A member logs their own sessions, and the app logs PlayStation ones for them:
-- only the service role (sync-steam) sets 'steam'. A member's insert keeps
-- 'playstation' and drops any other source; a member's edit keeps the one the
-- session has.
create or replace function public.log_entries_keep_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'UPDATE' then
      new.source := old.source;
    elsif new.source is distinct from 'playstation' then
      new.source := null;
    end if;
  end if;
  return new;
end;
$$;

-- Milestones count the sessions the member logged, as they did for Steam's (see
-- 20261020140337_milestones_without_steam.sql): a PlayStation session is the sync's
-- bookkeeping too. This is award_milestones_for as 20261101050000_verified_services_only.sql
-- left it, with that one filter changed (`source is null`, was `is distinct from 'steam'`).
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
  -- Sessions the member logged; the Steam and PlayStation syncs' are their own bookkeeping.
  sessions as (
    select le.logged_at,
           le.platform,
           (le.logged_at at time zone 'UTC') + (select local_offset from shift) as local_at
    from public.log_entries le
    where le.user_id = target
      and le.source is null
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

notify pgrst, 'reload schema';
