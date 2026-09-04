-- Day photos: the picture you stick on a day, the way you'd tape one to a paper wall calendar.
-- Stored as bytes in D1 (this deployment has no object store) and served from a route, so the
-- calendar range payload carries a short URL rather than a megabyte of base64.
CREATE TABLE IF NOT EXISTS day_covers (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mime TEXT NOT NULL DEFAULT 'image/jpeg',
  width INTEGER NOT NULL DEFAULT 0,
  height INTEGER NOT NULL DEFAULT 0,
  size INTEGER NOT NULL DEFAULT 0,
  name TEXT NOT NULL DEFAULT '',
  data BLOB NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_day_covers_user ON day_covers(user_id, created_at DESC);

-- Which stored photo a day is using, so one picture can be reused on several days and we can tell
-- an uploaded photo from a plain external URL.
ALTER TABLE calendar_days ADD COLUMN cover_id TEXT;
-- CSS object-position for the crop, e.g. "50% 30%".
ALTER TABLE calendar_days ADD COLUMN cover_position TEXT NOT NULL DEFAULT '50% 50%';
