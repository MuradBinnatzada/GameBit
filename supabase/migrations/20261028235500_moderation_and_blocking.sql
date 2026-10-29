-- Moderation, and blocking a member everywhere.
--
-- Until now only the discussions could be moderated or blocked in, and a moderator
-- worked by deleting rows in the dashboard. This adds what a place with
-- user-generated content is expected to have (App Store guideline 1.2): filtering
-- objectionable text, a way to report every kind of content, blocking, and a way to
-- remove an offending member, with every report visible in one queue so none waits
-- past 24 hours.
--
--   1. Blocking is app-wide. `discussion_blocks` becomes `user_blocks` (the rows
--      stay). A block hides the member's profile, library, activity, reviews,
--      public lists and discussion posts from the blocker and removes any follow
--      between the two; the blocked member can't follow the blocker (the follow is
--      dropped silently, so a block is not announced). One function,
--      private.hidden_members(), says whom the caller doesn't see (the members they
--      blocked and the suspended ones); every read path below uses it.
--
--   2. Suspending a member. moderation.suspend_member(...) records it in
--      moderation.suspensions, bans the account in Supabase Auth (no sign-in, no
--      refreshed token), ends its sessions and hides its content from everyone.
--      Tokens issued before it keep working for their last hour, so
--      public.mfa_satisfied() (which every policy and member-facing function
--      already asks) is false for a suspended member, and the `discussions` function
--      asks public.is_member_suspended(). Moderators work in the SQL editor: the
--      `moderation` schema is not exposed by the API and no client role can use it.
--      supabase/MODERATION.md is the runbook.
--
--   3. Text filter. The words the discussions refuse (racial slurs, child-abuse
--      phrases; _shared/discussion_filter.ts) are also refused in the other public
--      text: reviews, bios, display names, handles, connected-service names and
--      list titles and descriptions. private.breaks_chat_rules() is the same filter
--      in SQL, and triggers refuse a save that fails it with the error
--      `content_not_allowed` (SQLSTATE CP422, the field in the error's detail). A
--      brand-new profile is cleaned instead of refused, so a Google or Apple name
--      can't stop someone signing up. Text saved before this migration is not
--      touched; moderation.flagged_text() lists what the filter would refuse now.
--
--   4. Reports. public.user_reports takes reports of a profile, a photo or a list
--      (reviews and discussion posts already had theirs). All four report tables
--      get `status`, `handled_at` and `outcome`, and moderation.open_reports lists
--      every open one, oldest first, with how long it has been open and whether it
--      is past 24 hours.
--
-- Nothing private is exposed. The public_* views keep their definer views in the
-- `private` schema (20261022200000); the wrappers in `public` get a filter and
-- nothing else, so their columns are unchanged.
--
-- Deploy order: apply this migration, deploy the `discussions` function, then ship
-- the app build. An app build from before it can't block or unblock (the table is
-- renamed) and its discussion screens can't read the blocked list.

-- 0. Schemas ---------------------------------------------------------------------

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create schema if not exists moderation;
revoke all on schema moderation from public, anon, authenticated;
comment on schema moderation is
  'Moderators'' tools. Not exposed by the API (never add it to the Exposed schemas) and no client role may use it; work in the SQL editor. See supabase/MODERATION.md.';

-- 1. Blocks, for the whole app ---------------------------------------------------

do $$
begin
  if to_regclass('public.user_blocks') is null and to_regclass('public.discussion_blocks') is not null then
    alter table public.discussion_blocks rename to user_blocks;
    alter index if exists public.discussion_blocks_blocked_idx rename to user_blocks_blocked_idx;
    alter table public.user_blocks rename constraint discussion_blocks_pkey to user_blocks_pkey;
    alter table public.user_blocks rename constraint discussion_blocks_not_self to user_blocks_not_self;
    alter policy discussion_blocks_select_own on public.user_blocks rename to user_blocks_select_own;
    alter policy discussion_blocks_insert_own on public.user_blocks rename to user_blocks_insert_own;
    alter policy discussion_blocks_delete_own on public.user_blocks rename to user_blocks_delete_own;
    alter policy discussion_blocks_aal2_if_mfa on public.user_blocks rename to user_blocks_aal2_if_mfa;
  end if;
end;
$$;

comment on table public.user_blocks is
  'A member blocking another one: the blocked member''s profile, library, activity, reviews, lists and discussion posts are left out for the blocker, and any follow between them is removed. Own rows only.';

-- 2. Suspensions -----------------------------------------------------------------

create table if not exists moderation.suspensions (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users (id) on delete cascade,
  reason       text not null,
  suspended_at timestamptz not null default now(),
  -- NULL: until a moderator lifts it.
  until        timestamptz,
  lifted_at    timestamptz,
  suspended_by text not null default current_user
);

create index if not exists suspensions_user_idx on moderation.suspensions (user_id);

revoke all on moderation.suspensions from public, anon, authenticated;

-- Whether [target] is suspended right now.
create or replace function private.is_suspended(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from moderation.suspensions s
    where s.user_id = target
      and s.lifted_at is null
      and (s.until is null or s.until > now())
  )
$$;

-- The members the caller doesn't see: those they blocked, and the suspended ones.
-- Read it as `x not in (select h from private.hidden_members() h)`: Postgres works
-- the set out once per statement.
create or replace function private.hidden_members()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select b.blocked_id
  from public.user_blocks b
  where b.blocker_id = (select auth.uid())
  union
  select s.user_id
  from moderation.suspensions s
  where s.lifted_at is null
    and (s.until is null or s.until > now())
$$;

