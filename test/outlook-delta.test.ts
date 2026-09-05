import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { newMessageIdsFromPage, walkDelta } from "../src/worker/outlook";
import type { AccountRow } from "../src/worker/db";
import type { Env } from "../src/worker/env";

/** An Outlook account with a token that is nowhere near expiry, so no refresh is attempted. */
function account(): AccountRow {
  return {
    id: "acc1",
    user_id: "u1",
    provider: "outlook",
    email: "me@outlook.com",
    display_name: "Me",
    access_token: "tok",
    refresh_token: "rtok",
    token_expires_at: Date.now() + 3600_000,
    history_id: null,
    delta_link: null,
    initial_sync_done: 1,
    initial_sync_page_token: null,
    initial_sync_count: 0,
    sync_status: "idle",
    sync_error: null,
    last_synced_at: null,
    signature: "",
    cover_art: "",
    created_at: Date.now(),
  } as unknown as AccountRow;
}

const env = {} as Env;

function jsonOnce(body: unknown) {
  return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" } });
}

describe("newMessageIdsFromPage", () => {
  it("keeps created/updated ids", () => {
    expect(newMessageIdsFromPage({ value: [{ id: "a" }, { id: "b" }] })).toEqual(["a", "b"]);
  });

  it("drops @removed tombstones", () => {
    // Delta tracking is collection-level, so deletes and moves arrive on the same page.
    expect(newMessageIdsFromPage({ value: [{ id: "a" }, { id: "b", "@removed": { reason: "deleted" } }] })).toEqual(["a"]);
  });

  it("tolerates an empty or absent value array", () => {
    expect(newMessageIdsFromPage({})).toEqual([]);
    expect(newMessageIdsFromPage({ value: [] })).toEqual([]);
  });
});

describe("walkDelta", () => {
  let fetchMock: ReturnType<typeof vi.fn>;
  beforeEach(() => {
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });
  afterEach(() => vi.unstubAllGlobals());

  it("follows @odata.nextLink to the end and reports done", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonOnce({ value: [{ id: "a" }], "@odata.nextLink": "https://graph.microsoft.com/page2" }))
      .mockResolvedValueOnce(jsonOnce({ value: [{ id: "b" }], "@odata.deltaLink": "https://graph.microsoft.com/delta-final" }));

    const r = await walkDelta(env, account(), "mailFolders/inbox/messages/delta", { collect: true });
    expect(r.ids).toEqual(["a", "b"]);
    expect(r.cursor).toBe("https://graph.microsoft.com/delta-final");
    expect(r.done).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("collects nothing when priming, but still reaches the deltaLink", async () => {
    fetchMock.mockResolvedValueOnce(jsonOnce({ value: [{ id: "a" }, { id: "b" }], "@odata.deltaLink": "https://graph.microsoft.com/d" }));
    const r = await walkDelta(env, account(), "start", { collect: false });
    expect(r.ids).toEqual([]);
    expect(r.cursor).toBe("https://graph.microsoft.com/d");
    expect(r.done).toBe(true);
  });

  it("stops at the id cap but still hands back a resumable cursor", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonOnce({ value: [{ id: "a" }, { id: "b" }], "@odata.nextLink": "https://graph.microsoft.com/p2" }))
      .mockResolvedValueOnce(jsonOnce({ value: [{ id: "c" }], "@odata.deltaLink": "https://graph.microsoft.com/d" }));

    const r = await walkDelta(env, account(), "start", { collect: true, maxIds: 2 });
    expect(r.ids).toEqual(["a", "b"]);
    // A nextLink is as replayable as a deltaLink, so the cursor advances and page 2 is not re-read.
    expect(r.cursor).toBe("https://graph.microsoft.com/p2");
    expect(r.done).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("stops after MAX_PAGES on a very long chain, still resumable", async () => {
    for (let i = 0; i < 12; i++) {
      fetchMock.mockResolvedValueOnce(jsonOnce({ value: [], "@odata.nextLink": `https://graph.microsoft.com/p${i + 1}` }));
    }
    const r = await walkDelta(env, account(), "start", { collect: false });
    expect(r.done).toBe(false);
    expect(r.cursor).toBe("https://graph.microsoft.com/p10");
    expect(fetchMock).toHaveBeenCalledTimes(10);
  });

  it("de-duplicates ids repeated across pages", async () => {
    fetchMock
      .mockResolvedValueOnce(jsonOnce({ value: [{ id: "a" }], "@odata.nextLink": "https://graph.microsoft.com/p2" }))
      .mockResolvedValueOnce(jsonOnce({ value: [{ id: "a" }, { id: "b" }], "@odata.deltaLink": "https://graph.microsoft.com/d" }));
    const r = await walkDelta(env, account(), "start", { collect: true });
    expect(r.ids).toEqual(["a", "b"]);
  });

  it("never calls the Gmail API", async () => {
    fetchMock.mockResolvedValueOnce(jsonOnce({ value: [], "@odata.deltaLink": "https://graph.microsoft.com/d" }));
    await walkDelta(env, account(), "start", { collect: true });
    for (const call of fetchMock.mock.calls) {
      expect(String(call[0])).not.toContain("googleapis.com");
    }
  });
});
