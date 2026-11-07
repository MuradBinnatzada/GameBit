-- Notifications of one discussion: mute it, or follow it.
--
-- By default (no row) a member is told of a reply to one of their posts, and, if they
-- started the thread, of every reply in it (20261107120000, 20261107140000). A row in
-- `thread_notification_modes` changes that for one thread:
--   * `muted`: nothing from this thread, not even a reply to their own post;
--   * `following`: every new reply in the thread, whoever it answers (the opt-in for
--     members who did not start it).
-- Both still follow the member's "Replies" switch (`notification_settings.thread_replies`),
-- the blocks, the 10-minute throttle and the need for a registered phone. A reply tells
-- at most 200 followers (whichever 200 the database finds first), so one popular thread
-- can't make a post slow.
--
-- Own rows only. Rows go with the account and with the thread (on delete cascade).

create table if not exists public.thread_notification_modes (
  user_id    uuid not null references auth.users (id) on delete cascade,
  thread_id  uuid not null references public.discussion_threads (id) on delete cascade,
  mode       text not null
    constraint thread_notification_modes_mode_check check (mode in ('following', 'muted')),
  updated_at timestamptz not null default now(),
  primary key (user_id, thread_id)
);

create index if not exists thread_notification_followers_idx
  on public.thread_notification_modes (thread_id) where mode = 'following';

alter table public.thread_notification_modes enable row level security;
revoke all on public.thread_notification_modes from public, anon, authenticated;
grant select, insert, update, delete on public.thread_notification_modes to authenticated;
grant select, insert, update, delete on public.thread_notification_modes to service_role;

drop policy if exists thread_notification_modes_select_own on public.thread_notification_modes;
create policy thread_notification_modes_select_own
  on public.thread_notification_modes
  for select
  to authenticated
  using (user_id = (select auth.uid()) and (select public.mfa_satisfied()));

drop policy if exists thread_notification_modes_insert_own on public.thread_notification_modes;
create policy thread_notification_modes_insert_own
  on public.thread_notification_modes
  for insert
  to authenticated
  with check (user_id = (select auth.uid()) and (select public.mfa_satisfied()));

drop policy if exists thread_notification_modes_update_own on public.thread_notification_modes;
create policy thread_notification_modes_update_own
  on public.thread_notification_modes
  for update
  to authenticated
  using (user_id = (select auth.uid()) and (select public.mfa_satisfied()))
  with check (user_id = (select auth.uid()) and (select public.mfa_satisfied()));

drop policy if exists thread_notification_modes_delete_own on public.thread_notification_modes;
create policy thread_notification_modes_delete_own
  on public.thread_notification_modes
  for delete
  to authenticated
  using (user_id = (select auth.uid()) and (select public.mfa_satisfied()));

comment on table public.thread_notification_modes is
  'A member muting or following one discussion for push notifications (no row: the default). Own rows only.';

-- The same helper as in 20261107140000, with the mute added.
create or replace function private.queue_reply_notification(
  recipient uuid,
  p_thread uuid,
  p_title text,
  replier uuid,
  direct boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  key text := (case when direct then 'direct:' else 'reply:' end) || p_thread;
begin
  -- Nobody is told of their own reply.
  if recipient is null or recipient = replier then
    return;
  end if;
  -- Nothing from a discussion they muted.
  if exists (
    select 1 from public.thread_notification_modes m
     where m.user_id = recipient and m.thread_id = p_thread and m.mode = 'muted'
  ) then
    return;
  end if;
  -- Nor of the reply of a member they blocked, or who blocked them, or a suspended one.
  if exists (
    select 1 from public.user_blocks b
     where (b.blocker_id = recipient and b.blocked_id = replier)
        or (b.blocker_id = replier and b.blocked_id = recipient)
  ) or private.is_suspended(replier) then
    return;
  end if;
  if not coalesce((select s.thread_replies from public.notification_settings s where s.user_id = recipient), true) then
    return;
  end if;
  -- Nothing queued for a member with no phone to tell.
  if not exists (select 1 from public.push_devices d where d.user_id = recipient) then
    return;
  end if;
  -- At most one a thread and kind every 10 minutes.
  if exists (
    select 1 from public.notification_outbox o
     where o.user_id = recipient
       and o.dedupe_key = key
       and o.created_at > now() - interval '10 minutes'
  ) then
    return;
  end if;

  insert into public.notification_outbox (user_id, kind, data, dedupe_key)
  values (
    recipient,
    'thread_reply',
    jsonb_build_object(
      'thread_id', p_thread,
      'thread_title', left(p_title, 120),
      'from_id', replier,
      'direct', direct
    ),
    key
  )
  on conflict do nothing;
end;
$$;

revoke all on function private.queue_reply_notification(uuid, uuid, text, uuid, boolean) from public, anon, authenticated;

create or replace function public.discussion_posts_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner_id uuid;
  owner_title text;
  parent_author uuid;
  follower uuid;
begin
  -- Never in the way of a post: whatever goes wrong here costs a notification only.
  begin
    select t.author_id, t.title into owner_id, owner_title
      from public.discussion_threads t
     where t.id = new.thread_id;

    if new.reply_to is not null then
      select p.author_id into parent_author
        from public.discussion_posts p
       where p.id = new.reply_to and p.thread_id = new.thread_id;
    end if;

    -- The member answered hears of it as a reply to them ...
    perform private.queue_reply_notification(parent_author, new.thread_id, owner_title, new.author_id, true);
    -- ... the thread's starter of a reply in their thread, unless that is the same member ...
    if owner_id is distinct from parent_author then
      perform private.queue_reply_notification(owner_id, new.thread_id, owner_title, new.author_id, false);
    end if;
    -- ... and whoever follows the thread of every reply, if they are not told above.
    for follower in
      select m.user_id
        from public.thread_notification_modes m
       where m.thread_id = new.thread_id
         and m.mode = 'following'
         and m.user_id <> new.author_id
         and m.user_id is distinct from parent_author
         and m.user_id is distinct from owner_id
       limit 200
    loop
      perform private.queue_reply_notification(follower, new.thread_id, owner_title, new.author_id, false);
    end loop;
  exception when others then
    raise warning 'discussion_posts_notify: %', sqlerrm;
  end;
  return null;
end;
$$;

revoke all on function public.discussion_posts_notify() from public, anon, authenticated;
