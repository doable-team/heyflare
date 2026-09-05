-- Third-party IMAP/SMTP mailboxes (accounts.provider = 'imap'): Zoho, Fastmail, Migadu, cPanel webmail.
-- Credentials live here rather than on `accounts` so `SELECT * FROM accounts` never drags the
-- ciphertext around. password_enc is AES-GCM via ai/crypto.ts, keyed off SESSION_SECRET.
CREATE TABLE IF NOT EXISTS imap_accounts (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  imap_host TEXT NOT NULL,
  imap_port INTEGER NOT NULL DEFAULT 993,
  imap_security TEXT NOT NULL DEFAULT 'tls',
  smtp_host TEXT NOT NULL,
  smtp_port INTEGER NOT NULL DEFAULT 465,
  smtp_security TEXT NOT NULL DEFAULT 'tls',
  username TEXT NOT NULL,
  password_enc TEXT NOT NULL DEFAULT '',
  password_hint TEXT NOT NULL DEFAULT '',
  folder TEXT NOT NULL DEFAULT 'INBOX',
  uid_validity INTEGER NOT NULL DEFAULT 0,
  last_uid INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
