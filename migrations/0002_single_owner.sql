-- Single-owner mode: drop multi-user registration artifacts.
DROP TABLE IF EXISTS invites;
DROP TABLE IF EXISTS app_settings;
UPDATE users SET role = 'owner';
