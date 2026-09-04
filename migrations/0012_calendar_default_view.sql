-- The week scroll, not a single day, is the calendar's home view: HEY's "week after week, not
-- month after month". Move anyone still on the old default across.
UPDATE calendar_settings SET default_view = 'week' WHERE default_view = 'days';
