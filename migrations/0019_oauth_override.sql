-- Lets stored credentials deliberately take precedence over a Worker secret.
-- Without this, anyone who configured via `wrangler secret put` could never rotate from the UI —
-- which is the one thing the settings form exists to make possible.
ALTER TABLE oauth_credentials ADD COLUMN override_env INTEGER NOT NULL DEFAULT 0;
