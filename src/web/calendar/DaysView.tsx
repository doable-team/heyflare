import { useEffect, useLayoutEffect, useRef } from "react";
import { Moon } from "lucide-react";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { DayHeader, DayBody } from "./DayColumn";
import { WeekTasks } from "./WeekTasks";
import { addDays, dateRange, isToday, minutesOfDay, weekDays } from "../lib/caldate";

const COL_PX = 208;

/**
 * The filmstrip. Days run left to right as columns and time runs down inside each of them, so a
 * week reads as one continuous piece of tape rather than a grid of boxes. Everything lives in one
 * scroll container: the hour gutter is `sticky left`, the day headers are `sticky top`, which gives
 * both axes the right behaviour without synchronising two scrollers by hand.
 */
export function DaysView({ week = false }: { week?: boolean }) {
  const { from, to, cursor, setCursor, scale, settings, extend, today } = useCalendar();
  // Week view shows exactly the cursor's week; the filmstrip shows the whole loaded window.
  const days: string[] = week ? weekDays(cursor, settings.week_start) : dateRange(from, to);
  const scroller = useRef<HTMLDivElement>(null);
  const prevFrom = useRef(from);
  const firstScroll = useRef(true);

  // Growing the window at the head prepends columns, which would yank the view sideways. Add the
  // width we just inserted back onto scrollLeft in the same frame, before the browser paints.
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el || week) return;
    if (prevFrom.current !== from) {
      const added = dateRange(from, addDays(prevFrom.current, -1)).length;
      if (added > 0) el.scrollLeft += added * COL_PX;
      prevFrom.current = from;
    }
  }, [from, week]);

  // Keep the cursor's column on screen; jumping to a far-off date snaps rather than glides.
  useEffect(() => {
    const el = scroller.current;
    if (!el || week) return;
    const idx = days.indexOf(cursor);
    if (idx < 0) return;
    const x = idx * COL_PX;
    const left = el.scrollLeft;
    const right = left + el.clientWidth - COL_PX;
    if (x >= left + 8 && x <= right - 8) return;
    const target = Math.max(0, x - Math.min(2, Math.floor(el.clientWidth / COL_PX / 3)) * COL_PX);
    el.scrollTo({ left: target, behavior: firstScroll.current || Math.abs(target - left) > el.clientWidth * 2 ? "auto" : "smooth" });
    firstScroll.current = false;
  }, [cursor, days, week]);

  // Open on the current hour rather than at midnight.
  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    el.scrollTop = Math.max(0, scale.y(minutesOfDay(Date.now())) - el.clientHeight * 0.35);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Scrolling to either end of the strip loads more days.
  const onScroll = () => {
    const el = scroller.current;
    if (!el || week) return;
    if (el.scrollLeft < COL_PX * 3) extend("start", 21);
    else if (el.scrollLeft + el.clientWidth > el.scrollWidth - COL_PX * 3) extend("end", 21);
  };

  const template = `56px repeat(${days.length}, ${week ? "minmax(0, 1fr)" : `${COL_PX}px`})`;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <WeekTasks />
      <div
        ref={scroller}
        onScroll={onScroll}
        className={cn("min-h-0 flex-1 overflow-auto rounded-md border border-border bg-background", week && "overflow-x-hidden")}
      >
        <div className="grid" style={{ gridTemplateColumns: template, width: week ? "100%" : 56 + days.length * COL_PX }}>
          {/* row 1 — the sticky day headers */}
          <div className="sticky left-0 top-0 z-40 border-b border-border bg-background" />
          {days.map((d) => (
            <div key={`h-${d}`} className={cn("group/col sticky top-0 z-30 border-b border-border bg-background", isToday(d) && "shadow-[inset_0_-2px_0_0_var(--foreground)]")}>
              <DayHeader date={d} />
            </div>
          ))}

          {/* row 2 — the gutter and the timelines */}
          {/* Above the columns' own event/now-line layers (z-10/z-20) but below the sticky day headers. */}
          <div className="sticky left-0 z-[25] bg-background" style={{ height: scale.height }}>
            <HourGutter />
          </div>
          {days.map((d) => (
            <div key={`b-${d}`} onMouseDown={() => setCursor(d)}>
              <DayBody date={d} />
            </div>
          ))}
        </div>
      </div>
      <p className="pt-1.5 text-[11px] text-tertiary">
        {today === cursor ? "Today" : cursor} · ← → to walk the days, ↑ ↓ to move through the day, n for a new event
      </p>
    </div>
  );
}

/** Hour labels, aligned to the same piecewise scale the columns use. */
function HourGutter() {
  const { scale, settings, nightOpen, setNightOpen } = useCalendar();
  return (
    <div className="relative h-full pr-1.5 text-right">
      {scale.segments
        .filter((s) => s.night)
        .map((s) => (
          <button
            key={s.from}
            type="button"
            onClick={() => setNightOpen(!nightOpen)}
            style={{ top: s.y, height: s.height }}
            className="absolute inset-x-0 flex items-center justify-end gap-1 pr-1.5 text-[9px] text-tertiary hover:text-foreground"
          >
            <Moon size={9} />
          </button>
        ))}
      {scale.hours.map((h) =>
        h.hour === 0 || h.hour === 24 ? null : (
          <div key={h.hour} style={{ top: h.y - 5 }} className="absolute right-1.5 text-[10px] tnum text-tertiary">
            {label(h.hour, settings.time_format)}
          </div>
        ),
      )}
    </div>
  );
}

function label(hour: number, format: "12" | "24"): string {
  if (format === "24") return `${String(hour).padStart(2, "0")}:00`;
  const h = hour % 12 === 0 ? 12 : hour % 12;
  return `${h} ${hour < 12 || hour === 24 ? "AM" : "PM"}`;
}
