import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { BookOpen, ChevronLeft, ChevronRight, ChevronsUpDown } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { invalidateCalendar, useCalendarSourceMutations, useEventMutations, useHabitMutations } from "../api";
import { CalendarProvider, useCalendar } from "../calendar/CalendarContext";
import { EventBlock } from "../calendar/EventBlock";
import { EventSheet } from "../calendar/EventSheet";
import { MIN_EVENT_PX, snap } from "../calendar/scale";
import { addDays, dayNumber, fmtTimeRange, isToday, keyToDate, layoutColumns, minutesOfDay, msAt, todayKey, weekdayLabel } from "../lib/caldate";
import { Screen } from "./Screen";
import { usePullToRefresh } from "./usePullToRefresh";
import { useSwipe } from "./useSwipe";

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
/** How long a finger has to rest before the timeline takes the gesture off the page. */
const HOLD_MS = 400;

/**
 * One day, full screen. The same pieces the desktop day column carries — cover art, the day's
 * label, habits, all-day items, then the collapsing timeline — restacked vertically so a thumb
 * can reach them, with the day stepped by swiping rather than by scrolling a strip sideways.
 */
export default function MobileDay() {
  return (
    <CalendarProvider>
      <DayScreen />
    </CalendarProvider>
  );
}

function DayScreen() {
  const params = useParams<{ date: string }>();
  const date = params.date && DATE_RE.test(params.date) ? params.date : todayKey();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { cursor, setCursor, setView, view, range, eventsOn, openEvent } = useCalendar();
  const { syncAll } = useCalendarSourceMutations();
  const habitMut = useHabitMutations();

  // The route is the source of truth here; the provider's cursor follows it so the loaded window
  // (and anything else reading `useCalendar()`) is anchored on the day actually on screen.
  useEffect(() => {
    if (view !== "days") setView("days");
    if (cursor !== date) setCursor(date);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [date]);

  const go = (delta: number) => nav(`/calendar/${addDays(date, delta)}`, { replace: true });

  const ptr = usePullToRefresh(async () => {
    try {
      await syncAll.mutateAsync();
    } catch {
      /* a source that won't sync shouldn't swallow the refresh */
    }
    invalidateCalendar(qc);
  });

  const swipe = useSwipe({ threshold: 72, onLeft: () => go(1), onRight: () => go(-1) });
  // The timeline's long-press wins over the day swipe: once the hold fires, the swipe is cancelled
  // so a drag that sets a duration can't also step the day out from under it.
  const cancelSwipe = useRef<() => void>(() => {});
  useEffect(() => {
    cancelSwipe.current = swipe.handlers.onPointerCancel;
  });
  const committing = Math.abs(swipe.dx) >= (typeof window === "undefined" ? 9e9 : window.innerWidth * 0.9);

  const day = range?.days.find((d) => d.date === date);
  const dow = keyToDate(date).getDay();
  const habits = (range?.habits ?? []).filter((h) => !h.archived && (h.days.length === 0 || h.days.includes(dow)));
  const { allDay } = eventsOn(date);

  return (
    <Screen
      title={
        <span className="inline-flex items-baseline gap-1.5">
          <span>{weekdayLabel(date)}</span>
          <span className="text-[13px] font-normal tnum text-muted-foreground">
            {dayNumber(date)} {keyToDate(date).toLocaleString(undefined, { month: "short" })}
          </span>
        </span>
      }
      back="/calendar"
      right={
        <div className="flex items-center">
          <button type="button" onClick={() => go(-1)} aria-label="Previous day" className="size-11 flex items-center justify-center text-foreground active:opacity-60">
            <ChevronLeft size={22} />
          </button>
          <button type="button" onClick={() => go(1)} aria-label="Next day" className="size-11 flex items-center justify-center text-foreground active:opacity-60">
            <ChevronRight size={22} />
          </button>
        </div>
      }
    >
      <div {...ptr.handlers}>
        {ptr.indicator}
        <div
          {...swipe.handlers}
          className="touch-pan-y [-webkit-touch-callout:none]"
          style={{
            transform: `translateX(${committing ? 0 : swipe.dx}px)`,
            transition: swipe.dragging || committing ? "none" : "transform 200ms cubic-bezier(.2,.8,.2,1)",
          }}
        >
          {day?.cover_url && (
            <div className="relative h-28 overflow-hidden bg-muted">
              <img
                src={day.cover_url}
                alt=""
                loading="lazy"
                className="h-full w-full object-cover"
                style={{ objectPosition: day.cover_position || "50% 50%" }}
              />
            </div>
          )}
          {day?.label && <div className="px-4 pt-2 text-[13px] font-medium">{day.label}</div>}

          {habits.length > 0 && (
            <div className="flex flex-wrap gap-1.5 px-4 pt-3">
              {habits.map((h) => {
                const done = h.completions?.includes(date) ?? false;
                return (
                  <button
                    key={h.id}
                    type="button"
                    aria-pressed={done}
                    onClick={() => habitMut.toggle.mutate({ id: h.id, date })}
                    className={cn(
                      "h-8 px-3 rounded-full border text-[12px] inline-flex items-center gap-1.5 active:opacity-70",
                      done ? "bg-foreground text-background border-transparent" : "border-border text-muted-foreground",
                    )}
                  >
                    <span className="leading-none">{h.icon || h.name.slice(0, 1).toUpperCase()}</span>
                    <span className="leading-none">{h.name}</span>
                    {!!h.streak && <span className="leading-none tnum opacity-70">{h.streak}</span>}
                  </button>
                );
              })}
            </div>
          )}

          <Link to={`/journal/${date}`} className="mt-3 mx-4 flex items-center gap-2 h-10 rounded-lg bg-muted/50 px-3 active:bg-muted">
            <BookOpen size={15} className="text-muted-foreground shrink-0" />
            <span className="flex-1 text-[13px]">Journal</span>
            <span className="text-[11px] text-muted-foreground">{day?.has_journal ? "Written" : "Empty"}</span>
            <ChevronRight size={14} className="text-tertiary" />
          </Link>

          {allDay.length > 0 && (
            <div className="mt-3 px-4 flex flex-col gap-1">
              {allDay.map((e) => (
                <AllDayRow key={e.id} e={e} onTap={() => openEvent(e)} />
              ))}
            </div>
          )}

          <DayTimeline date={date} onHold={() => cancelSwipe.current()} />

          <div className="px-4 pt-3 text-center text-[11px] text-tertiary">Press and hold the timeline to add an event.</div>
        </div>
      </div>

      <EventSheet />
    </Screen>
  );
}

function AllDayRow({ e, onTap }: { e: CalEvent; onTap: () => void }) {
  return (
    <button
      type="button"
      onClick={onTap}
      className={cn(
        "w-full h-9 px-3 flex items-center gap-2 rounded-md bg-muted/70 text-left text-[13px] active:bg-muted",
        e.rsvp === "declined" && "opacity-50 line-through",
        e.status === "tentative" && "border border-dashed border-border bg-background",
      )}
    >
      {e.emoji && <span className="shrink-0">{e.emoji}</span>}
      <span className="min-w-0 flex-1 truncate">{e.title || "(no title)"}</span>
      <span className="shrink-0 text-[11px] text-muted-foreground">All day</span>
    </button>
  );
}

/**
 * The vertical timeline: the same piecewise scale as desktop (so nighttime collapses identically),
 * an hour gutter, the day's events laid into columns, a red now line, and press-and-hold to create.
 *
 * The hold is deliberately not the `useSwipe` long-press: creating an event needs the *position* of
 * the finger and then a drag for the duration, and it has to take the gesture away from the page's
 * vertical scroll — which is done by preventing the first `touchmove` once the hold has fired, at
 * which point the browser has not yet started a scroll because the finger hasn't moved.
 */
function DayTimeline({ date, onHold }: { date: string; onHold: () => void }) {
  const { scale, settings, eventsOn, openEvent, createEvent, nightOpen, setNightOpen } = useCalendar();
  const { timed } = eventsOn(date);
  const { setDone } = useEventMutations();
  const ref = useRef<HTMLDivElement>(null);
  const [draft, setDraft] = useState<{ from: number; to: number } | null>(null);
  const hold = useRef(false);
  const anchor = useRef(0);
  const timer = useRef<number | null>(null);
  const down = useRef<{ x: number; y: number } | null>(null);
  const today = isToday(date);
  const [nowMin, setNowMin] = useState(() => minutesOfDay(Date.now()));
  // MIN_EVENT_PX is the shortest a block is drawn; at this scale's daytime rate that is how much
  // time it visually claims, and the columns have to reserve the same.
  const layout = layoutColumns(timed, (MIN_EVENT_PX / scale.pxPerHour) * 3_600_000);

  useEffect(() => {
    if (!today) return;
    const t = window.setInterval(() => setNowMin(minutesOfDay(Date.now())), 60_000);
    return () => window.clearInterval(t);
  }, [today]);

  // While a hold is live the page must not scroll. Screen's own scroll-to-top runs on mount, so the
  // opening scroll waits a frame to land after it.
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const block = (e: TouchEvent) => {
      if (hold.current) e.preventDefault();
    };
    el.addEventListener("touchmove", block, { passive: false });
    return () => el.removeEventListener("touchmove", block);
  }, []);

  useEffect(() => {
    const f = requestAnimationFrame(() => {
      const el = ref.current;
      if (!el) return;
      const at = today ? Math.max(0, minutesOfDay(Date.now()) - 90) : 8 * 60;
      window.scrollTo({ top: Math.max(0, el.getBoundingClientRect().top + window.scrollY + scale.y(at) - 100) });
    });
    return () => cancelAnimationFrame(f);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [date]);

  const minutesAt = (clientY: number) => {
    const box = ref.current?.getBoundingClientRect();
    if (!box) return 0;
    return snap(scale.minutes(clientY - box.top));
  };
  const clearHold = () => {
    if (timer.current) {
      window.clearTimeout(timer.current);
      timer.current = null;
    }
  };
  const finish = (commit: boolean) => {
    clearHold();
    down.current = null;
    if (!hold.current) return;
    hold.current = false;
    const d = draft;
    setDraft(null);
    if (commit && d) createEvent({ starts_at: msAt(date, d.from), ends_at: msAt(date, Math.max(d.to, d.from + 15)) });
  };

  const hourLabel = (h: number) => {
    if (settings.time_format === "24") return String(h).padStart(2, "0");
    const x = h % 24;
    return `${x % 12 === 0 ? 12 : x % 12}${x < 12 ? "am" : "pm"}`;
  };

  return (
    <div className="mt-3 flex px-3">
      <div className="w-10 shrink-0 relative" style={{ height: scale.height }}>
        {scale.hours
          .filter((h) => h.hour < 24)
          .map((h) => (
            <div key={h.hour} className="absolute right-2 -translate-y-1/2 text-[10px] tnum text-tertiary" style={{ top: h.y }}>
              {hourLabel(h.hour)}
            </div>
          ))}
      </div>

      <div
        ref={ref}
        className="relative flex-1 border-l border-border select-none touch-pan-y [-webkit-touch-callout:none]"
        style={{ height: scale.height }}
        onContextMenu={(e) => e.preventDefault()}
        onPointerDown={(e) => {
          if ((e.target as HTMLElement).closest("button")) return;
          if (e.pointerType === "mouse" && e.button !== 0) return;
          down.current = { x: e.clientX, y: e.clientY };
          const at = minutesAt(e.clientY);
          const id = e.pointerId;
          const el = e.currentTarget;
          clearHold();
          timer.current = window.setTimeout(() => {
            timer.current = null;
            if (!down.current) return;
            hold.current = true;
            anchor.current = at;
            setDraft({ from: at, to: at + 30 });
            try {
              navigator.vibrate?.(10);
            } catch {
              /* no haptics here */
            }
            try {
              el.setPointerCapture(id);
            } catch {
              /* capture is a nicety, not a requirement */
            }
            onHold();
          }, HOLD_MS);
        }}
        onPointerMove={(e) => {
          if (hold.current) {
            const cur = minutesAt(e.clientY);
            const a = Math.min(anchor.current, cur);
            const b = Math.max(anchor.current, cur);
            setDraft({ from: a, to: Math.max(b, a + 15) });
            return;
          }
          const d = down.current;
          if (!d) return;
          // Any real movement before the hold fires means this was a scroll or a swipe, not a press.
          if (Math.abs(e.clientX - d.x) > 8 || Math.abs(e.clientY - d.y) > 8) {
            clearHold();
            down.current = null;
          }
        }}
        onPointerUp={() => finish(true)}
        onPointerCancel={() => finish(false)}
      >
        {scale.segments.map((s) =>
          s.band ? (
            <button
              key={s.from}
              type="button"
              onClick={() => setNightOpen(!nightOpen)}
              style={{ top: s.y, height: s.height }}
              className="absolute inset-x-0 z-0 bg-muted/60 flex items-center justify-center text-[9px] text-tertiary"
              aria-label={nightOpen ? "Collapse nighttime" : "Expand nighttime"}
            >
              <ChevronsUpDown size={10} />
            </button>
          ) : null,
        )}
        {scale.hours.map((h) => (
          <div key={h.hour} style={{ top: h.y }} className="pointer-events-none absolute inset-x-0 border-t border-border/60" />
        ))}

        {timed.map((e, i) => {
          const top = scale.y(minutesOfDay(Math.max(e.starts_at, msAt(date, 0))));
          const bottom = scale.y(minutesOfDay(Math.min(e.ends_at, msAt(date, 1439))));
          return (
            <EventBlock
              key={e.id}
              e={e}
              top={top}
              height={Math.max(bottom - top, MIN_EVENT_PX)}
              column={layout[i].column}
              columns={layout[i].columns}
              format={settings.time_format}
              onClick={() => openEvent(e)}
              onToggleDone={() => setDone.mutate({ id: e.id, done: !e.done, date })}
            />
          );
        })}

        {draft && (
          <div
            className="pointer-events-none absolute inset-x-0.5 z-30 overflow-hidden rounded-[4px] border border-dashed border-foreground/60 bg-foreground/5 px-1.5 py-0.5"
            style={{ top: scale.y(draft.from), height: Math.max(scale.y(draft.to) - scale.y(draft.from), 16) }}
          >
            <span className="text-[10px] tnum text-muted-foreground">{fmtTimeRange(msAt(date, draft.from), msAt(date, draft.to), false, settings.time_format)}</span>
          </div>
        )}

        {today && (
          <div className="pointer-events-none absolute inset-x-0 z-20" style={{ top: scale.y(nowMin) }}>
            <div className="h-px bg-red-500" />
            <div className="absolute -left-[3px] -top-[3px] size-[7px] rounded-full bg-red-500" />
          </div>
        )}
      </div>
    </div>
  );
}
