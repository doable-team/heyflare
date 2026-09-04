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

  const status = await credentialsStatus(c.env, provider);
  // A Worker secret is the stronger place to keep one, so it always wins. Silently storing a value
  // that will never be used would be worse than refusing it.
  if (status.source === "env") {
    return c.json(
      { error: "managed_by_secret", message: "This provider is configured by a Worker secret. Remove it to manage the credentials here." },
      409
    );
  }

  const b = await c.req.json<{ client_id?: string; client_secret?: string | null }>().catch(() => ({}) as never);
  if (typeof b.client_secret === "string" && b.client_secret.trim() && b.client_secret.trim().length < 8) {
    return c.json({ error: "invalid_secret" }, 400);
  }
  try {
    await saveCreds(c.env, provider, b);
  } catch (e) {
    return c.json({ error: (e as Error).message }, 500);
  }
  return c.json(await credentialsStatus(c.env, provider));
});

export default oauth;
