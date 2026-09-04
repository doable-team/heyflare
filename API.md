# API contract (worker <-> web)

All JSON. Auth via HttpOnly cookie `hey_session`. Errors: `{ error: string }` with 4xx/5xx.
Account-scoped routes take the account via `X-Account-Id` header (web stores the selected account id in localStorage `hey.accountId`). If missing, worker uses the user's first account. Every account-scoped route verifies the account belongs to the session user.

## Auth (`/auth/*`, handled by worker)
- `POST /auth/register` {email,name,password,invite?} -> {user}. First user OR email == SUPERADMIN_EMAIL becomes superadmin. If `registration_open` is '0', a valid invite code is required.
- `POST /auth/login` {email,password} -> {user}
- `POST /auth/logout`
- `GET  /auth/google/start` -> 302 to Google consent (scopes: gmail.modify, userinfo.email, userinfo.profile). Requires session.
- `GET  /auth/google/callback?code&state` -> creates/updates account, 302 to `/` (or `/?connected=1`).

## Me / settings
- `GET  /api/me` -> {user, accounts: Account[], registration_open}
- `PATCH /api/me` {name?, settings?} -> {user}
- `POST /api/me/password` {current,next}
- `GET  /api/accounts` -> Account[]
- `PATCH /api/accounts/:id` {signature?, cover_art?, display_name?} -> Account
- `DELETE /api/accounts/:id` (disconnect + delete data)
- `POST /api/accounts/:id/sync` -> triggers a sync now -> {ok, added}

## Mail (account-scoped)
- `GET /api/counts` -> Counts
- `GET /api/imbox` -> ImboxResponse (new_threads = bucket imbox & seen=0; seen_threads = bucket imbox & seen=1; both exclude reply_later/set_aside/hidden bubble_up; sorted last_message_at desc; limit 200 each)
- `GET /api/threads?bucket=feed|paper_trail|screened_out|trash|sent|everything&q=&page=&label=` -> {threads: ThreadSummary[], next_page: number|null}. `sent` = threads with any message from me. `everything` = all non-trash.
- `GET /api/feed` -> {threads: ThreadSummary[], next_page} but each thread includes `latest_message: Message` (so the feed can render expanded content)
- `GET /api/threads/:id` -> ThreadDetail. Marks seen=1, unread=0 (unless `?peek=1`).
- `POST /api/threads/:id/actions` {action, ...} where action is one of:
  - `mark_unread`, `mark_read`, `seen`
  - `reply_later` {on:boolean}
  - `set_aside` {on:boolean}
  - `bubble_up` {at: number|null}  (null cancels)
  - `move` {bucket: Bucket}  (imbox/feed/paper_trail/trash/screened_out) - only moves the thread, not the contact
  - `rename` {subject: string|null}
  - `note` {note: string}
  - `merge` {thread_ids: string[]}  (merge those into :id)
  - `labels` {add?: string[], remove?: string[]}  (label ids)
  - `collections` {add?: string[], remove?: string[]}
  - `delete` (permanent, local + Gmail trash)
  -> returns updated ThreadDetail
- `POST /api/threads/bulk` {thread_ids: string[], action, ...same params} -> {ok}
- `GET /api/messages/:id/attachments/:attId` -> streams attachment bytes (fetched from Gmail).
- `GET /api/search?q=&page=` -> {threads: ThreadSummary[], next_page}

## Screener (account-scoped)
- `GET /api/screener` -> {senders: {contact: Contact, threads: ThreadSummary[], suggestion: 'imbox'|'feed'|'paper_trail'}[]}
- `POST /api/screener/decide` {contact_id, decision: 'imbox'|'feed'|'paper_trail'|'screened_out', scope?: 'all'|'account'} -> {ok}. Sets contact.screen_status and moves ALL that contact's threads currently in 'screener' or 'screened_out' to that bucket (or to screened_out). `scope` defaults to `'all'`: the decision applies to that email on every account the user has connected (rows created where missing). `'account'` limits it to the account the contact row belongs to.
- `GET /api/screener/screened-out` -> {contacts: Contact[]}

