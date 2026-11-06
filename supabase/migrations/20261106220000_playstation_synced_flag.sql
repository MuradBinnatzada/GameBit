-- "This member has synced PlayStation": the small icon on a profile.
--
-- A profile shows a PlayStation icon beside the Steam one when the member has
-- trophies from a PlayStation sync on their account. It is not a verified account:
-- the sign-in happens on the member's phone, so the server cannot check it, and a
-- member could write the data the flag is read from. It says "synced", and no link
-- goes with it.
--
--   public_profiles.psn_synced   true when the member has a game with PlayStation
--                                trophy data (user_games.trophy_meta), and either
--                                shares their trophies (profiles.show_trophies,
--                                Settings > Privacy) or is the one asking. Hidden
--                                games do not count for anyone else.
--
-- So a member who turns off Show Trophies also drops the icon for everyone else,
-- and the flag is no way to learn what the setting hides.
--
-- Same views as 20261106120000_playstation_trophy_lists.sql (a definer view in
-- `private`, a thin invoker view over it that leaves out blocked and suspended
-- members), with psn_synced added at the end.
--
-- Deploy order: apply this migration, then ship the app (the profile page selects
-- psn_synced from public_profiles and fails to load until it exists).

create or replace view private.public_profiles
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
         p.show_trophies,
         (
           (p.show_trophies or p.id = (select auth.uid()))
           and exists (
             select 1 from public.user_games ug
             where ug.user_id = p.id
               and ug.trophy_meta is not null
               and (not ug.is_hidden or ug.user_id = (select auth.uid()))
           )
         ) as psn_synced
  from public.profiles p;

-- The wrapper expanded `*` when it was made: make it again to carry the new column.
create or replace view public.public_profiles
  with (security_invoker = true) as
  select * from private.public_profiles v
  where v.id not in (select h from private.hidden_members() h);

comment on view private.public_profiles is
  'Public fields of every profile, readable by any signed-in user through public.public_profiles: name, handle, avatar, bio, Steam ID (only ever one Steam confirmed), member since, counts, frame and milestones, whether they share their Steam achievements and PlayStation trophies, and whether they have synced PlayStation (an unverified icon). Never add email, or a name a member can type in as an account.';

revoke all on private.public_profiles from public, anon, authenticated;
grant select on private.public_profiles to authenticated;
revoke all on public.public_profiles from public, anon, authenticated;
grant select on public.public_profiles to authenticated;

notify pgrst, 'reload schema';

-- Fail loudly if the result is not what this file promises.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'public_profiles'
      and column_name = 'psn_synced'
  ) then
    raise exception 'public.public_profiles has no psn_synced column';
  end if;

  if has_table_privilege('anon', 'public.public_profiles', 'select')
     or not has_table_privilege('authenticated', 'public.public_profiles', 'select') then
    raise exception 'public.public_profiles has the wrong grants';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema in ('public', 'private')
      and table_name in ('public_profiles', 'public_user_games')
      and column_name in ('trophies', 'trophy_meta')
  ) then
    raise exception 'a public view exposes trophy data';
  end if;
end;
$$;
