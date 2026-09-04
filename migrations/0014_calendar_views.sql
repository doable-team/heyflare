-- HEY's calendar has three views: a day, a week and a year. The month grid and the agenda list
-- are gone, so anyone whose default pointed at one lands on the week instead.
UPDATE calendar_settings SET default_view = 'week' WHERE default_view NOT IN ('days', 'week', 'year');
