import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { msAuthUrl, hasMsMailScope, microsoftConfigured, getMsAccessToken, MicrosoftError } from "../src/worker/microsoft";
import type { Env } from "../src/worker/env";
import type { AccountRow } from "../src/worker/db";

const env = { MS_CLIENT_ID: "cid", MS_CLIENT_SECRET: "csecret" } as Env;

describe("microsoftConfigured", () => {
  it("needs both halves of the credential", () => {
    expect(microsoftConfigured(env)).toBe(true);
    expect(microsoftConfigured({ MS_CLIENT_ID: "cid" } as Env)).toBe(false);
    expect(microsoftConfigured({} as Env)).toBe(false);
  });
});

describe("msAuthUrl", () => {
  const url = new URL(msAuthUrl(env, "state123", "https://mail.example.com/auth/microsoft/callback"));

  it("uses the /common authority so personal and work accounts both work", () => {
    expect(url.origin + url.pathname).toBe("https://login.microsoftonline.com/common/oauth2/v2.0/authorize");
  });

  it("asks for every scope the feature needs", () => {
    const scopes = (url.searchParams.get("scope") ?? "").split(" ");
    // offline_access is what yields a refresh token; without it sync dies after an hour.
    expect(scopes).toEqual(expect.arrayContaining(["Mail.ReadWrite", "Mail.Send", "User.Read", "offline_access", "openid", "email", "profile"]));
  });

  it("round-trips the redirect URI and state", () => {
    expect(url.searchParams.get("redirect_uri")).toBe("https://mail.example.com/auth/microsoft/callback");
    expect(url.searchParams.get("state")).toBe("state123");
    expect(url.searchParams.get("response_type")).toBe("code");
  });

  it("passes a login hint only when given one", () => {
    expect(url.searchParams.get("login_hint")).toBeNull();
    const hinted = new URL(msAuthUrl(env, "s", "https://x/cb", "me@outlook.com"));
    expect(hinted.searchParams.get("login_hint")).toBe("me@outlook.com");
  });
});

describe("hasMsMailScope", () => {
  it("accepts Graph's resource-qualified scope strings", () => {
    // Microsoft echoes scopes back fully qualified, so an exact-token match would fail here.
    expect(hasMsMailScope("https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send")).toBe(true);
    expect(hasMsMailScope("Mail.ReadWrite Mail.Send")).toBe(true);
  });

  it("treats an unrecorded scope set as having mail", () => {
    expect(hasMsMailScope("")).toBe(true);
    expect(hasMsMailScope(null)).toBe(true);
  });

  it("rejects a scope set without mail access", () => {
    expect(hasMsMailScope("openid profile User.Read")).toBe(false);
  });
});

describe("token refresh", () => {
  let fetchMock: ReturnType<typeof vi.fn>;
  const updates: unknown[][] = [];

  function outlookAccount(overrides: Partial<AccountRow> = {}): AccountRow {
    return {
      id: "acc1", user_id: "u1", provider: "outlook", email: "me@outlook.com", display_name: "",
      access_token: "old", refresh_token: "r1", token_expires_at: Date.now() - 1000,
      sync_status: "idle", ...overrides,
    } as unknown as AccountRow;
  }

  const dbEnv = {
    ...env,
    DB: { prepare: () => ({ bind: (...args: unknown[]) => { updates.push(args); return { run: async () => ({}) }; } }) },
  } as unknown as Env;

  beforeEach(() => {
    updates.length = 0;
    fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
  });
  afterEach(() => vi.unstubAllGlobals());

  it("persists the rotated refresh token", async () => {
    // Microsoft rotates refresh tokens: keeping the old one would disconnect the account within the hour.
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ access_token: "new", refresh_token: "r2", expires_in: 3600 }), { status: 200 })
    );
    const acc = outlookAccount();
    const token = await getMsAccessToken(dbEnv, acc);
    expect(token).toBe("new");
    expect(acc.refresh_token).toBe("r2");
    expect(updates[0]).toContain("r2");
  });

  it("keeps the existing refresh token when the response omits one", async () => {
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ access_token: "new", expires_in: 3600 }), { status: 200 }));
    const acc = outlookAccount();
    await getMsAccessToken(dbEnv, acc);
    expect(acc.refresh_token).toBe("r1");
  });

  it("does not refresh a token that is still valid", async () => {
    const acc = outlookAccount({ access_token: "fresh", token_expires_at: Date.now() + 3600_000 });
    expect(await getMsAccessToken(dbEnv, acc)).toBe("fresh");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("refuses to refresh a non-Outlook account", async () => {
    const acc = outlookAccount({ provider: "gmail" } as Partial<AccountRow>);
    await expect(getMsAccessToken(dbEnv, acc)).rejects.toBeInstanceOf(MicrosoftError);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