## Contacts (account-scoped)
- `GET /api/contacts?q=` -> MergedContact[] — **one entry per email address**, merged across the accounts in scope (screened first, then last_seen_at desc). `MergedContact` = Contact plus `mixed` (the accounts disagree about `screen_status`) and `accounts: {account_id, contact_id, screen_status, bundled}[]`. Merge rules: `screen_status` = the shared value, else the most common one with `mixed: true`; `message_count` summed; `first_seen_at` min; `last_seen_at`/`screened_at` max; `name`/`avatar_url`/`notes` = first non-empty; `id`/`account_id` = the row that heard from them most recently, which is what links and PATCH address. Narrowing the scope (`X-Account-Id: <id>`) returns just that account's people.
- `GET /api/contacts/:id` -> {contact: MergedContact, threads: ThreadSummary[]} — `contact.id`/`account_id` stay the requested row; `threads` covers every account in scope.
- `PATCH /api/contacts/:id` {name?, notes?, screen_status?, bundled?, scope?: 'all'|'account'} -> MergedContact. `scope` defaults to `'all'` (every connected account, like screener/decide); `'account'` touches only this row and re-buckets only that account's threads. With `'all'` the change is applied even when this row already matches, so mixed accounts get squared up.

## Labels / Collections / Clips / Files (account-scoped)
- `GET/POST /api/labels`, `PATCH/DELETE /api/labels/:id` ({name,color})
- `GET /api/labels/:id/threads` -> {threads}
- `GET/POST /api/collections`, `GET /api/collections/:id` -> {collection, threads: ThreadSummary[], files: Attachment[]}, `PATCH/DELETE /api/collections/:id`
- `GET /api/clips` -> Clip[]; `POST /api/clips` {thread_id, message_id?, text}; `DELETE /api/clips/:id`
- `GET /api/files?page=` -> {files: Attachment[], next_page}

## Compose (account-scoped)
- `GET /api/drafts` -> Draft[]; `POST /api/drafts` {...} -> Draft; `PATCH /api/drafts/:id`; `DELETE /api/drafts/:id`
- `POST /api/send` {draft_id?, thread_id?, reply_to_message_id?, to, cc, bcc, subject, body_html, send_at?, attachments?: [{filename, mime_type, data_base64}]} -> {ok, thread_id, message_id}. If `send_at` in the future -> stored as scheduled draft (cron sends). Reply threads: sets In-Reply-To/References, Gmail threadId. Sent message gets ingested into local DB immediately. Recipients get contact.screen_status='imbox' if pending (HEY auto-approves people you write to).
- `POST /api/send/cancel` {draft_id} -> cancel a scheduled send.

## Admin (superadmin only)
- `GET /api/admin/stats` -> AdminStats
- `GET /api/admin/users` -> AdminUser[]
- `PATCH /api/admin/users/:id` {disabled?, role?, name?} -> AdminUser
- `DELETE /api/admin/users/:id`
- `POST /api/admin/users/:id/reset-password` {password}
- `GET/PATCH /api/admin/settings` {registration_open}
- `GET /api/admin/invites` -> invites[]; `POST /api/admin/invites` -> {code}; `DELETE /api/admin/invites/:code`
- `GET /api/admin/logs?account_id=` -> sync_log rows (latest 200)
- `POST /api/admin/accounts/:id/resync` -> reset history and resync

## Cron (worker `scheduled`)
- Every 2 min: for each account: incremental sync via Gmail history API (or continue initial sync in chunks of ~100 messages using Gmail batch endpoint). Also: bubble_up (bubble_up_at <= now -> bubbled=1, bubble_up_at=null, seen=0, unread=1), scheduled sends (drafts.status='scheduled' & send_at<=now).

