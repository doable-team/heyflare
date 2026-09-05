# Calendar

heyflare's calendar is modelled on HEY Calendar: time reads as a continuous filmstrip of days
rather than a grid of boxes, and the things that make a day yours — a label, a cover photo, habits,
a journal — sit in the same column as the meetings.

## Sources

| Source   | Where it comes from                | Writable |
|----------|------------------------------------|----------|
| `local`  | Created in heyflare                | yes      |
| `google` | Google Calendar, per Gmail account | yes      |
| `ics`    | A subscribed `.ics`/`webcal` URL   | no       |

Google needs the `https://www.googleapis.com/auth/calendar` scope, which existing accounts were not
connected with. `accounts.scopes` records what a refresh token actually carries, and Settings →
Calendar lists every Google account off `google_accounts` with what it is connected for — mail and
calendar, calendar only, or mail only — how many calendars heyflare holds for it, and its last sync
error. Each row can connect its calendar, reconnect (the same consent run, which is how a revoked or
expired grant is recovered) or disconnect its calendar.

A Google account can be connected **for calendar only**: `openid`, `email`, `profile` and the
Calendar scope, and no mail access at all. It is still a `provider = 'gmail'` row, so the mail cron
and `syncAccount` both skip anything whose `scopes` carry no `gmail.modify` — with the deliberate
exception of an empty `scopes`, which predates the column and *does* mean mail. `hasMailScope` and
`MAIL_SCOPE_SQL` in `src/worker/google.ts` are the two copies of that test; keep them in step.

Disconnecting a calendar deletes that account's `google` calendars and their events and strips the
Calendar scope from `accounts.scopes`, so the account offers "Connect calendar" again. It never
touches mail, never deletes the account, and changes nothing in Google.

## Views

HEY has three, and so does this: a **day**, a **week** and a **year**. There is no month grid and
no agenda list.

- **Week** — the home view. Weeks stack as rows and scroll continuously in both directions; the
  week you are on is framed. Each row is seven columns carrying the full 24 hours, linear, with
  events drawn to scale. No hour gutter and no hour rules. Habit badges straddle a rail along the
  top, all-day events are stadium pills at the foot of the column, and every row carries its own
  "sometime this week" strip. The month name is set rotated down the row's left edge, and again on
  the column boundary where a month turns.
- **Day** — horizontal. Time runs left to right at about 43px an hour and each event is a
  full-height bar whose *width* is its duration, its title rotated to read bottom-to-top: Jason
  Fried's "spine of a book in a library". Because night compresses to a fixed 80px, the track runs
  straight through midnight with no day boundary. Free time is drawn here at full scale and stamped
  with its length — your day starts full and you carve events out of it.
- **Year** — the whole year as one weekday-aligned ribbon: 28 columns, four weeks to a row, so the
  weekend stripes line up down the page. A month is marked where it begins, by a badge on the
  boundary and a tick down the column. Only all-day and multi-day items are drawn, as pills
  spanning the days they cover — a year of timed meetings is unreadable.

Mobile is deliberately conventional: a month grid with the day's agenda under it, and a vertical
day timeline. HEY's own phone app is vertical too — the horizontal ribbon does not survive a thumb.

## Day photos

A day can carry a picture, the way you would tape one to a paper wall calendar. It sits behind that
day's events at full strength under a scrim, so the photo reads as a photo and the text on top stays
legible. Photos are uploaded through the picker on a day, downscaled in the browser to 1800px on
the long edge, and stored as bytes in D1 (`day_covers`) rather than an object store, which this
deployment does not have. `calendar_days.cover_id` points at the stored photo so one picture can be
reused across days; `cover_url` may instead hold an external URL, and `cover_position` carries the
crop.

## Data model

`calendars` → `events` (+ `event_completions` for repeating todos). Recurrence is stored as an
RRULE on a master row; `local` and `ics` events are expanded server-side per request window, while
Google is asked for pre-expanded instances (`singleEvents=true`). A single occurrence that was
edited is stored as its own row with `master_id` + `occurrence_date`.

