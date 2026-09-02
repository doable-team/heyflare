-- Users & auth
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL DEFAULT '',
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'user', -- 'user' | 'superadmin'
  disabled INTEGER NOT NULL DEFAULT 0,
  settings_json TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL,
  last_login_at INTEGER
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  user_agent TEXT
);
CREATE INDEX idx_sessions_user ON sessions(user_id);

CREATE TABLE oauth_states (
  state TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE app_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT INTO app_settings(key, value) VALUES ('registration_open', '1');

CREATE TABLE invites (
  code TEXT PRIMARY KEY,
  created_by TEXT NOT NULL,
  used_by TEXT,
  created_at INTEGER NOT NULL,
  used_at INTEGER
);

-- Connected Gmail accounts
CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL DEFAULT 'gmail',
  email TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  access_token TEXT,
  refresh_token TEXT,
  token_expires_at INTEGER,
  history_id TEXT,
  initial_sync_done INTEGER NOT NULL DEFAULT 0,
  initial_sync_page_token TEXT,
  initial_sync_count INTEGER NOT NULL DEFAULT 0,
  sync_status TEXT NOT NULL DEFAULT 'idle', -- idle | syncing | error | disconnected
  sync_error TEXT,
  last_synced_at INTEGER,
  signature TEXT NOT NULL DEFAULT '',
  cover_art TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  UNIQUE(user_id, email)
);
CREATE INDEX idx_accounts_user ON accounts(user_id);

-- Contacts (per account) + screener decision
CREATE TABLE contacts (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  screen_status TEXT NOT NULL DEFAULT 'pending', -- pending | imbox | feed | paper_trail | screened_out
  screened_at INTEGER,
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  message_count INTEGER NOT NULL DEFAULT 0,
  notes TEXT NOT NULL DEFAULT '',
  UNIQUE(account_id, email)
);
CREATE INDEX idx_contacts_account_status ON contacts(account_id, screen_status);

-- Threads
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  gmail_thread_id TEXT NOT NULL,
  subject TEXT NOT NULL DEFAULT '',
  custom_subject TEXT,
  snippet TEXT NOT NULL DEFAULT '',
  bucket TEXT NOT NULL DEFAULT 'screener', -- screener | imbox | feed | paper_trail | screened_out | trash
  seen INTEGER NOT NULL DEFAULT 0,          -- opened at least once ("Previously seen")
  unread INTEGER NOT NULL DEFAULT 1,
  reply_later INTEGER NOT NULL DEFAULT 0,
  reply_later_at INTEGER,
  set_aside INTEGER NOT NULL DEFAULT 0,
  set_aside_at INTEGER,
  bubble_up_at INTEGER,                    -- hidden until this time
  bubbled INTEGER NOT NULL DEFAULT 0,       -- has bubbled up (show badge)
  merged_into TEXT,                         -- thread id this was merged into
  note TEXT NOT NULL DEFAULT '',            -- sticky note on the thread
  has_attachments INTEGER NOT NULL DEFAULT 0,
  trackers_blocked INTEGER NOT NULL DEFAULT 0,
  participants_json TEXT NOT NULL DEFAULT '[]', -- [{email,name}]
  last_from_email TEXT NOT NULL DEFAULT '',
  last_from_name TEXT NOT NULL DEFAULT '',
  message_count INTEGER NOT NULL DEFAULT 0,
  first_message_at INTEGER NOT NULL,
  last_message_at INTEGER NOT NULL,
  is_sent_only INTEGER NOT NULL DEFAULT 0,  -- thread only contains messages from me
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(account_id, gmail_thread_id)
);
CREATE INDEX idx_threads_account_bucket ON threads(account_id, bucket, last_message_at DESC);
CREATE INDEX idx_threads_reply_later ON threads(account_id, reply_later);
CREATE INDEX idx_threads_set_aside ON threads(account_id, set_aside);
CREATE INDEX idx_threads_bubble ON threads(bubble_up_at);

-- Messages
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  gmail_message_id TEXT NOT NULL,
  from_email TEXT NOT NULL DEFAULT '',
  from_name TEXT NOT NULL DEFAULT '',
  to_json TEXT NOT NULL DEFAULT '[]',
  cc_json TEXT NOT NULL DEFAULT '[]',
  bcc_json TEXT NOT NULL DEFAULT '[]',
  reply_to TEXT NOT NULL DEFAULT '',
  subject TEXT NOT NULL DEFAULT '',
  date INTEGER NOT NULL,
  snippet TEXT NOT NULL DEFAULT '',
  text_body TEXT NOT NULL DEFAULT '',
  html_body TEXT NOT NULL DEFAULT '',
  is_from_me INTEGER NOT NULL DEFAULT 0,
  unread INTEGER NOT NULL DEFAULT 1,
  message_id_header TEXT NOT NULL DEFAULT '',
  in_reply_to TEXT NOT NULL DEFAULT '',
  references_header TEXT NOT NULL DEFAULT '',
  list_unsubscribe TEXT NOT NULL DEFAULT '',
  gmail_labels_json TEXT NOT NULL DEFAULT '[]',
  has_attachments INTEGER NOT NULL DEFAULT 0,
  trackers_json TEXT NOT NULL DEFAULT '[]',
  size_estimate INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE(account_id, gmail_message_id)
);
CREATE INDEX idx_messages_thread ON messages(thread_id, date);
CREATE INDEX idx_messages_account_date ON messages(account_id, date DESC);

CREATE TABLE attachments (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL,
  gmail_attachment_id TEXT NOT NULL,
  filename TEXT NOT NULL DEFAULT '',
  mime_type TEXT NOT NULL DEFAULT 'application/octet-stream',
  size INTEGER NOT NULL DEFAULT 0,
  content_id TEXT NOT NULL DEFAULT '',
  is_inline INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_attachments_account ON attachments(account_id, created_at DESC);
CREATE INDEX idx_attachments_message ON attachments(message_id);

-- Labels
CREATE TABLE labels (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  color TEXT NOT NULL DEFAULT '#0f766e',
  created_at INTEGER NOT NULL,
  UNIQUE(account_id, name)
);
CREATE TABLE thread_labels (
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  label_id TEXT NOT NULL REFERENCES labels(id) ON DELETE CASCADE,
  PRIMARY KEY(thread_id, label_id)
);

-- Collections
CREATE TABLE collections (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE collection_threads (
  collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  added_at INTEGER NOT NULL,
  PRIMARY KEY(collection_id, thread_id)
);

-- Clips (highlighted snippets)
CREATE TABLE clips (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  message_id TEXT,
  text TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_clips_account ON clips(account_id, created_at DESC);

-- Drafts (compose + replies)
CREATE TABLE drafts (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  thread_id TEXT,
  reply_to_message_id TEXT,
  to_json TEXT NOT NULL DEFAULT '[]',
  cc_json TEXT NOT NULL DEFAULT '[]',
  bcc_json TEXT NOT NULL DEFAULT '[]',
  subject TEXT NOT NULL DEFAULT '',
  body_html TEXT NOT NULL DEFAULT '',
  send_at INTEGER,                 -- scheduled send (send later)
  status TEXT NOT NULL DEFAULT 'draft', -- draft | scheduled | sending | sent | failed
  error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_drafts_account ON drafts(account_id, updated_at DESC);
CREATE INDEX idx_drafts_scheduled ON drafts(status, send_at);

-- Sync / audit log
CREATE TABLE sync_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  account_id TEXT,
  level TEXT NOT NULL DEFAULT 'info',
  message TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_sync_log_account ON sync_log(account_id, created_at DESC);
