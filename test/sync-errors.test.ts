import { describe, it, expect, beforeAll, beforeEach, vi, afterEach } from "vitest";
import { migrate, resetData, seedUser, testEnv } from "./helpers";
import { syncAccount } from "../src/worker/sync";
import { ImapError } from "../src/worker/imap";
import type { AccountRow } from "../src/worker/db";

vi.mock("../src/worker/imapbox", () => ({ syncImapAccount: vi.fn() }));
import { syncImapAccount } from "../src/worker/imapbox";
const mockSync = syncImapAccount as unknown as ReturnType<typeof vi.fn>;

async function seedImap(): Promise<AccountRow> {
  await testEnv.DB.prepare(
    `INSERT INTO accounts (id, user_id, provider, email, display_name, initial_sync_done, initial_sync_count, sync_status, signature, cover_art, created_at)
     VALUES ('i1', 'u1', 'imap', 'me@example.com', '', 1, 0, 'idle', '', '', ?)`
  ).bind(Date.now()).run();
  return (await testEnv.DB.prepare(`SELECT * FROM accounts WHERE id='i1'`).first<AccountRow>())!;
}
const reload = async () => (await testEnv.DB.prepare(`SELECT * FROM accounts WHERE id='i1'`).first<AccountRow>())!;
const logCount = async () =>
  (await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM sync_log WHERE account_id='i1'`).first<{ n: number }>())!.n;

beforeAll(migrate);
beforeEach(async () => {
  await resetData();
  await seedUser();
  mockSync.mockReset();
});
afterEach(() => vi.restoreAllMocks());

describe("a mailbox with wrong credentials", () => {
  it("is disconnected rather than retried forever", async () => {
    // The cron selects `sync_status <> 'disconnected'`. Anything else is picked up again every
    // minute for as long as the password stays wrong, costing writes each time.
    mockSync.mockRejectedValue(new ImapError("imap_login_failed: NO [AUTHENTICATIONFAILED]", { auth: true }));
    const r = await syncAccount(testEnv, await seedImap());
    expect(r.status).toBe("disconnected");
    expect((await reload()).sync_status).toBe("disconnected");
  });

  it("is then skipped by the cron query entirely", async () => {
    mockSync.mockRejectedValue(new ImapError("imap_login_failed", { auth: true }));
    await syncAccount(testEnv, await seedImap());
    const due = await testEnv.DB.prepare(
      `SELECT id FROM accounts WHERE provider = 'imap' AND sync_status <> 'disconnected'`
    ).all<{ id: string }>();
    expect(due.results).toHaveLength(0);
  });
});

describe("a mailbox failing transiently", () => {
  it("stays in error so it keeps being retried", async () => {
    mockSync.mockRejectedValue(new ImapError("imap_timeout: greeting"));
    const r = await syncAccount(testEnv, await seedImap());
    expect(r.status).toBe("error");
    expect((await reload()).sync_status).toBe("error");
  });

  it("does not rewrite the row when the same failure repeats", async () => {
    // This is the write amplification: one UPDATE plus one log row per account per minute.
    mockSync.mockRejectedValue(new ImapError("imap_timeout: greeting"));
    const acc = await seedImap();
    await syncAccount(testEnv, acc);
    const afterFirst = await reload();
    const logsAfterFirst = await logCount();

    for (let i = 0; i < 5; i++) await syncAccount(testEnv, await reload());

    expect(await logCount()).toBe(logsAfterFirst);
    expect((await reload()).last_synced_at).toBe(afterFirst.last_synced_at);
  });

  it("does record a failure that has changed", async () => {
    mockSync.mockRejectedValueOnce(new ImapError("imap_timeout: greeting"));
    const acc = await seedImap();
    await syncAccount(testEnv, acc);
    const before = await logCount();
    mockSync.mockRejectedValueOnce(new ImapError("imap_select_failed: INBOX"));
    await syncAccount(testEnv, await reload());
    expect(await logCount()).toBe(before + 1);
  });
});
