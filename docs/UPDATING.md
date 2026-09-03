# Updating heyflare

Updating replaces code, never your mail. This page covers what changes, how to update on each setup,
and how to go back if something looks wrong.

## What an update changes

**Replaced:** the Worker code (API, sync, AI, inbound mail) and the static assets of the web app.

**Never touched:** your D1 database — mail, threads, contacts, screener decisions, labels, collections,
clips, notes, drafts, bundles, settings, two-factor secrets, AI provider keys and AI memory. Your Worker
secrets (Google OAuth, `CF_API_TOKEN`, `RESEND_API_KEY`, the session secret) live in Cloudflare and
survive deploys too, so nobody gets logged out and no account needs reconnecting.

Database changes ship as migrations that run themselves on the first request after a deploy — there is no
manual `db:migrate` step. Migrations only add tables and columns, so existing rows are kept as they are.

## Update your server

Pick the line that matches how you installed it.

### Created with `npm create heyflare`

```sh
npx create-heyflare deploy
```

Reuses the `wrangler.local.jsonc` already in the project: same Worker, same database, same secrets.

### Cloned the repo

```sh
git pull && npm run deploy
```

### Forked it, with Cloudflare Workers Builds

Merge upstream and push; Cloudflare deploys the result.

```sh
git remote add upstream https://github.com/doable-team/heyflare   # first time only
git fetch upstream
git merge upstream/main
git push
```

## Update the Mac app

Open the sidebar's **Update available** row (or **heyflare → Check for Updates…**) and press
**Update and restart**. The app downloads the new build, installs it and relaunches itself — your server,
window size and login are all kept.

You can also download the DMG from the [latest release](https://github.com/doable-team/heyflare/releases/latest)
and drag it over the old app.

The Mac app and the server update independently: the app is only a native window around your server, so
either can be newer than the other.

## Which version am I running?

- The sidebar shows an **Update available** row when a newer release exists.
- `https://your-host/api/version` returns the version, the commit it was built from, and the build time.
- The Mac app's version is in **heyflare → About heyflare**.

## Rolling back

Cloudflare keeps previous deployments, so the fastest way back is:

```sh
npx wrangler rollback -c wrangler.local.jsonc
```

Or open the Worker in the Cloudflare dashboard, go to **Deployments**, and roll back to an earlier one.

To deploy a specific older version from source:

```sh
git checkout v0.1.0
npm run deploy
git checkout main
```

Rolling back the code does not roll back the database. Since migrations only add things, an older build
keeps working against a newer database.

## If something looks wrong

- **Old UI after updating** — the browser cached the assets. Hard-refresh with `⌘⇧R` (`Ctrl+Shift+R` on
  Windows/Linux), or `⌘R` in the Mac app.
- **Errors after a deploy** — check the live logs: `npx wrangler tail -c wrangler.local.jsonc`, or the
  Worker's **Logs** tab in the dashboard.
- **A deploy half-finished** — run the deploy command again. Deploys replace the whole Worker, so a repeat
  run is safe.
- **Gmail disconnected or AI key missing** — that is not the update. Secrets live in Worker secrets and D1
  and are untouched; reconnect from **Settings → Accounts** or re-enter the key in **Settings → AI**.
- **Still stuck** — roll back with the command above, then open an issue with what
  `/api/version` reports.
