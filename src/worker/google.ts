import type { Env } from "./env";
import type { AccountRow } from "./db";
import { now } from "./db";

const GMAIL_BASE = "https://gmail.googleapis.com/gmail/v1/users/me/";
const BATCH_URL = "https://www.googleapis.com/batch/gmail/v1";
/** Granted on every connect. Calendar is asked for separately so mail-only users aren't scared off. */
export const CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar";
const SCOPES = [
  "https://www.googleapis.com/auth/gmail.modify",
  "https://www.googleapis.com/auth/contacts.other.readonly",
  "https://www.googleapis.com/auth/contacts.readonly",
  "https://www.googleapis.com/auth/directory.readonly",
  "openid",
  "email",
  "profile",
];

export class GmailError extends Error {
  status: number;
  body: string;
  constructor(status: number, body: string, message?: string) {
    super(message ?? `Gmail API error ${status}: ${body.slice(0, 300)}`);
    this.status = status;
    this.body = body;
  }
}

export function googleConfigured(env: Env): boolean {
  return !!(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET);
}

/** True when this account's refresh token already carries the Calendar scope. */
export function hasCalendarScope(scopes: string | null | undefined): boolean {
  return (scopes ?? "").split(/\s+/).includes(CALENDAR_SCOPE);
}

export function googleAuthUrl(env: Env, state: string, redirectUri: string, loginHint?: string, calendar = false): string {
  const u = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  u.searchParams.set("client_id", env.GOOGLE_CLIENT_ID!);
  u.searchParams.set("redirect_uri", redirectUri);
  u.searchParams.set("response_type", "code");
  u.searchParams.set("scope", (calendar ? [...SCOPES, CALENDAR_SCOPE] : SCOPES).join(" "));
  u.searchParams.set("access_type", "offline");
  u.searchParams.set("prompt", "consent");
  u.searchParams.set("include_granted_scopes", "true");
  u.searchParams.set("state", state);
  if (loginHint) u.searchParams.set("login_hint", loginHint);
  return u.toString();
}

export interface TokenResponse {
  access_token: string;
  refresh_token?: string;
  expires_in: number;
  id_token?: string;
  scope?: string;
  token_type?: string;
}

export async function exchangeCode(env: Env, code: string, redirectUri: string): Promise<TokenResponse> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: env.GOOGLE_CLIENT_ID!,
      client_secret: env.GOOGLE_CLIENT_SECRET!,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
  });
  const body = await res.text();
  if (!res.ok) throw new GmailError(res.status, body, `Token exchange failed: ${body.slice(0, 300)}`);
  return JSON.parse(body) as TokenResponse;
}

export async function fetchUserInfo(accessToken: string): Promise<{ email: string; name: string; picture: string }> {
  const res = await fetch("https://www.googleapis.com/oauth2/v3/userinfo", {
    headers: { authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) throw new GmailError(res.status, await res.text(), "userinfo failed");
  const j = (await res.json()) as { email?: string; name?: string; picture?: string };
  return { email: (j.email ?? "").toLowerCase(), name: j.name ?? "", picture: j.picture ?? "" };
}

/** Authed fetch against any Google API URL (People API etc.) using the account's token. */
export function googleFetch(env: Env, account: AccountRow, url: string, init: RequestInit = {}): Promise<Response> {
  return gmailFetch(env, account, url, init);
}

async function refreshAccessToken(env: Env, account: AccountRow): Promise<string> {
  if (account.provider === "domain") throw new GmailError(400, "not_gmail", "Not a Gmail account");
  if (!account.refresh_token) {
    await markDisconnected(env, account, "No refresh token; please reconnect the account.");
    throw new GmailError(401, "no_refresh_token", "Account disconnected: no refresh token");
  }
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID ?? "",
      client_secret: env.GOOGLE_CLIENT_SECRET ?? "",
      refresh_token: account.refresh_token,
      grant_type: "refresh_token",
    }),
  });
  const body = await res.text();
  if (!res.ok) {
    if (/invalid_grant/i.test(body)) {
      await markDisconnected(env, account, "Google revoked access (invalid_grant). Please reconnect.");
    }
    throw new GmailError(res.status, body, `Token refresh failed: ${body.slice(0, 200)}`);
  }
  const j = JSON.parse(body) as TokenResponse;
  account.access_token = j.access_token;
  account.token_expires_at = now() + (j.expires_in ?? 3600) * 1000;
  await env.DB.prepare(`UPDATE accounts SET access_token = ?, token_expires_at = ? WHERE id = ?`)
    .bind(account.access_token, account.token_expires_at, account.id)
    .run();
  return j.access_token;
}

