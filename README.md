# heyflare

A self-hosted, HEY-style email client that runs entirely on Cloudflare. Connect Gmail accounts and mailboxes on your own
domains, screen first-time senders, and read a calm, unified Imbox. Single owner, minimal black-and-white UI, tailor-made
mobile app UI, no external services beyond Google's APIs and Cloudflare.

## Features

- **The Screener** — every first-time sender waits for a yes/no. Decide once per person, across all your accounts.
- **Imbox, The Feed, Paper Trail** — people, newsletters, receipts. "New for you" vs "Previously seen".
- **Reply Later, Set Aside, Bubble Up** — trays docked in the Imbox, Focus & Reply mode, snooze with presets.
- **Bundles** — collapse a chatty sender into one row per batch; read the batch like a feed.
- **Unified inbox** across every connected account, with per-account glyphs and a From picker in compose.
- **Gmail** via OAuth (incremental history sync every minute plus sync-on-focus; sending through Gmail).
- **Custom domain mailboxes** — inbound through Cloudflare Email Routing, outbound through Cloudflare Email Sending or Resend.
- Contacts with Google profile photos, BIMI brand logos, address-book autocomplete, clips, collections, labels, files,
  notes, merge and rename threads, spy-pixel blocking, keyboard shortcuts, command palette, dark mode, two-factor auth.

## Stack

Cloudflare Workers (Hono) + D1 · React 19 + Vite + Tailwind v4 + shadcn/ui · Gmail REST API · postal-mime for inbound mail.

## Deploy your own

Prerequisites: a Cloudflare account, Node 20+, and a Google Cloud project.

### 1. Google OAuth client
1. https://console.cloud.google.com → create a project.
2. **APIs & Services → Library**: enable **Gmail API** and **People API**.
3. **OAuth consent screen**: External; add your Gmail addresses as test users (publish the app later to lift the 7-day
   refresh-token limit for test users). Scopes: `gmail.modify`, `contacts.other.readonly`, `contacts.readonly`,
   `directory.readonly`, `openid`, `email`, `profile`.
4. **Credentials → OAuth client ID → Web application**:
   - Authorized JavaScript origins: `https://YOUR_HOST`
   - Authorized redirect URIs: `https://YOUR_HOST/auth/google/callback` and `http://localhost:8787/auth/google/callback`

### 2. Cloudflare
```sh
git clone https://github.com/doable-team/heyflare && cd heyflare
npm install
npx wrangler login
npx wrangler d1 create heyflare-db          # copy the database_id
cp wrangler.jsonc wrangler.local.jsonc      # fill in database_id, account id, your hostname/route, APP_URL
npm run db:migrate:mine
npx wrangler secret put GOOGLE_CLIENT_ID     -c wrangler.local.jsonc
npx wrangler secret put GOOGLE_CLIENT_SECRET -c wrangler.local.jsonc
npx wrangler secret put SESSION_SECRET       -c wrangler.local.jsonc   # any long random string
npm run deploy:mine
```
`wrangler.local.jsonc` is git-ignored so your IDs never land in a fork. Use a Workers custom domain (a zone on your account,
no existing DNS record for the host) or a zone route; or delete `routes` to use the `*.workers.dev` URL.

### 3. First run
Open your host. You'll be sent to `/setup` to create the single owner login (any email + password). After that `/setup`
locks and only `/login` works. Then **Connect Gmail** from the sidebar. Turn on two-factor auth in Settings → Security.

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