-- The service role (the `discussions` function) asks before it writes a post.
create or replace function public.is_member_suspended(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_suspended(target)
$$;

revoke all on function private.is_suspended(uuid) from public, anon, authenticated;
revoke all on function private.hidden_members() from public, anon, authenticated;
revoke all on function public.is_member_suspended(uuid) from public, anon, authenticated;
grant execute on function private.hidden_members() to authenticated;
grant execute on function public.is_member_suspended(uuid) to service_role;

-- "Passed two-factor", and not suspended: every restrictive policy and every
-- member-facing function already asks this, so a suspended member's remaining
-- tokens read and write nothing. Without a session (anon, service role) there is
-- no member, so nothing changes for them.
create or replace function public.mfa_satisfied()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not private.is_suspended((select auth.uid()))
     and (
       coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
       or not exists (
         select 1 from auth.mfa_factors f
         where f.user_id = (select auth.uid())
           and f.status = 'verified'
       )
     )
$$;

comment on function public.mfa_satisfied() is
  'Whether the caller''s session passed two-factor authentication (aal2, or no verified factor) and the member is not suspended (20261019135155_require_mfa.sql, 20261028235500_moderation_and_blocking.sql).';

-- 3. What a block does -------------------------------------------------------------

-- Blocking ends any follow between the two members, both ways.
create or replace function private.user_blocks_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.social_follows f
  where (f.follower_id = new.blocker_id and f.followee_id = new.blocked_id)
     or (f.follower_id = new.blocked_id and f.followee_id = new.blocker_id);
  return null;
end;
$$;

drop trigger if exists user_blocks_cleanup on public.user_blocks;
create trigger user_blocks_cleanup
  after insert on public.user_blocks
  for each row execute function private.user_blocks_cleanup();

-- A blocked member can't follow the member who blocked them. The follow is skipped
-- without an error, so the block isn't announced to them.
create or replace function private.social_follows_skip_blocked()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.user_blocks b
    where b.blocker_id = new.followee_id and b.blocked_id = new.follower_id
  ) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists social_follows_skip_blocked on public.social_follows;
create trigger social_follows_skip_blocked
  before insert on public.social_follows
  for each row execute function private.social_follows_skip_blocked();

revoke all on function private.user_blocks_cleanup() from public, anon, authenticated;
revoke all on function private.social_follows_skip_blocked() from public, anon, authenticated;

