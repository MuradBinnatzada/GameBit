# Moderating Checkpoint

Members see each other's profiles, libraries, reviews, lists and discussion posts, so someone has to deal
with what they report. The App Store (guideline 1.2) expects four things, and this is where each lives:

| Expectation | Where |
| --- | --- |
| Filter objectionable text | The worst words are refused when text is saved: `supabase/functions/_shared/discussion_filter.ts` in the `discussions` function, the same filter in SQL (`private.breaks_chat_rules`) for profiles, reviews and lists |
| A way to report content | Profiles, photos, lists, reviews and discussion posts each have a report option in the app |
| A way to block abusive members | Block, from a profile, a review or a discussion post; **Settings > Privacy > Blocked members** lists and undoes them |
| Act on reports within 24 hours, remove offending members | The queue and the functions below. The Terms of Use (`docs/terms.html`) promise 24 hours: keep that promise |

Everything here is run in the **Supabase dashboard > SQL editor** (it runs as `postgres`). The `moderation`
schema is not exposed by the API and no member can reach it.

## Every day (and before 24 hours are up)

```sql
select source, hours_open, overdue, reason, reported_handle, content, reference
from moderation.open_reports;
```

It lists every open report from every report table, oldest first. `overdue` turns true after 24 hours.
`source` is `profile` (name, handle or bio), `list`, `review`, `thread` or `reply`; `content` is what was
reported; `reference` is the id to act on (the list, the thread, the reply, or the game of a review).

Look at the queue at least once a day; twice is better. Nothing pings you: set up a Supabase
**Database Webhook**, or a `pg_cron` job that mails you `select count(*) from moderation.open_reports
where overdue`, if you want it to.

## Acting on a report

Pick what fits; do them in the SQL editor. The member is never told who reported them.

**Remove a discussion thread or reply**: delete the row (its replies and reports go with it):

```sql
delete from public.discussion_threads where id = '<reference>';
delete from public.discussion_posts   where id = '<reference>';
```

**Empty a review** (the rating and the rest of the game stay):

```sql
select moderation.remove_review('<reported_id>', '<game id from reference>');
```

**Remove a public list**:

```sql
delete from public.game_lists where id = '<reference>';
```

**Wipe a profile's name, handle, bio, photo and service names** (the name becomes "Player"):

```sql
select moderation.clear_profile('<reported_id>');
```

**Suspend a member.** They are signed out everywhere, cannot sign in (Supabase Auth ban), and every
other member stops seeing their profile, library, reviews, lists and posts. `days` null means until you
reinstate them.

```sql
select moderation.suspend_member('<reported_id>', 'Harassment in the discussions', null);  -- for good
select moderation.suspend_member('<reported_id>', 'Spam', 7);                              -- 7 days
```

**Lift it:**

```sql
select moderation.reinstate_member('<reported_id>');
```

**Close the reports.** After you acted (or decided not to), mark every open report about that member
handled, so the queue only holds what is left. `actioned`: something was done; `dismissed`: nothing was wrong.

```sql
select moderation.close_reports_about('<reported_id>', 'actioned', 'removed review, 7 day suspension');
select moderation.close_reports_about('<reported_id>', 'dismissed', 'ordinary disagreement');
```

Reports about a thread, reply, review or list you deleted disappear with it. Reports stay in their tables
(`user_reports`, `review_reports`, `discussion_reports`) with `status`, `handled_at` and `outcome`, which is
your record of what was done.

## Text saved before the filter existed

```sql
select * from moderation.flagged_text();
```

lists display names, handles, bios, reviews and list titles that the filter would refuse today. Handle them
as above.

## Child sexual abuse material

If a report is about it: remove the content at once, suspend the account, and report it to the authorities
(in the US, the NCMEC CyberTipline; elsewhere, your national hotline) as the law of your country requires.
Take a copy of the report and the content for them before you delete anything.

## Appeals

Members write to the address in `docs/terms.html`. A suspension's reason is in `moderation.suspensions`
(`select * from moderation.suspensions where user_id = '<id>'`).

## Changing the filter

Add a term to `LATIN_TERMS` or `CYRILLIC_TERMS` in `supabase/functions/_shared/discussion_filter.ts` and an
example to `discussions_test.ts`. Then run

```bash
deno test --allow-read=supabase/migrations supabase/functions/_shared/
```

`filter_sql_test.ts` fails and prints the two new patterns. Put them in a **new migration** that redefines
`private.breaks_chat_rules` (copy the function from `20261028235500_moderation_and_blocking.sql` and change
the two `$re$` strings); a migration that was applied is never edited. The test always checks the newest
migration that defines the function.

Leave out anything with an ordinary meaning. The filter must never refuse an innocent sentence.
