-- Removing reported content from the app.
--
-- 20261101020000_admin_moderation.sql let an admin suspend members and close reports
-- from the app; taking the content itself down was still done in the SQL editor
-- (supabase/MODERATION.md). This is the same set of steps behind one wrapper for the
-- `admin-moderation` function, the same way (the service role only, the actor's id
-- given and checked again by private.require_admin):
--
--   review   empties the text (moderation.remove_review); the rating and the game stay
--   thread   deletes it with its replies and the reports about it
--   reply    deletes it and the reports about it
--   list     deletes it and the reports about it
--   profile  wipes the name, handle, bio, photo and service names (moderation.clear_profile)
--
-- A review's reports and a profile's reports are not deleted with what they are about,
-- so they are closed as actioned with the admin in their outcome. Only the reports
-- about that one thing: the member's other reported content stays in the queue.
--
-- The content must belong to the member named, so a stale or mistaken queue entry can
-- never take down someone else's.
--
-- Errors, by SQLSTATE: CP400 bad input, CP403 the actor is not an admin, CP404 the
-- content (or member) is gone.

create or replace function public.admin_remove_content(actor uuid, kind text, ref_id uuid, target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  note text := 'admin ' || actor::text || ': removed';
  gone integer;
begin
  perform private.require_admin(actor);
  if target is null
     or kind is null
     or kind not in ('review', 'thread', 'reply', 'list', 'profile')
     or (kind <> 'profile' and ref_id is null) then
    raise exception 'bad_input' using errcode = 'CP400';
  end if;

  if kind = 'review' then
    if not exists (select 1 from public.user_games g where g.user_id = target and g.game_id = ref_id) then
      raise exception 'no_such_content' using errcode = 'CP404';
    end if;
    perform moderation.remove_review(target, ref_id);
    update public.review_reports r
       set status = 'actioned', handled_at = now(), outcome = note
     where r.review_user_id = target and r.game_id = ref_id and r.status = 'open';

  elsif kind = 'thread' then
    delete from public.discussion_threads t where t.id = ref_id and t.author_id = target;
    get diagnostics gone = row_count;
    if gone = 0 then
      raise exception 'no_such_content' using errcode = 'CP404';
    end if;

  elsif kind = 'reply' then
    delete from public.discussion_posts x where x.id = ref_id and x.author_id = target;
    get diagnostics gone = row_count;
    if gone = 0 then
      raise exception 'no_such_content' using errcode = 'CP404';
    end if;

  elsif kind = 'list' then
    delete from public.game_lists l where l.id = ref_id and l.user_id = target;
    get diagnostics gone = row_count;
    if gone = 0 then
      raise exception 'no_such_content' using errcode = 'CP404';
    end if;

  else
    if not exists (select 1 from public.profiles p where p.id = target) then
      raise exception 'no_such_content' using errcode = 'CP404';
    end if;
    perform moderation.clear_profile(target);
    update public.user_reports r
       set status = 'actioned', handled_at = now(), outcome = note
     where r.reported_id = target and r.subject in ('profile', 'avatar') and r.status = 'open';
  end if;
end;
$$;

revoke all on function public.admin_remove_content(uuid, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.admin_remove_content(uuid, text, uuid, uuid) to service_role;

notify pgrst, 'reload schema';

-- Fail loudly if the result is not what this file promises.
do $$
declare
  fn regprocedure := 'public.admin_remove_content(uuid, text, uuid, uuid)'::regprocedure;
begin
  if has_function_privilege('anon', fn, 'execute')
     or has_function_privilege('authenticated', fn, 'execute') then
    raise exception '% must not be callable by members', fn;
  end if;
  if not has_function_privilege('service_role', fn, 'execute') then
    raise exception 'The admin-moderation function must be able to call %', fn;
  end if;
end;
$$;
