import type { Env } from "./env";
import { now } from "./db";
import { encryptSecret, decryptSecret } from "./ai/crypto";
import { getSessionSecret } from "./secrets";

/**
 * Where a provider's OAuth app credentials come from.
 *
 * A Worker secret always wins: it lives in Cloudflare's secret store rather than the database, so it
 * is the stronger place to keep one and an existing deploy must never change behaviour. The stored
 * fallback exists because Microsoft client secrets expire — rotating one should not require CLI
 * access and a redeploy. This mirrors `getSessionSecret`, which prefers the env var and otherwise
 * falls back to a value in the database.
 */
export type OAuthProvider = "google" | "microsoft";
export type CredentialSource = "env" | "db" | "none";

export interface ResolvedCreds {
  clientId: string;
  clientSecret: string;
  source: CredentialSource;
}

interface CredRow {
  provider: string;
  client_id: string;
  secret_enc: string;
  secret_hint: string;
  /** 1 when the stored credentials should be used even though a Worker secret exists. */
  override_env?: number;
  updated_at: number;
}

function envNames(provider: OAuthProvider): { id: keyof Env; secret: keyof Env } {
  return provider === "google"
    ? { id: "GOOGLE_CLIENT_ID", secret: "GOOGLE_CLIENT_SECRET" }
    : { id: "MS_CLIENT_ID", secret: "MS_CLIENT_SECRET" };
}

export async function resolveCreds(env: Env, provider: OAuthProvider): Promise<ResolvedCreds> {
  const names = envNames(provider);
  const envId = (env[names.id] as string | undefined) ?? "";
  const envSecret = (env[names.secret] as string | undefined) ?? "";
  const hasEnv = !!(envId && envSecret);

  const row = await env.DB.prepare(`SELECT * FROM oauth_credentials WHERE provider = ?`).bind(provider).first<CredRow>();
  const stored = !!(row?.client_id && row?.secret_enc);

  // The Worker secret is the default because it lives in Cloudflare's secret store rather than the
  // database — but only until someone deliberately takes over management here, which is the only way
  // to rotate an expiring secret without CLI access.
  if (hasEnv && !(stored && row?.override_env)) return { clientId: envId, clientSecret: envSecret, source: "env" };
  if (!stored) return { clientId: "", clientSecret: "", source: "none" };
  try {
    const secret = await decryptSecret(await getSessionSecret(env), row.secret_enc);
    return { clientId: row.client_id, clientSecret: secret, source: "db" };
  } catch {
    // A SESSION_SECRET that changed leaves the ciphertext unreadable; treat it as unconfigured
    // rather than throwing on every request.
    return { clientId: "", clientSecret: "", source: "none" };
  }
}

export async function isConfigured(env: Env, provider: OAuthProvider): Promise<boolean> {
  return (await resolveCreds(env, provider)).source !== "none";
}

/**
 * Whether each provider is usable, in a single query. `/api/me` reports both on every call —
 * including the unauthenticated one the login screen makes — so asking per provider doubles the
 * reads on the app's most-hit endpoint for no benefit.
 */
export async function configuredProviders(env: Env): Promise<{ google: boolean; microsoft: boolean }> {
  const envReady = (p: OAuthProvider) => {
    const n = envNames(p);
    return !!((env[n.id] as string | undefined) && (env[n.secret] as string | undefined));
  };
  const out = { google: envReady("google"), microsoft: envReady("microsoft") };
  if (out.google && out.microsoft) return out;

  const rows = await env.DB.prepare(
    `SELECT provider, client_id, secret_enc, override_env FROM oauth_credentials WHERE provider IN ('google', 'microsoft')`
  ).all<Pick<CredRow, "provider" | "client_id" | "secret_enc" | "override_env">>();
  for (const row of rows.results ?? []) {
    const p = row.provider === "microsoft" ? "microsoft" : "google";
    if (row.client_id && row.secret_enc) out[p] = true;
  }
  return out;
}

/** Mask a secret for display; the plaintext is never returned by the API. */
export function secretHint(secret: string): string {
  return secret.length > 8 ? `${secret.slice(0, 3)}…${secret.slice(-3)}` : "••••";
}

export interface CredentialStatus {
  provider: OAuthProvider;
  configured: boolean;
  /** Which credentials are actually in use right now. */
  source: CredentialSource;
  /** True when a Worker secret exists for this provider, whether or not it is the one being used. */
  env_available: boolean;
  /** True when the stored credentials are deliberately overriding a Worker secret. */
  overriding: boolean;
  client_id: string;
  secret_hint: string;
}

export async function credentialsStatus(env: Env, provider: OAuthProvider): Promise<CredentialStatus> {
  const names = envNames(provider);
  const envAvailable = !!((env[names.id] as string | undefined) && (env[names.secret] as string | undefined));
  const resolved = await resolveCreds(env, provider);
  const row = await env.DB.prepare(`SELECT * FROM oauth_credentials WHERE provider = ?`).bind(provider).first<CredRow>();
  return {
    provider,
    configured: resolved.source !== "none",
    source: resolved.source,
    env_available: envAvailable,
    overriding: resolved.source === "db" && envAvailable,
    client_id: resolved.source === "env" ? resolved.clientId : (row?.client_id ?? ""),
    secret_hint: resolved.source === "env" ? "set by a Worker secret" : (row?.secret_hint ?? ""),
  };
}

/**
 * Write the stored credentials. Three-state, matching how AI keys are saved: a string sets the
 * value, `null` clears it, and `undefined` leaves whatever is there alone — so saving a client id
 * does not require re-entering the secret.
 */
export async function saveCreds(
  env: Env,
  provider: OAuthProvider,
  patch: { client_id?: string; client_secret?: string | null; override_env?: boolean }
): Promise<void> {
  const row = await env.DB.prepare(`SELECT * FROM oauth_credentials WHERE provider = ?`).bind(provider).first<CredRow>();
  let clientId = row?.client_id ?? "";
  let enc = row?.secret_enc ?? "";
  let hint = row?.secret_hint ?? "";
  let override = row?.override_env ?? 0;
  if (typeof patch.override_env === "boolean") override = patch.override_env ? 1 : 0;

  if (typeof patch.client_id === "string") clientId = patch.client_id.trim();
  if (typeof patch.client_secret === "string") {
    const secret = patch.client_secret.trim();
    if (secret) {
      enc = await encryptSecret(await getSessionSecret(env), secret);
      hint = secretHint(secret);
    }
  } else if (patch.client_secret === null) {
    enc = "";
    hint = "";
  }

  await env.DB.prepare(
    `INSERT INTO oauth_credentials (provider, client_id, secret_enc, secret_hint, override_env, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(provider) DO UPDATE SET client_id = excluded.client_id, secret_enc = excluded.secret_enc,
       secret_hint = excluded.secret_hint, override_env = excluded.override_env, updated_at = excluded.updated_at`
  )
    .bind(provider, clientId, enc, hint, override, now())
    .run();
}
