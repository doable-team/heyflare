/**
 * Moving and resizing an event by dragging it, the way every calendar since iCal has done it.
 *
 * The two views that support it read time off completely different axes — the week runs down a
 * dead-linear column, the day runs sideways through a ribbon with the night squeezed — so nothing
 * here knows about pixels. Each view converts the pointer's travel into a *delta in milliseconds*
 * and, in the week, a whole number of columns; everything after that (snapping, the minimum
 * duration, which end moves, keeping an event inside its day) is the same in both and lives here.
 */
import type { CalEvent } from "@shared/types";
import { addDays, dateKey, msAt } from "../lib/caldate";

/** Below this the press is still a click: the block opens instead of moving. */
export const DRAG_SLOP_PX = 4;
/** The grab zone at either end of a block, in px. */
export const EDGE_PX = 6;
/** Every edge lands on a quarter hour. */
export const SNAP_MS = 15 * 60_000;
/** However hard you squeeze it, an event stays a quarter of an hour long. */
export const MIN_EVENT_MS = 15 * 60_000;

/** Which end of the event the gesture is holding — or the whole of it. */
export type DragMode = "move" | "start" | "end";

/** The prospective placement of an event mid-drag. All-day events carry their dates too. */
export interface DragSpan {
  starts_at: number;
  ends_at: number;
  start_date?: string | null;
  end_date?: string | null;
}

export function snapMs(ms: number, step = SNAP_MS): number {
  return Math.round(ms / step) * step;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}

/**
 * How thick to draw a grab handle on a block of this size. It never eats more than a third of a
 * short block, or a 20-minute meeting would be nothing but handles.
 */
export function handlePx(size: number): number {
  return Math.max(2, Math.min(EDGE_PX, Math.floor(size / 3)));
}

/**
 * `ms` shifted by whole *calendar* days: 9AM stays 9AM across a daylight-saving boundary, which
 * adding 86,400,000 would not.
 */
export function shiftDays(ms: number, days: number): number {
  if (!days) return ms;
  const d = new Date(ms);
  d.setDate(d.getDate() + days);
  return d.getTime();
}

/**
 * Where a timed event lands, given how far the pointer has travelled.
 *
 * `days` is the whole-column shift (the week's horizontal axis; zero everywhere else) and only
 * applies to a move — dragging an edge changes a time, not a day. `bounds`, when given, is the day
 * the block has been dragged into: a move is kept inside it so an event can't slide out of the
 * week row it started in, and an edge can't cross midnight. Anything that already sat outside
 * those bounds — a meeting that runs past midnight — is left alone rather than squashed into them.
 */
export function dragSpan(
  e: { starts_at: number; ends_at: number },
  mode: DragMode,
  deltaMs: number,
  days = 0,
  bounds?: { min: number; max: number },
): DragSpan {
  const duration = Math.max(MIN_EVENT_MS, e.ends_at - e.starts_at);

  if (mode === "move") {
    let s = snapMs(shiftDays(e.starts_at, days) + deltaMs);
    if (bounds && duration <= bounds.max - bounds.min) s = clamp(s, bounds.min, bounds.max - duration);
    return { starts_at: s, ends_at: s + duration };
  }

  if (mode === "start") {
    let s = snapMs(e.starts_at + deltaMs);
    if (bounds) s = Math.max(s, Math.min(bounds.min, e.starts_at));
    return { starts_at: Math.min(s, e.ends_at - MIN_EVENT_MS), ends_at: e.ends_at };
  }

  let t = snapMs(e.ends_at + deltaMs);
  if (bounds) t = Math.min(t, Math.max(bounds.max, e.ends_at));
  return { starts_at: e.starts_at, ends_at: Math.max(t, e.starts_at + MIN_EVENT_MS) };
}

/**
 * An all-day event moved `days` columns. Only the day may change — never the time — so this works
 * in date keys and rebuilds the instants from them, midnight to midnight with an exclusive end,
 * exactly as the editor submits one.
 */
export function allDaySpan(e: CalEvent, days: number): DragSpan {
  const start = e.start_date ?? dateKey(e.starts_at);
  const end = e.end_date ?? start;
  const s = addDays(start, days);
  const t = addDays(end, days);
  return { start_date: s, end_date: t, starts_at: msAt(s, 0), ends_at: msAt(addDays(t, 1), 0) };
}

/** True when the drag actually asks for something different from where the event already is. */
export function spanMoved(e: CalEvent, span: DragSpan): boolean {
  return span.starts_at !== e.starts_at || span.ends_at !== e.ends_at;
}

/** The patch that commits a drag. All-day events carry their dates; timed ones must not. */
export function spanPatch(e: CalEvent, span: DragSpan): { starts_at: number; ends_at: number; start_date?: string; end_date?: string } {
  return e.all_day
    ? { starts_at: span.starts_at, ends_at: span.ends_at, start_date: span.start_date ?? undefined, end_date: span.end_date ?? undefined }
    : { starts_at: span.starts_at, ends_at: span.ends_at };
}

/**
 * A drag that has been let go of but not yet answered by the server, or one still under the
 * pointer. Both are the same thing to a view: draw this event at these times instead.
 */
export interface EventPreview extends DragSpan {
  id: string;
  event: CalEvent;
}

/** The event as the preview would have it — a copy, so the cache is never written through. */
export function previewed(p: EventPreview): CalEvent {
  return { ...p.event, starts_at: p.starts_at, ends_at: p.ends_at, start_date: p.start_date ?? p.event.start_date, end_date: p.end_date ?? p.event.end_date };
}

/**
 * Swallow the click that a finished drag would otherwise fire. The press began on a button, so
 * letting go of it opens the event; a capture-phase listener eats exactly one click and then takes
 * itself off, and the timer takes it off again if the drag ended somewhere that never clicks.
 */
export function swallowNextClick(el: HTMLElement | null): () => void {
  if (!el) return () => {};
  const stop = (ev: Event) => {
    ev.stopPropagation();
    ev.preventDefault();
  };
  el.addEventListener("click", stop, { capture: true, once: true });
  const t = window.setTimeout(() => el.removeEventListener("click", stop, true), 400);
  return () => {
    window.clearTimeout(t);
    el.removeEventListener("click", stop, true);
  };
}
