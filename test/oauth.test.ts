import { describe, it, expect, beforeAll, beforeEach } from "vitest";
import { migrate, testEnv } from "./helpers";
import { resolveCreds, saveCreds, isConfigured, credentialsStatus, secretHint } from "../src/worker/oauth";
import type { Env } from "../src/worker/env";

/** The real test env has no OAuth vars set, so `db` and `none` are its natural states. */
const dbOnly = testEnv;
const withEnv = { ...testEnv, MS_CLIENT_ID: "env-id", MS_CLIENT_SECRET: "env-secret" } as Env;

beforeAll(migrate);
beforeEach(async () => {
  await testEnv.DB.prepare(`DELETE FROM oauth_credentials`).run();
});

describe("secretHint", () => {
  it("shows only the ends of a real secret", () => {
    const h = secretHint("OHO8Q~verylongsecretvalue_XYZ");
    expect(h).toContain("…");
    expect(h).not.toContain("verylongsecret");
  });

  it("does not leak the length of a short one", () => {
    expect(secretHint("abc")).toBe("••••");
  });
});

describe("resolveCreds precedence", () => {
  it("reports none when nothing is configured", async () => {
    const r = await resolveCreds(dbOnly, "microsoft");
    expect(r.source).toBe("none");
    expect(await isConfigured(dbOnly, "microsoft")).toBe(false);
  });

  it("uses stored credentials when no Worker secret is set", async () => {
    await saveCreds(dbOnly, "microsoft", { client_id: "db-id", client_secret: "db-secret-value" });
    const r = await resolveCreds(dbOnly, "microsoft");
    expect(r).toMatchObject({ clientId: "db-id", clientSecret: "db-secret-value", source: "db" });
  });

  it("lets a Worker secret win over the stored value", async () => {
    // The env var lives in Cloudflare's secret store, so it must take precedence and an existing
    // deploy must never change behaviour because someone typed into the settings form.
    await saveCreds(dbOnly, "microsoft", { client_id: "db-id", client_secret: "db-secret-value" });
    const r = await resolveCreds(withEnv, "microsoft");
    expect(r).toMatchObject({ clientId: "env-id", clientSecret: "env-secret", source: "env" });
  });

  it("ignores a half-configured env pair", async () => {
    const halfEnv = { ...testEnv, MS_CLIENT_ID: "env-id" } as Env;
    await saveCreds(dbOnly, "microsoft", { client_id: "db-id", client_secret: "db-secret-value" });
    expect((await resolveCreds(halfEnv, "microsoft")).source).toBe("db");
  });

  it("keeps providers independent", async () => {
    await saveCreds(dbOnly, "microsoft", { client_id: "ms", client_secret: "ms-secret-value" });
    expect((await resolveCreds(dbOnly, "google")).source).toBe("none");
  });

  it("treats a client id with no secret as unconfigured", async () => {
    await saveCreds(dbOnly, "microsoft", { client_id: "only-id" });
    expect((await resolveCreds(dbOnly, "microsoft")).source).toBe("none");
  });
});

describe("saveCreds is three-state", () => {
  it("leaves the secret alone when it is omitted", async () => {
    await saveCreds(dbOnly, "microsoft", { client_id: "id-1", client_secret: "secret-value-1" });
    await saveCreds(dbOnly, "microsoft", { client_id: "id-2" });
    const r = await resolveCreds(dbOnly, "microsoft");
    expect(r.clientId).toBe("id-2");
    expect(r.clientSecret).toBe("secret-value-1");
  });

  it("clears the secret when passed null", async () => {
    await saveCreds(dbOnly, "microsoft", { client_id: "id-1", client_secret: "secret-value-1" });
    await saveCreds(dbOnly, "microsoft", { client_secret: null });
    expect((await resolveCreds(dbOnly, "microsoft")).source).toBe("none");
  });
});

describe("credentialsStatus", () => {
  it("never returns the secret itself", async () => {
    await saveCreds(dbOnly, "microsoft", { client_id: "id", client_secret: "super-secret-value" });
    const st = await credentialsStatus(dbOnly, "microsoft");
    expect(JSON.stringify(st)).not.toContain("super-secret-value");
    expect(st.configured).toBe(true);
    expect(st.source).toBe("db");
  });

  it("marks env-managed credentials so the UI can lock the form", async () => {
    const st = await credentialsStatus(withEnv, "microsoft");
    expect(st.source).toBe("env");
    expect(st.secret_hint).toMatch(/Worker secret/i);
  });

  it("stores the secret encrypted, not in clear", async () => {
    await saveCreds(dbOnly, "microsoft", { client_id: "id", client_secret: "super-secret-value" });
    const row = await testEnv.DB.prepare(`SELECT secret_enc FROM oauth_credentials WHERE provider='microsoft'`).first<{ secret_enc: string }>();
    expect(row!.secret_enc).not.toContain("super-secret-value");
    expect(row!.secret_enc.length).toBeGreaterThan(20);
  });
});
