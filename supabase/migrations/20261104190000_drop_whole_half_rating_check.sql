-- A rating may be any tenth from 0 to 5, so the app can rate in halves of ten.
--
-- The app rates a game from half a star to ten and keeps it in user_games.rating,
-- still 0 to 5: half a star is a quarter of that scale, which `numeric(2,1)` keeps
-- to the tenth (0.5 stars as 0.3, 5.5 as 2.8, 7.5 as 3.8, 10 as 5.0); see
-- 20261102234500_community_rating_half_stars.sql and `_stars` in
-- lib/services/repository/row_mappers.dart.
--
-- The live table has a second rating check that no migration here made (it came
-- with the table, from the dashboard):
--
--   user_games_rating_check
--     CHECK (rating >= 0 AND rating <= 5 AND rating * 2 = floor(rating * 2))
--
-- Its last term only lets a rating be a multiple of 0.5, which is every whole star
-- of ten and none of the half stars: 5.5 stars (2.8) and 7.5 (3.8) were refused, and
-- the app said "Could not save that game update". Its range is the one
-- user_games_rating_range (20261019013500_value_limits_and_atomic_deletes.sql)
-- still holds, so dropping it loses no limit. Builds that rate in whole stars send
-- multiples of 0.5, which the range check lets through as before.

alter table public.user_games
  drop constraint if exists user_games_rating_check;
