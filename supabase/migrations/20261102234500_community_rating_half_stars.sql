-- The community rating, exact to the half star.
--
-- The app rates a game from half a star to ten, in halves, and keeps it in
-- user_games.rating as it always was, 0 to 5: half a star is a quarter of it, which
-- `numeric(2,1)` keeps to the tenth (0.5 stars as 0.3, 1 as 0.5, 7.5 as 3.8, 10 as
-- 5.0). Reading a rating back takes the nearest half star, so no rating moves; see
-- `_stars` in lib/services/repository/row_mappers.dart.
--
-- game_review_stats worked out its average from ratings rounded to a whole star
-- (each 0.5 of the 0 to 5 scale, which is a whole star of ten), so a 7.5 counted as
-- an 8 in the average. This reads each rating back to its quarter (the nearest
-- 0.25 of the 0 to 5 scale, the same rounding the app does) and averages those. The
-- answer keeps its shape and scale (the average out of 5, ten `half_stars`), so
-- every build of the app reads it, and for ratings in whole stars it is the number
-- it was. The ten counts are as they were: a half star is counted under the star
-- above it, 7.5 with the 8s.
--
-- Only the body of the function changes: its columns, grants and the views over
-- user_games are untouched.

-- As in 20261031230000_hidden_games.sql (the community rating counts the same
-- games the reviews list shows).
create or replace function public.game_review_stats(target_game uuid)
returns table (ratings integer, average double precision, reviews integer, half_stars integer[])
language sql
stable
security definer
set search_path = ''
as $$
  with allowed as (
    select (select auth.uid()) is not null and (select public.mfa_satisfied()) as ok
  ),
  -- Each rating in quarters of the 0 to 5 scale: 0.5 stars is 1, 10 stars is 20.
  rated as (
    select round(ug.rating * 4)::double precision as quarters
    from public.user_games ug, allowed
    where allowed.ok
      and ug.game_id = target_game
      and ug.rating > 0
      and (not ug.is_hidden or ug.user_id = (select auth.uid()))
  ),
  buckets as (
    select ceil(r.quarters / 2)::integer as bucket, count(*)::integer as n
    from rated r
    group by 1
  )
  select (select count(*) from rated)::integer as ratings,
         coalesce((select avg(r.quarters) from rated r) / 4, 0)::double precision
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
$$;

comment on function public.game_review_stats(uuid) is
  'How many members rated target_game and reviewed it, the average rating out of 5, and how many gave each of the ten stars (half_stars, a half star counted under the star above it). Never return a user id or a single member''s row.';

-- Functions are executable by PUBLIC unless revoked.
revoke all on function public.game_review_stats(uuid) from public, anon, authenticated;
grant execute on function public.game_review_stats(uuid) to authenticated;

notify pgrst, 'reload schema';

-- Fail loudly if the result is not what this file promises.
do $$
declare
  stats constant regprocedure := 'public.game_review_stats(uuid)'::regprocedure;
begin
  if not (select prosecdef from pg_proc where oid = stats) then
    raise exception 'game_review_stats must be SECURITY DEFINER';
  end if;

  if has_function_privilege('anon', stats, 'execute')
     or not has_function_privilege('authenticated', stats, 'execute') then
    raise exception 'game_review_stats has the wrong grants';
  end if;

  if (select pg_get_function_result(stats)) not like '%half_stars integer[]%' then
    raise exception 'game_review_stats does not answer half_stars';
  end if;
end $$;
