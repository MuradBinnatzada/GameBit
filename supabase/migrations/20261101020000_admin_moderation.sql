-- Moderating from the app.
--
-- Until now the owner moderated in the Supabase SQL editor (supabase/MODERATION.md).
-- This lets the owner, and anyone they add, do the main part of it from the app:
-- read the queue of open reports, suspend and reinstate a member, close reports.
--
--   1. moderation.admins lists who may. The owner adds themselves once in the SQL
--      editor (supabase/MODERATION.md); no client role can read or write the table.
--   2. The tools stay in the moderation schema, which the API doesn't expose, and the
--      app can't call them. The new `admin-moderation` Edge Function does, through the
--      public.admin_* wrappers below: callable by the service role only (the same way
--      public.is_member_suspended is), each with the signed-in member's id as `actor`
--      and each asking again whether that member is an admin. The function checks the
--      session and two-factor; the database is the one place that decides who is an admin.
--   3. The app learns whether to show the admin screens by asking the database about
--      itself (public.am_i_admin()), which says nothing about anyone else, so ordinary
--      members never reach the Edge Function.
--   4. An admin who is suspended is no admin. An admin can't be suspended from the app
--      (take them out of moderation.admins first), so a stolen admin session can't be
--      used to lock the owner out.
--
-- Errors, by SQLSTATE (the function turns them into its codes):
--   CP400  bad input           CP403  the actor is not an admin
--   CP404  no such member      CP409  the member is an admin

-- 1. Who may -----------------------------------------------------------------------

create table if not exists moderation.admins (
  user_id  uuid primary key references auth.users (id) on delete cascade,
  added_at timestamptz not null default now()
);

revoke all on moderation.admins from public, anon, authenticated;

comment on table moderation.admins is
  'Members who may moderate from the app (the admin-moderation function). Write it in the SQL editor: insert into moderation.admins (user_id) select id from auth.users where email = ''you@example.com''.';

create or replace function private.is_admin(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from moderation.admins a where a.user_id = target)
     and not private.is_suspended(target)
$$;

