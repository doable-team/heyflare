# heyflare

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/doable-team/heyflare) [![npm](https://img.shields.io/npm/v/create-heyflare?label=npm%20create%20heyflare)](https://www.npmjs.com/package/create-heyflare) [![License: MIT](https://img.shields.io/badge/license-MIT-black)](LICENSE)

A self-hosted, HEY-style email client that runs entirely on Cloudflare — **with a built-in AI agent** that reads, triages and
drafts for you. Connect Gmail accounts and mailboxes on your own domains, screen first-time senders, read a calm, unified Imbox, and keep a
HEY-style calendar next to it. Single owner, minimal black-and-white UI, tailor-made
mobile app UI, no external services beyond Google's APIs and Cloudflare.

## Built-in AI agent

heyflare ships with an **agent inside the product** — not a CLI bolted on the side. Open it from the sidebar or with `⌘J`; it
lives in a resizable side panel and can see the thread you're reading.

- **Talk to your mail.** "What's new for me today?", "Anything waiting in the Screener?", "Find the invoice from Stripe", "Summarise this thread".
- **Acts, with tools.** Search and read threads, screen senders in or out, move to Imbox / Feed / Paper Trail, Reply Later, Set Aside, Bubble Up, labels, collections, clips, bundles, contacts.
- **Writes, you decide.** It drafts replies and forwards; you press Send. (You can allow autonomous sending if you want it.)
- **Reply with AI** on any thread: type what you want to say, pick a tone, and the reply opens in the composer prefilled after the agent reads the whole thread.
- **Memory that learns.** It studies the mail you send to learn your tone (greetings, sign-offs, length, phrasing), facts about you, preferences and per-contact notes — a compact set you can read, edit or wipe in Settings → AI. Reply drafts use it.
- **Bring your own model.** Anthropic, OpenAI, xAI (Grok), OpenRouter, Google Gemini, or any OpenAI-compatible endpoint (Ollama, Groq, Mistral, LM Studio…). Keys are stored encrypted on your Worker; mail is sent to the provider only when you use an AI feature.

## Screenshots

| Imbox | Screener |
|---|---|
| ![Imbox](docs/screenshots/imbox-v2.png) | ![Screener](docs/screenshots/screener-v2.png) |

| Thread with the AI assistant | The Feed |
|---|---|
| ![Assistant](docs/screenshots/assistant-v2.png) | ![Feed](docs/screenshots/feed-v2.png) |

| Paper Trail | Mobile |
|---|---|
| ![Paper Trail](docs/screenshots/paper-trail-v2.png) | <img src="docs/screenshots/mobile-imbox-v2.png" width="260" /> <img src="docs/screenshots/mobile-thread-v2.png" width="260" /> |

## Features

- **The Screener** — every first-time sender waits for a yes/no. Decide once per person, across all your accounts.
- **Imbox, The Feed, Paper Trail** — people, newsletters, receipts. "New for you" vs "Previously seen".
- **Power through new** — the whole "New for you" queue stacked on one page: reply, defer or file each one, `o` to start.
- **Reply Later, Set Aside, Bubble Up** — trays docked in the Imbox, Focus & Reply mode, snooze with presets.
- **Bundles** — collapse a chatty sender into one row per batch; read the batch like a feed.
- **Calendar** — weeks that scroll continuously, HEY-style, each day a list of chips rather than an hour grid, with a
  fitted single-day timeline beside it; plus month, year and agenda views.
  Google Calendar over OAuth (two-way), subscribed `.ics`/`webcal` feeds (read-only), `.ics` import, and heyflare's own
  calendars. Habits, a journal, day labels and cover art, "sometime this week" tasks, countdowns, time tracking, and the
  next three days shown at the top of the Imbox. `0` flips between mail and calendar.
- **Unified inbox** across every connected account, with per-account glyphs and a From picker in compose.
- **Gmail** via OAuth (incremental history sync every minute plus sync-on-focus; sending through Gmail).
- **Custom domain mailboxes** — inbound through Cloudflare Email Routing, outbound through Cloudflare Email Sending or Resend.
- Contacts with Google profile photos, BIMI brand logos, address-book autocomplete, clips, collections, labels, files,
  notes, merge and rename threads, spy-pixel blocking, keyboard shortcuts, command palette, dark mode, two-factor auth.

## Stack

Cloudflare Workers (Hono) + D1 · React 19 + Vite + Tailwind v4 + shadcn/ui · Gmail REST API · postal-mime for inbound mail.

## Install with npm

```sh
npm create heyflare@latest my-mail
```

A short wizard copies the app into `my-mail`, installs dependencies and walks you through the Cloudflare deploy: Wrangler
login, a D1 database, Worker name and hostname (`*.workers.dev` or a custom domain), optional Google OAuth secrets, then
build + deploy. Migrations run on first request. Redeploy later with `npx create-heyflare deploy` (or `npm run deploy`).

To update, run `npm create heyflare@latest` into a new folder and copy your `wrangler.local.jsonc` across — or use the
GitHub fork path below to pull changes with git.

## One-click deploy

Click **Deploy to Cloudflare** above. Cloudflare copies this repo into your GitHub/GitLab account, creates the Worker and a
D1 database, fills in the database id, builds (`npm run build`) and deploys (`npx wrangler deploy`). The Worker applies its
own database migrations on the first request, and generates its own encryption secret, so nothing else is needed to boot.
The flow asks for the two Google OAuth values listed in `.dev.vars.example`; you can leave them empty and add them later.

After the deploy:
1. Open your `https://<worker>.<account>.workers.dev` URL → you land on `/setup` → create the owner login.
2. Create the Google OAuth client (section 1 below) using that workers.dev URL (or your custom domain) as the origin and
   `…/auth/google/callback` as the redirect URI, then add `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in
   Workers → your Worker → Settings → Variables and Secrets (if you skipped them during the deploy).
3. Connect Gmail from the sidebar. Optional secrets: `CF_API_TOKEN` (automatic custom-domain setup), `RESEND_API_KEY`.
4. Want your own hostname? Add a custom domain under Workers → Settings → Domains & Routes (or a `routes` entry in the config).

### Prefer a fork?
The button **clones** the repo into your account (Cloudflare's flow can't fork). To keep a link to upstream:
1. Fork `doable-team/heyflare` on GitHub.
2. In the Cloudflare dashboard: **Workers & Pages → Create → Import a repository** → pick your fork. Build command `npm run build`, deploy command `npx wrangler deploy`.
3. Cloudflare provisions the D1 database from `wrangler.jsonc` on first deploy; the app applies migrations itself.
4. Later, `git pull upstream main` in your fork and push — Workers Builds redeploys.

## Deploy manually

Prerequisites: a Cloudflare account, Node 20+, and a Google Cloud project.

### 1. Google OAuth client
1. https://console.cloud.google.com → create a project.
2. **APIs & Services → Library**: enable **Gmail API**, **People API** and, for the calendar, **Google Calendar API**.
3. **OAuth consent screen**: External; add your Gmail addresses as test users (publish the app later to lift the 7-day
   refresh-token limit for test users). Scopes: `gmail.modify`, `contacts.other.readonly`, `contacts.readonly`,
   `directory.readonly`, `openid`, `email`, `profile`. Add `https://www.googleapis.com/auth/calendar` if you want the
   calendar — heyflare asks for it separately, from Settings → Calendar, so connecting mail alone never touches it.
4. **Credentials → OAuth client ID → Web application**:
   - Authorized JavaScript origins: `https://YOUR_HOST`
   - Authorized redirect URIs: `https://YOUR_HOST/auth/google/callback` and `http://localhost:8787/auth/google/callback`

### 2. Cloudflare
```sh
git clone https://github.com/doable-team/heyflare && cd heyflare
npm install
npx wrangler login
npx wrangler d1 create heyflare-db          # copy the database_id
cp wrangler.jsonc wrangler.local.jsonc      # set database_id, optionally account_id, routes/custom domain, APP_URL var
npx wrangler secret put GOOGLE_CLIENT_ID     -c wrangler.local.jsonc
npx wrangler secret put GOOGLE_CLIENT_SECRET -c wrangler.local.jsonc
npm run deploy:mine
```
Migrations apply automatically on the Worker's first request (`npm run db:migrate:mine` is optional and stays compatible,
it uses the same `d1_migrations` table). The AI-key encryption secret is generated on first use; set a `SESSION_SECRET`
secret only if you want to control it yourself.

`wrangler.local.jsonc` is git-ignored so your IDs never land in a fork. Use a Workers custom domain (a zone on your account,
no existing DNS record for the host) or a zone route; or delete `routes` to use the `*.workers.dev` URL.

### 3. First run
Open your host. You'll be sent to `/setup` to create the single owner login (any email + password). After that `/setup`
locks and only `/login` works. Then **Connect Gmail** from the sidebar. Turn on two-factor auth in Settings → Security.

## Mac app

A native macOS app (Tauri 2, WebKit, ~10 MB) lives in [`apps/mac`](apps/mac). It wraps your server with a real title bar,
native menu bar and shortcuts, dock badge, notifications, external links in your browser, and auto-updates. Download the
DMG from [Releases](https://github.com/doable-team/heyflare/releases) or build it yourself (`cd apps/mac && npm install && npm run build`).

Downloaded builds aren't notarized yet, so macOS may say the app is "damaged". Clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/heyflare.app
```

## iPhone app

A native iOS app (Tauri 2, WKWebView) lives in [`apps/ios`](apps/ios). It wraps the same server with the hand-built
mobile UI, system notifications and links that open in Safari. It builds with a **free Apple ID** — no paid developer
account — and [`apps/ios/README.md`](apps/ios/README.md) covers signing it, the 7-day expiry, and refreshing over Wi-Fi
with SideStore or AltStore. You need full Xcode to build it.

```sh
cd apps/ios && npm install && npm run ios:init && npm run dev
```

## Updating

heyflare tells you when a new version is out: an **Update available** row appears at the bottom of the sidebar, and the
dialog explains what changed and how to get it.

- **Mac app** — press **Update and restart**. It downloads, installs and relaunches itself.
- **iPhone app** — rebuild from source, or let SideStore or AltStore refresh it.
- **Created with npm** — `npx create-heyflare deploy`
- **Cloned repo** — `git pull && npm run deploy`
- **Fork + Workers Builds** — merge upstream and push; Cloudflare deploys it.

Your data is never touched: mail, contacts, screener decisions, settings, 2FA and AI memory live in your D1 database, and
new database migrations apply themselves on the first request after a deploy. Full details, including rollback:
[`docs/UPDATING.md`](docs/UPDATING.md).

## How mail flows
- Connecting Gmail imports **nothing**. It records Gmail's history cursor and only mail that arrives afterwards syncs.
- Every first-time sender waits in the **Screener**. Decisions are per person and apply across all your accounts.
- Gmail is polled every minute (Cloudflare cron) and whenever the app is opened or regains focus (throttled). Custom-domain
  mail is pushed in instantly by Email Routing.
- Sending uses your Gmail account (it appears in Gmail's Sent too), with undo-send and send-later.
- Contact photos come from the People API (profile + directory) and BIMI logos from DNS; otherwise initials.

## Custom domain mailboxes
Settings → Domains. The domain must be a zone on your Cloudflare account (full setup).
- **Inbound**: with a `CF_API_TOKEN` secret (Zone Read, Email Routing Rules Edit, Email Routing Settings Edit) heyflare
  enables Email Routing and points the catch-all rule at the Worker automatically; without it the UI shows the manual steps.
  Enabling routing takes over **all** mail for that domain — the app shows the current MX and asks first.
- **Outbound**: Cloudflare **Email Sending** (Workers Paid, onboard the domain in the dashboard, then uncomment the
  `send_email` binding in your config) or **Resend** (`RESEND_API_KEY` secret). Until one is configured, mailboxes receive
  but can't send.

## Local development
```sh
cp .dev.vars.example .dev.vars    # Google creds + SESSION_SECRET
npm run db:migrate:local
npm run dev:worker                # worker on :8787 (API, cron, email handler)
npm run dev                       # vite on :5173 (proxies /api and /auth)
```
Inbound mail can be simulated against the local worker: `POST http://localhost:8787/cdn-cgi/handler/email?from=a@b.co&to=you@yourdomain` with a raw RFC 822 body.

## Two-factor authentication
TOTP (Google Authenticator, 1Password, Authy…) with 10 single-use recovery codes. Settings → Security.

## Docs
- `API.md` — the worker/web API contract.
- `DESIGN.md` — the design system (Notion-minimal, shadcn, mobile spec).
- [`docs/CALENDAR.md`](docs/CALENDAR.md) — how the calendar is put together: sources, views, schema, API, sync.
- [`docs/UPDATING.md`](docs/UPDATING.md) — what an update changes, how to update, how to roll back.

## License
MIT © Doable Team

## AI assistant (bring your own key)
heyflare has an in-product assistant (sidebar → Assistant, ⌘J) that can search and read your mail, screen senders, organise
threads (Reply Later, Set Aside, Bubble Up, move, labels, collections, clips, bundles), look up contacts, and write drafts in
your voice. It follows HEY's principle: **the agent writes, you decide** — drafts are never sent unless you press Send (or
explicitly allow autonomous sending in Settings → AI). Thread pages get **Reply with AI** (one-line brief → a full reply drafted
into the composer, using your tone) and **Summarise with AI**.

**Providers** (Settings → AI): Anthropic (official SDK, default), OpenAI, xAI (Grok), OpenRouter, Google Gemini, or any
OpenAI-compatible server (Ollama, LM Studio, Groq, Mistral…). Keys are stored encrypted with `SESSION_SECRET` and never shown
again. The model is free text with suggestions per provider.

**Memory**: the assistant keeps a small, editable memory of who you are, how you write (greetings, sign-offs, length), your
preferences, and notes on people. It learns from the mail you send (at most twice a day, can be turned off), from what it does
for you, and from notes you add. Everything is visible and editable in Settings → AI → Memory, and can be wiped.

**Privacy**: mail is only sent to the provider when you use an AI feature (chat, reply, summarise, or background learning).
