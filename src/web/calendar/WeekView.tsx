import { useMemo } from "react";
import { useCalendar } from "./CalendarContext";
import { TimeGrid, type GridPager } from "./TimeGrid";
import { weekDays } from "../lib/caldate";

/** Seven columns: the week the cursor is in, starting on the settings' first day. */
export function WeekView({ pager }: { pager: GridPager }) {
  const { cursor, settings } = useCalendar();
  const days = useMemo(() => weekDays(cursor, settings.week_start), [cursor, settings.week_start]);
  return <TimeGrid days={days} pager={pager} />;
}