## Implementation notes / deviations (backend)
- `GET /api/me` also returns `google_configured: boolean` (whether Google OAuth secrets are set).
- `POST /api/accounts/:id/sync` returns `{ok, added, status: 'ok'|'error'|'disconnected', account}`.
- `GET /api/threads?bucket=` additionally accepts `reply_later`, `set_aside`, `bubbled`, `screener`.
- `GET /api/files?q=` supports a filename/subject filter.
- `GET /api/search` echoes `q`. Search also matches thread notes and message subjects/senders.
- `POST /api/threads/:id/actions` with `action: 'delete'` returns `{ok:true, deleted:true}` (no ThreadDetail). `move` also accepts `bucket: 'screener'`. `reply_later` and `set_aside` are mutually exclusive (turning one on clears the other).
- `POST /api/threads/bulk` rejects `merge` (use the single-thread action).
- `POST /api/send` errors: `no_recipients`, `account_disconnected`, `scheduled_send_no_attachments`, `send_failed` (+`message`). Attachments: max 10, sent inline as base64.
- Auth errors: `invalid_email`, `password_too_short`, `email_taken`, `invite_required`, `invalid_invite`, `invalid_credentials`, `account_disabled`.
- Google OAuth redirect URI is `${APP_URL}/auth/google/callback` (or `http://localhost:<port>/auth/google/callback` in local dev) — both must be registered in the Google Cloud console.
- Gmail message fetches use the batch endpoint (100 per subrequest); initial sync ingests up to 600 messages from the last 60 days, 100 per chunk, up to 3 chunks per cron tick.
- Secrets: `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (`wrangler secret put ...`). `SESSION_SECRET` is not required (sessions are random 256-bit ids stored in D1).

## Integration notes (added during assembly)
- `GET /api/threads?bucket=bubble_up` lists threads with a future `bubble_up_at` (ordered soonest first).
- Account scoping also accepts `?account=<id>` (used by attachment `<a>`/`<img>` links that cannot send headers).
- Anonymous `GET /api/me` returns `{ user: null, accounts: [], registration_open, google_configured }` instead of 401 (register page uses it).
- Pagination is zero-based on every list endpoint.

## Unified scope (added for the unified inbox)
- `X-Account-Id: all` (or header absent) = **unified scope**: every account-scoped list/count/search/screener/contacts/labels/collections/clips/files/drafts endpoint returns rows across ALL of the user's accounts. A specific id narrows to that account. Header is still validated against the user.
- Every account-owned object now carries `account_id`: `ThreadSummary`, `ThreadDetail`, `Message`, `Contact`, `Label`, `Collection`, `Clip`, `Draft`, `Attachment`.
- Per-object routes (`/api/threads/:id`, actions, bulk, contacts/:id, labels/:id, collections/:id, clips/:id, drafts/:id, attachments) resolve the owning account from the object row (must belong to the user), regardless of the header.
- Creating objects in unified scope: `POST /api/labels`, `POST /api/collections`, `POST /api/clips`, `POST /api/drafts` accept optional `account_id`; default = the thread's account when a `thread_id` is given, else the user's first account. Labels/collections may be applied to threads of any of the user's accounts.
- `POST /api/send` accepts `account_id` (the From account). Default = the thread's account for replies, else the user's first account. Response includes `account_id`.
- `GET /api/counts`, `GET /api/imbox`, `GET /api/feed`, `GET /api/threads`, `GET /api/search`, `GET /api/files`, `GET /api/screener`, `GET /api/contacts` all honor unified scope. Screener entries include `account_id`. Contact rows stay per (account, email), but `GET /api/contacts` and `GET /api/contacts/:id` merge them per person; screening and bundling changes default to every account and take `scope: 'account'` to stay local.
- `POST /api/accounts/:id/sync` unchanged; `GET /api/me` unchanged.

## Custom domains & mailboxes (added)
Custom domain mailboxes are `accounts` rows with `provider = 'domain'` (email = `local@domain`), so every mail feature
(screener, buckets, unified inbox, send) works the same as for Gmail. Inbound arrives through Cloudflare Email Routing
(catch-all rule → this Worker's `email()` handler). Outbound uses Cloudflare Email Sending (`env.EMAIL` send_email binding,
if configured) or Resend (`RESEND_API_KEY` secret) — per-domain `sending` field reports which.

Secrets: `CF_API_TOKEN` (optional; Cloudflare API token with Zone:Read + Email Routing Rules:Edit + Email Routing Settings:Edit
for the zones you want automated). `CF_ACCOUNT_ID` var already present via wrangler (`account_id`) — expose as `CF_ACCOUNT_ID` var.
Without `CF_API_TOKEN`, domain setup is "manual": the API returns the exact steps/records and the UI shows them.

- `GET  /api/domains` -> Domain[] where Domain = { id, name, zone_id: string|null, status: 'pending'|'active'|'error',
  routing: 'unconfigured'|'enabled'|'manual', sending: 'cloudflare'|'resend'|'none', catch_all_account_id: string|null,
  error: string|null, dns: {type,name,content,priority?}[] (records Cloudflare needs, when known), mailboxes: Account[], created_at }
- `POST /api/domains` { name } -> Domain. With CF_API_TOKEN: finds the zone (must be active, full setup), enables Email Routing,
  sets the catch-all rule to action `worker` = this Worker name (`WORKER_NAME` var, default `hey-far-hn`), status active.
  Without token: status 'pending', routing 'manual', returns instructions. Never enables routing on a zone whose MX records are
  not Cloudflare's without `confirm: true` in the body (the API returns 409 `{error:'mx_in_use', mx:[...]}` first) — the UI must
  show a warning that this takes over all mail for the domain.
- `POST /api/domains/:id/verify` -> re-checks routing/catch-all status (with token) and updates status.
- `DELETE /api/domains/:id` -> removes the domain + its mailboxes (does not disable routing on Cloudflare).
- `POST /api/domains/:id/mailboxes` { local_part, display_name?, catch_all?: boolean } -> Account (provider 'domain').
  `catch_all` makes this mailbox receive mail for any unknown address on the domain.
- `PATCH /api/domains/:id` { catch_all_account_id?: string|null }
- Mailboxes are deleted via `DELETE /api/accounts/:id` (existing).
- `Account` gains `provider: 'gmail'|'domain'` and `domain_id: string|null`.
- Inbound (`email()` handler): parse with postal-mime; look up RCPT TO in accounts (provider domain); else domain catch-all;
  else `setReject("550 5.1.1 No such mailbox")`. Ingest as a message (same screener/bucket logic; attachments stored in a new
  `attachment_blobs` table when total ≤ 900KB per attachment, else metadata only with `stored=0`), dedupe on Message-ID.
- Outbound: `POST /api/send` with a domain mailbox as `account_id`: send via `env.EMAIL.send({from,to,cc,bcc,subject,html,text,
  headers:{'In-Reply-To','References'}, attachments})` when `env.EMAIL` exists, else Resend REST when `RESEND_API_KEY` set,
  else 400 `{error:'sending_not_configured'}`. Store the sent message locally (is_from_me=1) with a generated Message-ID.
- Attachment proxy `/api/messages/:id/attachments/:attId` serves from `attachment_blobs` for domain mailboxes.

## Account reset (added)
- `POST /api/accounts/:id/reset` -> `{ ok, account, sync_error }`. "Start fresh": deletes everything synced for the account
  (threads, messages, attachments + blobs, contacts/screener decisions, clips, drafts, labels, collections, sync log) and resets
  sync state; for Gmail it immediately records the current historyId so only mail arriving from now on is synced. Nothing in
  Gmail changes. `sync_error` is set when that first sync failed (it is retried by the cron).
- Connecting a Gmail account no longer imports history: the first sync just records Gmail's historyId ("start from now"), and
  every sender is screened when their first new mail arrives.

## Power through new
- `GET /api/power-through` -> `{ items: (ThreadSummary & { latest_message: Message | null })[] }` — everything in the
  Imbox's "New for you" (bucket `imbox`, not reply_later/set_aside, visible, and either unseen and unbundled or inside an
  **open** bundle), newest first, capped at 50, each with its latest message body. Honours unified scope.
- `POST /api/power-through/seen` `{ thread_ids: string[] }` -> `{ ok, count }` — marks those threads seen + read
  (max 200, ownership-checked) and clears Gmail's UNREAD label per account, best-effort. Used by "Mark all as seen";
  nothing is marked seen just by scrolling the page.

## Calendar
Mounted at `/api/calendar` behind `requireUser` and, unlike mail, **not** account-scoped — the calendar belongs to the
owner, not to a mailbox, so `X-Account-Id` is ignored. The full route table, data model and sync behaviour live in
[`docs/CALENDAR.md`](docs/CALENDAR.md). In brief:
- `GET /api/calendar/events?from=&to=` -> `CalendarRange` — expanded occurrences plus habits, day labels and cover art,
  the week's flexible tasks and time entries. Recurring masters from local and subscribed calendars are expanded per
  request window; Google is asked for pre-expanded instances (`singleEvents=true`).
- Events: `POST`, `PATCH /:id?scope=this|following|all`, `DELETE /:id?scope=…`, `/:id/rsvp`, `/:id/done`,
  `/events/from-thread` (returns a prefill, creates nothing), `GET /events/:id.ics`.
- Sources: `GET/POST /sources`, `/sources/subscribe` (ICS or webcal, read-only, SSRF-guarded), `/sources/import`,
  `PATCH/DELETE /sources/:id`, `/sources/:id/sync`, `/sources/sync`, and `/google/connect-link` for the Calendar scope.
- Also `habits`, `days/:date`, `journal/:date`, `flex-tasks`, `time`, and `settings`.
- `accounts.scopes` records which OAuth scopes a refresh token carries; a Gmail account without
  `https://www.googleapis.com/auth/calendar` appears in `connectable` and needs one extra consent.