-- The members the caller blocked, newest block first, for the Blocked members screen.
create or replace function public.my_blocked_members()
returns table (
  id uuid,
  handle text,
  display_name text,
  avatar_url text,
  avatar_frame text,
  showcased_milestones text[]
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.handle::text, p.display_name::text, p.avatar_url::text,
         p.avatar_frame::text, p.showcased_milestones
  from public.user_blocks k
  join public.profiles p on p.id = k.blocked_id
  where k.blocker_id = (select auth.uid())
    and (select auth.uid()) is not null
    and (select public.mfa_satisfied())
  order by k.created_at desc, p.id
$$;

drop function if exists public.my_discussion_blocks();

revoke all on function public.my_blocked_members() from public, anon, authenticated;
grant execute on function public.my_blocked_members() to authenticated;

-- 4. The text filter -----------------------------------------------------------------

-- Lower case, without accents, invisible characters and look-alike letters: what
-- plain() does in discussion_filter.ts. (\p{M} and \p{Cf} become the ranges that
-- matter: PostgreSQL's regular expressions have no property escapes.)
create or replace function private.chat_plain(t text)
returns text
language sql
immutable
set search_path = ''
as $$
  select translate(
    lower(regexp_replace(
      normalize(coalesce(t, ''), nfkd),
      '[̀-ͯ᪰-᫿᷀-᷿⃐-⃿︠-︯­​-‏‪-‮⁠-⁤⁦-⁯﻿]',
      '', 'g'
    )),
    'ɡɑıοαι', 'gaioai'
  )
$$;

-- A digit or sign between two letters is the letter it stands for ("n1gger").
create or replace function private.chat_unleet(t text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  result text := t;
  pairs constant text[] := array['0', 'o', '1', 'i', '3', 'e', '4', 'a', '5', 's', '7', 't', '@', 'a', '$', 's', '!', 'i'];
begin
  for i in 1 .. array_length(pairs, 1) by 2 loop
    result := regexp_replace(
      result,
      '(?<=[[:alpha:]])[' || pairs[i] || '](?=[[:alpha:]])',
      pairs[i + 1],
      'g'
    );
  end loop;
  return result;
end;
$$;

-- Whether [t] has a word the chat rules refuse, however it was dressed up: the
-- discussions' filter (supabase/functions/_shared/discussion_filter.ts), pattern for
-- pattern. filter_sql_test.ts checks that the newest migration defining this function
-- holds the two $re$ strings that file produces. To change a term, change it there and
-- redefine this function in a NEW migration with the strings the test prints.
create or replace function private.breaks_chat_rules(t text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  base text;
  latin text;
  cyrillic text;
begin
  if t is null or btrim(t) = '' then
    return false;
  end if;
  -- Longer than any field that is checked.
  base := private.chat_unleet(private.chat_plain(left(t, 5000)));
  -- Cyrillic letters that look like Latin ones, so a Latin word typed with them is read as Latin.
  latin := translate(base, 'авекмнорстухі', 'abekmhopctyxi');
  -- Latin letters (and 3, 0, @) that look like Cyrillic ones, for a Russian word.
  cyrillic := translate(base, 'abekmhopctyxi30@', 'авекмнорстухизоа');
  return latin ~ $re$(?<![a-z])(?:(?:(?:s+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}n+[^[:alnum:]]{0,2}d+|j+[^[:alnum:]]{0,2}u+[^[:alnum:]]{0,2}n+[^[:alnum:]]{0,2}g+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}e+|p+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}c+[^[:alnum:]]{0,2}h+|d+[^[:alnum:]]{0,2}u+[^[:alnum:]]{0,2}n+[^[:alnum:]]{0,2}e+|t+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}r+))?[^[:alnum:]]{0,2}n+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}g+[^[:alnum:]]{0,2}g+[^[:alnum:]]{0,2}(?:e+[^[:alnum:]]{0,2}r+|a+|a+[^[:alnum:]]{0,2}h+|a+[^[:alnum:]]{0,2}z+|u+[^[:alnum:]]{0,2}h+)[^[:alnum:]]{0,2}s*|(?:w+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}t+[^[:alnum:]]{0,2}b+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}c+[^[:alnum:]]{0,2}k+|w+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}t+[^[:alnum:]]{0,2}b+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}c+[^[:alnum:]]{0,2}k+[^[:alnum:]]{0,2}s+|t+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}w+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}d+|t+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}w+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}s+|r+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}g+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}d+|r+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}g+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}s+|z+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}p+[^[:alnum:]]{0,2}p+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}d+|z+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}p+[^[:alnum:]]{0,2}p+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}s+)|(?:j+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}g+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}b+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}o+|j+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}g+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}b+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}s+|p+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}k+[^[:alnum:]]{0,2}i+|p+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}k+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}s+)|(?:c+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}d+|c+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}n+|k+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}d+|k+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}s+|k+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}e+|k+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}y+|u+[^[:alnum:]]{0,2}n+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}g+[^[:alnum:]]{0,2}e+|p+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}t+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}n+|t+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}r+|t+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}s+)[^[:alnum:]]{0,2}(?:p+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}n+|p+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}n+[^[:alnum:]]{0,2}o+|p+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}n+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}g+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}p+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}y+)|c+[^[:alnum:]]{0,2}s+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}m+|(?:r+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}p+[^[:alnum:]]{0,2}e+|r+[^[:alnum:]]{0,2}a+[^[:alnum:]]{0,2}p+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}n+[^[:alnum:]]{0,2}g+|m+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}s+[^[:alnum:]]{0,2}t+|m+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}s+[^[:alnum:]]{0,2}t+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}n+[^[:alnum:]]{0,2}g+)[^[:alnum:]]{0,2}(?:o+[^[:alnum:]]{0,2}f+)?[^[:alnum:]]{0,2}(?:(?:a+|t+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}e+))?[^[:alnum:]]{0,2}(?:l+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}t+[^[:alnum:]]{0,2}t+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}e+)?[^[:alnum:]]{0,2}(?:c+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}d+|c+[^[:alnum:]]{0,2}h+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}n+|k+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}d+|k+[^[:alnum:]]{0,2}i+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}s+|t+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}r+|t+[^[:alnum:]]{0,2}o+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}d+[^[:alnum:]]{0,2}l+[^[:alnum:]]{0,2}e+[^[:alnum:]]{0,2}r+[^[:alnum:]]{0,2}s+))(?![a-z])$re$
      or cyrillic ~ $re$(?<![а-яё])(?:н+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}г+[^[:alnum:]]{0,2}г+[^[:alnum:]]{0,2}(?:е+[^[:alnum:]]{0,2}р+|а+)[^[:alnum:]]{0,2}(?:(?:ы+|о+[^[:alnum:]]{0,2}в+|а+[^[:alnum:]]{0,2}м+|а+[^[:alnum:]]{0,2}м+[^[:alnum:]]{0,2}и+|у+|о+[^[:alnum:]]{0,2}м+))?|ч+[^[:alnum:]]{0,2}у+[^[:alnum:]]{0,2}р+[^[:alnum:]]{0,2}к+[^[:alnum:]]{0,2}(?:а+|и+|у+|е+|о+[^[:alnum:]]{0,2}и+|а+[^[:alnum:]]{0,2}м+|а+[^[:alnum:]]{0,2}м+[^[:alnum:]]{0,2}и+|а+[^[:alnum:]]{0,2}х+)|х+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}ч+[^[:alnum:]]{0,2}(?:(?:и+|е+[^[:alnum:]]{0,2}и+|а+[^[:alnum:]]{0,2}м+|а+[^[:alnum:]]{0,2}м+[^[:alnum:]]{0,2}и+|и+[^[:alnum:]]{0,2}к+|и+[^[:alnum:]]{0,2}к+[^[:alnum:]]{0,2}а+|и+[^[:alnum:]]{0,2}к+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}в+))?|ж+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}д+[^[:alnum:]]{0,2}(?:(?:ы+|о+[^[:alnum:]]{0,2}в+|а+[^[:alnum:]]{0,2}м+|а+[^[:alnum:]]{0,2}м+[^[:alnum:]]{0,2}и+|а+[^[:alnum:]]{0,2}х+|о+[^[:alnum:]]{0,2}в+[^[:alnum:]]{0,2}к+[^[:alnum:]]{0,2}а+|о+[^[:alnum:]]{0,2}в+[^[:alnum:]]{0,2}н+[^[:alnum:]]{0,2}я+|о+[^[:alnum:]]{0,2}в+[^[:alnum:]]{0,2}с+[^[:alnum:]]{0,2}к+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}и+))?|д+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}т+[^[:alnum:]]{0,2}с+[^[:alnum:]]{0,2}к+[^[:alnum:]]{0,2}(?:о+[^[:alnum:]]{0,2}е+|а+[^[:alnum:]]{0,2}я+|у+[^[:alnum:]]{0,2}ю+|о+[^[:alnum:]]{0,2}и+|и+[^[:alnum:]]{0,2}е+|и+[^[:alnum:]]{0,2}х+|и+[^[:alnum:]]{0,2}м+)[^[:alnum:]]{0,2}п+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}р+[^[:alnum:]]{0,2}н+[^[:alnum:]]{0,2}(?:(?:о+|о+[^[:alnum:]]{0,2}г+[^[:alnum:]]{0,2}р+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}ф+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}я+|о+[^[:alnum:]]{0,2}г+[^[:alnum:]]{0,2}р+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}ф+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}ю+|о+[^[:alnum:]]{0,2}г+[^[:alnum:]]{0,2}р+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}ф+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}и+))?|п+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}р+[^[:alnum:]]{0,2}н+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}с+[^[:alnum:]]{0,2}д+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}т+[^[:alnum:]]{0,2}ь+[^[:alnum:]]{0,2}м+[^[:alnum:]]{0,2}и+|(?:и+[^[:alnum:]]{0,2}з+[^[:alnum:]]{0,2}н+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}с+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}л+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}в+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}т+[^[:alnum:]]{0,2}ь+|и+[^[:alnum:]]{0,2}з+[^[:alnum:]]{0,2}н+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}с+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}л+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}в+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}н+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}е+|н+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}с+[^[:alnum:]]{0,2}и+[^[:alnum:]]{0,2}л+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}в+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}т+[^[:alnum:]]{0,2}ь+)[^[:alnum:]]{0,2}(?:р+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}б+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}н+[^[:alnum:]]{0,2}к+[^[:alnum:]]{0,2}а+|р+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}б+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}н+[^[:alnum:]]{0,2}к+[^[:alnum:]]{0,2}а+|д+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}т+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}и+|м+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}л+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}л+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}т+[^[:alnum:]]{0,2}к+[^[:alnum:]]{0,2}у+|м+[^[:alnum:]]{0,2}а+[^[:alnum:]]{0,2}л+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}л+[^[:alnum:]]{0,2}е+[^[:alnum:]]{0,2}т+[^[:alnum:]]{0,2}о+[^[:alnum:]]{0,2}к+))(?![а-яё])$re$;
