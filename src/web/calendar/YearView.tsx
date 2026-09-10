import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { useDark } from "./colors";
import { addDays, daysBetween, keyToDate, monthEndOf, monthName, weekStartOf } from "../lib/caldate";

/**
 * The year: twelve small months, Apple style. A day is bold when something is on it, carries a
 * dot when the journal has an entry for it, and opens the day view when clicked.
 */

/** A day cell, and the weekday letters above the first row. */
const CELL_PX = 32;
/** The month name's line, and the air under it. */
const NAME_PX = 20;
const NAME_GAP_PX = 8;
/** Air between blocks. */
const GAP_X = 24;
const GAP_Y = 32;
/** Air around the whole grid. */
const PAD_PX = 24;
const RED_LIGHT = "#ff3b30";
const RED_DARK = "#ff453a";
const LETTERS = ["S", "M", "T", "W", "T", "F", "S"];

export function YearView() {
  const { cursor, setCursor, setView, today, settings, range, eventsOn, revealAt } = useCalendar();
  const dark = useDark();
  const year = cursor.slice(0, 4);

  // Four blocks across when there is room for them, three when there is less, two otherwise.
  const box = useRef<HTMLDivElement>(null);
  const [cols, setCols] = useState(4);
  useLayoutEffect(() => {
    const el = box.current;
    if (!el) return;
    const measure = () => {
      const w = el.clientWidth;
      setCols(w >= 1100 ? 4 : w >= 820 ? 3 : 2);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const journal = useMemo(() => new Set((range?.days ?? []).filter((d) => d.has_journal).map((d) => d.date)), [range?.days]);
  const busy = (d: string) => {
    const { allDay, timed } = eventsOn(d);
    return allDay.length + timed.length > 0;
  };

  const pick = (d: string) => {
    setCursor(d);
    setView("days");
  };

  // Keep the cursor's month on screen as the keys walk it, and when "Today" asks for it.
  const blocks = useRef(new Map<string, HTMLDivElement>());
  useEffect(() => {
    blocks.current.get(cursor.slice(0, 7))?.scrollIntoView({ block: "nearest" });
  }, [cursor, revealAt.nonce]);

  const letters = useMemo(() => Array.from({ length: 7 }, (_, i) => LETTERS[(settings.week_start + i) % 7]), [settings.week_start]);

  return (
    <div ref={box} className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden overscroll-contain">
      <div className="grid" style={{ padding: PAD_PX, gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`, columnGap: GAP_X, rowGap: GAP_Y }}>
        {Array.from({ length: 12 }, (_, m) => {
          const key = `${year}-${String(m + 1).padStart(2, "0")}`;
          const first = `${key}-01`;
          const last = monthEndOf(first);
          const gridStart = weekStartOf(first, settings.week_start);
          const count = daysBetween(gridStart, last) + 1;
          const rows = Math.ceil(count / 7);
          return (
            <div
              key={key}
              ref={(el) => {
                if (el) blocks.current.set(key, el);
                else blocks.current.delete(key);
              }}
              style={{ width: CELL_PX * 7 }}
            >
              <div className="text-[13px] font-semibold text-foreground" style={{ height: NAME_PX, lineHeight: `${NAME_PX}px`, marginBottom: NAME_GAP_PX, color: key === today.slice(0, 7) ? (dark ? RED_DARK : RED_LIGHT) : undefined }}>
                {monthName(first)}
              </div>
              <div className="grid grid-cols-7">
                {letters.map((l, i) => (
                  <div key={i} className="flex items-center justify-center text-[10px] text-muted-foreground" style={{ height: CELL_PX }}>
                    {l}
                  </div>
                ))}
                {Array.from({ length: rows * 7 }, (_, i) => {
                  const d = addDays(gridStart, i);
                  if (d < first || d > last) return <div key={i} style={{ height: CELL_PX }} />;
                  const isToday = d === today;
                  return (
                    <button
                      key={i}
                      type="button"
                      onClick={() => pick(d)}
                      title={d}
                      className="relative flex items-center justify-center text-[12px] tnum"
                      style={{ height: CELL_PX }}
                    >
                      <span
                        className={cn(
                          "inline-flex size-6 items-center justify-center rounded-full",
                          busy(d) && "font-semibold",
                          isToday && "bg-foreground text-background",
                          !isToday && d === cursor && "border border-foreground",
                        )}
                      >
                        {keyToDate(d).getDate()}
                      </span>
                      {journal.has(d) && <span className="absolute bottom-[2px] left-1/2 size-[3px] -translate-x-1/2 rounded-full bg-foreground/50" />}
                    </button>
                  );
                })}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