Alongside those: `habits` + `habit_completions`, `calendar_days` (label, cover art, journal),
`flex_tasks` ("sometime this week", unfinished ones roll forward), `time_entries`, and
`calendar_settings`.

Times are epoch milliseconds. All-day items also carry `start_date`/`end_date` as `YYYY-MM-DD` so a
birthday lands on the same date in every timezone.

## API

All routes are under `/api/calendar`, session-authenticated, scoped to the single owner.

### Range

`GET /api/calendar/events?from=YYYY-MM-DD&to=YYYY-MM-DD` → `CalendarRange`

Everything needed to draw that window: expanded events, habits with their completions, day labels
and cover art, the week's flex tasks, and time entries. `from`/`to` are inclusive dates in the
user's timezone. Hidden calendars are excluded unless `all=1`.

### Events

- `POST   /api/calendar/events` → `CalEvent`
- `PATCH  /api/calendar/events/:id` — `?scope=this|following|all` for recurring events
- `DELETE /api/calendar/events/:id` — same `scope`
- `POST   /api/calendar/events/:id/duplicate` — a standalone copy on the same calendar, no
  recurrence and no attendees; one occurrence of a series copies that occurrence's own times
- `POST   /api/calendar/events/:id/rsvp` `{ rsvp }`
- `POST   /api/calendar/events/:id/done` `{ done, date? }` — todos
- `POST   /api/calendar/events/from-thread` `{ thread_id }` — prefill from an email
- `GET    /api/calendar/events/:id.ics` — download one event

An `:id` may be `<row>@<YYYY-MM-DD>`, addressing one occurrence of a recurring master.

### Sources

- `GET    /api/calendar/sources` → `CalendarSourcesResponse`
- `POST   /api/calendar/sources` `{ name, color }` — a new local calendar
- `POST   /api/calendar/sources/subscribe` `{ url, name?, color? }` — an ICS feed
- `PATCH  /api/calendar/sources/:id` `{ name?, color?, visible?, is_default? }`
- `DELETE /api/calendar/sources/:id`
- `POST   /api/calendar/sources/:id/sync`
- `POST   /api/calendar/sources/sync` — every source
- `POST   /api/calendar/sources/import` — an uploaded `.ics` body, becomes editable local events

### Google

- `POST /api/calendar/google/connect-link` `{ account_id?, calendar_only? }` → `{ url }` — consent in
  the browser. `calendar_only` asks for calendar access and no mail access at all.
- `POST /api/calendar/google/:accountId/disconnect` → the `/sources` payload plus `{ ok, removed }` —
  drops that account's calendars and events and forgets its Calendar scope. Mail and the account
  itself are untouched, and so is Google.
- `GET  /auth/google/start?calendar=1` (or `?calendar_only=1`) — same, from the web app

### The rest

- `GET/PUT  /api/calendar/settings`
- `GET/POST/PATCH/DELETE /api/calendar/habits`, `POST /api/calendar/habits/:id/toggle` `{ date }`
- `GET/PUT  /api/calendar/days/:date` — label, photo (`cover_id`, `cover_url`, `cover_position`)
- `GET/POST/DELETE /api/calendar/covers` — the day-photo library; `POST` takes raw image bytes with
  the type in `content-type`, `GET /covers/:id` serves them
- `GET/PUT  /api/calendar/journal/:date`, `GET /api/calendar/journal` — the index
- `GET/POST/PATCH/DELETE /api/calendar/flex-tasks` — `?week=YYYY-MM-DD`
- `GET/POST /api/calendar/time`, `POST /api/calendar/time/:id/stop`, `PATCH`/`DELETE`

## Sync

The cron trigger refreshes every Google calendar (incremental, by `syncToken`) and re-fetches ICS
feeds older than an hour. A calendar that errors keeps its last events and surfaces `sync_error`.

### The write budget