end;
$fn$;

revoke all on function private.chat_plain(text) from public, anon, authenticated;
revoke all on function private.chat_unleet(text) from public, anon, authenticated;
revoke all on function private.breaks_chat_rules(text) from public, anon, authenticated;

-- Refuses a save: the error the app turns into "this breaks the community rules".
create or replace function private.refuse_chat_text(field text, value text)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if private.breaks_chat_rules(value) then
    raise exception 'content_not_allowed' using errcode = 'CP422', detail = field;
  end if;
end;
$$;

revoke all on function private.refuse_chat_text(text, text) from public, anon, authenticated;
grant execute on function private.refuse_chat_text(text, text) to authenticated;
grant execute on function private.breaks_chat_rules(text) to authenticated;
grant execute on function private.chat_plain(text) to authenticated;
grant execute on function private.chat_unleet(text) to authenticated;

-- Profiles: name, handle, bio and the names of the connected services. A new
-- profile is cleaned, not refused (its name may come from Google or Apple and must
-- not stop the sign-up); a change is refused. The service role and the dashboard
-- are exempt.
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
  if new.psn_id is distinct from old.psn_id then
    perform private.refuse_chat_text('psn_id', new.psn_id);
  end if;
  if new.xbox_id is distinct from old.xbox_id then
    perform private.refuse_chat_text('xbox_id', new.xbox_id);
  end if;
  if new.discord_id is distinct from old.discord_id then
    perform private.refuse_chat_text('discord_id', new.discord_id);
  end if;
  if new.instagram_id is distinct from old.instagram_id then
    perform private.refuse_chat_text('instagram_id', new.instagram_id);
  end if;
  if new.twitch_id is distinct from old.twitch_id then
    perform private.refuse_chat_text('twitch_id', new.twitch_id);
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_check_public_text on public.profiles;
create trigger profiles_check_public_text
  before insert or update on public.profiles
  for each row execute function private.profiles_check_public_text();

-- Reviews: a review is checked when it is written or changed, not each time the
-- row is saved for another reason (a status, a rating, a Steam sync).
create or replace function private.user_games_check_review_text()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' or new.review is distinct from old.review then
    perform private.refuse_chat_text('review', new.review);
  end if;
  return new;
end;
$$;

drop trigger if exists user_games_check_review_text on public.user_games;
create trigger user_games_check_review_text
  before insert or update on public.user_games
  for each row execute function private.user_games_check_review_text();

-- Lists: title and description.
create or replace function private.game_lists_check_text()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if tg_op = 'INSERT' or new.title is distinct from old.title then
    perform private.refuse_chat_text('title', new.title);
  end if;
  if tg_op = 'INSERT' or new.description is distinct from old.description then
    perform private.refuse_chat_text('description', new.description);
  end if;
  return new;
end;
$$;

drop trigger if exists game_lists_check_text on public.game_lists;
create trigger game_lists_check_text
  before insert or update on public.game_lists
  for each row execute function private.game_lists_check_text();

revoke all on function private.profiles_check_public_text() from public, anon, authenticated;
revoke all on function private.user_games_check_review_text() from public, anon, authenticated;
revoke all on function private.game_lists_check_text() from public, anon, authenticated;

-- 5. Reports -----------------------------------------------------------------------

-- A member's report of another's profile, profile photo or public list. Write only
-- for members: moderators read it in moderation.open_reports.
create table if not exists public.user_reports (
  id          bigint generated always as identity primary key,
  reporter_id uuid not null default auth.uid()
    references auth.users (id) on delete cascade,
  reported_id uuid not null
    references auth.users (id) on delete cascade,
  subject     text not null
    constraint user_reports_subject_check check (subject in ('profile', 'avatar', 'list')),
  -- The list a 'list' report is about, and only then.
  list_id     uuid references public.game_lists (id) on delete cascade,
  reason      text not null
    constraint user_reports_reason_check check (reason in ('spam', 'abuse', 'other')),
  created_at  timestamptz not null default now(),
  status      text not null default 'open'
    constraint user_reports_status_check check (status in ('open', 'actioned', 'dismissed')),
  handled_at  timestamptz,
  outcome     text,
  constraint user_reports_not_self check (reporter_id <> reported_id),
  constraint user_reports_list_matches check ((subject = 'list') = (list_id is not null))
);

-- One report per member and thing reported: reporting again changes nothing.
create unique index if not exists user_reports_member_once
  on public.user_reports (reporter_id, reported_id, subject) where list_id is null;
create unique index if not exists user_reports_list_once
  on public.user_reports (reporter_id, list_id) where list_id is not null;
create index if not exists user_reports_reported_idx on public.user_reports (reported_id);
create index if not exists user_reports_list_idx on public.user_reports (list_id) where list_id is not null;

comment on table public.user_reports is
  'A member''s report of another member''s profile, photo or public list. Write only for members: moderators read it in moderation.open_reports.';

-- The state of every report table: open until a moderator handles it. A member
-- can insert but never sets these (the trigger below), and can't update.
alter table public.review_reports
  add column if not exists status text not null default 'open',
  add column if not exists handled_at timestamptz,
  add column if not exists outcome text;
alter table public.review_reports
  drop constraint if exists review_reports_status_check,
  add constraint review_reports_status_check check (status in ('open', 'actioned', 'dismissed'));

