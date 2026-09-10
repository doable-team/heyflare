import { useLayoutEffect, useMemo, useRef, useState } from "react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { AllDayPill, TimedRow } from "./EventBlock";
import { dateKey, daysBetween, monthGrid, monthShort, weekdayShort } from "../lib/caldate";

/**
 * The month: six weeks of seven cells, every cell listing its day the way Apple Calendar does —
 * all-day things as pills that run across the cells they cover, timed things as a dot, a time
 * and a title — and counting what does not fit.
 */

/** The weekday header row. */
const HEADER_PX = 28;
/** A cell's padding on every side. */
const CELL_PAD_PX = 4;
/** The day number's line, and the air under it before the first event row. */
const NUMBER_PX = 22;
const NUMBER_GAP_PX = 2;
/** An event row, and the gap between two. */
const ROW_PX = 18;
const ROW_GAP_PX = 1;
/** Where the first event row starts inside a cell. */
const ROWS_TOP_PX = CELL_PAD_PX + NUMBER_PX + NUMBER_GAP_PX;

/** What one lane of one cell holds. */
type Item = { kind: "span"; seg: Segment } | { kind: "timed"; e: CalEvent };

/** An all-day event clipped to one week row. */
interface Segment {
  e: CalEvent;
  start: number;
  end: number;
  /** Began before this row's first day. */
  continuing: boolean;
  lane: number;
}

/** A segment cut to the cells where its lane is actually visible. */
interface Run {
  seg: Segment;
  start: number;
  end: number;
}