async function markDisconnected(env: Env, account: AccountRow, reason: string) {
  account.sync_status = "disconnected";
  account.sync_error = reason;
  await env.DB.prepare(`UPDATE accounts SET sync_status = 'disconnected', sync_error = ? WHERE id = ?`).bind(reason, account.id).run();
}

export async function getAccessToken(env: Env, account: AccountRow, force = false): Promise<string> {
  if (!force && account.access_token && account.token_expires_at && account.token_expires_at - now() > 60_000) {
    return account.access_token;
  }
  return refreshAccessToken(env, account);
}

/** Fetch against the Gmail API. `path` is relative to users/me/ (or absolute). */
export async function gmailFetch(env: Env, account: AccountRow, path: string, init: RequestInit = {}): Promise<Response> {
  if (account.provider === "domain") throw new GmailError(400, "not_gmail", "Not a Gmail account");
  const url = /^https?:/i.test(path) ? path : GMAIL_BASE + path;
  let token = await getAccessToken(env, account);
  const doFetch = (t: string) =>
    fetch(url, {
      ...init,
      headers: { ...(init.headers as Record<string, string> | undefined), authorization: `Bearer ${t}` },
    });
  let res = await doFetch(token);
  if (res.status === 401) {
    token = await getAccessToken(env, account, true);
    res = await doFetch(token);
  }
  return res;
}

export async function gmailJson<T = any>(env: Env, account: AccountRow, path: string, init: RequestInit = {}): Promise<T> {
  const res = await gmailFetch(env, account, path, init);
  const text = await res.text();
  if (!res.ok) throw new GmailError(res.status, text);
  return (text ? JSON.parse(text) : {}) as T;
}

export async function gmailPost<T = any>(env: Env, account: AccountRow, path: string, body: unknown): Promise<T> {
  return gmailJson<T>(env, account, path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

/**
 * Batch GET messages using the Gmail batch endpoint (up to 100 per request).
 * Returns successfully-fetched message objects; failed items are skipped.
 */
export async function gmailBatchGet<T = any>(
  env: Env,
  account: AccountRow,
  ids: string[],
  format: "full" | "metadata" | "minimal" = "full",
  extraQuery = ""
): Promise<T[]> {
  const out: T[] = [];
  for (let i = 0; i < ids.length; i += 100) {
    const slice = ids.slice(i, i + 100);
    const boundary = `batch_${crypto.randomUUID().replace(/-/g, "")}`;
    const parts: string[] = [];
    slice.forEach((id, idx) => {
      parts.push(
        `--${boundary}\r\nContent-Type: application/http\r\nContent-ID: <item${idx}>\r\n\r\nGET /gmail/v1/users/me/messages/${encodeURIComponent(id)}?format=${format}${extraQuery}\r\n\r\n`
      );
    });
    parts.push(`--${boundary}--\r\n`);
    const body = parts.join("");

    let token = await getAccessToken(env, account);
    const send = (t: string) =>
      fetch(BATCH_URL, {
        method: "POST",
        headers: { authorization: `Bearer ${t}`, "content-type": `multipart/mixed; boundary=${boundary}` },
        body,
      });
    let res = await send(token);
    if (res.status === 401) {
      token = await getAccessToken(env, account, true);
      res = await send(token);
    }
    const text = await res.text();
    if (!res.ok) throw new GmailError(res.status, text, `Batch GET failed: ${text.slice(0, 200)}`);
    const ct = res.headers.get("content-type") ?? "";
    const bm = ct.match(/boundary="?([^";]+)"?/i);
    const rb = bm?.[1];
    if (!rb) throw new GmailError(500, text.slice(0, 200), "Batch response missing boundary");
    for (const item of parseBatchResponse(text, rb)) {
      if (item.status >= 200 && item.status < 300 && item.body) {
        try {
          out.push(JSON.parse(item.body) as T);
        } catch {
          // skip malformed
        }
      }
    }
  }
  return out;
}

function parseBatchResponse(text: string, boundary: string): { status: number; body: string }[] {
  const items: { status: number; body: string }[] = [];
  const normalized = text.replace(/\r\n/g, "\n");
  const segments = normalized.split(`--${boundary}`);
  for (const seg of segments) {
    const s = seg.trim();
    if (!s || s === "--") continue;
    // Outer part headers, blank line, inner HTTP response.
    const firstBreak = s.indexOf("\n\n");
    if (firstBreak < 0) continue;
    const inner = s.slice(firstBreak + 2);
    const statusMatch = inner.match(/^HTTP\/[\d.]+\s+(\d{3})/);
    const status = statusMatch ? parseInt(statusMatch[1], 10) : 0;
    const secondBreak = inner.indexOf("\n\n");
    const body = secondBreak >= 0 ? inner.slice(secondBreak + 2).trim() : "";
    items.push({ status, body });
  }
  return items;
}