alter table public.discussion_reports
  add column if not exists status text not null default 'open',
  add column if not exists handled_at timestamptz,
  add column if not exists outcome text;
alter table public.discussion_reports
  drop constraint if exists discussion_reports_status_check,
  add constraint discussion_reports_status_check check (status in ('open', 'actioned', 'dismissed'));

create index if not exists review_reports_open_idx on public.review_reports (created_at) where status = 'open';
create index if not exists discussion_reports_open_idx on public.discussion_reports (created_at) where status = 'open';
create index if not exists user_reports_open_idx on public.user_reports (created_at) where status = 'open';

create or replace function private.reports_new_are_open()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.status := 'open';
  new.handled_at := null;
  new.outcome := null;
  return new;
end;
$$;

-- At most 20 reports an hour per member through user_reports: a script can't bury
-- the queue.
create or replace function private.user_reports_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.user_reports r
      where r.reporter_id = new.reporter_id
        and r.created_at > now() - interval '1 hour') >= 20 then
    raise exception 'rate_limited' using errcode = 'CP429';
  end if;
  return new;
end;
$$;

drop trigger if exists reports_new_are_open on public.review_reports;
create trigger reports_new_are_open
  before insert on public.review_reports
  for each row execute function private.reports_new_are_open();

drop trigger if exists reports_new_are_open on public.discussion_reports;
create trigger reports_new_are_open
  before insert on public.discussion_reports
  for each row execute function private.reports_new_are_open();

drop trigger if exists reports_new_are_open on public.user_reports;
create trigger reports_new_are_open
  before insert on public.user_reports
  for each row execute function private.reports_new_are_open();

drop trigger if exists user_reports_limit on public.user_reports;
create trigger user_reports_limit
  before insert on public.user_reports
  for each row execute function private.user_reports_limit();

revoke all on function private.reports_new_are_open() from public, anon, authenticated;
revoke all on function private.user_reports_limit() from public, anon, authenticated;

alter table public.user_reports enable row level security;

-- A member reports as themselves, and reads back only their own reports (an
-- insert on conflict needs to see the row it would conflict with).
drop policy if exists user_reports_select_own on public.user_reports;
create policy user_reports_select_own
  on public.user_reports
  for select to authenticated
  using (reporter_id = (select auth.uid()));

drop policy if exists user_reports_insert_own on public.user_reports;
create policy user_reports_insert_own
  on public.user_reports
  for insert to authenticated
  with check (reporter_id = (select auth.uid()));

drop policy if exists user_reports_aal2_if_mfa on public.user_reports;
create policy user_reports_aal2_if_mfa
  on public.user_reports
  as restrictive
  for all to authenticated
  using ((select public.mfa_satisfied()))
  with check ((select public.mfa_satisfied()));

revoke all on public.user_reports from public, anon, authenticated;
grant select, insert on public.user_reports to authenticated;

-- 6. What a block and a suspension hide ------------------------------------------------

-- The public_* wrappers (20261022200000) filter on the member the row is about.
-- The definer views behind them, and so the columns, are unchanged.
create or replace view public.public_profiles
  with (security_invoker = true) as
  select * from private.public_profiles v
  where v.id not in (select h from private.hidden_members() h);

create or replace view public.public_followers
  with (security_invoker = true) as
  select * from private.public_followers v
  where v.id not in (select h from private.hidden_members() h);

create or replace view public.public_following
  with (security_invoker = true) as
  select * from private.public_following v
  where v.id not in (select h from private.hidden_members() h);

create or replace view public.public_user_games
  with (security_invoker = true) as
  select * from private.public_user_games v
  where v.user_id not in (select h from private.hidden_members() h);

create or replace view public.public_recent_activity
  with (security_invoker = true) as
  select * from private.public_recent_activity v
  where v.user_id not in (select h from private.hidden_members() h);

-- A public list is as visible as its owner.
drop policy if exists game_lists_select on public.game_lists;
create policy game_lists_select
  on public.game_lists
  for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or (is_public and user_id not in (select h from private.hidden_members() h))
  );

-- The functions that read other members' content, with the same filter. They are
-- the earlier definitions (the migration named on each), plus one condition.
-- game_reviews: 20261022120000_game_reviews.sql
create or replace function public.game_reviews(
  target_game uuid,
  only_following boolean default false,
  sort_by text default 'friends',
  page_size integer default 20,
  page_offset integer default 0
)
returns table (
  id uuid,
  handle text,
  display_name text,
  avatar_url text,
  avatar_frame text,
  showcased_milestones text[],
  status text,
  rating double precision,
  hours_played double precision,
  review text,
  reviewed_at timestamptz,
  is_following boolean
)
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
-- following_recent_activity: 20261019135155_require_mfa.sql
create or replace function public.following_recent_activity(
  max_rows integer default 30
)
returns table (
  user_id uuid,
  handle text,
  display_name text,
  avatar_url text,
  game_id uuid,
  igdb_id public.games.igdb_id%type,
  steam_app_id public.games.steam_app_id%type,
  title public.games.title%type,
  publisher public.games.publisher%type,
  developer public.games.developer%type,
  release_year public.games.release_year%type,
  platforms public.games.platforms%type,
  genres public.games.genres%type,
  summary public.games.summary%type,
  cover_url public.games.cover_url%type,
  kind text,
  hours double precision,
  rating double precision,
  occurred_at timestamptz
)
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
-- following_game_activity: 20261019135155_require_mfa.sql
create or replace function public.following_game_activity(
  target_game uuid,
  per_status integer default 20
)
returns table (
  id uuid,
  handle text,
  display_name text,
  avatar_url text,
  status text,
  rating double precision,
  date_added timestamptz,
  status_total integer,
  review text
)
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
      and f.followee_id not in (select h from private.hidden_members() h)
      and (select public.mfa_satisfied())
  ) r
  where r.position <= least(greatest(coalesce(per_status, 20), 1), 50)
  order by r.status, r.position
