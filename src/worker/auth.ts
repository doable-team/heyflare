import type { Context, MiddlewareHandler } from "hono";
import { getCookie, setCookie, deleteCookie } from "hono/cookie";
import type { AppEnv } from "./env";
import type { UserRow, AccountRow } from "./db";
import { now } from "./db";

const PBKDF2_ITER = 100_000;
const SESSION_COOKIE = "hey_session";
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

function toB64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
function fromB64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function pbkdf2(password: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, 256);
  return new Uint8Array(bits);
}

export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await pbkdf2(password, salt, PBKDF2_ITER);
  return `pbkdf2$${PBKDF2_ITER}$${toB64(salt)}$${toB64(hash)}`;
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parts = stored.split("$");
  if (parts.length !== 4 || parts[0] !== "pbkdf2") return false;
  const iterations = parseInt(parts[1], 10);
  const salt = fromB64(parts[2]);
  const expected = fromB64(parts[3]);
  const actual = await pbkdf2(password, salt, iterations);
  if (actual.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < actual.length; i++) diff |= actual[i] ^ expected[i];
  return diff === 0;
}

function randomId(bytes = 32): string {
  const arr = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(arr, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function createSession(c: Context<AppEnv>, userId: string): Promise<string> {
  const id = randomId(32);
  const t = now();
  await c.env.DB.prepare(`INSERT INTO sessions (id, user_id, created_at, expires_at, user_agent) VALUES (?, ?, ?, ?, ?)`)
    .bind(id, userId, t, t + SESSION_TTL_MS, c.req.header("user-agent") ?? null)
    .run();
  const secure = new URL(c.req.url).protocol === "https:";
  setCookie(c, SESSION_COOKIE, id, {
    httpOnly: true,
    secure,
    sameSite: "Lax",
    path: "/",
    maxAge: SESSION_TTL_MS / 1000,
  });
  return id;
}

export async function destroySession(c: Context<AppEnv>) {
  const id = getSessionId(c);
  if (id) await c.env.DB.prepare(`DELETE FROM sessions WHERE id = ?`).bind(id).run();
  deleteCookie(c, SESSION_COOKIE, { path: "/" });
}

function getSessionId(c: Context<AppEnv>): string | null {
  const auth = c.req.header("authorization");
  if (auth && auth.toLowerCase().startsWith("bearer ")) return auth.slice(7).trim();
  return getCookie(c, SESSION_COOKIE) ?? null;
}

export async function getSessionUser(c: Context<AppEnv>): Promise<UserRow | null> {
  const id = getSessionId(c);
  if (!id) return null;
  const row = await c.env.DB.prepare(
    `SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.id = ? AND s.expires_at > ?`
  )
    .bind(id, now())
    .first<UserRow>();
  return row ?? null;
}

export const requireUser: MiddlewareHandler<AppEnv> = async (c, next) => {
  const user = await getSessionUser(c);
  if (!user) return c.json({ error: "unauthorized" }, 401);
  if (user.disabled) return c.json({ error: "account_disabled" }, 403);
  c.set("user", user);
  await next();
};


/**
 * Account scope. `X-Account-Id: <id>` (or `?account=<id>`) narrows to one account; `all` or absent is the
 * unified scope across every account the user owns. An id that doesn't belong to the user falls back to unified.
 */
export const requireAccount: MiddlewareHandler<AppEnv> = async (c, next) => {
  const user = c.get("user");
  const wanted = (c.req.header("x-account-id") || c.req.query("account") || "").trim();
  const all = await c.env.DB.prepare(`SELECT * FROM accounts WHERE user_id = ? ORDER BY created_at ASC`).bind(user.id).all<AccountRow>();
  const accounts = all.results;
  if (!accounts.length) return c.json({ error: "no_account" }, 400);
  const specific = wanted && wanted !== "all" ? accounts.find((a) => a.id === wanted) ?? null : null;
  c.set("account", specific ?? accounts[0]);
  c.set("accountIds", specific ? [specific.id] : accounts.map((a) => a.id));
  c.set("allAccountIds", accounts.map((a) => a.id));
  await next();
};
