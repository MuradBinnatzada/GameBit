-- Replying to a post. A reply can name the post it answers (`reply_to`): the screen shows
-- "Replying to <name>" with the start of that post, and the notification goes to that
-- member as well as to the thread's starter.
--
--   * discussion_posts.reply_to: the post answered, in the same thread (the `discussions`
--     function checks that; nothing else writes posts). When that post is deleted the
--     reply stays, with nothing quoted (on delete set null). No reply_to: the reply is to
--     the thread itself, as before.
--   * discussion_posts_page also answers who and what was replied to. The quote is left
--     out for the viewer when its author is hidden from them (blocked or suspended) or
--     the viewer reported that post, like the post itself.
--   * discussion_posts_notify (the push notification trigger, 20261107120000):
--       - the author of the post answered is told "replied to you" (data.direct = true);
--       - the thread's starter is told of the reply as before, unless they are that same
--         member (then they get the one, direct);
--       - nobody is told of their own reply, nor of one by a member they blocked or who
--         blocked them, and each follows the member's "Replies" switch, needs a phone and
--         is throttled to one every 10 minutes for each (thread, kind).
--
-- Deploy order: this migration, then the discussions function (it writes reply_to), then
-- the app. A build from before this shows the replies without the quote.

alter table public.discussion_posts
  add column if not exists reply_to uuid references public.discussion_posts (id) on delete set null;

create index if not exists discussion_posts_reply_to_idx
  on public.discussion_posts (reply_to) where reply_to is not null;

comment on column public.discussion_posts.reply_to is
  'The post of the same thread this reply answers; null for a reply to the thread itself, or when that post was deleted.';

-- 1. Reading a thread's replies ----------------------------------------------------

-- The result gains columns, which `create or replace` cannot do: drop and make it again
-- with the same body (20261028235500) plus the quote, and the same privileges.
drop function if exists public.discussion_posts_page(uuid, integer, integer);

create function public.discussion_posts_page(
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
  author_showcase text[],
  reply_to_id uuid,
  reply_to_author_name text,
  reply_to_excerpt text
)
language sql
stable
security definer
set search_path = ''
as $$
  select x.id, x.thread_id, x.body, x.created_at,
         p.id, p.handle::text, p.display_name::text, p.avatar_url::text,
         p.avatar_frame::text, p.showcased_milestones,
         q.id, q.name, q.excerpt
  from public.discussion_posts x
  join public.profiles p on p.id = x.author_id
  left join lateral (
    select r.id,
           coalesce(rp.display_name::text, '@' || rp.handle::text, '') as name,
           left(r.body, 140) as excerpt
      from public.discussion_posts r
      join public.profiles rp on rp.id = r.author_id
     where r.id = x.reply_to
       and r.author_id not in (select h from private.hidden_members() h)
       and not exists (
         select 1 from public.discussion_reports d
          where d.reporter_id = (select auth.uid()) and d.post_id = r.id)
  ) q on true
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

revoke all on function public.discussion_posts_page(uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.discussion_posts_page(uuid, integer, integer) to authenticated;

-- 2. Telling the member who was replied to ---------------------------------------------

-- Queues a "reply" notification for [recipient], unless one of the reasons not to
-- (see the trigger below) holds. [direct]: it is a reply to their own post.
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
    -- ... and the thread's starter of a reply in their thread, unless that is the same member.
    if owner_id is distinct from parent_author then
      perform private.queue_reply_notification(owner_id, new.thread_id, owner_title, new.author_id, false);
    end if;
  exception when others then
    raise warning 'discussion_posts_notify: %', sqlerrm;
  end;
  return null;
end;
$$;

revoke all on function public.discussion_posts_notify() from public, anon, authenticated;