D1's free tier allows 100,000 row writes a day, and a write to a row is billed again for every
index on it. Calendar events are the only table here with thousands of rows, so they decide whether
the app fits:

- An `events` row carries two full indexes plus three **partial** ones (`master_id`, `thread_id`,
  and the recurring masters — all `WHERE … IS NOT NULL`). A Google instance has none of those
  columns set, so it costs four writes, not seven. Every lookup on those columns names them with `=`
  or `IN`, which is what lets SQLite use a partial index.
- A pull never rewrites a row whose Google **etag** we already hold. Token polls only carry changes
  anyway; this is what makes a *full* pull — the first sync, an expired token, the monthly refresh —
  cost reads instead of writes.
- The first pull is bounded (120 days back, 540 forward), and Google's sync token keeps that window
  for life, so an event drifting into range later is never reported through it. Each calendar is
  therefore pulled from scratch **once a month** (`full_synced_at`), one calendar per cron tick.
  Instances beyond the window are not stored until they come within reach.
- A calendar shared with several of the user's accounts is stored once per account, but only the
  first copy is visible; the rest arrive hidden, which polls them every six hours instead of every
  minute and draws nothing twice.

To see what the database is doing: `wrangler d1 execute … --remote --json` reports `rows_read` and
`rows_written` per statement, and the `sync_log` table records when a limit was hit.

## Client

`src/web/lib/caldate.ts` holds the date helpers (`todayKey`, `addDays`, `weekDays`, `monthGrid`,
`fmtTime`, `fmtTimeRange`, `countdownLabel`, `msAt`, `layoutColumns`, …). `src/web/api.ts` holds the
hooks: `useCalendarRange`, `useCalendarSources`, `useCalendarSettings`,
`useCalendarSettingsMutation`, `useEventMutations` (`create`/`update`/`remove`/`rsvp`/`setDone`),
`useCalendarSourceMutations` (`create`/`subscribe`/`update`/`remove`/`sync`/`syncAll`/`importIcs`),
`useHabits`, `useHabitMutations` (`create`/`update`/`remove`/`toggle`), `useCalendarDay`,
`useCalendarDayMutation`, `useJournal`, `useJournalIndex`, `useJournalMutation`, `useFlexTasks`,
`useFlexTaskMutations`, `useTimeEntries`, `useTimeMutations`, `useEventFromThread`,
`useCalendarConnectLink`, `useCalendarDisconnect`, and `eventIcsUrl`.

`src/web/calendar/CalendarContext.tsx` gives every view the same state through `useCalendar()`:
settings, calendars, `view`/`setView`, `cursor`/`setCursor`, `today`, the loaded window
(`from`/`to`/`extend`), `range`, `scale` (the piecewise day geometry from `scale.ts`),
`nightOpen`/`setNightOpen`, `eventsOn(date)` → `{ allDay, timed }`, and the editor
(`editor`, `openEvent`, `createEvent`, `closeEditor`).

Views live in `src/web/calendar/`: `WeekView` (the scrolling stack of week rows), `DayRibbon` (the
horizontal day) and `YearView`, with `EventSheet` as the editor and `DayPhoto` as the photo picker.
`scale.ts` owns the ribbon — the piecewise minute-to-pixel mapping that both time views read. Journal and Habits are their own pages.
Mobile has its own screens under `src/web/mobile/`.

## Keyboard

`0` toggles mail and calendar. Inside the calendar: `←`/`→` walk the days, `↑`/`↓` scroll the
timeline, `↑`/`↓` step through the calendar; `←`/`→` keep their meaning everywhere else in the app — out to
the sidebar and over to the assistant — so the calendar does not take them. `t` today, `d` day,
`w` week, `y` year, `n` new event, `j` journal, `b` habits, `Esc` back to the sidebar.

"Today" is a *reveal*, not a cursor move: you can scroll a long way without touching the cursor, so
it has to work when the cursor is already sitting on today. Views watch `revealAt` for that, and
report the month they are actually showing back to the toolbar, so the title follows the scroll.
