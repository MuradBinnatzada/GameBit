-- A new account had a public profile before its email address was confirmed.
--
-- `handle_new_user()` made the profile when the auth user was inserted. With email
-- confirmation on, that is at sign-up, before the link in the email is opened, so the
-- profile was in `public_profiles` (member search, follower lists, discussions, ...)
-- for anyone to find, under an address nobody had proved was theirs.
--
-- The profile is now made when the address is confirmed, and not before:
--   * `on_auth_user_created` fires only for a user inserted already confirmed, which
--     is what Google and Apple sign-ins are (the provider vouches for the address);
--   * `on_auth_user_confirmed` is new: it fires when `email_confirmed_at` goes from null
--     to a value, i.e. when the link in the email is opened. That update is in the same
--     transaction as the sign-in it allows, so the profile exists before the app has
--     its session. A sign-in by Google to an address that had an unconfirmed email
--     account confirms it too, and takes the same path.
-- No policy or view changed: every place that lists members reads `profiles`, and an
-- unconfirmed account now has no row there. The app's own `ensureProfile` still makes
-- the row if it is ever missing, but only with a session, which an unconfirmed email
-- account cannot get.
--
-- The function is the one of 20261101010000_fix_new_user_trigger.sql, with one change.
-- `on conflict` used to overwrite the name and photo of a profile that already existed.
-- Now that the function can run on an update, that could undo a member's own edits (a
-- row can only exist already for an account made before this migration), so it leaves
-- an existing row alone. On an insert the row cannot exist (it references the user).
--
-- Profiles that exist now for accounts that never confirmed are removed: they are what
-- anyone could find. Only accounts that never signed in are touched, so nobody who has
-- used the app loses theirs, and the profile of an account that confirms later is made
-- by the trigger above with the same id, name and handle. Nothing else references
-- `profiles` (the other tables point at `auth.users`), so nothing cascades.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  shown text;
begin
  shown := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    nullif(btrim(split_part(coalesce(new.email, ''), '@', 1)), ''),
    'Player'
  );
  if private.breaks_chat_rules(shown) then
    shown := 'Player';
  end if;

  insert into public.profiles (id, display_name, handle, avatar_url)
  values (
    new.id,
    shown,
    'player_' || substr(replace(new.id::text, '-', ''), 1, 10),
    coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- A trigger function is not an API (20261022190000_advisor_cleanup.sql).
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- `create or replace` rather than drop and create: replacing needs only the TRIGGER
-- privilege on `auth.users`, dropping needs to own it, and the migration of
-- 20261101010000_fix_new_user_trigger.sql already replaced this trigger that way.
create or replace trigger on_auth_user_created
  after insert on auth.users
  for each row
  when (new.email_confirmed_at is not null)
  execute function public.handle_new_user();

create or replace trigger on_auth_user_confirmed
  after update on auth.users
  for each row
  when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function public.handle_new_user();

delete from public.profiles p
using auth.users u
where u.id = p.id
  and u.email_confirmed_at is null
  and u.last_sign_in_at is null;
