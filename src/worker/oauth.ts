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
  if (envId && envSecret) return { clientId: envId, clientSecret: envSecret, source: "env" };

  const row = await env.DB.prepare(`SELECT * FROM oauth_credentials WHERE provider = ?`).bind(provider).first<CredRow>();
  if (!row?.client_id || !row?.secret_enc) return { clientId: "", clientSecret: "", source: "none" };
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

/** Mask a secret for display; the plaintext is never returned by the API. */
export function secretHint(secret: string): string {
  return secret.length > 8 ? `${secret.slice(0, 3)}…${secret.slice(-3)}` : "••••";
}

export interface CredentialStatus {
  provider: OAuthProvider;
  configured: boolean;
  /** "env" means a Worker secret is set, so the stored value is ignored and the UI is read-only. */
  source: CredentialSource;
  client_id: string;
  secret_hint: string;
}

export async function credentialsStatus(env: Env, provider: OAuthProvider): Promise<CredentialStatus> {
  const resolved = await resolveCreds(env, provider);
  const row = await env.DB.prepare(`SELECT * FROM oauth_credentials WHERE provider = ?`).bind(provider).first<CredRow>();
  return {
    provider,
    configured: resolved.source !== "none",
    source: resolved.source,
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
  patch: { client_id?: string; client_secret?: string | null }
): Promise<void> {
  const row = await env.DB.prepare(`SELECT * FROM oauth_credentials WHERE provider = ?`).bind(provider).first<CredRow>();
  let clientId = row?.client_id ?? "";
  let enc = row?.secret_enc ?? "";
  let hint = row?.secret_hint ?? "";

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
    `INSERT INTO oauth_credentials (provider, client_id, secret_enc, secret_hint, updated_at)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(provider) DO UPDATE SET client_id = excluded.client_id, secret_enc = excluded.secret_enc,
       secret_hint = excluded.secret_hint, updated_at = excluded.updated_at`
  )
    .bind(provider, clientId, enc, hint, now())
    .run();
}
