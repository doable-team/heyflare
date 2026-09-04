# Connecting mailboxes

heyflare can read and send from four kinds of mailbox. They all land in the same unified Imbox,
share one Screener, and behave identically once connected — the difference is only in how mail gets
in and out.

| Type | Good for | Inbound | Outbound | Needs |
|---|---|---|---|---|
| **Gmail** | Gmail, Google Workspace | Gmail API, polled every minute | Gmail API | Google OAuth client |
| **Outlook** | Outlook.com, Hotmail, Live, Microsoft 365 | Microsoft Graph, polled every minute | Graph `sendMail` | Microsoft Entra app |
| **IMAP/SMTP** | Fastmail, Migadu, cPanel webmail, self-hosted | IMAP, polled every minute | The provider's SMTP | An app password |
| **Domain mailbox** | An address on a domain you own | Cloudflare Email Routing — **pushed instantly** | Cloudflare Email Sending or Resend | The domain on Cloudflare |

Whichever you pick, **connecting imports nothing**. heyflare records where the mailbox stands right
now and syncs only what arrives afterwards. That is deliberate: it keeps the Screener meaningful
instead of burying you in years of history.

Every first-time sender waits in the **Screener** for a yes or no — so after connecting, new mail
appears there rather than in the Imbox until you have decided about the sender.

---

## Gmail

1. Create an OAuth client (see the main README, "Google OAuth client").
2. Set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.
3. Sidebar → **Connect Gmail**.

---

## Outlook

Microsoft retired Basic authentication for IMAP, POP and SMTP on **16 September 2024**, and removed
app passwords with it. A username and password will not connect an Outlook mailbox to anything,
in heyflare or any other client — OAuth is the only route. heyflare therefore talks to Microsoft
Graph over HTTPS rather than IMAP.

### Register the app

If you sign in to the Azure portal with a **personal** Microsoft account you land in a shared
"Microsoft Services" tenant that has no directory, so app registration is blocked. Symptoms are
`AADSTS16000` on sign-in, or `401 No access` on the App registrations blade. You need a directory of
your own first: create one via **Microsoft Entra ID → Manage tenants → Create**, or by signing up at
<https://azure.microsoft.com/free>, then switch into it with the directory picker.

1. **Entra ID → App registrations → New registration**.
2. **Supported account types**: *Accounts in any organizational directory and personal Microsoft
   accounts*. This is what lets both `@outlook.com` and work accounts sign in.
3. **Redirect URI** (platform **Web**): `https://YOUR_HOST/auth/microsoft/callback`.
   Add `http://localhost:8787/auth/microsoft/callback` too for local development — Microsoft permits
   plain `http` for `localhost` specifically.
4. **Certificates & secrets → New client secret**, then copy the **Value** column.

   Two columns in that table look like credentials and only one is. **Value** is the secret that
   authenticates. **Secret ID** is a GUID naming the row — Azure's internal reference to that
   credential, useless for signing in and harmless to share.

   The Value is displayed **once**, right after you create it, and is masked permanently after you
   navigate away; Microsoft stores only a hash, so there is no way to reveal it later. If you did not
   copy it, you cannot recover it — create a new secret and delete the old one.
5. **API permissions → Microsoft Graph → Delegated permissions**, add all four:
   `Mail.ReadWrite`, `Mail.Send`, `User.Read`, `offline_access`.
   `offline_access` is what yields a refresh token — without it, syncing stops after about an hour.
   No admin consent is required; you consent yourself at sign-in.

### Connect

Set `MS_CLIENT_ID` and `MS_CLIENT_SECRET`, then sidebar → **Connect Outlook**.

---

## IMAP / SMTP

Settings → Accounts → **Add mailbox**. Pick a provider preset or enter the servers yourself, then
supply an **app-specific password** where the provider offers one. heyflare logs in to *both*
servers before saving anything, so a mistake is reported immediately rather than leaving a
half-connected account behind.

- **IMAP**: port 993, implicit TLS.
- **SMTP**: port 465 (implicit TLS) or 587 (STARTTLS).
- **Port 25 cannot work.** Cloudflare blocks outbound connections to it and there is no way around
  that. Use 465 or 587.

Your password is encrypted at rest with AES-GCM keyed off `SESSION_SECRET`, is never returned by the
API, and Settings shows only a masked hint.

### Before you start

Most providers need IMAP switched on explicitly, and most require an app-specific password rather
than your account password once two-factor auth is enabled.

