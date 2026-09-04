import { describe, it, expect, vi, beforeAll, beforeEach, afterEach } from "vitest";
import { syncOutlookAccount } from "../src/worker/outlook";
import { toAccount } from "../src/worker/db";
import { migrate, resetData, seedUser, seedOutlookAccount, testEnv, rawMime } from "./helpers";
import type { AccountRow } from "../src/worker/db";

function json(body: unknown) {
  return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
}
function text(body: string) {
  return new Response(body, { status: 200, headers: { "content-type": "text/plain" } });
}

const DELTA = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$deltatoken=NEXT";

let fetchMock: ReturnType<typeof vi.fn>;

beforeAll(migrate);
beforeEach(async () => {
  await resetData();
  await seedUser();
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});
afterEach(() => vi.unstubAllGlobals());

async function reload(id = "acc1"): Promise<AccountRow> {
  return (await testEnv.DB.prepare(`SELECT * FROM accounts WHERE id = ?`).bind(id).first<AccountRow>())!;
}

describe("migration 0015", () => {
  it("adds the delta_link cursor column", async () => {
    const info = await testEnv.DB.prepare(`PRAGMA table_info(accounts)`).all<{ name: string }>();
    expect(info.results.map((r) => r.name)).toContain("delta_link");
  });
});

describe("first connect", () => {
  it("records a cursor without importing anything", async () => {
    // The HEY behaviour: connecting a mailbox imports no history, it only starts watching.
    fetchMock.mockResolvedValueOnce(json({ value: [{ id: "old1" }, { id: "old2" }], "@odata.deltaLink": DELTA }));
    const acc = await seedOutlookAccount({ delta_link: null, initial_sync_done: 0 } as never);

    const r = await syncOutlookAccount(testEnv, acc);

    expect(r.added).toBe(0);
    const after = await reload();
    expect(after.delta_link).toBe(DELTA);
    expect(after.initial_sync_done).toBe(1);
    const msgs = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM messages`).first<{ n: number }>();
    expect(msgs!.n).toBe(0);
    // Only the delta walk happened — no message bodies were fetched.
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("keeps priming across ticks until it reaches the end of a long chain", async () => {
    // A big inbox needs more than one invocation to walk; it must not start ingesting halfway.
    const pages = Array.from({ length: 10 }, (_, i) =>
      json({ value: [{ id: `old${i}` }], "@odata.nextLink": `https://graph.microsoft.com/p${i + 1}` })
    );
    for (const p of pages) fetchMock.mockResolvedValueOnce(p);
    const acc = await seedOutlookAccount({ delta_link: null, initial_sync_done: 0 } as never);

    await syncOutlookAccount(testEnv, acc);

    const after = await reload();
    expect(after.initial_sync_done).toBe(0);
    expect(after.delta_link).toBe("https://graph.microsoft.com/p10");
    const msgs = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM messages`).first<{ n: number }>();
    expect(msgs!.n).toBe(0);
  });
});

describe("incremental sync", () => {
  it("ingests new mail into the Screener and advances the cursor", async () => {
    fetchMock
      .mockResolvedValueOnce(json({ value: [{ id: "m1" }], "@odata.deltaLink": DELTA }))
      .mockResolvedValueOnce(text(rawMime()));
    const acc = await seedOutlookAccount({ delta_link: "https://graph.microsoft.com/old-cursor" });

    const r = await syncOutlookAccount(testEnv, acc);

    expect(r.added).toBe(1);
    const thread = await testEnv.DB.prepare(`SELECT * FROM threads`).first<{ bucket: string; subject: string }>();
    // An unknown sender must wait for a yes/no rather than landing in the Imbox.
    expect(thread!.bucket).toBe("screener");
    expect(thread!.subject).toBe("Hello there");
    expect((await reload()).delta_link).toBe(DELTA);
  });

  it("is idempotent: the same message twice adds one row", async () => {
    const acc = await seedOutlookAccount({ delta_link: "https://graph.microsoft.com/c0" });
    fetchMock
      .mockResolvedValueOnce(json({ value: [{ id: "m1" }], "@odata.deltaLink": DELTA }))
      .mockResolvedValueOnce(text(rawMime()));
    await syncOutlookAccount(testEnv, acc);

    fetchMock
      .mockResolvedValueOnce(json({ value: [{ id: "m1" }], "@odata.deltaLink": DELTA }))
      .mockResolvedValueOnce(text(rawMime()));
    const second = await syncOutlookAccount(testEnv, await reload());

    expect(second.added).toBe(0);
    const n = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM messages`).first<{ n: number }>();
    expect(n!.n).toBe(1);
  });

  it("threads a reply onto the original rather than starting a new thread", async () => {
    const acc = await seedOutlookAccount({ delta_link: "https://graph.microsoft.com/c0" });
    fetchMock
      .mockResolvedValueOnce(json({ value: [{ id: "m1" }], "@odata.deltaLink": DELTA }))
      .mockResolvedValueOnce(text(rawMime({ messageId: "<first@example.com>" })));
    await syncOutlookAccount(testEnv, acc);

    fetchMock
      .mockResolvedValueOnce(json({ value: [{ id: "m2" }], "@odata.deltaLink": DELTA }))
      .mockResolvedValueOnce(text(rawMime({ messageId: "<second@example.com>", subject: "Re: Hello there", inReplyTo: "<first@example.com>" })));
    await syncOutlookAccount(testEnv, await reload());

    const threads = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM threads`).first<{ n: number }>();
    expect(threads!.n).toBe(1);
    const msgs = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM messages`).first<{ n: number }>();
    expect(msgs!.n).toBe(2);
  });

  it("leaves the cursor alone when a body fetch fails mid-run", async () => {
    // Replaying is safe (ingest is idempotent); losing mail is not. The cursor must not move.
    const before = "https://graph.microsoft.com/c0";
    const acc = await seedOutlookAccount({ delta_link: before });
    fetchMock
      .mockResolvedValueOnce(json({ value: [{ id: "m1" }], "@odata.deltaLink": DELTA }))
      .mockResolvedValueOnce(new Response("boom", { status: 500 }));

    await expect(syncOutlookAccount(testEnv, acc)).rejects.toThrow();
    expect((await reload()).delta_link).toBe(before);
  });

  it("resets to priming when Graph rejects an expired delta token", async () => {
    // Re-walking as new would dump the whole mailbox into the Screener, so it re-primes instead.
    const acc = await seedOutlookAccount({ delta_link: "https://graph.microsoft.com/stale" });
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ error: { code: "resyncRequired" } }), { status: 410 }));

    const r = await syncOutlookAccount(testEnv, acc);

    expect(r.added).toBe(0);
    const after = await reload();
    expect(after.delta_link).toBeNull();
    expect(after.initial_sync_done).toBe(0);
    const n = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM messages`).first<{ n: number }>();
    expect(n!.n).toBe(0);
  });

  it("also resets on syncStateNotFound", async () => {
    const acc = await seedOutlookAccount({ delta_link: "https://graph.microsoft.com/stale" });
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ error: { code: "syncStateNotFound" } }), { status: 400 }));
    await syncOutlookAccount(testEnv, acc);
    expect((await reload()).initial_sync_done).toBe(0);
  });

  it("stores a mid-chain nextLink so a capped run resumes instead of losing mail", async () => {
    // Regression: a page carrying more ids than the per-run cap used to drop the surplus.
    const many = Array.from({ length: 30 }, (_, i) => ({ id: `m${i}` }));
    // Route by URL: ingest also does BIMI logo lookups, so a fixed queue would run dry.
    let n = 0;
    fetchMock.mockImplementation(async (u: unknown) => {
      const url = String(u);
      if (url.includes("/$value")) return text(rawMime({ messageId: `<m${n++}@example.com>` }));
      if (url.startsWith("https://graph.microsoft.com/")) return json({ value: many, "@odata.nextLink": "https://graph.microsoft.com/page2" });
      // Anything else is an ingest-time side call (BIMI logo lookup).
      return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
    });
    const acc = await seedOutlookAccount({ delta_link: "https://graph.microsoft.com/c0" });

    const r = await syncOutlookAccount(testEnv, acc);

    // Everything on the page it actually read was ingested — nothing silently dropped.
    expect(r.added).toBe(30);
    // And the cursor advanced to the nextLink, so page 2 is picked up on the following tick.
    expect((await reload()).delta_link).toBe("https://graph.microsoft.com/page2");
  });

  it("never calls the Gmail API", async () => {
    fetchMock
      .mockResolvedValueOnce(json({ value: [{ id: "m1" }], "@odata.deltaLink": DELTA }))
      .mockResolvedValueOnce(text(rawMime()));
    await syncOutlookAccount(testEnv, await seedOutlookAccount({ delta_link: "https://graph.microsoft.com/c0" }));
    for (const call of fetchMock.mock.calls) {
      expect(String(call[0])).not.toContain("googleapis.com");
    }
  });
});

describe("toAccount", () => {
  it("reports outlook as outlook and never leaks tokens", async () => {
    const acc = await seedOutlookAccount();
    const dto = toAccount(acc) as unknown as Record<string, unknown>;
    // Before 0015 this coerced anything non-domain to "gmail".
    expect(dto.provider).toBe("outlook");
    expect(dto).not.toHaveProperty("access_token");
    expect(dto).not.toHaveProperty("refresh_token");
  });
});

describe("cron selection", () => {
  const SQL = `SELECT id FROM accounts WHERE provider = 'outlook' AND sync_status <> 'disconnected' AND refresh_token IS NOT NULL AND (scopes IS NULL OR scopes = '' OR scopes LIKE '%Mail.ReadWrite%')`;

  it("picks up a healthy Outlook account", async () => {
    await seedOutlookAccount();
    const r = await testEnv.DB.prepare(SQL).all<{ id: string }>();
    expect(r.results.map((x) => x.id)).toEqual(["acc1"]);
  });

  it("skips a disconnected one", async () => {
    await seedOutlookAccount();
    await testEnv.DB.prepare(`UPDATE accounts SET sync_status = 'disconnected' WHERE id = 'acc1'`).run();
    const r = await testEnv.DB.prepare(SQL).all<{ id: string }>();
    expect(r.results).toHaveLength(0);
  });

  it("skips one with no mail scope", async () => {
    await seedOutlookAccount();
    await testEnv.DB.prepare(`UPDATE accounts SET scopes = 'openid profile' WHERE id = 'acc1'`).run();
    const r = await testEnv.DB.prepare(SQL).all<{ id: string }>();
    expect(r.results).toHaveLength(0);
  });
});