export function MonthView() {
  const { cursor, setCursor, setView, today, settings, range, eventsOn, openEvent } = useCalendar();
  const days = useMemo(() => monthGrid(cursor, settings.week_start), [cursor, settings.week_start]);
  const month = cursor.slice(0, 7);
  const weeks = useMemo(() => Array.from({ length: 6 }, (_, r) => days.slice(r * 7, r * 7 + 7)), [days]);

  // How many rows a cell can show is a matter of how tall it is, and that is a matter of the window.
  const firstRow = useRef<HTMLDivElement>(null);
  const [rowPx, setRowPx] = useState(0);
  useLayoutEffect(() => {
    const el = firstRow.current;
    if (!el) return;
    const measure = () => setRowPx(el.clientHeight);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const capacity = Math.max(0, Math.floor((rowPx - ROWS_TOP_PX - CELL_PAD_PX + ROW_GAP_PX) / (ROW_PX + ROW_GAP_PX)));

  const allDay = useMemo(() => (range?.events ?? []).filter((e) => e.all_day), [range?.events]);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="grid shrink-0 grid-cols-7 border-b border-border" style={{ height: HEADER_PX }}>
        {weeks[0].map((d) => (
          <div key={d} className="flex items-center justify-end pr-2 text-[11px] font-medium text-muted-foreground">
            {weekdayShort(d)}
          </div>
        ))}
      </div>
      <div className="flex min-h-0 flex-1 flex-col">
        {weeks.map((week, r) => (
          <WeekRow
            key={week[0]}
            innerRef={r === 0 ? firstRow : undefined}
            week={week}
            month={month}
            today={today}
            cursor={cursor}
            capacity={capacity}
            allDay={allDay}
            eventsOn={eventsOn}
            format={settings.time_format}
            onPick={setCursor}
            onOpenDay={(d) => {
              setCursor(d);
              setView("days");
            }}
            onOpen={openEvent}
          />
        ))}
      </div>
    </div>
  );
}

function WeekRow({
  innerRef,
  week,
  month,
  today,
  cursor,
  capacity,
  allDay,
  eventsOn,
  format,
  onPick,
  onOpenDay,
  onOpen,
}: {
  innerRef?: React.RefObject<HTMLDivElement | null>;
  week: string[];
  month: string;
  today: string;
  cursor: string;
  capacity: number;
  allDay: CalEvent[];
  eventsOn: (date: string) => { allDay: CalEvent[]; timed: CalEvent[] };
  format: "12" | "24";
  onPick: (d: string) => void;
  onOpenDay: (d: string) => void;
  onOpen: (e: CalEvent) => void;
}) {
  const first = week[0];
  const last = week[6];

  const { cells, runs, more } = useMemo(() => {
    // Lanes are shared across the row: a pill keeps its row index from the first cell it covers to
    // the last, and the timed events of each day fill in around it.
    const lanes: (Item | null)[][] = week.map(() => []);
    const segs: Omit<Segment, "lane">[] = [];
    for (const e of allDay) {
      const from = e.start_date ?? dateKey(e.starts_at);
      const to = e.end_date ?? from;
      if (to < first || from > last) continue;
      segs.push({ e, start: Math.max(0, daysBetween(first, from)), end: Math.min(6, daysBetween(first, to)), continuing: from < first });
    }
    segs.sort((a, b) => a.start - b.start || b.end - a.end || a.e.starts_at - b.e.starts_at || a.e.id.localeCompare(b.e.id));
    const placed: Segment[] = [];
    for (const s of segs) {
      let lane = 0;
      while (week.slice(s.start, s.end + 1).some((_, i) => lanes[s.start + i][lane])) lane++;
      const seg: Segment = { ...s, lane };
      for (let c = s.start; c <= s.end; c++) lanes[c][lane] = { kind: "span", seg };
      placed.push(seg);
    }
    week.forEach((d, c) => {
      for (const e of eventsOn(d).timed) {
        // A timed event that crosses midnight is listed on the day it starts.
        if (dateKey(e.starts_at) !== d) continue;
        let lane = 0;
        while (lanes[c][lane]) lane++;
        lanes[c][lane] = { kind: "timed", e };
      }
    });

    // As many rows as fit; when a cell holds more than that, the last row becomes the count.
    const total = lanes.map((l) => l.filter(Boolean).length);
    const visible = total.map((t) => (t <= capacity ? capacity : Math.max(0, capacity - 1)));
    const more = total.map((t, c) => (t <= capacity ? 0 : t - lanes[c].slice(0, visible[c]).filter(Boolean).length));

    const runs: Run[] = [];
    for (const seg of placed) {
      let start = -1;
      for (let c = seg.start; c <= seg.end + 1; c++) {
        const shown = c <= seg.end && seg.lane < visible[c];
        if (shown && start < 0) start = c;
        if (!shown && start >= 0) {
          runs.push({ seg, start, end: c - 1 });
          start = -1;
        }
      }
    }
    const cells = lanes.map((l, c) => l.slice(0, visible[c]).map((it) => (it?.kind === "timed" ? it.e : null)));
    return { cells, runs, more };
  }, [week, first, last, allDay, eventsOn, capacity]);

  return (
    <div ref={innerRef} className="relative grid min-h-0 flex-1 grid-cols-7">
      {week.map((d, c) => (
        <div
          key={d}
          onClick={() => onPick(d)}
          onDoubleClick={() => onOpenDay(d)}
          className={cn("relative min-w-0 border-b border-border p-1 hover:bg-muted/30", c < 6 && "border-r")}
        >
          <div className="flex justify-end" style={{ height: NUMBER_PX }}>
            <span
              className={cn(
                "inline-flex h-[22px] min-w-[22px] items-center justify-center rounded-full px-1 text-[12px] font-medium tnum",
                d.slice(0, 7) !== month && "text-tertiary",
                d === today && "bg-foreground text-background",
                d !== today && d === cursor && "border border-foreground",
              )}
            >
              {d.slice(8) === "01" ? `${monthShort(d)} 1` : Number(d.slice(8))}
            </span>
          </div>
          <div className="absolute inset-x-1" style={{ top: ROWS_TOP_PX }}>
            {cells[c].map((e, lane) =>
              e ? (
                <div key={e.id} className="absolute inset-x-0" style={{ top: lane * (ROW_PX + ROW_GAP_PX) }}>
                  <TimedRow e={e} format={format} onClick={() => onOpen(e)} />
                </div>
              ) : null,
            )}
            {more[c] > 0 && (
              <div className="absolute inset-x-0 px-1 text-[11px] leading-[18px] text-muted-foreground" style={{ top: cells[c].length * (ROW_PX + ROW_GAP_PX) }}>
                +{more[c]} more
              </div>
            )}
          </div>
        </div>
      ))}

      {/* The pills float over the cells rather than living inside one: a week-long trip is one bar. */}
      <div className="pointer-events-none absolute inset-0 z-10">
        {runs.map((r) => (
          <AllDayPill
            key={`${r.seg.e.id}:${r.start}`}
            e={r.seg.e}
            height={ROW_PX}
            continuing={r.seg.continuing || r.start > r.seg.start}
            onClick={() => onOpen(r.seg.e)}
            className="pointer-events-auto absolute"
            style={{
              left: `calc(${(r.start / 7) * 100}% + ${CELL_PAD_PX}px)`,
              width: `calc(${((r.end - r.start + 1) / 7) * 100}% - ${CELL_PAD_PX * 2}px)`,
              top: ROWS_TOP_PX + r.seg.lane * (ROW_PX + ROW_GAP_PX),
            }}
          />
        ))}
      </div>
    </div>
  );
}