create or replace function private.require_admin(actor uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if actor is null or not private.is_admin(actor) then
    raise exception 'not_admin' using errcode = 'CP403';
  end if;
end;
$$;

revoke all on function private.is_admin(uuid) from public, anon, authenticated;
revoke all on function private.require_admin(uuid) from public, anon, authenticated;

-- Whether the caller is an admin: all the app needs to know to show its admin screens.
-- It answers for the caller only. Everything an admin does is checked again on the server.
create or replace function public.am_i_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_admin((select auth.uid()))
$$;

revoke all on function public.am_i_admin() from public, anon;
grant execute on function public.am_i_admin() to authenticated;

-- 2. What the function asks ------------------------------------------------------------

-- Whether [target] is an admin right now.
create or replace function public.is_member_admin(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_admin(target)
$$;

-- The open reports, oldest first (moderation.open_reports), without who reported.
create or replace function public.admin_open_reports(actor uuid)
returns table (
  source          text,
  reported_at     timestamptz,
  hours_open      numeric,
  overdue         boolean,
  reason          text,
  reported_id     uuid,
  reported_handle text,
  reported_name   text,
  content         text,
  reference       text,
  suspended       boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin(actor);
  return query
    select r.source, r.reported_at, r.hours_open, r.overdue, r.reason, r.reported_id,
           r.reported_handle, p.display_name, r.content, r.reference,
           private.is_suspended(r.reported_id)
    from moderation.open_reports r
    left join public.profiles p on p.id = r.reported_id
    order by r.reported_at
    limit 200;
end;
$$;

-- The members suspended right now, the newest suspension first: the only place the
-- app can find them, because everyone else (an admin too) no longer sees their profile.
create or replace function public.admin_suspended_members(actor uuid)
returns table (
  user_id      uuid,
  handle       text,
  display_name text,
  reason       text,
  suspended_at timestamptz,
  until        timestamptz,
  suspended_by text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin(actor);
  return query
    select s.user_id, p.handle::text, p.display_name, s.reason, s.suspended_at, s.until, s.suspended_by
    from moderation.suspensions s
    left join public.profiles p on p.id = s.user_id
    where s.lifted_at is null
      and (s.until is null or s.until > now())
    order by s.suspended_at desc
    limit 200;
end;
$$;

-- Suspends [target] for [days] days (null: until reinstated), as moderation.suspend_member,
-- records which admin did it and closes the open reports about the member as actioned.
-- Answers how many reports it closed.
create or replace function public.admin_suspend_member(actor uuid, target uuid, why text, days integer default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  cleaned text := btrim(coalesce(why, ''));
begin
  perform private.require_admin(actor);
  if target is null or cleaned = '' or length(cleaned) > 500
     or (days is not null and days not between 1 and 3650) then
    raise exception 'bad_input' using errcode = 'CP400';
  end if;
  if not exists (select 1 from auth.users u where u.id = target) then
    raise exception 'no_such_member' using errcode = 'CP404';
  end if;
  if exists (select 1 from moderation.admins a where a.user_id = target) then
    raise exception 'member_is_admin' using errcode = 'CP409';
  end if;

  perform moderation.suspend_member(target, cleaned, days);
  update moderation.suspensions s
     set suspended_by = 'admin:' || actor::text
   where s.user_id = target and s.lifted_at is null;
  return moderation.close_reports_about(target, 'actioned', 'admin ' || actor::text || ': suspended, ' || left(cleaned, 200));
end;
$$;

-- Lifts every suspension of [target].
create or replace function public.admin_reinstate_member(actor uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_admin(actor);
  if target is null then
    raise exception 'bad_input' using errcode = 'CP400';
  end if;
  perform moderation.reinstate_member(target);
end;
$$;

-- Marks every open report about [target] handled: [result] is 'actioned' or 'dismissed'.
-- Answers how many it closed.
create or replace function public.admin_close_reports(actor uuid, target uuid, result text, note text default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_admin(actor);
  if target is null or result is null or result not in ('actioned', 'dismissed') then
    raise exception 'bad_input' using errcode = 'CP400';
  end if;
  return moderation.close_reports_about(
    target,
    result,
    'admin ' || actor::text || coalesce(': ' || nullif(left(btrim(note), 200), ''), '')
  );
end;
$$;

revoke all on function public.is_member_admin(uuid) from public, anon, authenticated;
revoke all on function public.admin_open_reports(uuid) from public, anon, authenticated;
revoke all on function public.admin_suspended_members(uuid) from public, anon, authenticated;
revoke all on function public.admin_suspend_member(uuid, uuid, text, integer) from public, anon, authenticated;
revoke all on function public.admin_reinstate_member(uuid, uuid) from public, anon, authenticated;
revoke all on function public.admin_close_reports(uuid, uuid, text, text) from public, anon, authenticated;

grant execute on function public.is_member_admin(uuid) to service_role;
grant execute on function public.admin_open_reports(uuid) to service_role;
grant execute on function public.admin_suspended_members(uuid) to service_role;
grant execute on function public.admin_suspend_member(uuid, uuid, text, integer) to service_role;
grant execute on function public.admin_reinstate_member(uuid, uuid) to service_role;
grant execute on function public.admin_close_reports(uuid, uuid, text, text) to service_role;

notify pgrst, 'reload schema';

-- Fail loudly if the result is not what this file promises.
do $$
declare
  fn regprocedure;
begin
  if has_table_privilege('anon', 'moderation.admins', 'select')
     or has_table_privilege('authenticated', 'moderation.admins', 'select')
     or has_table_privilege('authenticated', 'moderation.admins', 'insert') then
    raise exception 'moderation.admins must not be reachable by members';
  end if;
  if has_function_privilege('anon', 'public.am_i_admin()'::regprocedure, 'execute')
     or not has_function_privilege('authenticated', 'public.am_i_admin()'::regprocedure, 'execute') then
    raise exception 'public.am_i_admin has the wrong grants';
  end if;
  foreach fn in array array[
    'public.is_member_admin(uuid)'::regprocedure,
    'public.admin_open_reports(uuid)'::regprocedure,
    'public.admin_suspended_members(uuid)'::regprocedure,
    'public.admin_suspend_member(uuid, uuid, text, integer)'::regprocedure,
    'public.admin_reinstate_member(uuid, uuid)'::regprocedure,
    'public.admin_close_reports(uuid, uuid, text, text)'::regprocedure,
    'private.is_admin(uuid)'::regprocedure,
    'private.require_admin(uuid)'::regprocedure
  ] loop
    if has_function_privilege('anon', fn, 'execute')
       or has_function_privilege('authenticated', fn, 'execute') then
      raise exception '% must not be callable by members', fn;
    end if;
  end loop;
  foreach fn in array array[
    'public.is_member_admin(uuid)'::regprocedure,
    'public.admin_open_reports(uuid)'::regprocedure,
    'public.admin_suspended_members(uuid)'::regprocedure,
    'public.admin_suspend_member(uuid, uuid, text, integer)'::regprocedure,
    'public.admin_reinstate_member(uuid, uuid)'::regprocedure,
    'public.admin_close_reports(uuid, uuid, text, text)'::regprocedure
  ] loop
    if not has_function_privilege('service_role', fn, 'execute') then
      raise exception 'The admin-moderation function must be able to call %', fn;
    end if;
  end loop;
end;
$$;
