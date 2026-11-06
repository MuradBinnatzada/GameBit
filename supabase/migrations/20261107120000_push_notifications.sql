-- Push notifications (Firebase Cloud Messaging): wishlist price drops and replies to a
-- member's discussion threads.
--
-- How it fits together
--   * The app registers its FCM token with `register_push_device` when the member turns
--     push on in Settings > Notifications, and removes it with `unregister_push_device`
--     when they turn it off or sign out. One token belongs to one member: registering it
--     again (another member signs in on the same phone) moves it.
--   * What to be told about is in `notification_settings` (own row; both switches are on
--     until the member turns them off).
--   * Something worth telling goes into `notification_outbox`, a queue only the service
--     role reads:
--       - a reply to a thread: the trigger `discussion_posts_notify` below, at most one
--         notification per thread and member every 10 minutes;
--       - a price drop: the `check-prices` function, every 3 hours (it asks IsThereAnyDeal
--         about the wishlist games of members who have a device, and remembers what it
--         told each member in `price_alert_state`, so a sale is announced once).
--   * The `send-notifications` function drains the queue every minute and sends each
--     message through FCM, in the language of the device.
--
-- Everything here goes with the account (on delete cascade), so delete-account needs no
-- change. Nothing but the service role reads the devices, the queue or the alert state;
-- a member can only read and write their own two switches.
--
-- ONE-TIME SETUP, after this migration:
--   Vault (SQL editor): the two secrets the schedule calls with. If background_steam_sync
--   set them up already, only compare cron_secret with the function secret below.
--     select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
--     select vault.create_secret('<a long random string>',            'cron_secret');
--   shell:   supabase secrets set CRON_SECRET=<the same string>
--            supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
--            (the Firebase project's service account key: Project settings > Service
--            accounts > Generate new private key), and ITAD_API_KEY for the price check.
--   deploy:  supabase functions deploy send-notifications check-prices
-- The two functions have `verify_jwt = false` (supabase/config.toml): the schedule has no
-- user session, and the new publishable API keys are not JWTs, so the gateway could not
-- check them. What lets a call in is the `x-cron-secret` header, checked inside the function.
-- Until FCM_SERVICE_ACCOUNT exists the functions answer NOT_CONFIGURED and the queue just
-- grows (the rows are kept for 7 days, then dropped).
--
-- Pause it:   select cron.unschedule('push-send');  select cron.unschedule('push-price-check');
-- Look at it: select * from cron.job_run_details order by start_time desc limit 20;
--             select id, user_id, kind, attempts, sent_at from public.notification_outbox order by id desc limit 20;

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- 1. Devices -----------------------------------------------------------------------