$$;
-- discussion_boards_overview: 20261022165000_discussions.sql
create or replace function public.discussion_boards_overview()
returns table (
  id text,
  title text,
  description text,
  board_position integer,
  thread_count integer,
  latest_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select b.id, b.title, b.description, b.position,
         count(t.id)::integer,
         max(t.last_post_at)
  from public.discussion_boards b
  left join public.discussion_threads t
    on t.board_id = b.id
   and t.author_id not in (select h from private.hidden_members() h)
  where (select auth.uid()) is not null
    and (select public.mfa_satisfied())
  group by b.id, b.title, b.description, b.position
  order by b.position, b.id
$$;
-- discussion_threads_page: 20261022165000_discussions.sql
create or replace function public.discussion_threads_page(
  board text default null,
  about_game uuid default null,
  page_size integer default 20,
  page_offset integer default 0
)
returns table (
  id uuid,
  board_id text,
  game_id uuid,
  game_title text,
  game_igdb_id integer,
  game_cover_url text,
  title text,
  preview text,
  reply_count integer,
  created_at timestamptz,
  last_post_at timestamptz,
  pinned boolean,
  locked boolean,
  author_id uuid,
  author_handle text,
  author_name text,
  author_avatar_url text,
  author_avatar_frame text,
  author_showcase text[]
)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, t.board_id, t.game_id,
         g.title::text, g.igdb_id::integer, g.cover_url::text,
         t.title, left(t.body, 200), t.reply_count, t.created_at, t.last_post_at,
         t.pinned, t.locked,
         p.id, p.handle::text, p.display_name::text, p.avatar_url::text,
         p.avatar_frame::text, p.showcased_milestones
  from public.discussion_threads t
  join public.profiles p on p.id = t.author_id
  left join public.games g on g.id = t.game_id
  where (select auth.uid()) is not null
    and (select public.mfa_satisfied())
    and (board is null or t.board_id = board)
    and (about_game is null or t.game_id = about_game)
    and t.author_id not in (select h from private.hidden_members() h)
    and not exists (
      select 1 from public.discussion_reports r
      where r.reporter_id = (select auth.uid()) and r.thread_id = t.id)
  order by (board is not null and t.pinned) desc, t.last_post_at desc, t.id
  limit least(greatest(coalesce(page_size, 20), 1), 50)
  offset greatest(coalesce(page_offset, 0), 0)
$$;
-- discussion_thread: 20261022165000_discussions.sql
create or replace function public.discussion_thread(thread uuid)
returns table (
  id uuid,
  board_id text,
  game_id uuid,
  game_title text,
  game_igdb_id integer,
  game_cover_url text,
  title text,
  body text,
  reply_count integer,
  created_at timestamptz,
  last_post_at timestamptz,
  pinned boolean,
  locked boolean,
  author_id uuid,
  author_handle text,
  author_name text,
  author_avatar_url text,
  author_avatar_frame text,
  author_showcase text[]
)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, t.board_id, t.game_id,
         g.title::text, g.igdb_id::integer, g.cover_url::text,
         t.title, t.body, t.reply_count, t.created_at, t.last_post_at,
         t.pinned, t.locked,
         p.id, p.handle::text, p.display_name::text, p.avatar_url::text,
         p.avatar_frame::text, p.showcased_milestones
  from public.discussion_threads t
  join public.profiles p on p.id = t.author_id
  left join public.games g on g.id = t.game_id
  where t.id = thread
    and (select auth.uid()) is not null
    and (select public.mfa_satisfied())
    and t.author_id not in (select h from private.hidden_members() h)
    and not exists (
      select 1 from public.discussion_reports r
      where r.reporter_id = (select auth.uid()) and r.thread_id = t.id)
$$;
-- discussion_posts_page: 20261022165000_discussions.sql
create or replace function public.discussion_posts_page(
  thread uuid,
  page_size integer default 30,
  page_offset integer default 0
)
returns table (
  id uuid,
  thread_id uuid,
  body text,
  created_at timestamptz,
  author_id uuid,
  author_handle text,
  author_name text,
  author_avatar_url text,
  author_avatar_frame text,
  author_showcase text[]
)
language sql
stable
security definer
set search_path = ''
as $$
  select x.id, x.thread_id, x.body, x.created_at,
         p.id, p.handle::text, p.display_name::text, p.avatar_url::text,
         p.avatar_frame::text, p.showcased_milestones
  from public.discussion_posts x
  join public.profiles p on p.id = x.author_id
  where x.thread_id = thread
    and (select auth.uid()) is not null
    and (select public.mfa_satisfied())
    and x.author_id not in (select h from private.hidden_members() h)
    and not exists (
      select 1 from public.discussion_reports r
      where r.reporter_id = (select auth.uid()) and r.post_id = x.id)
  order by x.created_at, x.id
  limit least(greatest(coalesce(page_size, 30), 1), 50)
  offset greatest(coalesce(page_offset, 0), 0)
$$;

-- 7. The moderators' tools -----------------------------------------------------------

-- Every open report, oldest first: what was reported, who reported it, and for how
-- long it has been waiting. `overdue` is past 24 hours. `reference` is the id to
-- act on (the list, the thread, the reply; for a review, the game).
create or replace view moderation.open_reports as
select q.*,
       round((extract(epoch from now() - q.reported_at) / 3600)::numeric, 1) as hours_open,
       now() - q.reported_at > interval '24 hours' as overdue
from (
  select 'profile'::text as source,
         r.created_at as reported_at,
         r.reason,
         r.reporter_id,
         r.reported_id,
         p.handle::text as reported_handle,
         case r.subject
           when 'avatar' then 'photo: ' || coalesce(p.avatar_url, '(none)')
           else 'name: ' || coalesce(p.display_name, '') || ' | handle: ' || coalesce(p.handle::text, '')
                || ' | bio: ' || left(coalesce(p.bio, ''), 300)
         end as content,
         null::text as reference
  from public.user_reports r
  join public.profiles p on p.id = r.reported_id
  where r.status = 'open' and r.subject <> 'list'

  union all
  select 'list',
         r.created_at, r.reason, r.reporter_id, r.reported_id,
         p.handle::text,
         'list: ' || l.title || ' | ' || left(l.description, 300),
         l.id::text
  from public.user_reports r
  join public.profiles p on p.id = r.reported_id
  join public.game_lists l on l.id = r.list_id
  where r.status = 'open' and r.subject = 'list'

  union all
  select 'review',
         r.created_at, r.reason, r.reporter_id, r.review_user_id,
         p.handle::text,
         left(ug.review, 500),
         r.game_id::text
  from public.review_reports r
  join public.profiles p on p.id = r.review_user_id
  join public.user_games ug on ug.user_id = r.review_user_id and ug.game_id = r.game_id
  where r.status = 'open'

  union all
  select 'thread',
         r.created_at, r.reason, r.reporter_id, t.author_id,
         p.handle::text,
         t.title || ' | ' || left(t.body, 500),
         t.id::text
  from public.discussion_reports r
  join public.discussion_threads t on t.id = r.thread_id
  join public.profiles p on p.id = t.author_id
  where r.status = 'open'

  union all
  select 'reply',
         r.created_at, r.reason, r.reporter_id, x.author_id,
         p.handle::text,
         left(x.body, 500),
         x.id::text
  from public.discussion_reports r
  join public.discussion_posts x on x.id = r.post_id
  join public.profiles p on p.id = x.author_id
  where r.status = 'open'
) q
order by q.reported_at;

comment on view moderation.open_reports is
  'Every open report from every report table, oldest first, with hours_open and overdue (past 24 hours).';

-- Public text the filter would refuse now: what was saved before it existed.
create or replace function moderation.flagged_text()
returns table (source text, member_id uuid, handle text, content text)
language sql
stable
set search_path = ''
as $$
  select 'display_name', p.id, p.handle::text, p.display_name from public.profiles p
    where private.breaks_chat_rules(p.display_name)
  union all
  select 'handle', p.id, p.handle::text, p.handle::text from public.profiles p
    where private.breaks_chat_rules(p.handle::text)
  union all
  select 'bio', p.id, p.handle::text, p.bio from public.profiles p
    where private.breaks_chat_rules(p.bio)
  union all
  select 'review', ug.user_id, p.handle::text, ug.review
    from public.user_games ug join public.profiles p on p.id = ug.user_id
    where private.breaks_chat_rules(ug.review)
  union all
  select 'list', l.user_id, p.handle::text, l.title || ' | ' || l.description
    from public.game_lists l join public.profiles p on p.id = l.user_id
    where private.breaks_chat_rules(l.title || ' ' || l.description)
$$;

-- Suspends [target]: banned from signing in (Supabase Auth), signed out
-- everywhere, and invisible to every other member. [days] null: until reinstated.
create or replace function moderation.suspend_member(target uuid, why text, days integer default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  ends timestamptz := case when days is null then null else now() + make_interval(days => days) end;
begin
  if not exists (select 1 from auth.users u where u.id = target) then
    raise exception 'No such member: %', target;
  end if;
  if coalesce(btrim(why), '') = '' then
    raise exception 'Say why: a suspension without a reason is not recorded';
  end if;

  update moderation.suspensions set lifted_at = now()
   where user_id = target and lifted_at is null;
  insert into moderation.suspensions (user_id, reason, until) values (target, why, ends);

  -- Auth has no "forever": a hundred years is.
  update auth.users set banned_until = coalesce(ends, now() + interval '100 years')
   where id = target;
  -- Their refresh tokens go with their sessions.
  delete from auth.sessions where user_id = target;
end;
$$;

-- Lifts every suspension of [target].
create or replace function moderation.reinstate_member(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update moderation.suspensions set lifted_at = now()
   where user_id = target and lifted_at is null;
  update auth.users set banned_until = null where id = target;
end;
$$;

-- Marks every open report about [target]'s profile, photo, lists, reviews and
-- discussion posts as handled. [result] is 'actioned' (something was done) or
-- 'dismissed' (nothing was wrong); [note] is kept with each report. Answers how many.
create or replace function moderation.close_reports_about(target uuid, result text, note text default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  total integer := 0;
  n integer;
begin
  if result not in ('actioned', 'dismissed') then
    raise exception 'result is actioned or dismissed';
  end if;

  update public.user_reports
     set status = result, handled_at = now(), outcome = note
   where reported_id = target and status = 'open';
  get diagnostics n = row_count; total := total + n;

  update public.review_reports
     set status = result, handled_at = now(), outcome = note
   where review_user_id = target and status = 'open';
  get diagnostics n = row_count; total := total + n;

  update public.discussion_reports r
     set status = result, handled_at = now(), outcome = note
   where r.status = 'open'
     and (exists (select 1 from public.discussion_threads t where t.id = r.thread_id and t.author_id = target)
          or exists (select 1 from public.discussion_posts x where x.id = r.post_id and x.author_id = target));
  get diagnostics n = row_count; total := total + n;

  return total;
end;
$$;

-- Wipes what a profile shows: name, handle, bio, photo and the service names.
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
         avatar_url = null,
         psn_id = null, xbox_id = null, discord_id = null, instagram_id = null, twitch_id = null
   where id = target;
end;
$$;

-- Empties one member's review of one game (the rating and the rest stay).
create or replace function moderation.remove_review(target uuid, game uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.user_games set review = '' where user_id = target and game_id = game
$$;

revoke all on all functions in schema moderation from public, anon, authenticated;
revoke all on moderation.open_reports from public, anon, authenticated;

notify pgrst, 'reload schema';

-- Fail loudly if the result is not what this file promises.
do $$
declare
  v text;
  fn regprocedure;
  leftover text;
begin
  -- Blocks.
  if to_regclass('public.user_blocks') is null or to_regclass('public.discussion_blocks') is not null then
    raise exception 'discussion_blocks must have become user_blocks';
  end if;
  if (select count(*) from pg_policies
      where schemaname = 'public'
        and policyname in ('user_blocks_aal2_if_mfa', 'user_reports_aal2_if_mfa')
        and permissive = 'RESTRICTIVE' and cmd = 'ALL') <> 2 then
    raise exception 'A block or report table has no restrictive two-factor policy';
  end if;
  if exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in ('user_blocks', 'user_reports') and not c.relrowsecurity
  ) then
    raise exception 'Row level security is not enabled on user_blocks or user_reports';
  end if;
  if has_table_privilege('anon', 'public.user_reports', 'select')
     or has_table_privilege('authenticated', 'public.user_reports', 'update')
     or has_table_privilege('authenticated', 'public.user_reports', 'delete')
     or has_table_privilege('anon', 'public.user_blocks', 'select')
     or has_table_privilege('authenticated', 'public.user_blocks', 'update') then
    raise exception 'The block and report tables have the wrong grants';
  end if;
  if exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename in ('user_blocks', 'user_reports')
      and permissive = 'PERMISSIVE'
      and coalesce(qual, '') not like '%auth.uid()%'
      and coalesce(with_check, '') not like '%auth.uid()%'
  ) then
    raise exception 'A block or report policy is not limited to the member''s own rows';
  end if;

  -- The moderators' schema is out of reach of every client role.
  if has_schema_privilege('anon', 'moderation', 'usage')
     or has_schema_privilege('authenticated', 'moderation', 'usage')
     or has_table_privilege('authenticated', 'moderation.suspensions', 'select')
     or has_table_privilege('authenticated', 'moderation.open_reports', 'select')
     or has_table_privilege('anon', 'moderation.open_reports', 'select') then
    raise exception 'The moderation schema must not be reachable by members';
  end if;
  foreach fn in array array[
    'moderation.suspend_member(uuid, text, integer)'::regprocedure,
    'moderation.reinstate_member(uuid)'::regprocedure,
    'moderation.close_reports_about(uuid, text, text)'::regprocedure,
    'moderation.clear_profile(uuid)'::regprocedure,
    'moderation.remove_review(uuid, uuid)'::regprocedure,
    'public.is_member_suspended(uuid)'::regprocedure
  ] loop
    if has_function_privilege('anon', fn, 'execute')
       or has_function_privilege('authenticated', fn, 'execute') then
      raise exception '% must not be callable by members', fn;
    end if;
  end loop;
  if not has_function_privilege('service_role', 'public.is_member_suspended(uuid)'::regprocedure, 'execute') then
    raise exception 'The discussions function must be able to call is_member_suspended';
  end if;
  if has_function_privilege('anon', 'private.hidden_members()'::regprocedure, 'execute')
     or not has_function_privilege('authenticated', 'private.hidden_members()'::regprocedure, 'execute') then
    raise exception 'private.hidden_members has the wrong grants';
  end if;

  -- Everything that reads other members' content leaves out the hidden ones.
  foreach v in array array[
    'public_profiles', 'public_followers', 'public_following',
    'public_user_games', 'public_recent_activity'
  ] loop
    if pg_get_viewdef(to_regclass(format('public.%I', v)), true) not like '%hidden_members%' then
      raise exception 'public.% does not leave out hidden members', v;
    end if;
    if not (select coalesce(c.reloptions @> array['security_invoker=true'], false)
            from pg_class c where c.oid = to_regclass(format('public.%I', v))) then
      raise exception 'public.% must stay a security_invoker view', v;
    end if;
  end loop;
  foreach fn in array array[
    'public.game_reviews(uuid, boolean, text, integer, integer)'::regprocedure,
    'public.following_game_activity(uuid, integer)'::regprocedure,
    'public.following_recent_activity(integer)'::regprocedure,
    'public.discussion_boards_overview()'::regprocedure,
    'public.discussion_threads_page(text, uuid, integer, integer)'::regprocedure,
    'public.discussion_thread(uuid)'::regprocedure,
    'public.discussion_posts_page(uuid, integer, integer)'::regprocedure
  ] loop
    if (select prosrc from pg_proc where oid = fn) not like '%hidden_members%' then
      raise exception '% does not leave out hidden members', fn;
    end if;
    if not (select prosecdef from pg_proc where oid = fn)
       or has_function_privilege('anon', fn, 'execute')
       or not has_function_privilege('authenticated', fn, 'execute') then
      raise exception '% has the wrong security or grants', fn;
    end if;
  end loop;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'game_lists'
      and policyname = 'game_lists_select' and qual like '%hidden_members%'
  ) then
    raise exception 'game_lists_select does not leave out hidden members';
  end if;
  if not (select prosecdef from pg_proc where oid = 'public.my_blocked_members()'::regprocedure)
     or has_function_privilege('anon', 'public.my_blocked_members()'::regprocedure, 'execute')
     or not has_function_privilege('authenticated', 'public.my_blocked_members()'::regprocedure, 'execute') then
    raise exception 'public.my_blocked_members has the wrong security or grants';
  end if;

  -- A suspended member passes nothing.
  if (select prosrc from pg_proc where oid = 'public.mfa_satisfied()'::regprocedure) not like '%is_suspended%' then
    raise exception 'public.mfa_satisfied must refuse a suspended member';
  end if;

  -- The filter, on a word that must be refused and one that must not.
  if not private.breaks_chat_rules('n' || 'igg' || 'er')
     or private.breaks_chat_rules('a snigger and Pakistan') then
    raise exception 'private.breaks_chat_rules does not do what discussion_filter.ts does';
  end if;
  if (select count(*) from pg_trigger
      where tgname in ('profiles_check_public_text', 'user_games_check_review_text', 'game_lists_check_text',
                       'user_blocks_cleanup', 'social_follows_skip_blocked', 'reports_new_are_open')
        and not tgisinternal) < 8 then
    raise exception 'A moderation trigger is missing';
  end if;

  -- The advisor's rule, again: nothing in `public` that members can select may be a definer view.
  select string_agg(c.relname, ', ') into leftover
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'v'
    and (has_table_privilege('anon', c.oid, 'select')
         or has_table_privilege('authenticated', c.oid, 'select'))
    and not coalesce(c.reloptions @> array['security_invoker=true'], false);
  if leftover is not null then
    raise exception 'Definer views are readable through the API: %', leftover;
  end if;
end;
$$;