| Provider | IMAP host | SMTP host | Notes |
|---|---|---|---|
| Fastmail | `imap.fastmail.com` | `smtp.fastmail.com` | App password under Settings → Privacy & Security |
| Migadu | `imap.migadu.com` | `smtp.migadu.com` | |
| Zoho (personal) | `imap.zoho.com` | `smtp.zoho.com` | For `@zohomail.com` addresses |
| Zoho (own domain) | `imappro.zoho.com` | `smtppro.zoho.com` | Organisation accounts use the `pro` hosts |
| cPanel webmail | usually `mail.yourdomain.com` | usually `mail.yourdomain.com` | Check your host's control panel |

> **Zoho's free plan cannot be connected at all.** It excludes IMAP, POP3, ActiveSync *and*
> forwarding — it is browser-only, and no mail client can reach it. Zoho's own documentation states
> "For newly signed up users (Free plan), the IMAP Access feature will not be available." A paid plan
> (Mail Lite or above) is required. On a non-US data centre, swap the host suffix for `.eu`, `.in`
> or `.com.au`.

Because mail is sent through your provider's own SMTP server, **they** sign DKIM for you —
deliverability is theirs, not something heyflare has to solve.

---

## Domain mailboxes

An address on a domain you own, with the domain set up as a zone on your Cloudflare account. This is
the only type where mail is **pushed** the moment it arrives rather than polled, and it needs no
third-party account at all.

Settings → **Domains** → add the domain → create a mailbox. See the main README for DNS and
`CF_API_TOKEN` details.

Two things to know:

- **Enabling Email Routing takes over all mail for that domain.** The MX records change to
  Cloudflare, so any existing provider stops receiving. heyflare shows the current MX and asks first.
- **Inbound needs a deployed Worker.** Cloudflare Email Routing delivers to your Worker on the
  internet and cannot reach `localhost`. To exercise the path locally, post a raw message to the
  local email handler instead:

  ```sh
  curl -X POST "http://localhost:8787/cdn-cgi/handler/email?from=a@b.co&to=you@yourdomain" \
       --data-binary @message.eml
  ```

Sending needs Cloudflare Email Sending (Workers Paid) or a `RESEND_API_KEY`. Until one is set, a
domain mailbox receives but cannot send.

---

## Where OAuth credentials live, and rotating them

Gmail and Outlook each need an OAuth app's client ID and secret. heyflare reads them from two
places, in this order:

1. **Worker secrets** — `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`, `MS_CLIENT_ID` /
   `MS_CLIENT_SECRET`. Set with `wrangler secret put`, or `.dev.vars` locally. These always win.
2. **Settings → Accounts → Provider credentials** — stored in the database, encrypted with AES-GCM
   keyed off `SESSION_SECRET`, and never returned by the API.

A Worker secret is the stronger place to keep one, because it lives in Cloudflare's secret store
rather than your database. The stored fallback exists so a secret can be rotated from the browser
without CLI access and a redeploy — which matters because **Microsoft client secrets expire**, 24
months at the most and often sooner. When a Worker secret is set, the form shows the provider as
managed and refuses to store a value that would be ignored.

Rotating:

```sh
# Worker secret
npx wrangler secret put MS_CLIENT_SECRET

# or, if no Worker secret is set: Settings → Accounts → Provider credentials → paste → Save
```

Either way, create the new secret in the provider's console first, switch heyflare over, then delete
the old one. Existing connected mailboxes keep working — the credentials authenticate the *app*, not
your mailbox, so rotating one does not sign anybody out.

Credentials are never written to the repository. `.dev.vars` is git-ignored.

---

## Troubleshooting

**Nothing appears after connecting.** Expected at first — nothing historical is imported. Send
yourself a new message, then look in the **Screener**, not the Imbox: first-time senders wait there.

**Nothing syncs when running locally.** `wrangler dev` does not fire the cron trigger, so nothing
polls on its own. Use **Sync** in Settings → Accounts, or switch away from the browser tab and back
(sync-on-focus, throttled to 45 seconds). Deployed, the cron handles it every minute.

**`AADSTS50011` redirect mismatch.** The redirect URI in Azure must match exactly, including scheme,
port and any trailing slash.

**`AADSTS65001` consent required.** The Graph permissions were not added or not saved.

**Outlook stops syncing after about an hour.** `offline_access` is missing from the app
registration, so no refresh token was issued.

**IMAP or SMTP reports "Invalid credentials" / `535`.** In order of likelihood: the provider's plan
does not include IMAP; IMAP access is not enabled in their settings; you used your account password
where an app-specific password is required; or an organisation account is pointed at the personal
host names.

**`smtp_port_25_blocked`.** Cloudflare blocks outbound port 25. Use 465 or 587.
