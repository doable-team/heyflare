import { useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { Link } from "react-router-dom";
import { BookOpen, Plus } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { eventColors } from "./colors";
import { freeGaps, heyRange, heyTime, makeRibbon, spanLabel, type Ribbon, type RibbonRun } from "./scale";
import { useCalendarDayMutation, useHabitMutations } from "../api";
import { DayPhotoBackdrop, DayPhotoButton } from "./DayPhoto";
import {
  addDays,
  dateKey,
  dateRange,
  daysBetween,
  dayNumber,
  isToday,
  layoutColumns,
  longDayLabel,
  msAt,
  relativeDay,
  startOfDayMs,
  todayKey,
  weekdayLabel,
} from "../lib/caldate";

/**
 * The day view, drawn the way HEY draws it: **time runs sideways**.
 *
 * "We've got this really unusual novel view, which is a horizontal timeline of time where the
 * events are printed vertically on the screen, like the spine of a book in a library." — Jason
 * Fried. So the x axis is time, and an event is a full-height bar as wide as it is long, filled
 * solid with its calendar's colour, its title rotated to read bottom-to-top. A shelf of spines.
 *
 * Two things follow from that, and they are the whole point:
 *
 *  - It never ends. The strip is one continuous ribbon that scrolls straight through midnight,
 *    with the night hours squeezed (see `makeRibbon`), so roughly a day and a half of real time
 *    fits on screen and tomorrow morning is just further to the right.
 *
 *  - Free time is drawn, at full scale, and stamped with how long it is — "we're actually showing
 *    the duration of non-events… your day is actually full". You carve an event out of the gap
 *    rather than dropping it onto a blank.
 */

/** Measured off 37signals' own screenshot: dead linear, and the bars sit at full track height. */
const PX_PER_HOUR = 42.7;
/** Nothing narrower than this reads as a bar, however short the meeting. */
const MIN_BAR_PX = 26;
/** Below this a bar has room for the rotated title and nothing else. */
const TIME_ON_BAR_PX = 84;
/** Don't stamp a sliver of free time with its length. */
const MIN_STAMP_PX = 34;
/** Snap dragged-out events to the quarter hour. */
const SNAP_MS = 15 * 60_000;

const CAPTION_H = 19;
const HOURS_H = 17;
const TRACK_TOP = CAPTION_H + HOURS_H;

export function DayRibbon({ full = false }: { full?: boolean }) {
  const { cursor, setCursor, settings, eventsOn, range, openEvent, createEvent, nightOpen, setNightOpen, revealAt, reportVisibleMonth } = useCalendar();
  const { allDay } = eventsOn(cursor);
  const habitMut = useHabitMutations();
  const dayMut = useCalendarDayMutation();
  const day = range?.days.find((d) => d.date === cursor);
  const habits = (range?.habits ?? []).filter((h) => !h.archived && h.days.includes(new Date(`${cursor}T00:00:00`).getDay()));

  // The ribbon is deliberately wider than the day it is named after: yesterday evening is still
  // worth a glance, and the next two mornings are where you are actually about to live.
  const fromKey = addDays(cursor, -1);
  const toKey = addDays(cursor, 3);
  const winFrom = startOfDayMs(fromKey);
  const winTo = startOfDayMs(toKey);

  const ribbon = useMemo(
    () =>
      makeRibbon({
        from: winFrom,
        to: winTo,
        pxPerHour: PX_PER_HOUR,
        nightStart: settings.night_start,
        nightEnd: settings.night_end,
        collapseNight: settings.collapse_night && !nightOpen,
      }),
    [winFrom, winTo, settings.night_start, settings.night_end, settings.collapse_night, nightOpen],
  );

  // Everything timed that touches the window, in one list — the ribbon runs through midnight, so
  // slicing per calendar day would only put back the boundary this view exists to remove.
  const timed = useMemo(
    () => (range?.events ?? []).filter((e) => !e.all_day && e.ends_at > winFrom && e.starts_at < winTo).sort((a, b) => a.starts_at - b.starts_at || b.ends_at - a.ends_at),
    [range, winFrom, winTo],
  );
  const layout = useMemo(() => layoutColumns(timed), [timed]);
  const gaps = useMemo(() => freeGaps(timed, winFrom, winTo), [timed, winFrom, winTo]);

  // A caption per day boundary. `ribbon.midnights` only reports the midnights that land on a run
  // boundary, and with the night compressed midnight sits *inside* the night run, so the rest are
  // filled in by date.
  // A day's caption belongs over that day's daylight, not over midnight — midnight sits inside the
  // compressed night block, so anchoring there parks the label on the wrong side of the join.
  const dayMarks = useMemo(() => {
    const nightEnd = settings.night_end;
    const nightStart = settings.night_start;
    return dateRange(fromKey, toKey)
      .map((key) => {
        const base = startOfDayMs(key);
        const wakeFrom = ribbon.pos(base + nightEnd * 3_600_000);
        const wakeTo = ribbon.pos(base + Math.min(nightStart, 24) * 3_600_000);
        return { key, pos: (wakeFrom + wakeTo) / 2, width: Math.max(0, wakeTo - wakeFrom) };
      })
      .filter((m) => m.width > 40 && m.pos > 2 && m.pos < ribbon.length - 2)
      .sort((a, b) => a.pos - b.pos);
  }, [ribbon, fromKey, toKey, settings.night_end, settings.night_start]);

  const hourStep = ribbon.pxPerHour >= 40 ? 1 : 2;

  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(t);
  }, []);
  const showNow = now >= winFrom && now <= winTo;

  // Land with the present a third of the way in, so there's context behind and room ahead.
  const scrollRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const anchor = isToday(cursor) ? Date.now() : msAt(cursor, 9 * 60);
    el.scrollLeft = Math.max(0, ribbon.pos(anchor) - el.clientWidth / 3);
    // `revealAt.nonce` is in the deps so "Today" re-anchors even when the cursor already held it
    // and you had simply scrolled the ribbon away.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ribbon, cursor, revealAt.nonce]);

  // Tell the toolbar which month the ribbon is actually showing — a third in, where the eye is.
  const onRibbonScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    reportVisibleMonth(dateKey(ribbon.at(el.scrollLeft + el.clientWidth / 3)).slice(0, 7));
  };

  const trackRef = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<{ from: number; to: number } | null>(null);
  const instantAt = (clientX: number): number => {
    const box = trackRef.current?.getBoundingClientRect();
    if (!box) return winFrom;
    return Math.round(ribbon.at(clientX - box.left) / SNAP_MS) * SNAP_MS;
  };

  const countdowns = (range?.events ?? [])
    .filter((e) => e.countdown && (e.start_date ?? "") >= todayKey())
    .sort((a, b) => (a.start_date ?? "").localeCompare(b.start_date ?? ""))
    .slice(0, 8);

  const [labelDraft, setLabelDraft] = useState(day?.label ?? "");
  const [editingLabel, setEditingLabel] = useState(false);
  useEffect(() => setLabelDraft(day?.label ?? ""), [day?.label, cursor]);

  return (
    <div className={cn("flex min-h-0 flex-col overflow-hidden rounded-md border border-border bg-background", full ? "flex-1" : "h-full")}>
      <header className="shrink-0 border-b border-border px-3 py-2">
        <div className="flex items-center gap-1">
          <div className="min-w-0 flex-1 text-center">
            <div className="truncate text-[14px] font-semibold">{longDayLabel(cursor)}</div>
            {relativeDay(cursor) && <div className="text-[11px] text-muted-foreground">{relativeDay(cursor)}</div>}
          </div>
          <Link to={`/journal/${cursor}`} className="rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground" title="Journal">
            <BookOpen size={15} />
          </Link>
          <DayPhotoButton date={cursor} day={day} className="p-1" />
          <button
            type="button"
            onClick={() => createEvent({ starts_at: msAt(cursor, 9 * 60), ends_at: msAt(cursor, 10 * 60) })}
            className="rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
            aria-label="New event"
          >
            <Plus size={15} />
          </button>
        </div>

        {editingLabel ? (
          <input
            autoFocus
            value={labelDraft}
            onChange={(e) => setLabelDraft(e.target.value)}
            onBlur={() => {
              setEditingLabel(false);
              if ((day?.label ?? "") !== labelDraft) dayMut.mutate({ date: cursor, label: labelDraft });
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter") (e.target as HTMLInputElement).blur();
              if (e.key === "Escape") {
                setLabelDraft(day?.label ?? "");
                setEditingLabel(false);
              }
            }}
            placeholder="Name this day"
            className="mt-1 h-5 w-full bg-transparent text-center text-[12px] outline-none placeholder:text-tertiary"
          />
        ) : (
          <button
            type="button"
            onClick={() => setEditingLabel(true)}
            className={cn("mt-0.5 h-5 w-full truncate text-center text-[12px]", day?.label ? "text-muted-foreground" : "text-tertiary/70 hover:text-tertiary")}
          >
            {day?.label || "Name this day"}
          </button>
        )}

        {habits.length > 0 && (
          <div className="mt-1.5 flex flex-wrap justify-center gap-1.5">
            {habits.map((h) => {
              const done = h.completions?.includes(cursor);
              return (
                <button
                  key={h.id}
                  type="button"
                  onClick={() => habitMut.toggle.mutate({ id: h.id, date: cursor })}
                  aria-pressed={done}
                  title={`${h.name}${done ? " · done" : ""}`}
                  className={cn(
                    "inline-flex size-7 items-center justify-center rounded-full border text-[13px] transition-colors",
                    done ? "border-transparent" : "border-border text-muted-foreground hover:border-foreground/40",
                  )}
                  style={done ? { background: h.color || "currentColor", color: "#fff" } : undefined}
                >
                  {h.icon || h.name.slice(0, 1).toUpperCase()}
                </button>
              );
            })}
          </div>
        )}
      </header>

      {/* The cover photo runs floor-to-ceiling behind the whole strip, not as a thumbnail. */}
      <div className="relative min-h-0 flex-1">
        <DayPhotoBackdrop day={day} />

        <div ref={scrollRef} onScroll={onRibbonScroll} className="overscroll-contain absolute inset-0 overflow-x-auto overflow-y-hidden">
          <div className="relative h-full" style={{ width: Math.max(ribbon.length, 1) }}>
            {/* Which day you are scrolled into. */}
            {dayMarks.map((m) => (
              <div
                key={m.key}
                className={cn(
                  "pointer-events-none absolute whitespace-nowrap text-[10.5px] leading-[19px]",
                  isToday(m.key) ? "font-semibold text-foreground" : "text-muted-foreground",
                )}
                style={{ left: m.pos, top: 0, transform: "translateX(-50%)" }}
              >
                {weekdayLabel(m.key)} {dayNumber(m.key)}
              </div>
            ))}

            {ribbon.hours
              .filter((h) => h.hour % hourStep === 0)
              .map((h) => (
                <div key={h.ms} className="pointer-events-none absolute whitespace-nowrap text-[11px] tnum text-muted-foreground" style={{ left: h.pos + 3, top: CAPTION_H }}>
                  {heyTime(h.ms, settings.time_format)}
                </div>
              ))}

            <div
              ref={trackRef}
              className="absolute inset-x-0 bottom-0 select-none"
              style={{ top: TRACK_TOP }}
              onMouseDown={(e) => {
                if (e.button !== 0 || (e.target as HTMLElement).closest("button")) return;
                const from = instantAt(e.clientX);
                setDrag({ from, to: from + 30 * 60_000 });
              }}
              onMouseMove={(e) => drag && setDrag({ ...drag, to: instantAt(e.clientX) })}
              onMouseUp={() => {
                if (!drag) return;
                const a = Math.min(drag.from, drag.to);
                const b = Math.max(drag.from, drag.to);
                setDrag(null);
                createEvent({ starts_at: a, ends_at: b === a ? a + 30 * 60_000 : b });
              }}
              onMouseLeave={() => setDrag(null)}
            >
              {/* Free time, drawn to scale and stamped — the thesis of the whole view. */}
              {gaps.map((g) => {
                const left = ribbon.pos(g.from);
                const width = ribbon.pos(g.to) - left;
                if (width < 1) return null;
                const stamp = stampPos(ribbon, g.from, g.to);
                return (
                  <div key={g.from} className="pointer-events-none absolute inset-y-0 bg-muted/60" style={{ left, width }}>
                    {width >= MIN_STAMP_PX && stamp !== null && (
                      <span className="absolute bottom-1 -translate-x-1/2 whitespace-nowrap text-[9.5px] text-tertiary" style={{ left: stamp - left }}>
                        {spanLabel(g.to - g.from)}
                      </span>
                    )}
                  </div>
                );
              })}

              {/* The only ruling: a near-invisible hairline under each hour label. */}
              {ribbon.hours
                .filter((h) => h.hour % hourStep === 0)
                .map((h) => (
                  <div key={h.ms} className="pointer-events-none absolute inset-y-0 border-l border-border/40" style={{ left: h.pos }} />
                ))}

              {ribbon.runs.filter((r) => r.night).map((r) => (
                <NightBlock key={r.from} run={r} ribbon={ribbon} onClick={() => setNightOpen(!nightOpen)} />
              ))}

              {timed.map((e, i) => (
                <Spine key={e.id} e={e} ribbon={ribbon} slot={layout[i]} format={settings.time_format} onClick={() => openEvent(e)} />
              ))}

              {drag && (
                <div
                  className="pointer-events-none absolute inset-y-1 z-30 rounded-[3px] border border-dashed border-foreground/50 bg-foreground/10"
                  style={{
                    left: ribbon.pos(Math.min(drag.from, drag.to)),
                    width: Math.max(ribbon.pos(Math.max(drag.from, drag.to)) - ribbon.pos(Math.min(drag.from, drag.to)), 6),
                  }}
                />
              )}

              {showNow && (
                <div className="pointer-events-none absolute inset-y-0 z-40" style={{ left: ribbon.pos(now) }}>
                  <div className="h-full w-px bg-red-500" />
                  <div className="absolute -left-[3px] -top-[3px] size-[7px] rounded-full bg-red-500" />
                  <div className="absolute -top-[1px] left-2 rounded-sm bg-red-500 px-1 py-px text-[9.5px] font-medium tnum text-white">
                    {heyTime(now, settings.time_format)}
                  </div>
                </div>
              )}

              {timed.length === 0 && (
                <p className="pointer-events-none absolute inset-y-0 flex items-center whitespace-nowrap text-[12px] text-tertiary" style={{ left: ribbon.pos(msAt(cursor, 10 * 60)) }}>
                  Nothing scheduled. Drag across the strip to make something.
                </p>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* HEY pins all-day items to the bottom of the day, as fully-rounded pills. */}
      {allDay.length > 0 && (
        <div className="flex shrink-0 flex-wrap items-center gap-1.5 border-t border-border px-3 py-1.5">
          {allDay.map((e) => {
            const c = eventColors(e.calendar_color);
            return (
              <button
                key={e.id}
                type="button"
                onClick={() => openEvent(e)}
                title={e.title || "(no title)"}
                className={cn("max-w-[240px] truncate rounded-full px-2.5 py-[3px] text-[11.5px] font-medium", e.rsvp === "declined" && "opacity-45 line-through")}
                style={{ background: c.background, color: c.color }}
              >
                {e.emoji ? `${e.emoji} ` : ""}
                {e.title || "(no title)"}
              </button>
            );
          })}
        </div>
      )}

      {countdowns.length > 0 && (
        <div className="shrink-0 overflow-x-auto border-t border-border px-3 py-1.5">
          <div className="flex items-center gap-2 whitespace-nowrap text-[11px] text-muted-foreground">
            {countdowns.map((e: CalEvent, i) => {
              const d = Math.max(0, daysBetween(todayKey(), e.start_date ?? todayKey()));
              return (
                <span key={e.id} className="flex shrink-0 items-center gap-2">
                  {i > 0 && <span className="text-tertiary">·</span>}
                  <button type="button" onClick={() => openEvent(e)} className="shrink-0 hover:text-foreground">
                    {d === 0 ? (
                      <>Today —</>
                    ) : (
                      <>
                        <span className="tnum">{d}</span> {d === 1 ? "day" : "days"} until
                      </>
                    )}{" "}
                    {e.emoji} {e.title}
                  </button>
                </span>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}

/**
 * One event, as the spine of a book on a shelf: the bar is as wide as the meeting is long and as
 * tall as the track, filled solid, with the title turned on its side. "People looking at this
 * observationally as a screenshot go, I can't read that… you get the shapes of the letters even if
 * they're turned the other way." Overlapping events split the height instead of the width, because
 * the width is already spoken for — it is the duration.
 */
function Spine({
  e,
  ribbon,
  slot,
  format,
  onClick,
}: {
  e: CalEvent;
  ribbon: Ribbon;
  slot: { column: number; columns: number };
  format: "12" | "24";
  onClick: () => void;
}) {
  const left = ribbon.pos(e.starts_at);
  const width = Math.max(ribbon.pos(e.ends_at) - left, MIN_BAR_PX);
  const c = eventColors(e.calendar_color);
  const wide = width >= TIME_ON_BAR_PX;
  const share = 100 / slot.columns;
  return (
    <button
      type="button"
      onClick={onClick}
      title={`${e.title || "(no title)"} · ${heyRange(e.starts_at, e.ends_at, format)}`}
      className={cn(
        "absolute z-20 overflow-hidden rounded-[3px] text-left transition-opacity hover:opacity-90",
        e.rsvp === "declined" && "opacity-40",
        e.status === "tentative" && "opacity-70",
      )}
      style={{
        left,
        width,
        top: `calc(${slot.column * share}% + 2px)`,
        height: `calc(${share}% - 4px)`,
        background: c.background,
        color: c.color,
      }}
    >
      {wide && (
        <span className="absolute inset-x-1.5 top-[3px] truncate text-[10px] leading-[12px] tnum opacity-70">{heyRange(e.starts_at, e.ends_at, format)}</span>
      )}
      <span className={cn("flex h-full w-full items-center justify-center overflow-hidden px-0.5", wide && "pt-3")}>
        <span className="max-h-full overflow-hidden text-[12px] font-semibold leading-none" style={{ writingMode: "vertical-rl", transform: "rotate(180deg)" }}>
          {e.emoji ? `${e.emoji} ` : ""}
          {e.title || "(no title)"}
        </span>
      </span>
    </button>
  );
}

/**
 * The quiet hours. They are squeezed by the ribbon rather than cut out, so the strip keeps running
 * through midnight; the block is dark, faintly starred, and torn along both edges so it reads as a
 * piece removed from the day rather than an event of its own. Click it to see the hours at scale.
 */
function NightBlock({ run, ribbon, onClick }: { run: RibbonRun; ribbon: Ribbon; onClick: () => void }) {
  const dots = useMemo(() => stars(run.from, Math.max(5, Math.min(26, Math.round(run.size / 4)))), [run.from, run.size]);
  const d = new Date(run.from);
  const midnight = new Date(d.getFullYear(), d.getMonth(), d.getDate() + (d.getHours() >= 12 ? 1 : 0), 0, 0, 0, 0).getTime();
  const midPos = midnight > run.from && midnight < run.to ? ribbon.pos(midnight) - run.pos : null;

  return (
    <button
      type="button"
      onClick={onClick}
      title="Nighttime — click to open the quiet hours"
      className="absolute inset-y-0 z-10 overflow-hidden bg-[#1c1c24] dark:bg-[#2c2c3b]"
      style={{ left: run.pos, width: run.size, ...tornEdges }}
    >
      {dots.map((s, i) => (
        <span
          key={i}
          className="absolute rounded-full bg-white"
          style={{ left: `${s.x * 100}%`, top: `${s.y * 100}%`, width: s.big ? 2 : 1, height: s.big ? 2 : 1, opacity: s.o }}
        />
      ))}
      {midPos !== null && <span className="absolute inset-y-0 w-px bg-black" style={{ left: midPos }} />}
      <span className="flex h-full w-full items-center justify-center">
        <span className="text-[9.5px] tracking-wide text-white/45" style={{ writingMode: "vertical-rl", transform: "rotate(180deg)" }}>
          Nighttime
        </span>
      </span>
    </button>
  );
}

/**
 * Torn paper down the left and right edges: three mask layers unioned — a solid middle inset by the
 * tooth size, and a repeating diagonal comb tiled up each edge.
 */
const SAW = 5;
const TEAR_LEFT = `repeating-linear-gradient(-45deg, #000 0 ${SAW}px, transparent ${SAW}px ${SAW * 2}px)`;
const TEAR_RIGHT = `repeating-linear-gradient(45deg, #000 0 ${SAW}px, transparent ${SAW}px ${SAW * 2}px)`;
const tornEdges: CSSProperties = {
  maskImage: `${TEAR_LEFT}, linear-gradient(#000, #000), ${TEAR_RIGHT}`,
  maskSize: `${SAW}px ${SAW * 2}px, calc(100% - ${SAW * 2}px) 100%, ${SAW}px ${SAW * 2}px`,
  maskPosition: "left center, center, right center",
  maskRepeat: "repeat-y, no-repeat, repeat-y",
  WebkitMaskImage: `${TEAR_LEFT}, linear-gradient(#000, #000), ${TEAR_RIGHT}`,
  WebkitMaskSize: `${SAW}px ${SAW * 2}px, calc(100% - ${SAW * 2}px) 100%, ${SAW}px ${SAW * 2}px`,
  WebkitMaskPosition: "left center, center, right center",
  WebkitMaskRepeat: "repeat-y, no-repeat, repeat-y",
};

/** Stars, placed from the run's own start instant so they never jitter between renders. */
function stars(seed: number, count: number): { x: number; y: number; o: number; big: boolean }[] {
  let s = (Math.floor(seed / 60_000) ^ 0x9e3779b9) >>> 0;
  const next = () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
  return Array.from({ length: count }, () => {
    const x = 0.05 + next() * 0.9;
    const y = 0.06 + next() * 0.88;
    const r = next();
    return { x, y, o: 0.2 + r * 0.55, big: r > 0.78 };
  });
}

/**
 * Where to stamp a free-time band. A gap that runs into the night is mostly hidden under the night
 * block, so the label goes in the middle of the widest waking stretch it covers.
 */
function stampPos(ribbon: Ribbon, from: number, to: number): number | null {
  let best: { a: number; b: number } | null = null;
  for (const r of ribbon.runs) {
    if (r.night) continue;
    const a = Math.max(r.from, from);
    const b = Math.min(r.to, to);
    if (b <= a) continue;
    if (!best || b - a > best.b - best.a) best = { a, b };
  }
  if (!best) return null;
  return (ribbon.pos(best.a) + ribbon.pos(best.b)) / 2;
}
