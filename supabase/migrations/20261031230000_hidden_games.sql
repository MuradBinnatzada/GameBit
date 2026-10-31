-- Hidden games: a member can hide a game of their library from every other member.
--
-- `user_games.is_hidden` is the member's own choice, made in the app (a Hide button on
-- the game's screen; a Hidden tab in their Library lists them). A hidden game stays in
-- the member's library, stats and lists as it was: only what OTHER members can read of
-- them changes. The rule is "hidden unless it is yours": a member always sees their own
-- hidden games, wherever the app asks the server.
--
-- Everything that shows one member's games to another reads them through the views and
-- functions below, so each one is redefined here with that one condition added (the
-- definitions are those of the latest migration that wrote them):
--
--   private.public_user_games      another member's Library, their favorites
--   private.public_recent_activity another member's recent sessions
--   private.public_profiles        the game count on a profile (so it matches the library)
--   public.game_reviews, game_review_stats       reviews and the community rating
--   public.following_recent_activity             "From people you follow" on Home
--   public.following_game_activity               "Friends" on a game's screen
--   public.public_profile_stats                  the game count of a profile
--   public.public_achievement_totals / _summary / public_game_achievements
--                                               Steam achievements, by game and in total
--   public.game_list_items (policy)              a hidden game in someone's public list
--   public.merge_user_game_into                  merging two rows keeps a game hidden
--
-- Not hidden, on purpose: the completion times (only medians of many members are read,
-- never one member's), and the milestones a member earned (they say how many, not which).

alter table public.user_games
  add column if not exists is_hidden boolean not null default false;

-- Whether [owner] hid [game]. For the policy on list items below, which runs as the
-- caller, who can't read another member's user_games.
create or replace function private.is_game_hidden(owner uuid, game uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.user_games ug
    where ug.user_id = owner and ug.game_id = game and ug.is_hidden
  )
$$;

revoke all on function private.is_game_hidden(uuid, uuid) from public, anon;
grant execute on function private.is_game_hidden(uuid, uuid) to authenticated;

-- The views the public_* wrappers (20261022200000, 20261028235500) read. Their columns
-- are unchanged.
create or replace view private.public_user_games
  with (security_invoker = false) as
  select ug.user_id,
         ug.game_id,
         ug.status,
         ug.rating,
         ug.hours_played,
         ug.played_on,
         ug.date_added,
         ug.is_favorite,
         g.igdb_id,
         g.steam_app_id,
         g.title,
         g.publisher,
         g.developer,
         g.release_year,
         g.platforms,
         g.genres,
         g.summary,
         g.cover_url,
         ug.custom_backdrop_url,
         ug.review,
         ug.completed_at,
         ug.perfected
  from public.user_games ug
  join public.games g on g.id = ug.game_id
  where not ug.is_hidden or ug.user_id = (select auth.uid());

create or replace view private.public_recent_activity
  with (security_invoker = false) as
  select l.id,
         l.user_id,
         l.game_id,
         l.hours,
         l.platform,
         l.logged_at,
         g.igdb_id,
         g.steam_app_id,
         g.title,
         g.publisher,
         g.developer,
         g.release_year,
         g.platforms,
         g.genres,
         g.summary,
         g.cover_url
  from public.log_entries l
  join public.games g on g.id = l.game_id
  where l.user_id = (select auth.uid())
     or not exists (
       select 1 from public.user_games h
       where h.user_id = l.user_id and h.game_id = l.game_id and h.is_hidden
     );

create or replace view private.public_profiles
  with (security_invoker = false) as
  select p.id,
         p.handle,
         p.display_name,
         p.avatar_url,
         nullif(btrim(p.steam_id), '') is not null as steam_connected,
         p.connected_services,
         p.bio,
         p.steam_id,
         p.psn_id,
         p.xbox_id,
         p.discord_id,
         p.created_at as joined_at,
         p.instagram_id,
         p.twitch_id,
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

-- Two rows of one member merge into one: the merged game stays hidden if either was.
create or replace function public.merge_user_game_into(target_user uuid, from_id uuid, into_id uuid)
returns boolean
language plpgsql
set search_path = public
as $$
begin
  if target_user is null or from_id is null or into_id is null or from_id = into_id then
    return false;
  end if;
  if not exists (select 1 from user_games where user_id = target_user and game_id = from_id) then
    return false;
  end if;

  if exists (select 1 from user_games where user_id = target_user and game_id = into_id) then
    update user_games t
       set hours_played   = greatest(coalesce(t.hours_played, 0), coalesce(f.hours_played, 0)),
           status         = case when coalesce(f.hours_played, 0) > coalesce(t.hours_played, 0)
                                 then f.status else t.status end,
           played_on      = case when coalesce(f.hours_played, 0) > coalesce(t.hours_played, 0)
                                 then coalesce(f.played_on, t.played_on)
                                 else coalesce(t.played_on, f.played_on) end,
           rating         = coalesce(nullif(t.rating, 0), f.rating, t.rating),
           purchase_price = coalesce(nullif(t.purchase_price, 0), f.purchase_price, t.purchase_price),
           is_favorite    = coalesce(t.is_favorite, false) or coalesce(f.is_favorite, false),
           is_hidden      = t.is_hidden or f.is_hidden,
           date_added     = least(t.date_added, f.date_added),
           achievements   = coalesce(t.achievements, f.achievements),
           achievements_unlocked  = coalesce(t.achievements_unlocked, f.achievements_unlocked),
           achievements_total     = coalesce(t.achievements_total, f.achievements_total),
           achievements_playtime  = coalesce(t.achievements_playtime, f.achievements_playtime),
           achievements_synced_at = coalesce(t.achievements_synced_at, f.achievements_synced_at)
      from user_games f
     where t.user_id = target_user and t.game_id = into_id
       and f.user_id = target_user and f.game_id = from_id;
    delete from user_games where user_id = target_user and game_id = from_id;
  else
    update user_games
       set game_id = into_id,
           custom_backdrop_url = null
     where user_id = target_user and game_id = from_id;
  end if;

  update log_entries set game_id = into_id where user_id = target_user and game_id = from_id;
  return true;
end;
$$;

-- Reviews other members wrote are listed without the hidden ones (a member still sees their own).
create or replace function public.game_reviews(target_game uuid, only_following boolean DEFAULT false, sort_by text DEFAULT 'friends'::text, page_size integer DEFAULT 20, page_offset integer DEFAULT 0)
returns TABLE(id uuid, handle text, display_name text, avatar_url text, avatar_frame text, showcased_milestones text[], status text, rating double precision, hours_played double precision, review text, reviewed_at timestamp with time zone, is_following boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.handle, r.display_name, r.avatar_url, r.avatar_frame,
         r.showcased_milestones, r.status, r.rating, r.hours_played, r.review,
         r.reviewed_at, r.is_following
  from (
    select p.id,
           p.handle::text as handle,
           p.display_name::text as display_name,
           p.avatar_url::text as avatar_url,
           p.avatar_frame::text as avatar_frame,
           p.showcased_milestones as showcased_milestones,
           ug.status::text as status,
           coalesce(ug.rating, 0)::double precision as rating,
           coalesce(ug.hours_played, 0)::double precision as hours_played,
           ug.review::text as review,
           coalesce(ug.reviewed_at, ug.date_added)::timestamptz as reviewed_at,
           exists (
             select 1 from public.social_follows f
             where f.follower_id = (select auth.uid()) and f.followee_id = ug.user_id
           ) as is_following
    from public.user_games ug
    join public.profiles p on p.id = ug.user_id
    where ug.game_id = target_game
      and btrim(ug.review) <> ''
      and (not ug.is_hidden or ug.user_id = (select auth.uid()))
      and (select auth.uid()) is not null
      and (select public.mfa_satisfied())
      and not exists (
        select 1 from public.review_reports rr
        where rr.reporter_id = (select auth.uid())
          and rr.review_user_id = ug.user_id
          and rr.game_id = ug.game_id
      )
      and ug.user_id not in (select h from private.hidden_members() h)
  ) r
  where not coalesce(only_following, false) or r.is_following
  order by
    case when coalesce(sort_by, 'friends') = 'friends' then r.is_following end desc nulls last,
    case when sort_by = 'highest' then (r.rating > 0) end desc nulls last,
    case when sort_by = 'highest' then r.rating end desc nulls last,
    case when sort_by = 'lowest' then (r.rating > 0) end desc nulls last,
    case when sort_by = 'lowest' then r.rating end asc nulls last,
    r.reviewed_at desc nulls last,
    r.id
  limit least(greatest(coalesce(page_size, 20), 1), 50)
  offset greatest(coalesce(page_offset, 0), 0)
$$;

-- The community rating counts the same games the reviews list shows.
create or replace function public.game_review_stats(target_game uuid)
returns TABLE(ratings integer, average double precision, reviews integer, half_stars integer[])
language sql
stable
security definer
set search_path = ''
as $$
  with allowed as (
    select (select auth.uid()) is not null and (select public.mfa_satisfied()) as ok
  ),
  buckets as (
    select round(ug.rating * 2)::integer as bucket, count(*)::integer as n
    from public.user_games ug, allowed
    where allowed.ok
      and ug.game_id = target_game
      and ug.rating > 0
      and (not ug.is_hidden or ug.user_id = (select auth.uid()))
    group by 1
  )
  select coalesce(sum(b.n), 0)::integer as ratings,
         coalesce(sum(b.n * b.bucket)::double precision / nullif(sum(b.n) * 2, 0), 0)
           as average,
         (select count(*)::integer
          from public.user_games ug, allowed
          where allowed.ok
            and ug.game_id = target_game
            and btrim(ug.review) <> ''
            and (not ug.is_hidden or ug.user_id = (select auth.uid()))) as reviews,
         array(
           select coalesce((select b2.n from buckets b2 where b2.bucket = k), 0)
           from generate_series(1, 10) k
           order by k
         ) as half_stars
  from buckets b
$$;

-- "From people you follow": no session, rating or completion of a hidden game.
create or replace function public.following_recent_activity(max_rows integer DEFAULT 30)
returns TABLE(user_id uuid, handle text, display_name text, avatar_url text, game_id uuid, igdb_id bigint, steam_app_id bigint, title text, publisher text, developer text, release_year integer, platforms text[], genres text[], summary text, cover_url text, kind text, hours double precision, rating double precision, occurred_at timestamp with time zone)
language sql
stable
security definer
set search_path = ''
as $$
  with cap as (
    select least(greatest(coalesce(max_rows, 30), 1), 100) as n
  ),
  followed as (
    select f.followee_id as user_id
    from public.social_follows f
    where f.follower_id = (select auth.uid())
      and f.followee_id <> (select auth.uid())
      and f.followee_id not in (select h from private.hidden_members() h)
      and (select public.mfa_satisfied())
  ),
  sessions as (
    select distinct on (s.user_id, s.game_id)
           s.user_id,
           s.game_id,
           'session'::text as kind,
           s.hours::double precision as hours,
           0::double precision as rating,
           s.logged_at::timestamptz as occurred_at
    from followed fo
    cross join cap
    cross join lateral (
      select l.user_id, l.game_id, l.hours, l.logged_at
      from public.log_entries l
      where l.user_id = fo.user_id
        and l.logged_at is not null
        and l.hours > 0
        and not exists (
          select 1 from public.user_games h
          where h.user_id = l.user_id and h.game_id = l.game_id and h.is_hidden
        )
      order by l.logged_at desc
      limit cap.n
    ) s
    order by s.user_id, s.game_id, s.logged_at desc
  ),
  library as (
    select u.user_id,
           u.game_id,
           case when u.status::text = 'completed' then 'completed' else 'rated' end
             as kind,
           0::double precision as hours,
           coalesce(u.rating, 0)::double precision as rating,
           u.occurred_at
    from followed fo
    cross join cap
    cross join lateral (
      select ug.user_id, ug.game_id, ug.status, ug.rating,
             (case when ug.status::text = 'completed'
                   then coalesce(ug.completed_at, ug.date_added)
                   else ug.date_added end)::timestamptz as occurred_at
      from public.user_games ug
      where ug.user_id = fo.user_id
        and ug.date_added is not null
        and not ug.is_hidden
        and (ug.status::text = 'completed' or coalesce(ug.rating, 0) > 0)
      order by 5 desc
      limit cap.n
    ) u
  ),
  events as (
    select * from sessions
    union all
    select * from library
  )
  select e.user_id,
         p.handle::text,
         p.display_name::text,
         p.avatar_url::text,
         e.game_id,
         g.igdb_id,
         g.steam_app_id,
         g.title,
         g.publisher,
         g.developer,
         g.release_year,
         g.platforms,
         g.genres,
         g.summary,
         g.cover_url,
         e.kind,
         e.hours,
         e.rating,
         e.occurred_at
  from events e
  join public.profiles p on p.id = e.user_id
  join public.games g on g.id = e.game_id
  order by e.occurred_at desc, e.user_id, e.game_id, e.kind
  limit least(greatest(coalesce(max_rows, 30), 1), 100)
$$;

-- "Friends" on a game's screen: not a member who hid it.
create or replace function public.following_game_activity(target_game uuid, per_status integer DEFAULT 20)
returns TABLE(id uuid, handle text, display_name text, avatar_url text, status text, rating double precision, date_added timestamp with time zone, status_total integer, review text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.handle, r.display_name, r.avatar_url,
         r.status, r.rating, r.date_added, r.status_total, r.review
  from (
    select p.id,
           p.handle::text as handle,
           p.display_name::text as display_name,
           p.avatar_url::text as avatar_url,
           ug.status::text as status,
           coalesce(ug.rating, 0)::double precision as rating,
           ug.date_added::timestamptz as date_added,
           count(*) over (partition by ug.status)::integer as status_total,
           coalesce(ug.review, '')::text as review,
           row_number() over (
             partition by ug.status
             order by (coalesce(ug.rating, 0) > 0) desc,
                      ug.date_added desc nulls last,
                      p.id
           ) as position
    from public.social_follows f
    join public.user_games ug
      on ug.user_id = f.followee_id and ug.game_id = target_game
    join public.profiles p on p.id = f.followee_id
    where f.follower_id = (select auth.uid())
      and ug.status is not null
      and not ug.is_hidden
      and f.followee_id not in (select h from private.hidden_members() h)
      and (select public.mfa_satisfied())
  ) r
  where r.position <= least(greatest(coalesce(per_status, 20), 1), 50)
  order by r.status, r.position
$$;

-- The game count of a profile leaves hidden games out, so it matches the library others see.
create or replace function public.public_profile_stats(target_user uuid)
returns TABLE(followers integer, following integer, viewer_follows boolean, games integer)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select count(*)::integer from public.social_follows where followee_id = target_user),
    (select count(*)::integer from public.social_follows where follower_id = target_user),
    exists (
      select 1 from public.social_follows
      where follower_id = (select auth.uid()) and followee_id = target_user
    ),
    (
      select count(*)::integer from public.user_games ug
      where ug.user_id = target_user and (not ug.is_hidden or target_user = (select auth.uid()))
    )
  where (select auth.uid()) is not null
    and (select public.mfa_satisfied())
$$;

-- Steam achievement totals, summary and one game's list leave hidden games out.
create or replace function public.public_achievement_totals(target_user uuid)
returns TABLE(unlocked integer, total integer, games integer, completed_games integer)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(ug.achievements_unlocked), 0)::integer,
         coalesce(sum(ug.achievements_total), 0)::integer,
         count(*)::integer,
         (count(*) filter (where ug.achievements_unlocked >= ug.achievements_total))::integer
  from public.user_games ug
  where ug.user_id = target_user
    and (select auth.uid()) is not null
    and (select public.mfa_satisfied())
    and ug.achievements_unlocked > 0
    and ug.achievements_total > 0
    and (not ug.is_hidden or target_user = (select auth.uid()))
  having target_user = (select auth.uid())
      or exists (
        select 1 from public.profiles p
        where p.id = target_user and p.show_steam_achievements
      )
$$;

create or replace function public.public_achievement_summary(target_user uuid)
returns TABLE(game_id uuid, title text, cover_url text, unlocked integer, total integer)
language sql
stable
security definer
set search_path = ''
as $$
  select ug.game_id, g.title, g.cover_url, ug.achievements_unlocked, ug.achievements_total
  from public.user_games ug
  join public.games g on g.id = ug.game_id
  where ug.user_id = target_user
    and (select auth.uid()) is not null
    and (select public.mfa_satisfied())
    and ug.achievements_unlocked > 0
    and ug.achievements_total > 0
    and (not ug.is_hidden or target_user = (select auth.uid()))
    and (
      target_user = (select auth.uid())
      or exists (
        select 1 from public.profiles p
        where p.id = target_user and p.show_steam_achievements
      )
    )
  order by ug.achievements_unlocked::numeric / ug.achievements_total desc,
           ug.achievements_unlocked desc,
           g.title,
           ug.game_id
  limit 500
$$;

create or replace function public.public_game_achievements(target_user uuid, target_game uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select ug.achievements
  from public.user_games ug
  where ug.user_id = target_user
    and ug.game_id = target_game
    and (not ug.is_hidden or target_user = (select auth.uid()))
    and (select auth.uid()) is not null
    and (select public.mfa_satisfied())
    and jsonb_typeof(ug.achievements) = 'array'
    and (
      target_user = (select auth.uid())
      or exists (
        select 1 from public.profiles p
        where p.id = target_user and p.show_steam_achievements
      )
    )
$$;

-- A hidden game stays out of the public list of its owner (who still sees all of it).
drop policy if exists game_list_items_select on public.game_list_items;
create policy game_list_items_select
  on public.game_list_items
  for select
  to authenticated
  using (
    exists (
      select 1 from public.game_lists l
      where l.id = game_list_items.list_id
        and (
          l.user_id = (select auth.uid())
          or (l.is_public and not private.is_game_hidden(l.user_id, game_list_items.game_id))
        )
    )
  );
