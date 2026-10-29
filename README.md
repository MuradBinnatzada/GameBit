# Checkpoint

Your game library and playtime tracker. Build a library, log your hours, rate games, import your Steam library, and follow other players.

## Features

- Search games (powered by IGDB) and add them to your library, or browse the most popular, highest rated and newest releases
- Track status, playtime, ratings and reviews per game
- Log play sessions, backdate them, edit or delete them later, or time them with the live play timer
- Import your Steam library; new Steam playtime becomes play sessions on its own; achievement progress for every Steam game, on your profile and other members'
- Year in Review: your year of play by month, game, platform and genre
- Custom lists of games, private or public; "What should I play next?"; wishlist release alerts
- Export your library and sessions as CSV, and import a library from a CSV file
- Share links to games, profiles and public lists
- Follow other players and browse their libraries; discussion boards
- Report profiles, photos, lists, reviews and posts, and block members everywhere in the app (see *Moderation*)
- Offline support: the library is cached locally and edits made offline sync when you reconnect
- Sign in with Google, Apple (iOS) or an email and password, with optional two-factor authentication (an authenticator app)

## Tech stack

- **App:** Flutter / Dart (Android, iOS, web, desktop targets)
- **Backend:** [Supabase](https://supabase.com) (auth, Postgres, Edge Functions)
- **Edge Functions** (`supabase/functions`): `igdb-handler`, `game-news`, `discussions`, `sync-steam`, `sync-achievements`, `steam-link`, `delete-account`, `mfa-recovery`. Third-party API credentials (Twitch/IGDB, Steam) live server-side only.

## Project layout

```
lib/
  app/        app shell and root widget
  l10n/       the strings, one .arb file per language
  models/     data models
  screens/    home, search, library, game detail, profile
  services/   Supabase repository (checkpoint_repository.dart, its queries one file per
              topic in repository/), auth, IGDB, connectivity, local cache, offline
              edits, crash reporting
  state/      domain stores (auth, library, profile, ...); the library store's methods
              are in library_store.dart and in library_store/, one file per concern
  widgets/    shared UI
supabase/     config, migrations, edge functions, MODERATION.md (the moderator's runbook)
test/         unit and widget tests
docs/         landing page, privacy policy and terms of use
```

## Getting started

Prerequisites: the [Flutter SDK](https://docs.flutter.dev/get-started/install) (see `pubspec.yaml` for the required SDK version). The Linux desktop build also needs libsecret and jsoncpp (`sudo apt install libsecret-1-dev libjsoncpp-dev`), which `flutter_secure_storage` links against.

```bash
flutter pub get
flutter run
```

Run the tests:

```bash
flutter test
```

### CI/CD

GitHub Actions (`.github/workflows`):

- **CI** (`ci.yml`) runs `flutter analyze` and `flutter test` on every pull request and push to `main`, type-checks the Edge Functions with `deno check`, and runs the shared helpers' tests (`deno test supabase/functions/_shared/`).
- **Deploy Supabase** (`deploy-supabase.yml`) applies new migrations (`supabase db push`) and deploys the Edge Functions when `supabase/` changes on `main`, or when started by hand. It needs the repository secrets `SUPABASE_ACCESS_TOKEN` and `SUPABASE_DB_PASSWORD` and the variable `SUPABASE_PROJECT_ID`. It runs in the `production` environment, where you can require a reviewer before migrations touch the live database.

### Database migrations

`supabase/migrations` builds the whole database from nothing, in file-name order: `20261011000000_base_schema.sql` creates the tables the project started with (they were first made in the dashboard), and every later file builds on it. `supabase db reset` (locally) or `supabase db push` (a new project) applies them all.

A migration's name starts with its UTC timestamp, and `supabase db push` refuses a new file that sorts before one the database already has. Name new ones with `supabase migration new <what_it_does>`; CI (`ci.yml`, *Check migration names*) fails on a file dated in the future or two files with the same timestamp.

**One-time step for the live database.** Nine migrations used to be dated ahead (up to 2026-10-26) and were renamed to the dates they were written, and the base schema was added in front of them. The live database already has all of it, so its migration history is corrected without running anything:

```bash
supabase migration repair --status reverted 20261019120000 20261020120000 20261021120000 20261022120000 20261023120000 20261024110000 20261024120000 20261025120000 20261026120000
supabase migration repair --status applied 20261011000000 20261018140000 20261018150000 20261018160000 20261018170000 20261018180000 20261018190000 20261018200000 20261018210000 20261018220000
supabase db push --dry-run
```

The dry run should then list only the migrations from `20261019013500` on. Until the repair is done, the deploy workflow stops at its dry run without changing anything.

Four more (discussions, the advisor clean-up, the trigger function grants and the invoker views) were dated 2026-10-23 and renamed to 2026-10-22 after they were applied, so the same kind of repair is needed once:

```bash
supabase migration repair --status reverted 20261023120000 20261023130000 20261023140000 20261023150000
supabase migration repair --status applied 20261022165000 20261022190000 20261022195000 20261022200000
supabase db push --dry-run
```

The dry run should report that the remote database is up to date.

**The live database differs from the files in one place:** its `public_user_games` view had a `custom_cover_url` column the migrations never made. `20261019015200_completion_dates_reviews_release_dates.sql` drops and recreates the view, so it no longer has that column.

**Limits** (`20261019013500_value_limits_and_atomic_deletes.sql`): the database refuses hours below 0 or above 100 000, ratings outside 0 to 5, prices outside 0 to 100 000, reviews over 2 000 characters, session notes over 1 000, and sessions dated more than a day ahead; values already saved out of range were moved into it. Removing a game from the library is one call, `remove_library_game`, which deletes its sessions and the library row in one transaction (`clear_library` does the same for the whole library).

### Edge Function errors

The functions answer a failure with `{ "error": "...", "code": "...", "retry_after": 60 }` and a `Retry-After` header when waiting helps. The app turns the `code` into a message (`lib/services/sync_failure.dart`): rate limiting or downtime at Steam or IGDB shows **Sync Delayed** on the Profile tab, and a sync that IGDB only got part of the way through reports the games left for the next one in `delayed`.

### Rate limits

Steam, IGDB and Twitch answer HTTP 429 when they are over their limits. The functions retry a 429 with exponential backoff and jitter (`supabase/functions/_shared/backoff.ts`), waiting for the `Retry-After` the API sent when it is short. The waits are capped so a request never hangs: a search retries for about 3.5 s, an achievements load for 6 s. A limit that outlasts the retries is reported as `*_RATE_LIMITED` with `retry_after`, and `igdb-handler` then answers further searches from the same instance with that error for up to a minute without calling IGDB.

Each member also has limits of their own, so one account (or a script with its token) can't use up the shared quotas: 200 `igdb-handler` requests a minute, 10 manual Steam syncs an hour, 100 achievement loads in 10 minutes, 10 Steam sign-ins (`steam-link`) an hour, 60 `game-news` requests a minute, 5 new discussion threads an hour and 20 discussion replies in 10 minutes, 10 account deletion attempts an hour, 10 sets of new two-factor backup codes an hour and 5 tries of a backup code an hour (`mfa-recovery`; see *Security*) (`supabase/functions/_shared/rate_limit.ts`, counted in the database by `consume_rate_limit`). Over a limit a function answers `RATE_LIMITED` (429) with `retry_after`. A limiter that can't be reached lets the call through, except for backup code tries, which it refuses until it can count them again.

### Row ownership

`profiles`, `user_games`, `log_entries` and `social_follows` carry restrictive RLS policies for INSERT, UPDATE and DELETE (`20261017120000_enforce_row_ownership.sql`): a signed-in member can only write rows whose owner column is their own `auth.uid()`, whatever other policies exist on the table. The migration fails if a table ends up without them.

### Public profiles and followers

Tapping a member in **Search > Users** (or in a follower list) opens their profile, laid out like your own: photo, name, bio, followers and following (one screen with a tab for each), their favorites, latest play sessions, playtime, the four status boxes (each opens their library), hours per platform, a ratings chart and a short menu into their library, wishlist and follow lists. The accounts they connected are small icons above the bio, game profiles (Steam, PSN, Xbox, Nintendo) first, then social media (Discord, Instagram, Twitch); Steam, Xbox, PSN, Instagram and Twitch open the account, Discord copies the username. Your own Profile tab is the same page built from your live library, with **Edit Profile** and **Settings** under the counts and **Sign out** at the top right beside your name. You connect, rename and disconnect services (and sync your Steam library) under **Settings > Account > Connect accounts**; Steam is connected by signing in through Steam (see *Security*). Their **Library** screen is the same screen as yours (tabs per status with counts, search, platform filter, sorting, grid or list). The Followers and Following counts on your own Profile tab open the same two-tab screen.

All of it is read through views and functions that name their columns, never from the `profiles`, `user_games` or `log_entries` tables, which stay own-row only: `public_profiles`, `public_user_games`, `public_followers`, `public_following`, `public_recent_activity` and `public_profile_stats` (`20261017140000_public_profiles_and_social_graph.sql`, `20261017150000_public_connected_services.sql`, `20261018120000_public_profile_details.sql`, `20261018140000_instagram_twitch_accounts.sql`). What other signed-in members can see is listed in the migration headers and in `docs/privacy.html`: the profile header including bio, Steam ID, PSN id, Xbox gamertag and Discord, Instagram and Twitch usernames (the links need them), the library without purchase prices, and the latest sessions without their notes. Never exposed: email, purchase price, session notes. Achievements show as counts: the profile loads `public_achievement_totals` (unlocked out of all, over every game) and `public_achievement_summary` (every game with at least one achievement unlocked and how far they got, most complete first, up to 500), both read from count columns, never from the lists. Tapping a game opens its achievements in a dialog (search, all / unlocked / locked, Steam's share of players who have each one). The list comes from `public_game_achievements` when the one stored matches the game's counts, otherwise from Steam through `sync-achievements`, which may load another member's game too (see below). These are `SECURITY DEFINER` functions that need a signed-in caller, because RLS works on rows and letting members read each other's `user_games` rows would hand over the `achievements` column too.

**Where the `public_*` views live (`20261022200000_invoker_views_over_private_schema.sql`).** They have to run as their owner, because `profiles`, `user_games` and `log_entries` are own-row only. The definer views are in the `private` schema, which the API does not expose (never add it to the Exposed schemas), and `public.public_profiles`, `public_followers`, `public_following`, `public_user_games` and `public_recent_activity` are plain `security_invoker` views over them, so the app's requests and the Supabase advisor's "Security Definer View" check both see only the thin ones. To change a view's columns, `create or replace view private.<name>` and then `create or replace view public.<name> with (security_invoker = true) as select * from private.<name>`; a migration that makes the `public` one a definer view again brings the advisor's error back.

A game's screen has a **Friends** panel: which of the members you follow completed the game, are playing it or want to play it (To Play and Wishlist together), each as their photo (tap to open their profile) with the stars they gave, if any. It is one call to `following_game_activity` (`20261018170000_friends_on_game_screen.sql`), which returns up to 20 members per status, rated first, and the full count of each; it exposes nothing `public_user_games` doesn't already. Dropped is left out, and the panel is hidden when signed out or when none of them has the game.

Home has a **From people you follow** row: what the members you follow did lately, newest first, as the game's cover (tap to open the game) with the member's photo on its corner (tap to open their profile) and what they did: "+2h · 3h ago" for a session (the latest of each game), "Completed", or "Rated 4.5" for a game rated but not completed. It is one call to `following_recent_activity` (`20261018220000_following_recent_activity.sql`), at most 30 items (the server caps it at 100), and exposes nothing `public_recent_activity` and `public_user_games` don't already. A completion or a rating carries no time on screen: the only date other members can see is when the game was added to the library, which is what orders them. `FriendsFeedStore` keeps it in memory, lets Home ask again once it is five minutes old, and drops it on sign-out; the row is hidden when signed out, when the request fails or when none of them did anything.

### Achievement counts

`user_games` keeps each Steam game's `achievements_unlocked` and `achievements_total` (`20261018160000_steam_achievement_counts.sql`). Every Steam sync (by hand or in the background) counts the games played since they were last counted, one `GetPlayerAchievements` request per game (Steam has no call that answers for many games with a Web API key), six at a time, most recently played first. `achievements_playtime` remembers the playtime at the count, so a game not played since is not asked about again. A sync counts at most 400 games (60 in the background) and stops starting new requests 125 s in (40 s in the background), on a Steam 429 or on a private profile; the rest is counted on the next sync, and counting never fails a sync. A trigger keeps the counts in step whenever a full list is written to `achievements`, and sets `achievements_synced_at`.

`sync-achievements` takes an optional `user_id`. With another member's id it loads that member's list for the game from the Steam ID on *their* profile (the request can't name a Steam ID), saves it on their row and answers it; a list fetched in the last 10 minutes is answered from the row without asking Steam, so viewers can't make it hammer Steam. That is what Steam shows anyone on their public Steam profile, and what `public_game_achievements` already hands out once stored. Apply the migration, then deploy `sync-steam` and `sync-achievements`, then ship the app. Existing members see every game after their next Steam sync.

The numbers on a profile (games per status, hours, hours per platform, the ratings chart) are worked out in the app by `LibraryStats` from a few columns of the member's library (a page of 500 at a time), the same code that serves your own profile. The member's whole library, with covers, is read only when their Library screen opens. The state lives in `PublicProfileStore`, `PublicLibraryStore`, `SocialGraphStore` and `PublicAchievementsStore` (`lib/state/`), which keep their data in memory only and drop it on sign-out; none of them touches `ProfileStore`.

Your own connected services are mirrored from the device to your `profiles` row (`connected_services`, `psn_id`, `xbox_id`, `discord_id`, `instagram_id`, `twitch_id`) by `ProfileStore`: the device list is saved first, and a change that can't be sent while offline is remembered (`accounts_pending.<user id>`) and sent when the connection is back. Otherwise the server's list is adopted on load, so a second device shows the same services. Apply the migrations before shipping a build that reads them.

### Background Steam sync

pg_cron calls `sync-steam` every 15 minutes (`20261017130000_background_steam_sync.sql`). It refreshes the libraries of members who have synced by hand before, were active in the last 30 days and are due (12 hours after their last sync; failures back off), ten per run. The job does nothing until you run the one-time setup at the top of that migration: three Vault secrets (`project_url`, `anon_key`, `cron_secret`) and the function secret `CRON_SECRET` with the same value as `cron_secret`. Pause it with `select cron.unschedule('sync-steam-background');`.

### Account deletion

**Settings > Account > Delete account** (required by the App Store and Google Play) asks for confirmation, then calls the `delete-account` Edge Function. It identifies the caller from their JWT and, using the service role, removes their avatar files, log entries, library, follows (both directions) and profile, clears `created_by` on catalog games they added (the games stay for other members), and finally deletes the Supabase auth user. The identity goes last, so a failure part way leaves an account that can still sign in and retry. The app then signs out and erases everything it held on the device for that account (saved copy, queued offline edits, service names). It needs no extra secrets.

**Game details.** Opening a game asks `igdb-handler` (`mode: "details"`, by IGDB id) for its whole page: the exact release platforms (PS3 and Xbox 360 are two platforms, as on IGDB), genres, themes, game modes, player perspectives, game engine, main developers, publishers, storyline and similar games. The details screen shows them, and the exact platforms and genres also replace what the library held, so "Played on" offers exactly the platforms the game is on. The stable part (platforms, genres, themes, modes, perspectives, engines, developers, publishers) is saved on the game's shared `games` row by the function, at most once a week, and the Library filters read it (next paragraph); storyline and similar games change over time and are only kept in memory. The time to beat panel shows the median of the times Checkpoint players reported (once enough have) and links to the game on HowLongToBeat. It is a link only: HowLongToBeat (Ziff Davis) forbids automated access to its data (`robots.txt` disallows `/api` and says scraping needs written permission), so the app never fetches from it. Games nobody has opened yet (a library imported from Steam before this, say) are filled in the same way in the background: after the library loads, and after a Steam sync, the app lists the library games whose `games` row was never filled in (`igdb_synced_at` is NULL, a separate query that returns only those ids, so the library payload does not grow) and sends them to `igdb-handler` (`mode: "backfill"`, up to 50 IGDB ids, one IGDB request) 25 at a time, two seconds apart. The function writes each due row as `details` does and answers each game's exact platforms and genres, which the library shows right away. On `IGDB_RATE_LIMITED` / `IGDB_UNAVAILABLE` the app waits the `retry_after` it is given and carries on; any other failure ends the run until the next load (`lib/state/catalog_backfill.dart`). Apply `20261018150000_igdb_game_details.sql` and redeploy `igdb-handler` before shipping the app build; platform names live in `GamePlatform` (`lib/models/game.dart`) and must stay in step with `lib/services/game_api_service.dart` and `supabase/functions/_shared/platforms.ts`.

**Library filters.** The filter icon in the Library header (badged with how many things are picked) opens a sheet to narrow the library by platform (one), and by genre, theme, game mode, player perspective, engine, developer and publisher (any number of values of each: a game needs any one of an attribute's picked values and a match in every attribute picked). Each list holds only the values at least one of your games has, most common first with a count, and a long one (developers, publishers) shows its first values with "Show all" and a search box. What is picked shows as removable chips under the title, and the sheet and the empty state say so when picks leave games out. Genres and platforms are on the games the library already loads. Themes, modes, perspectives, engines, developers and publishers are not: adding six lists to every game would grow the library payload and the copy saved on the device (the part that is already slow to read) for something most visits never use. `LibraryAttributesStore` (`lib/state/library_attributes_store.dart`) reads them in one separate paged query (`CheckpointRepository.fetchLibraryAttributes`: `user_games` joined to `games` for the rows with `igdb_synced_at` set, those six columns only) the first time the sheet opens, keeps them in memory until the account changes, and reads again on the next open after `LibraryStore` reports that the server filled in rows (a game's screen opened, a backfill batch). A game whose row was never filled in has no values yet, so those filters leave it out; the sheet, the chip row and the empty state say how many games that is, and it shrinks as the background backfill and the game screens fill rows in. Another member's Library screen keeps its platform menu only.

### Play sessions

A session is logged from the Quick Log sheet (with **When** to backdate it), from **Log Hours** on a game (the difference becomes a session), or with the **play timer**: *Play it* in **What should I play?** starts it, and *Stop* (on the bar above the tabs) opens the session filled in with the time and when it started. The timer is kept on the device per account, so it keeps running while the app is closed. Tapping a session on a game's screen (or under *See all*) edits its hours, platform, day and note, or deletes it with Undo; the game's total moves with it. Edits and deletes made offline are kept and sent later, like any other edit (`PendingEdits.logEdits`, `logDeletes`).

**From Steam** (`20261019014800_steam_playtime_sessions.sql`, `supabase/functions/_shared/steam_sessions.ts`): `sync-steam` keeps the Steam playtime it saw on each library row (`steam_playtime_minutes`). When a later sync (by hand or the background one) sees more, it logs the difference as a session with `source = 'steam'`, dated when Steam says the game was last played; under 5 minutes waits for the next sync. The first playtime seen for a game is its history, so it is only recorded. Members can't set `source` themselves (a trigger keeps it).

### Year in Review

Profile > **Year in Review** works out a year on the device (`lib/models/year_review.dart`) from the sessions and the library: hours, sessions, games, days played, the longest streak, hours by month (with a table view), the most played games, platforms and genres, and the games completed that year. `user_games.completed_at` is kept by a trigger when a game is marked completed (`20261019015200_...`); games completed before it existed count in the year they were last played.

### Reviews, lists and the picker

**Reviews** (`20261022120000_game_reviews.sql`): a review (2 000 characters) under your rating on a game's screen, which every signed-in member can read. The game's **Reviews** panel shows the community rating (the average and how many gave each star, `game_review_stats`) and the first reviews, the members you follow first; **See all** opens every review (`game_reviews`, paged), ordered friends first, newest, highest or lowest rated, or only those of the members you follow. A review can be reported (spam, abuse or something else) or its author blocked: the report is written to `review_reports`, which nothing in the app reads back (moderators read it in `moderation.open_reports`, see *Moderation*), and the review no longer shows for the member who reported it. A review is refused when it has a word the chat rules refuse (SQLSTATE `CP422`). `user_games.reviewed_at` dates a review, kept by a trigger.

**Game news** (`game-news`): Home's **Game news** button opens the News screen. **Latest** is the gaming press for everyone, not only the games in the library: the function merges the public RSS feeds of IGN, Eurogamer, Rock Paper Shotgun, GameSpot, Kotaku, GamesRadar+, Nintendo Life and Push Square (for a Russian app, StopGame, Igromania, Playground.ru and 3DNews; `NEWS_SOURCES` in `supabase/functions/_shared/news.ts`), newest first, with a chip per outlet to narrow it. **My games** is Steam's own news (`ISteamNews/GetNewsForApp`, no key needed) for up to ten library games that have a Steam app id, the ones being played first. The app shows an outlet's name, a headline, the start of the story and a picture, and opens the outlet's own page for the rest; nothing is republished or stored. Each feed is fetched at most every 10 minutes per warm instance (Steam's news every 15) whoever asks, a feed that fails is retried after a minute with the copy held meanwhile, and a language none of whose outlets answer falls back to English. Only signed-in members can call it. It needs no secrets; it is deployed with the other functions.

**Discussions** (`20261022165000_discussions.sql`, the `discussions` function): the fifth tab, in the middle. Seven pre-made boards (General, Game talk, What should I play?, Help & tips, News talk, Off-topic, Checkpoint feedback; seeded in the migration, so the owner adds or renames one there, and the app shows its own translation of the ones it knows by id) hold threads that members start: a title and an opening text, optionally about a game (a game's screen has a **Game discussions** panel with a button to start one). Replies are flat, oldest first. A member reads through functions that leave out the threads and replies of members they blocked and what they reported (`discussion_threads_page`, `discussion_thread`, `discussion_posts_page`), reports a thread or a reply (spam, abuse, other: `discussion_reports`, write only, moderators read it in the dashboard), blocks a member (`user_blocks`, app-wide since `20261028235500_moderation_and_blocking.sql`, see *Moderation*) and deletes their own thread or reply. **Nobody writes a thread or a reply directly**: the tables have no privileges for members, and the `discussions` function does it with the service role after it has checked the member is signed in and past two-factor, **counted the rate limit** (5 threads an hour, 20 replies in 10 minutes; a refused post counts too), refused a post with **one of the worst words** (racial slurs and child-abuse phrases only, in Latin and Cyrillic letters and the usual ways around a filter; whole words, so "Pakistan" and "snigger" are fine; `_shared/discussion_filter.ts`, to extend it add a line there and an example to its test), more than 3 links, a wrong length or a repeat of the last post. The app shows the **chat rules** (five short lines, `ChatRulesSheet`) before a member's first post on a device, and from the tab's menu. A moderator removes a thread or reply by deleting its row in the dashboard (`supabase/MODERATION.md`), and sets `locked` or `pinned` on a thread there. Deleting an account removes the member's threads, replies, reports and blocks. Apply the migration and deploy `discussions` before shipping the app build.

**Lists** (`20261019115300_game_lists.sql`): Profile > **Lists**, and the list button on a game's screen. A list holds any catalog game, in the order you drag them into; a public list shows on your profile and opens from a link for any signed-in member, a private one is yours only. 100 lists per member and 500 games per list. Lists need a connection (they aren't kept offline); an edit the server refuses is put back with a message. `merge_game_into` moves list entries when it folds a duplicate game.

**What should I play?** (Home): picks a game at random from your To Play and Playing games (or the statuses and platform you choose), never the same one twice in a row; *Play it* marks it Playing and starts the timer.

### Wishlist release alerts

`games.release_date` holds the day IGDB gives for a game's first release, written by `igdb-handler` and `sync-steam` with the rest of the catalog row and by the app when it adds a game from search. Home's **Wishlist Releases** row shows wishlist games out in the last 14 days or coming in the next 60, and the app says once (per release, per device) when one came out. Release dates move, so the background catalog fill-in also re-asks for wishlist and To Play games that aren't out yet once their row is a week old.

### Import and export

Settings > **Your data** saves the library and the play sessions as CSV files (any spreadsheet opens them), and imports a library file: Checkpoint's own export, or another tracker's with a `title` column and, optionally, status, rating (out of 5, 10 or 100), hours, platform and review. Each game is matched on IGDB by its id when the file has one, otherwise by its exact title (and year), a few a second; games already in the library are updated and their hours never go down. Imported hours log no sessions. What can't be matched is listed.

### Share links

Games, profiles and public lists have **Copy link**. A link is the web app's address with the target after `#` (`https://<web app>/#/game/1942`, `/#/u/<member id>`, `/#/list/<list id>`), so it needs no redirect rules on the host. The web app opens it on load; a profile or list asks to sign in first. The web build knows its own address; for the Android, iOS and desktop builds pass it with `--dart-define=CHECKPOINT_WEB_URL=https://<web app>` (without it they show no share buttons).

### Languages

The app is in English and Russian, and follows the device's language until the member picks one in Settings > Appearance > **Language** (saved on the device). Its strings are in `lib/l10n/app_<language>.arb`, with `app_en.arb` as the template; `flutter pub get` (and every build) generates `lib/l10n/generated/` from them. Widgets read them as `context.l10n.<message>`; stores, services and models, which have no `BuildContext`, read `L10n.current.<message>` (`lib/l10n/l10n.dart`). Plurals and selects are ICU messages, so each language says "1 game, 2 games" its own way, and dates and numbers follow the language through `intl` (`lib/utils/formatters.dart`). The layout uses start and end rather than left and right, so a right-to-left language mirrors.

**Adding a language** is a translation:

1. Copy `lib/l10n/app_en.arb` to `app_<code>.arb` (`de`, `fr`...), set `@@locale`, and translate every value; `languageName` is the language's own name ("Deutsch"), which the picker shows. Keep the `{placeholders}`, and give the plurals the forms the language has (`one`, `few`, `many`, `other`...).
2. Add the code to `CFBundleLocalizations` in `ios/Runner/Info.plist` and `macos/Runner/Info.plist`.

`test/l10n_test.dart` fails while a language misses a message or a placeholder; a message left out still shows in English. A new message goes into `app_en.arb` and every other `.arb`.

**What comes from elsewhere** follows the language too. Genres, themes, game modes and perspectives are IGDB's fixed lists, translated in the `.arb` files (`tagName` in `lib/models/filter_options.dart`); game and studio names stay as they are. Steam achievements come in Steam's own translation: `sync-achievements` takes the app's language (`lang`) and keeps each language's names on the stored list (`_shared/steam_languages.ts`). A game's summary and storyline and a studio's description are machine-translated by DeepL in `igdb-handler` (`_shared/deepl.ts`), once per text and language, and kept in `text_translations` (`20261020170000_text_translations.sql`), so every member gets the stored copy; the screen says so and offers the original. It needs a DeepL API key (the free plan's 500,000 characters a month go a long way, as each text is translated only once):

```bash
supabase db push
supabase secrets set DEEPL_API_KEY=<your key>
supabase functions deploy igdb-handler sync-achievements
```

Without the key the app shows IGDB's English text. Supabase's sign-in emails (confirm, reset password) are set up in the Supabase dashboard, not here, and are in English.

### Releasing

The app id is `com.checkpoint.mobileapp` on every platform. After changing it, update the Android and iOS OAuth clients in Google Cloud (package name and SHA-1, bundle id).

**Android signing.** Release builds are signed with the upload key named in `android/key.properties`, which is never committed. Make the key once and keep it (and its passwords) safe:

```bash
keytool -genkey -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then create `android/key.properties`:

```
storePassword=<the keystore password>
keyPassword=<the key password>
keyAlias=upload
storeFile=upload-keystore.jks
```

`storeFile` is relative to `android/app`. Without `key.properties`, `flutter build appbundle` stops with an error rather than signing the bundle with the debug key (a release APK still builds, debug-signed, for testing on a device).

**Sign in with Apple** (required by the App Store next to Google sign-in) is offered on iOS. In Xcode, give the Runner target your team and the *Sign in with Apple* capability (the entitlement is in `ios/Runner/Runner.entitlements`). In Supabase > Authentication > Providers > Apple, enable it and add `com.checkpoint.mobileapp` to its client IDs. Apple shares the member's name only on their first sign-in; the app saves it as their profile name.

## Moderation

`supabase/migrations/20261028235500_moderation_and_blocking.sql`, `supabase/functions/_shared/standing.ts`, `supabase/MODERATION.md` (the moderator's runbook, with the SQL to run), `docs/terms.html`. It answers App Store guideline 1.2: filter objectionable content, let members report it and block abusive members, and act on reports within 24 hours.

- **Filtering.** The discussions function refuses the worst words (racial slurs, child-abuse phrases; `_shared/discussion_filter.ts`). The same filter runs in the database (`private.breaks_chat_rules`) on the other public text: display name, handle, bio, the connected-service names, a review, a list's title and description. A save that fails is refused with `content_not_allowed` (SQLSTATE `CP422`, the field in the error's detail) and the app says so (`lib/services/content_refusal.dart`); a brand-new profile is cleaned instead (a Google or Apple name must not stop a sign-up). Text saved before the migration is not touched: `select * from moderation.flagged_text()` lists it. `filter_sql_test.ts` fails when the SQL patterns drift from the TypeScript filter.
- **Reporting.** Reviews (`review_reports`), discussion posts (`discussion_reports`) and now profiles, photos and public lists (`user_reports`, 20 an hour per member). Each report table has `status` (`open`, `actioned`, `dismissed`), `handled_at` and `outcome`; a member can insert but never set them. `moderation.open_reports` lists every open report, oldest first, with `hours_open` and `overdue` (past 24 hours).
- **Blocking is app-wide.** `discussion_blocks` became `user_blocks`. A block hides the member's profile, library, activity, reviews, public lists and discussion posts from the blocker (`private.hidden_members()` is the one place that says whom, used by the `public_*` wrapper views, `game_reviews`, `following_*`, the discussion functions and the `game_lists` policy), ends any follow between the two and stops the blocked member following back (silently, so a block isn't announced). Blocking is from a profile's menu, a review's menu and a discussion post's menu; `BlocksStore` keeps the list (**Settings > Privacy > Blocked members**) and tells the stores that hold members' data to drop theirs.
- **Suspending a member.** `moderation.suspend_member(id, reason, days)` records the suspension, bans the account in Supabase Auth (`banned_until`, so no sign-in and no token refresh), ends its sessions and hides it from everyone. A token issued before lasts up to an hour, so `public.mfa_satisfied()` (asked by every policy and member-facing function) is false for a suspended member, and the `discussions` function asks `public.is_member_suspended()`. A suspended member who tries to sign in is told so, with the contact address (`user_banned`). `moderation.reinstate_member(id)` undoes it. The `moderation` schema is out of reach of every client role and of the API.
- **Terms.** Sign-in shows "By continuing you agree to the Terms of Use and the Privacy Policy" with links, and Settings > Privacy has them and a way to write to us. The pages are served from `docs/`; the app finds them at `CHECKPOINT_DOCS_URL`.

## Security

What the server enforces, whatever a client sends (the anon key in `lib/main.dart` is public by design; these rules are what protect the data):

- **Row level security** on every table; members write only their own rows (see *Row ownership*), and other members' data is read only through views and functions that list their columns.
- **The game catalog is written by the server only** (`20261019132900_security_hardening.sql`): the app sends an IGDB id to `igdb-handler` (mode `add`), which builds the row from IGDB's answer, so nobody can put their own title or cover on a game everyone sees. Achievements and Steam playtime on a library row are also the server's; a member's writes to them are ignored.
- **Limits on what members type**: numbers, reviews and notes (*Database migrations*), and name, handle, bio and avatar on the profile. An avatar must be a photo uploaded to the project's `avatars` bucket, or a Google account photo, so a profile can't load an image from a server that logs who looks at it.
- **A Steam ID is proved, not typed** (`supabase/functions/steam-link`, `20261019134937_steam_id_from_steam_only.sql`). **Connect** on Steam opens "Sign in through Steam" (OpenID 2.0): `steam-link` hands the app Steam's page with a return address that carries a state it signed (the member's id, where to go next, 10 minutes to finish), and when Steam sends the browser back it checks the state and has Steam confirm the answer (`check_authentication`, sent to Steam's own address). With `STEAM_LINK_CONFIRM_URL` set, it saves nothing yet. It sends the browser to the confirm page (`web/steam-link.html`, served with the web app at that address) with a token it signed over the state and the SteamID64 from `openid.claimed_id`, carried after `#`, good for 5 minutes and never past the state. The page names the Checkpoint member the link was started from (handle and display name). It posts the token back only when the person who signed in to Steam presses **Link Steam**, and only then does the function save the ID with the service role, taking it off any other profile. Steam isn't asked a second time, because it confirms an answer once. Without `STEAM_LINK_CONFIRM_URL` (`supabase start`, a backend without the web app), the function saves the ID right after Steam confirms it, as it did before the confirm page existed. A member's own writes to `steam_id` are ignored (clearing it, which is Disconnect, still works), so nobody can import someone else's library and achievements by typing their ID. The web app goes to Steam and comes back to itself with `?steam_link=ok` or an error code; the desktop apps catch the return on a free `127.0.0.1` port; Android and iOS open Steam in an in-app browser tab and read the profile every few seconds until the ID is there (the app has no link scheme Steam could call it back on). `return_to` must be a loopback address or, with `ALLOWED_ORIGINS` set, one of its origins. Steam's return carries no Supabase token, so `supabase/config.toml` turns off the gateway's JWT check for this one function (`verify_jwt = false`, which `supabase functions deploy` reads); the function checks the token itself when a link starts. IDs saved before the migration were typed in and stay until their owner connects the account or the member disconnects; the migration header has the one-line update that makes everyone prove theirs. Someone who starts a link and gets you to finish Steam's sign-in on it, within its 10 minutes, no longer gets your Steam account that way. The confirm page shows their handle, not yours, with a warning, and nothing is saved unless you press **Link Steam**. What it can't stop: someone who links anyway, reading past another member's handle. Supabase serves a function's HTML as plain text on its own domain, so the page lives with the web app. **`STEAM_LINK_CONFIRM_URL` must be set wherever the web app is public**: without it there is no confirm step, and that trick works again. Set to anything but an https (or loopback http) address, Connect on Steam answers that it isn't available. With `ALLOWED_ORIGINS` set, the page's origin must be listed.
- **Two-factor authentication, opt-in** (`20261019135155_require_mfa.sql`, `supabase/functions/_shared/mfa.ts`). Settings > Security > **Authenticator app** turns on a code from an authenticator app (Supabase Auth MFA, TOTP): the setup shows a QR code and the setup key (copyable; on Android and iOS also an *Open in authenticator app* link) and checks the first code, and Supabase then signs the account out on its other devices. After every sign-in (email, Google, Apple, the desktop loopback, a reset link) the app asks for the code over everything (`lib/app/second_factor_gate.dart`) and treats the account as signed out until it is right; **Sign out** there works. The server holds the same line, so the prompt can't be skipped by calling the API with the token from the password alone: while an account with a verified factor has an `aal1` session, restrictive policies on `profiles`, `user_games`, `log_entries`, `social_follows`, `game_lists`, `game_list_items` and avatar uploads let it read and write nothing, the SECURITY DEFINER functions return nothing, and the Edge Functions answer `MFA_REQUIRED` (403). Turning it off asks first and needs a session that entered its code. Accounts without it see no change. App builds from before this change don't ask for the code, so an account that turns it on can't use them.
- **Two-factor backup codes** (`20261019204652_mfa_recovery_codes.sql`, `supabase/functions/mfa-recovery`, `supabase/functions/_shared/recovery_codes.ts`), so a member who loses their authenticator app isn't locked out. Right after the first code, the setup makes 10 one-time codes and shows them with **Copy** and **I saved them**; Settings > Security > **New backup codes** (shown while two-factor is on) replaces them after asking, and the old ones stop working. Making codes needs a session that entered its code (`MFA_REQUIRED` otherwise). A code is 10 characters from `crypto.getRandomValues` (Crockford base32, shown as `7K3QD-M9XHT`; typing forgives case, spaces, dashes and O/I/L for 0/1/1) and is shown once: `public.mfa_recovery_codes` keeps only the SHA-256 of the member's id and the code, and only the service role can use the table (RLS on, no policies, nothing granted to members). The code prompt has **Use a backup code**. `mfa-recovery` (mode `redeem`) is the one thing that accepts the `aal1` session of an account with two-factor on: after the rate limit (5 tries an hour, counted before the code is checked), a code that matches an unused one of the member's, made since their current authenticator app was added, is marked used, every MFA factor of the account is deleted and the other codes go; if the factors can't be deleted the code is given back. The app refreshes its session, which then owes no code, lets the member in, and says two-factor is off and to turn it on again in Settings > Security. **A member with neither the app nor a code** can still be let in by the owner: Supabase dashboard > Authentication > Users > the member > delete their authenticator factor, which turns two-factor off the same way. Deploy order: the migration, then the Edge Functions (deploy-supabase.yml does both), then the app; builds from before it don't offer backup codes.
- **Per-member rate limits** on the Edge Functions (see *Rate limits*); Supabase Auth rate-limits sign-ins and sign-ups per IP.
- **Secrets** (Steam key, Twitch/IGDB credentials, `CRON_SECRET`, the service role key) live only in Supabase function secrets and Vault, never in the repository.
- **CORS**: set the function secret `ALLOWED_ORIGINS` to the web app's origins (comma separated, e.g. `supabase secrets set ALLOWED_ORIGINS=https://<web app>`) so only it can call the functions from a browser. Unset, any origin may, as before; the native apps send no origin and are never affected.

On the device: Android and iOS keep the session's tokens encrypted (Android Keystore, iOS Keychain; `lib/services/session_storage.dart`), and Android excludes the app's files from backups and device transfers. The web app sends security headers (`web/_headers`, for Netlify) that stop other sites from framing it.

**Settings to make in the Supabase dashboard** (`supabase/config.toml` only configures `supabase start`):

- Authentication > Providers > Email: turn on **Confirm email** (otherwise anyone can open an account in someone else's address) and **Secure password change**.
- Authentication > Policies (or Providers > Email): minimum password length **8** or more, require **letters and digits**, and turn on **leaked password protection** (Pro plan). `supabase/config.toml` says 8 for `supabase start`, but the live project's value is only what the dashboard says: check it. The app asks for 8 characters whenever a password is chosen (sign-up, reset, change; `minPasswordLength`) whatever the project is set to; signing in accepts any, so an older account isn't locked out.
- Authentication > Multi-Factor: **Authenticator app (TOTP)** must be enabled (it is by default) for Settings > Security > Authenticator app to work; turned off, the setup says two-factor isn't available.
- Authentication > URL Configuration: list only the exact addresses the app returns to (the web app, `http://localhost:3000` for desktop sign-in). No wildcards.
- Authentication > Rate Limits: keep sign-in/sign-up and email limits low; consider **CAPTCHA** (hCaptcha or Turnstile) if bots sign up (the app would need the widget).
- Advisors > Security Advisor: the "security definer view" warnings for the `public_*` views are intentional (see *Public profiles and followers*); anything else is worth a look.

**Release builds**: build with `--obfuscate --split-debug-info=build/symbols` (`flutter build appbundle --obfuscate --split-debug-info=build/symbols`, the same for `ipa`), and keep `build/symbols` of each release to read its crash reports. Android release builds are already shrunk by R8.

**Crash reports** (`lib/services/crash_reporting.dart`): [Sentry](https://sentry.io), off unless the build is given a DSN, so debug runs and tests send nothing: `--dart-define=SENTRY_DSN=https://...@....ingest.sentry.io/...` (and `--dart-define=CHECKPOINT_ENV=production`, which tags the reports). A report is the error and its stack, the app version and the device model; no account, no breadcrumbs (screens, taps, requests), no screenshots, no performance traces, and emails, ids and tokens in an error message are replaced before it leaves the device (`CrashReporting.scrub`, tested). A failed connection is not reported. Settings > Privacy > **Send crash reports** turns it off per device. In the Sentry project turn on **Prevent Storing of IP Addresses** (Settings > Security & Privacy) so the privacy policy's "no IP address" holds, and upload `build/symbols` of each release (`sentry-cli debug-files upload`) to read obfuscated stacks. It is disclosed in `docs/privacy.html`: change them together.

**Staging and other backends.** The Supabase project is chosen when the app is built, not in the code: `--dart-define=SUPABASE_URL=https://<ref>.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<anon key> --dart-define=CHECKPOINT_ENV=staging` (`lib/app/app_config.dart`). Without them the build is production. A URL without its key (or the reverse) stops at start-up with a message. `web/steam-link.html` has the function's address in its `FUNCTION_URL`: change it with the web app's.

**The contact address** is in `docs/privacy.html`, `docs/terms.html`, `docs/index.html` and `AppConfig.contactEmail` (`--dart-define=CHECKPOINT_CONTACT_EMAIL=...`): change them together.

**Not done, on purpose**: certificate pinning (Supabase and Cloudflare rotate their certificates, and a pinned app stops working until it is updated; TLS with the system's trusted roots is what protects the traffic), Play Integrity / App Attest (needs a server check of every request and can't cover the web and desktop apps, while the rules above hold whatever client calls the API), and root or jailbreak detection (it protects nothing the server doesn't already enforce, and is easy to bypass). Supabase Auth hashes passwords with bcrypt; the app never sees or stores them.

### Using your own backend

The app ships pointing at the project's Supabase instance with a public anon key, which is safe to expose when Row Level Security is enabled. To run against your own backend:

1. Create a Supabase project and apply the migrations (`supabase link`, then `supabase db push`). The background Steam sync needs its one-time setup (see above).
2. Deploy the functions in `supabase/functions` (`supabase functions deploy`, which reads `supabase/config.toml` for `steam-link`'s JWT setting) and set their secrets (Twitch client ID/secret for IGDB, Steam API key, and `CRON_SECRET` if you want the background sync). `steam-link` works without secrets, but once the web app is public set `STEAM_LINK_CONFIRM_URL` to the address of its confirm page there (`supabase secrets set STEAM_LINK_CONFIRM_URL=https://<web app>/steam-link.html`; see *Security*). The page asks the `steam-link` named in its `FUNCTION_URL`, so point that at your project as well. Behind a custom domain, or under `supabase start`, set `STEAM_LINK_CALLBACK_URL` to the function's public address (`http://127.0.0.1:54321/functions/v1/steam-link` locally).
3. Build the app with your Supabase URL and key (`--dart-define=SUPABASE_URL=...`, `--dart-define=SUPABASE_PUBLISHABLE_KEY=...`; see *Staging and other backends*).
4. Create Google OAuth client IDs and update `lib/services/auth_service.dart`. For iOS, pass `--dart-define=GOOGLE_IOS_CLIENT_ID=...`.
5. For email sign-in, enable Authentication > Providers > Email, and choose whether new accounts must confirm their address first (the app handles both). The links in the confirmation and password reset emails go to the Site URL, or on web to the address that served the app, which must be listed under Authentication > URL Configuration > Redirect URLs. Opening a reset link signs the user in and the app asks for a new password (email accounts can also change it under Settings > Security). Only the web app can receive the link for now: Android and iOS need a deep-link scheme and desktop a way to catch it, and the link must be opened in the same browser that asked for it (Supabase's PKCE flow keeps the verifier there).

## Privacy and terms

See [docs/privacy.html](docs/privacy.html) and [docs/terms.html](docs/terms.html).

## License

Copyright (c) 2026 Murad Binnatzada. All rights reserved. This is proprietary software, and the source is visible for reference only. See [LICENSE](LICENSE).
