-- Google address book (People API): everyone you've corresponded with, for compose autocomplete.
CREATE TABLE IF NOT EXISTS address_book (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  avatar_url TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (account_id, email)
);
CREATE INDEX IF NOT EXISTS idx_address_book_email ON address_book(account_id, email);
