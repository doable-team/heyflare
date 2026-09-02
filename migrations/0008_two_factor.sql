-- Two-factor authentication (TOTP) + recovery codes, and short-lived login tickets.
ALTER TABLE users ADD COLUMN totp_secret TEXT;
ALTER TABLE users ADD COLUMN totp_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN recovery_codes_json TEXT NOT NULL DEFAULT '[]';
CREATE TABLE IF NOT EXISTS mfa_tickets (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
