-- OAuth app credentials for the mail providers, so they can be rotated from Settings without a
-- redeploy. Microsoft client secrets expire (24 months at most), which makes rotation recurring
-- maintenance rather than a one-off. A Worker secret, when set, always wins over the stored value.
CREATE TABLE IF NOT EXISTS oauth_credentials (
  provider TEXT PRIMARY KEY,
  client_id TEXT NOT NULL DEFAULT '',
  secret_enc TEXT NOT NULL DEFAULT '',
  secret_hint TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL
);
