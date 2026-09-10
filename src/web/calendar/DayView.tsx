import { useMemo } from "react";
import { useCalendar } from "./CalendarContext";
import { TimeGrid, type GridPager } from "./TimeGrid";

/** Exactly the week's grid with one column: the cursor day. */
export function DayView({ pager }: { pager: GridPager }) {
  const { cursor } = useCalendar();
  const days = useMemo(() => [cursor], [cursor]);
  return <TimeGrid days={days} single pager={pager} />;
}