create table if not exists public.push_devices (
  token      text primary key
    constraint push_devices_token_check check (char_length(token) between 20 and 4096),
  user_id    uuid not null references auth.users (id) on delete cascade,
  platform   text not null
    constraint push_devices_platform_check check (platform in ('android', 'ios')),
  -- The device's language (two letters), which the message is written in, and its
  -- region, which picks the currency prices are looked up in.
  language   text not null default 'en'
    constraint push_devices_language_check check (language ~ '^[a-z]{2}$'),
  country    text not null default 'US'
    constraint push_devices_country_check check (country ~ '^[A-Z]{2}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists push_devices_user_idx on public.push_devices (user_id, updated_at desc);

alter table public.push_devices enable row level security;
revoke all on public.push_devices from public, anon, authenticated;
grant select, insert, update, delete on public.push_devices to service_role;

comment on table public.push_devices is
  'FCM tokens of the phones that asked for push notifications, one member each. Written by register_push_device; read by the service role only.';

-- Registers (or moves) the caller's device. At most 10 devices a member: the least
-- recently registered go.
create or replace function public.register_push_device(
  device_token text,
  device_platform text,
  device_language text default 'en',
  device_country text default 'US'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := (select auth.uid());
begin
  if me is null or not (select public.mfa_satisfied()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  insert into public.push_devices as d (token, user_id, platform, language, country)
  values (device_token, me, device_platform, lower(device_language), upper(device_country))
  on conflict (token) do update
    set user_id = me,
        platform = excluded.platform,
        language = excluded.language,
        country = excluded.country,
        updated_at = now();

  delete from public.push_devices
   where user_id = me
     and token in (
       select p.token from public.push_devices p
        where p.user_id = me
        order by p.updated_at desc, p.token
        offset 10
     );
end;
$$;

revoke all on function public.register_push_device(text, text, text, text) from public, anon;
grant execute on function public.register_push_device(text, text, text, text) to authenticated;

-- Forgets the caller's device (the member turned push off, or signed out).
create or replace function public.unregister_push_device(device_token text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.push_devices
   where token = device_token
     and user_id = (select auth.uid());
$$;

revoke all on function public.unregister_push_device(text) from public, anon;
grant execute on function public.unregister_push_device(text) to authenticated;

-- 2. What a member wants to hear about ---------------------------------------------

create table if not exists public.notification_settings (
  user_id        uuid primary key references auth.users (id) on delete cascade,
  price_drops    boolean not null default true,
  thread_replies boolean not null default true,
  updated_at     timestamptz not null default now()
);

alter table public.notification_settings enable row level security;
revoke all on public.notification_settings from public, anon, authenticated;
grant select, insert, update on public.notification_settings to authenticated;
grant select, insert, update, delete on public.notification_settings to service_role;

drop policy if exists notification_settings_select_own on public.notification_settings;
create policy notification_settings_select_own
  on public.notification_settings
  for select
  to authenticated
  using (user_id = (select auth.uid()) and (select public.mfa_satisfied()));

drop policy if exists notification_settings_insert_own on public.notification_settings;
create policy notification_settings_insert_own
  on public.notification_settings
  for insert
  to authenticated
  with check (user_id = (select auth.uid()) and (select public.mfa_satisfied()));

drop policy if exists notification_settings_update_own on public.notification_settings;
create policy notification_settings_update_own
  on public.notification_settings
  for update
  to authenticated
  using (user_id = (select auth.uid()) and (select public.mfa_satisfied()))
  with check (user_id = (select auth.uid()) and (select public.mfa_satisfied()));

comment on table public.notification_settings is
  'Which push notifications a member wants (both on until they turn one off). Own row only; no row means both on.';

-- 3. The queue ---------------------------------------------------------------------

create table if not exists public.notification_outbox (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  kind        text not null
    constraint notification_outbox_kind_check check (kind in ('price_drop', 'thread_reply')),
  -- What the message is about (ids and the few words it quotes), not its text: the
  -- sender writes it in the device's language.
  data        jsonb not null default '{}'::jsonb,
  -- A notification waiting to be sent with the same key as another waiting one is the
  -- same notification (several replies before the first went out).
  dedupe_key  text,
  created_at  timestamptz not null default now(),
  claimed_at  timestamptz,
  sent_at     timestamptz,
  attempts    integer not null default 0
);

create unique index if not exists notification_outbox_waiting_key
  on public.notification_outbox (user_id, dedupe_key)
  where dedupe_key is not null and sent_at is null;
create index if not exists notification_outbox_waiting_idx
  on public.notification_outbox (id) where sent_at is null;
create index if not exists notification_outbox_recent_idx
  on public.notification_outbox (user_id, dedupe_key, created_at desc) where dedupe_key is not null;

alter table public.notification_outbox enable row level security;
revoke all on public.notification_outbox from public, anon, authenticated;
grant select, insert, update, delete on public.notification_outbox to service_role;

comment on table public.notification_outbox is
  'Push notifications waiting to be sent (and, for a week, the ones sent). Service role only.';

-- What the sender takes next: up to batch_size waiting notifications (not claimed in the
-- last 5 minutes, tried fewer than 5 times), marked claimed so two runs never send the
-- same one. Rows older than 7 days are dropped.
create or replace function public.claim_notifications(batch_size integer default 100)
returns table (id bigint, user_id uuid, kind text, data jsonb, attempts integer)
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.notification_outbox o where o.created_at < now() - interval '7 days';

  return query
  update public.notification_outbox o
     set claimed_at = now(),
         attempts = o.attempts + 1
   where o.id in (
     select w.id
       from public.notification_outbox w
      where w.sent_at is null
        and w.attempts < 5
        and (w.claimed_at is null or w.claimed_at < now() - interval '5 minutes')
      order by w.id
      limit greatest(1, least(batch_size, 500))
      for update skip locked
   )
  returning o.id, o.user_id, o.kind, o.data, o.attempts;
end;
$$;

revoke all on function public.claim_notifications(integer) from public, anon, authenticated;
grant execute on function public.claim_notifications(integer) to service_role;

-- 4. Replies to a thread -------------------------------------------------------------

create or replace function public.discussion_posts_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  owner_id uuid;
  owner_title text;
begin
  -- Never in the way of a post: whatever goes wrong here costs a notification only.
  begin
    select t.author_id, t.title into owner_id, owner_title
      from public.discussion_threads t
     where t.id = new.thread_id;

    -- Nobody is told of their own reply.
    if owner_id is null or owner_id = new.author_id then
      return null;
    end if;
    -- Nor of the reply of a member they blocked, or who blocked them.
    if exists (
      select 1 from public.user_blocks b
       where (b.blocker_id = owner_id and b.blocked_id = new.author_id)
          or (b.blocker_id = new.author_id and b.blocked_id = owner_id)
    ) or private.is_suspended(new.author_id) then
      return null;
    end if;
    if not coalesce((select s.thread_replies from public.notification_settings s where s.user_id = owner_id), true) then
      return null;
    end if;
    -- Nothing queued for a member with no phone to tell.
    if not exists (select 1 from public.push_devices d where d.user_id = owner_id) then
      return null;
    end if;
    -- At most one a thread every 10 minutes.
    if exists (
      select 1 from public.notification_outbox o
       where o.user_id = owner_id
         and o.dedupe_key = 'reply:' || new.thread_id
         and o.created_at > now() - interval '10 minutes'
    ) then
      return null;
    end if;

    insert into public.notification_outbox (user_id, kind, data, dedupe_key)
    values (
      owner_id,
      'thread_reply',
      jsonb_build_object(
        'thread_id', new.thread_id,
        'thread_title', left(owner_title, 120),
        'from_id', new.author_id
      ),
      'reply:' || new.thread_id
    )
    on conflict do nothing;
  exception when others then
    raise warning 'discussion_posts_notify: %', sqlerrm;
  end;
  return null;
end;
$$;

revoke all on function public.discussion_posts_notify() from public, anon, authenticated;

drop trigger if exists discussion_posts_notify on public.discussion_posts;
create trigger discussion_posts_notify
  after insert on public.discussion_posts
  for each row execute function public.discussion_posts_notify();

-- 5. Price drops ---------------------------------------------------------------------

-- What the member was last told about each wishlist game, so a sale is announced once.
create table if not exists public.price_alert_state (
  user_id     uuid not null references auth.users (id) on delete cascade,
  game_id     uuid not null references public.games (id) on delete cascade,
  last_price  numeric(12, 2) not null,
  currency    text not null,
  notified_at timestamptz not null default now(),
  primary key (user_id, game_id)
);

alter table public.price_alert_state enable row level security;
revoke all on public.price_alert_state from public, anon, authenticated;
grant select, insert, update, delete on public.price_alert_state to service_role;

comment on table public.price_alert_state is
  'The price a member was last notified of for a wishlist game (check-prices). Service role only.';

-- The wishlist games to look at: one row for each (member, game) of a member who has a
-- phone registered and price drops on, with the region of their latest phone. Not the
-- members suspended.
create or replace function public.price_alert_candidates(max_rows integer default 20000)
returns table (user_id uuid, game_id uuid, country text)
language sql
stable
security definer
set search_path = ''
as $$
  select ug.user_id, ug.game_id, dev.country
    from public.user_games ug
    join lateral (
      select d.country
        from public.push_devices d
       where d.user_id = ug.user_id
       order by d.updated_at desc
       limit 1
    ) dev on true
    left join public.notification_settings s on s.user_id = ug.user_id
   where ug.status = 'wishlist'
     and coalesce(s.price_drops, true)
     and not private.is_suspended(ug.user_id)
   order by ug.user_id, ug.game_id
   limit greatest(1, least(max_rows, 100000));
$$;

revoke all on function public.price_alert_candidates(integer) from public, anon, authenticated;
grant execute on function public.price_alert_candidates(integer) to service_role;

-- 6. The schedule --------------------------------------------------------------------
-- Calls an Edge Function with the Vault secrets project_url and cron_secret (see the setup
-- above). Returns the pg_net request id, or null when they are not set up yet. No API key
-- goes with the call: these functions are not behind the gateway's JWT check.
create or replace function public.invoke_push_function(function_name text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  project_url text;
  cron_secret text;
begin
  select decrypted_secret into project_url from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into cron_secret from vault.decrypted_secrets where name = 'cron_secret';

  if coalesce(project_url, '') = '' or coalesce(cron_secret, '') = '' then
    raise warning 'invoke_push_function: Vault secrets project_url and cron_secret must both be set; skipping this run';
    return null;
  end if;

  return net.http_post(
    url := rtrim(project_url, '/') || '/functions/v1/' || function_name,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', cron_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
end;
$$;

revoke all on function public.invoke_push_function(text) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'push-send') then
    perform cron.unschedule('push-send');
  end if;
  perform cron.schedule('push-send', '* * * * *', $job$select public.invoke_push_function('send-notifications')$job$);

  if exists (select 1 from cron.job where jobname = 'push-price-check') then
    perform cron.unschedule('push-price-check');
  end if;
  perform cron.schedule('push-price-check', '17 */3 * * *', $job$select public.invoke_push_function('check-prices')$job$);
end;
$$;
