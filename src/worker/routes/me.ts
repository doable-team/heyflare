import { Hono, type Context } from "hono";
import type { AppEnv } from "../env";
import type { AccountRow, UserRow } from "../db";
import { now, toAccount, toUser, safeJson } from "../db";
import { hashPassword, verifyPassword } from "../auth";
import { configuredProviders } from "../oauth";
import { generateSecret, otpauthUrl, verifyTotp, generateRecoveryCodes, hashRecoveryCode, matchRecoveryCode } from "../totp";
import type { UserSettings } from "@shared/types";

const me = new Hono<AppEnv>();

me.get("/", async (c) => {
  const user = c.get("user");
  const accounts = await c.env.DB.prepare(`SELECT * FROM accounts WHERE user_id = ? ORDER BY created_at ASC`).bind(user.id).all<AccountRow>();
  const cfg = await configuredProviders(c.env);
  return c.json({
    user: toUser(user),
    accounts: accounts.results.map(toAccount),
    setup_required: false,
    google_configured: cfg.google,
    microsoft_configured: cfg.microsoft,
  });
});

me.patch("/", async (c) => {
  const user = c.get("user");
  const body = await c.req.json<{ name?: string; settings?: UserSettings }>().catch(() => ({}) as any);
  const name = typeof body.name === "string" ? body.name.trim().slice(0, 100) : user.name;
  const settings = body.settings ? { ...safeJson<UserSettings>(user.settings_json, {}), ...body.settings } : safeJson<UserSettings>(user.settings_json, {});
  await c.env.DB.prepare(`UPDATE users SET name = ?, settings_json = ? WHERE id = ?`).bind(name, JSON.stringify(settings), user.id).run();
  const fresh = await c.env.DB.prepare(`SELECT * FROM users WHERE id = ?`).bind(user.id).first<UserRow>();
  return c.json({ user: toUser(fresh!) });
});

me.post("/password", async (c) => {
  const user = c.get("user");
  const body = await c.req.json<{ current?: string; next?: string }>().catch(() => ({}) as any);
  if (!(await verifyPassword(body.current ?? "", user.password_hash))) return c.json({ error: "invalid_credentials" }, 401);
  if ((body.next ?? "").length < 8) return c.json({ error: "password_too_short" }, 400);
  await c.env.DB.prepare(`UPDATE users SET password_hash = ? WHERE id = ?`).bind(await hashPassword(body.next!), user.id).run();
  return c.json({ ok: true, at: now() });
});

// ---------- Two-factor authentication ----------

function recoveryList(u: UserRow): string[] {
  return safeJson<string[]>(u.recovery_codes_json ?? "[]", []);
}

async function freshUser(c: Context<AppEnv>): Promise<UserRow> {
  const id = c.get("user").id;
  return (await c.env.DB.prepare(`SELECT * FROM users WHERE id = ?`).bind(id).first<UserRow>())!;
}

/** A valid TOTP code, or an unused recovery code (which gets consumed). */
async function checkSecondFactor(db: D1Database, u: UserRow, code: string): Promise<boolean> {
  if (!u.totp_enabled || !u.totp_secret) return false;
  if (await verifyTotp(u.totp_secret, code)) return true;
  const list = recoveryList(u);
  const idx = await matchRecoveryCode(code, list);
  if (idx < 0) return false;
  list.splice(idx, 1);
  await db.prepare(`UPDATE users SET recovery_codes_json = ? WHERE id = ?`).bind(JSON.stringify(list), u.id).run();
  return true;
}

me.get("/2fa", async (c) => {
  const u = await freshUser(c);
  return c.json({ enabled: !!u.totp_enabled, recovery_left: u.totp_enabled ? recoveryList(u).length : 0 });
});

me.post("/2fa/setup", async (c) => {
  const u = await freshUser(c);
  if (u.totp_enabled) return c.json({ error: "already_enabled" }, 400);
  const secret = generateSecret();
  await c.env.DB.prepare(`UPDATE users SET totp_secret = ?, totp_enabled = 0 WHERE id = ?`).bind(secret, u.id).run();
  return c.json({ secret, otpauth_url: otpauthUrl(u.email, secret) });
});

me.post("/2fa/enable", async (c) => {
  const u = await freshUser(c);
  const body = await c.req.json<{ code?: string }>().catch(() => ({}) as any);
  if (u.totp_enabled) return c.json({ error: "already_enabled" }, 400);
  if (!u.totp_secret) return c.json({ error: "setup_first" }, 400);
  if (!(await verifyTotp(u.totp_secret, body.code ?? ""))) return c.json({ error: "invalid_code" }, 400);
  const codes = generateRecoveryCodes();
  const hashed = await Promise.all(codes.map((x) => hashRecoveryCode(x)));
  await c.env.DB.prepare(`UPDATE users SET totp_enabled = 1, recovery_codes_json = ? WHERE id = ?`).bind(JSON.stringify(hashed), u.id).run();
  return c.json({ ok: true, recovery_codes: codes });
});

me.post("/2fa/recovery-codes", async (c) => {
  const u = await freshUser(c);
  const body = await c.req.json<{ code?: string }>().catch(() => ({}) as any);
  if (!u.totp_enabled || !u.totp_secret) return c.json({ error: "not_enabled" }, 400);
  if (!(await verifyTotp(u.totp_secret, body.code ?? ""))) return c.json({ error: "invalid_code" }, 400);
  const codes = generateRecoveryCodes();
  const hashed = await Promise.all(codes.map((x) => hashRecoveryCode(x)));
  await c.env.DB.prepare(`UPDATE users SET recovery_codes_json = ? WHERE id = ?`).bind(JSON.stringify(hashed), u.id).run();
  return c.json({ ok: true, recovery_codes: codes });
});

me.post("/2fa/disable", async (c) => {
  const u = await freshUser(c);
  const body = await c.req.json<{ password?: string; code?: string }>().catch(() => ({}) as any);
  if (!(await verifyPassword(body.password ?? "", u.password_hash))) return c.json({ error: "invalid_credentials" }, 401);
  if (u.totp_enabled && !(await checkSecondFactor(c.env.DB, u, body.code ?? ""))) return c.json({ error: "invalid_code" }, 400);
  await c.env.DB.prepare(`UPDATE users SET totp_secret = NULL, totp_enabled = 0, recovery_codes_json = '[]' WHERE id = ?`).bind(u.id).run();
  return c.json({ ok: true });
});

export default me;
