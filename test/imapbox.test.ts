import { describe, it, expect, vi, beforeAll, beforeEach, afterEach } from "vitest";
import { migrate, resetData, seedUser, testEnv, rawMime } from "./helpers";
import { passwordHint, encryptPassword, loadImapRow, configFor, syncImapAccount } from "../src/worker/imapbox";
import type { AccountRow } from "../src/worker/db";

vi.mock("../src/worker/imap", async (orig) => {
  const actual = await orig<typeof import("../src/worker/imap")>();
  return { ...actual, imapFetchNew: vi.fn(), imapVerify: vi.fn() };
});
import { imapFetchNew } from "../src/worker/imap";

const fetchNew = imapFetchNew as unknown as ReturnType<typeof vi.fn>;
const bytes = (s: string) => new TextEncoder().encode(s);

async function seedImapAccount(over: Partial<Record<string, unknown>> = {}): Promise<AccountRow> {
  const t = Date.now();
  await testEnv.DB.prepare(
    `INSERT INTO accounts (id, user_id, provider, email, display_name, access_token, refresh_token, token_expires_at, scopes,
       history_id, delta_link, initial_sync_done, initial_sync_page_token, initial_sync_count, sync_status, sync_error,
       last_synced_at, signature, cover_art, avatar_url, created_at)
     VALUES ('imap1', 'u1', 'imap', 'me@zoho.test', 'Me', NULL, NULL, NULL, '', NULL, NULL, 0, NULL, 0, 'idle', NULL, NULL, '', '', '', ?)`
  ).bind(t).run();
  await testEnv.DB.prepare(
    `INSERT INTO imap_accounts (account_id, imap_host, imap_port, imap_security, smtp_host, smtp_port, smtp_security,
       username, password_enc, password_hint, folder, uid_validity, last_uid, updated_at)
     VALUES ('imap1', 'imap.zoho.com', 993, 'tls', 'smtp.zoho.com', 465, 'tls', 'me@zoho.test', ?, '••••34', 'INBOX', ?, ?, ?)`
  )
    .bind(await encryptPassword(testEnv, "app-password-1234"), over.uid_validity ?? 100, over.last_uid ?? 5, t)
    .run();
  return (await testEnv.DB.prepare(`SELECT * FROM accounts WHERE id = 'imap1'`).first<AccountRow>())!;
}

beforeAll(migrate);
beforeEach(async () => {
  await resetData();
  await testEnv.DB.prepare(`DELETE FROM imap_accounts`).run();
  await seedUser();
  fetchNew.mockReset();
});
afterEach(() => vi.restoreAllMocks());

describe("migration 0016", () => {
  it("creates the credentials table", async () => {
    const r = await testEnv.DB.prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name='imap_accounts'`).first();
    expect(r).toBeTruthy();
  });
});

describe("passwordHint", () => {
  it("reveals only the last couple of characters", () => {
    expect(passwordHint("app-password-1234")).toMatch(/34$/);
    expect(passwordHint("app-password-1234")).not.toContain("app-password");
  });

  it("does not leak length for very short secrets", () => {
    expect(passwordHint("abc")).toBe("••••");
  });
});

describe("credential storage", () => {
  it("round-trips the password through encryption and never stores it in clear", async () => {
    await seedImapAccount();
    const row = await loadImapRow(testEnv, "imap1");
    expect(row!.password_enc).not.toContain("app-password");
    const cfg = await configFor(testEnv, "imap1");
    expect(cfg!.imap.password).toBe("app-password-1234");
    expect(cfg!.smtp.password).toBe("app-password-1234");
    expect(cfg!.smtp.port).toBe(465);
  });
});

describe("syncImapAccount", () => {
  it("ingests new mail into the Screener and advances the cursor", async () => {
    const acc = await seedImapAccount();
    fetchNew.mockResolvedValue({
      uidValidity: 100,
      lastUid: 7,
      reset: false,
      messages: [{ uid: 7, raw: bytes(rawMime({ messageId: "<a@example.com>" })) }],
    });

    const r = await syncImapAccount(testEnv, acc);

    expect(r.added).toBe(1);
    const thread = await testEnv.DB.prepare(`SELECT bucket FROM threads`).first<{ bucket: string }>();
    expect(thread!.bucket).toBe("screener");
    const row = await loadImapRow(testEnv, "imap1");
    expect(row!.last_uid).toBe(7);
  });

  it("is idempotent when the server replays a message", async () => {
    const acc = await seedImapAccount();
    fetchNew.mockResolvedValue({
      uidValidity: 100,
      lastUid: 7,
      reset: false,
      messages: [{ uid: 7, raw: bytes(rawMime({ messageId: "<a@example.com>" })) }],
    });
    await syncImapAccount(testEnv, acc);
    const second = await syncImapAccount(testEnv, acc);
    expect(second.added).toBe(0);
    const n = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM messages`).first<{ n: number }>();
    expect(n!.n).toBe(1);
  });

  it("re-baselines instead of re-importing when UIDVALIDITY changes", async () => {
    // A renumbered folder invalidates every stored UID; importing it all would flood the Screener.
    const acc = await seedImapAccount();
    fetchNew.mockResolvedValue({ uidValidity: 999, lastUid: 42, reset: true, messages: [] });

    const r = await syncImapAccount(testEnv, acc);

    expect(r.added).toBe(0);
    const row = await loadImapRow(testEnv, "imap1");
    expect(row!.uid_validity).toBe(999);
    expect(row!.last_uid).toBe(42);
    const n = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM messages`).first<{ n: number }>();
    expect(n!.n).toBe(0);
  });

  it("leaves the cursor alone when ingest throws", async () => {
    const acc = await seedImapAccount();
    fetchNew.mockRejectedValue(new Error("imap_fetch_failed: boom"));
    await expect(syncImapAccount(testEnv, acc)).rejects.toThrow(/boom/);
    const row = await loadImapRow(testEnv, "imap1");
    expect(row!.last_uid).toBe(5);
  });

  it("does nothing for an account with no stored credentials", async () => {
    const t = Date.now();
    await testEnv.DB.prepare(
      `INSERT INTO accounts (id, user_id, provider, email, display_name, initial_sync_done, initial_sync_count, sync_status, signature, cover_art, created_at)
       VALUES ('orphan', 'u1', 'imap', 'x@y.z', '', 0, 0, 'idle', '', '', ?)`
    ).bind(t).run();
    const acc = (await testEnv.DB.prepare(`SELECT * FROM accounts WHERE id='orphan'`).first<AccountRow>())!;
    expect(await syncImapAccount(testEnv, acc)).toEqual({ added: 0 });
  });
});
