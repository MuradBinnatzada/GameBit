-- New accounts could not be created: "Database error saving new user" (HTTP 500).
--
-- `handle_new_user()` makes the profile of every new auth user. It was written in the
-- dashboard (no earlier file creates it) with `search_path = public` and a cast of the
-- new handle to `citext`. 20261022190000_advisor_cleanup.sql moved the `citext`
-- extension out of `public` into `extensions` ("no function with a `public`
-- search_path compares a handle", it said, which missed this cast), and from then on
-- the cast failed with `type "citext" does not exist`, so every sign-up, by email or
-- Google, was refused. Accounts that existed kept working.
--
-- This replaces the function, so that it is also in the repository, with:
--   * no `search_path` to depend on (everything it uses is schema-qualified), and no
--     cast at all: a text value goes into the citext column by assignment, wherever
--     the extension lives;
--   * the name cleaned like any new profile (20261028235500_moderation_and_blocking.sql):
--     a name from Google, or the start of an email address, that the chat rules refuse
--     becomes "Player". That trigger lets this function's own insert pass (it runs as
--     the table owner), so the check has to be here;
--   * blank names skipped (`full_name` empty, an email with nothing before the @);
--   * no `updated_at`: the live table has that column (made in the dashboard, with its
--     own trigger), a database built from these files does not, and the trigger stamps
--     the update by itself.
-- The profile it makes is otherwise what it was: the id, the name, a handle of
-- `player_` and ten characters of the id, and the photo Google or Apple sent.
--
-- The trigger is created here too (it was also made in the dashboard), identical to the
-- live one, so a database built from these files has it.

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
  on conflict (id) do update
    set display_name = excluded.display_name,
        avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url);
  return new;
end;
$$;

-- A trigger function is not an API (20261022190000_advisor_cleanup.sql).
revoke all on function public.handle_new_user() from public, anon, authenticated;

create or replace trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
