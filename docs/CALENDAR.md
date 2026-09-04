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
connected with. `accounts.scopes` records what a refresh token actually carries; an account missing
the scope shows up in `connectable` and gets a "Connect Calendar" button that re-runs consent.

## Views

- **Week** — the home view, and the one HEY is built around: "week after week, not month after
  month". Weeks stack as rows and scroll continuously in both directions, each row seven day cells.
  A day cell is a *list of one-line chips* in time order — duration is not drawn at all, because at
  this scale what matters is what's on, not how long it runs. Month names print inline where a
  month turns, and a day's label sits above the row.
- **Day** — the only place time is drawn to scale: one day, events positioned by hour, hour marks
  down the right edge, a red line at now, and the hours outside the day collapsed into a
  "Nighttime" band you can click open. It sits beside the week scroll on a wide screen.
- **Month** — a conventional grid, for orientation.
- **Year** — every day of the year; only all-day and multi-day items are drawn.
- **Agenda** — a flat list of what's next.

The day timeline is *fitted*: the scale is built from the hours that day's events actually occupy
and stretched to fill the pane, so a day reads as a full day rather than a few boxes adrift in a
24-hour chart. What falls outside becomes the collapsed band. Overlapping events sit side by side,
never stacked.

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

- `POST /api/calendar/google/connect-link` `{ account_id? }` → `{ url }` — consent in the browser
- `GET  /auth/google/start?calendar=1` — same, from the web app

### The rest

- `GET/PUT  /api/calendar/settings`
- `GET/POST/PATCH/DELETE /api/calendar/habits`, `POST /api/calendar/habits/:id/toggle` `{ date }`
- `GET/PUT  /api/calendar/days/:date` — label and cover art
- `GET/PUT  /api/calendar/journal/:date`, `GET /api/calendar/journal` — the index
- `GET/POST/PATCH/DELETE /api/calendar/flex-tasks` — `?week=YYYY-MM-DD`
- `GET/POST /api/calendar/time`, `POST /api/calendar/time/:id/stop`, `PATCH`/`DELETE`

## Sync

The cron trigger refreshes every Google calendar (incremental, by `syncToken`) and re-fetches ICS
feeds older than an hour. A calendar that errors keeps its last events and surfaces `sync_error`.

## Client

`src/web/lib/caldate.ts` holds the date helpers (`todayKey`, `addDays`, `weekDays`, `monthGrid`,
`fmtTime`, `fmtTimeRange`, `countdownLabel`, `msAt`, `layoutColumns`, …). `src/web/api.ts` holds the
hooks: `useCalendarRange`, `useCalendarSources`, `useCalendarSettings`,
`useCalendarSettingsMutation`, `useEventMutations` (`create`/`update`/`remove`/`rsvp`/`setDone`),
`useCalendarSourceMutations` (`create`/`subscribe`/`update`/`remove`/`sync`/`syncAll`/`importIcs`),
`useHabits`, `useHabitMutations` (`create`/`update`/`remove`/`toggle`), `useCalendarDay`,
`useCalendarDayMutation`, `useJournal`, `useJournalIndex`, `useJournalMutation`, `useFlexTasks`,
`useFlexTaskMutations`, `useTimeEntries`, `useTimeMutations`, `useEventFromThread`,
`useCalendarConnectLink`, and `eventIcsUrl`.

`src/web/calendar/CalendarContext.tsx` gives every view the same state through `useCalendar()`:
settings, calendars, `view`/`setView`, `cursor`/`setCursor`, `today`, the loaded window
(`from`/`to`/`extend`), `range`, `scale` (the piecewise day geometry from `scale.ts`),
`nightOpen`/`setNightOpen`, `eventsOn(date)` → `{ allDay, timed }`, and the editor
(`editor`, `openEvent`, `createEvent`, `closeEditor`).

Views live in `src/web/calendar/`: `WeekScroll` (the continuous week list) and `DayPane` (the
single-day timeline) make up the home view, alongside `MonthView`, `YearView` and `AgendaView`,
with `EventSheet` as the editor. `scale.ts` owns the fitted day geometry. Journal and Habits are their own pages.
Mobile has its own screens under `src/web/mobile/`.

## Keyboard

`0` toggles mail and calendar. Inside the calendar: `←`/`→` walk the days, `↑`/`↓` scroll the
timeline, `t` today, `d` day, `w` week, `m` month, `y` year, `a` agenda, `n` new event, `j`
journal, `b` habits, `Esc` back to the sidebar.
