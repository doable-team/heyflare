import { Hono } from "hono";
import type { AppEnv } from "../env";
import { credentialsStatus, saveCreds, type OAuthProvider } from "../oauth";

const oauth = new Hono<AppEnv>();

const PROVIDERS: OAuthProvider[] = ["google", "microsoft"];

function isProvider(v: string): v is OAuthProvider {
  return (PROVIDERS as string[]).includes(v);
}

/** Where each provider's credentials come from, with the secret reduced to a hint. */
oauth.get("/", async (c) => {
  return c.json(await Promise.all(PROVIDERS.map((p) => credentialsStatus(c.env, p))));
});

oauth.put("/:provider", async (c) => {
  const provider = c.req.param("provider");
  if (!isProvider(provider)) return c.json({ error: "unknown_provider" }, 400);

  const b = await c.req
    .json<{ client_id?: string; client_secret?: string | null; override_env?: boolean }>()
    .catch(() => ({}) as never);
  if (typeof b.client_secret === "string" && b.client_secret.trim() && b.client_secret.trim().length < 8) {
    return c.json({ error: "invalid_secret" }, 400);
  }

  // Taking over from a Worker secret has to be deliberate, and it has to actually be possible —
  // otherwise a deployment configured by `wrangler secret put` could never rotate from here, which
  // is the whole reason this form exists. Saving credentials while a Worker secret is set implies
  // the takeover unless the caller says otherwise.
  const status = await credentialsStatus(c.env, provider);
  const settingCreds = typeof b.client_id === "string" || typeof b.client_secret === "string";
  const patch = {
    ...b,
    override_env: typeof b.override_env === "boolean" ? b.override_env : status.env_available && settingCreds ? true : undefined,
  };

  if (patch.override_env === true) {
    // Against the stored row specifically: under a Worker secret the resolved fields are always
    // populated, so checking those would let an override be set with nothing behind it — leaving a
    // row that breaks the moment the Worker secret is removed.
    const willHaveSecret = (typeof b.client_secret === "string" && !!b.client_secret.trim()) || status.has_stored_secret;
    const willHaveId = (typeof b.client_id === "string" && !!b.client_id.trim()) || !!status.stored_client_id;
    if (!willHaveSecret || !willHaveId) {
      return c.json({ error: "incomplete_credentials", message: "Enter both a client ID and a secret before overriding the Worker secret." }, 400);
    }
  }
  try {
    await saveCreds(c.env, provider, patch);
  } catch (e) {
    return c.json({ error: (e as Error).message }, 500);
  }
  return c.json(await credentialsStatus(c.env, provider));
});

export default oauth;
