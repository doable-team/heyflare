/**
 * Geometry for the day timeline.
 *
 * Two ideas keep this from turning into a spreadsheet grid.
 *
 * First, the day is *fitted*: the scale is built from the hours your events actually occupy, then
 * stretched to fill the height available. A day that runs 08:00–19:00 fills the screen instead of
 * floating in the middle of a 24-hour chart, and you never scroll through empty morning.
 *
 * Second, what falls outside that window collapses into a thin band you can click open. So the
 * mapping from a wall-clock minute to a y offset is piecewise across up to three segments, and
 * every event block, hour rule and now line has to read it from here rather than compute its own.
 */

/** Never draw an hour shorter than this, however empty the day. */
export const MIN_PX_PER_HOUR = 46;
/** Nor taller than this, however sparse — a two-event day shouldn't become a poster. */
export const MAX_PX_PER_HOUR = 132;
/** Height of a collapsed band, whole segment. */
export const BAND_PX = 30;
/** Nothing shorter than this reads as a block. */
export const MIN_EVENT_PX = 30;

export interface ScaleOpts {
  /** First minute of the fitted window (minutes past midnight). */
  from: number;
  /** Last minute of the fitted window. */
  to: number;
  /** When false, the whole 24 hours are drawn at full scale. */
  collapse: boolean;
  /** Height the timeline should fill, when known. */
  fit?: number;
  pxPerHour?: number;
}

export interface Segment {
  from: number;
  to: number;
  y: number;
  height: number;
  /** True for the collapsed early/late bands. */
  band: boolean;
}

export interface TimeScale {
  height: number;
  pxPerHour: number;
  segments: Segment[];
  /** y offset, in px, of a wall-clock minute. */
  y(minutes: number): number;
  /** Inverse: the minute at a y offset, for click-to-create. */
  minutes(y: number): number;
  /** Hour marks that get a rule and a label. */
  hours: { hour: number; y: number }[];
  bandTop: Segment | null;
  bandBottom: Segment | null;
}

/**
 * The window worth drawing for a set of events: the span they cover, padded, widened to a decent
 * working day so an empty calendar still looks like a day, and snapped to whole hours.
 */
export function fitWindow(events: { starts_at: number; ends_at: number; all_day: boolean }[], minutesOfDay: (ms: number) => number): { from: number; to: number } {
  let lo = 9 * 60;
  let hi = 18 * 60;
  for (const e of events) {
    if (e.all_day) continue;
    const s = minutesOfDay(e.starts_at);
    const t = minutesOfDay(e.ends_at - 1);
    if (s < lo) lo = s;
    // An event running past midnight reports a smaller end than start; let it push the day open.
    if (t > hi || t < s) hi = t < s ? 1440 : t;
  }
  const from = Math.max(0, Math.floor((lo - 45) / 60) * 60);
  const to = Math.min(1440, Math.ceil((hi + 45) / 60) * 60);
  return { from, to: Math.max(to, from + 6 * 60) };
}

export function makeScale({ from, to, collapse, fit, pxPerHour }: ScaleOpts): TimeScale {
  const lo = collapse ? Math.max(0, Math.min(1380, from)) : 0;
  const hi = collapse ? Math.min(1440, Math.max(lo + 60, to)) : 1440;
  const openMinutes = hi - lo;

  // Fit the open part of the day to the height we've been given, within reason.
  const bands = (lo > 0 ? BAND_PX : 0) + (hi < 1440 ? BAND_PX : 0);
  const perHour = pxPerHour
    ? pxPerHour
    : fit && fit > bands
      ? Math.max(MIN_PX_PER_HOUR, Math.min(MAX_PX_PER_HOUR, ((fit - bands) / openMinutes) * 60))
      : 60;
  const perMin = perHour / 60;

  const bounds = [0, lo, hi, 1440].filter((v, i, a) => i === 0 || v > a[i - 1]);
  const segments: Segment[] = [];
  let y = 0;
  for (let i = 0; i < bounds.length - 1; i++) {
    const a = bounds[i];
    const b = bounds[i + 1];
    const band = b <= lo || a >= hi;
    const height = band ? BAND_PX : (b - a) * perMin;
    segments.push({ from: a, to: b, y, height, band });
    y += height;
  }
  const height = y;

  const yOf = (minutes: number): number => {
    const m = Math.max(0, Math.min(1440, minutes));
    for (const s of segments) {
      if (m <= s.to) return s.y + ((m - s.from) / (s.to - s.from)) * s.height;
    }
    return height;
  };
  const minutesOf = (py: number): number => {
    const p = Math.max(0, Math.min(height, py));
    for (const s of segments) {
      if (p <= s.y + s.height) return s.from + ((p - s.y) / s.height) * (s.to - s.from);
    }
    return 1440;
  };

  // Label only the hours inside the open window; a collapsed band gets one glyph instead.
  const hours: { hour: number; y: number }[] = [];
  const stepH = perHour < 54 ? 2 : 1;
  for (let h = Math.ceil(lo / 60); h * 60 <= hi; h++) {
    if ((h - Math.ceil(lo / 60)) % stepH === 0) hours.push({ hour: h, y: yOf(h * 60) });
  }

  return {
    height,
    pxPerHour: perHour,
    segments,
    y: yOf,
    minutes: minutesOf,
    hours,
    bandTop: segments.find((s) => s.band && s.from === 0) ?? null,
    bandBottom: segments.find((s) => s.band && s.to === 1440) ?? null,
  };
}

/** Snap a minute to the nearest 15 for click-and-drag creation. */
export function snap(minutes: number, step = 15): number {
  return Math.round(minutes / step) * step;
}

/* ------------------------------------------------------------------------------------------------
 * The ribbon: one continuous run of time, mapped to one axis.
 *
 * HEY's calendar is spatial — "empty space means something, the size of events means something"
 * (Jason Fried) — so time is drawn strictly to scale, with one exception: the night hours are
 * squeezed into a fixed block about four times narrower than they deserve. That makes the axis
 * piecewise, and it lets the day view scroll straight through midnight without a day boundary.
 *
 * The same ribbon serves the vertical week columns (one ribbon per day) and the horizontal day
 * view (one ribbon spanning several days), which is why it works in instants rather than minutes.
 * ---------------------------------------------------------------------------------------------- */

/** 10pm–6am, condensed to this many pixels however long it really is. */
export const NIGHT_PX = 80;
export const DAY_PX_PER_HOUR = 43;

export interface RibbonRun {
  from: number;
  to: number;
  pos: number;
  size: number;
  night: boolean;
}

export interface Ribbon {
  length: number;
  pxPerHour: number;
  runs: RibbonRun[];
  /** Offset along the axis, in px, of an instant. */
  pos(ms: number): number;
  /** The instant at an offset — for click and drag. */
  at(px: number): number;
  /** Whole hours inside the waking runs, for labelling. */
  hours: { ms: number; pos: number; hour: number }[];
  /** Midnights, for the day boundaries in the horizontal view. */
  midnights: { ms: number; pos: number }[];
}

function startOfHour(ms: number): number {
  const d = new Date(ms);
  d.setMinutes(0, 0, 0);
  return d.getTime();
}

/** The instant night begins/ends on the local day containing `ms`. */
function nightEdge(ms: number, hour: number): number {
  const d = new Date(ms);
  d.setHours(hour, 0, 0, 0);
  return d.getTime();
}

export function makeRibbon(opts: {
  from: number;
  to: number;
  pxPerHour?: number;
  nightStart?: number;
  nightEnd?: number;
  nightPx?: number;
  collapseNight?: boolean;
}): Ribbon {
  const { from, to } = opts;
  const pxPerHour = opts.pxPerHour ?? DAY_PX_PER_HOUR;
  const nightStart = opts.nightStart ?? 22;
  const nightEnd = opts.nightEnd ?? 6;
  const nightPx = opts.collapseNight === false ? 0 : (opts.nightPx ?? NIGHT_PX);
  const collapse = opts.collapseNight !== false && nightStart > nightEnd;
  const perMs = pxPerHour / 3_600_000;

  const isNight = (ms: number): boolean => {
    if (!collapse) return false;
    const h = new Date(ms).getHours();
    return h >= nightStart || h < nightEnd;
  };
  /** The next instant at which night-ness flips, after `ms`. */
  const nextEdge = (ms: number): number => {
    const h = new Date(ms).getHours();
    if (!collapse) return to;
    if (h >= nightStart) return nightEdge(ms + 86_400_000, nightEnd); // runs into tomorrow morning
    if (h < nightEnd) return nightEdge(ms, nightEnd);
    return nightEdge(ms, nightStart);
  };

  const runs: RibbonRun[] = [];
  let pos = 0;
  let cur = from;
  let guard = 0;
  while (cur < to && guard++ < 2000) {
    const night = isNight(cur);
    const edge = Math.min(nextEdge(cur), to);
    const size = night ? (nightPx * (edge - cur)) / Math.max(1, nextEdge(cur) - cur) : (edge - cur) * perMs;
    runs.push({ from: cur, to: edge, pos, size, night });
    pos += size;
    cur = edge;
  }
  const length = pos;

  const posOf = (ms: number): number => {
    if (ms <= from) return 0;
    if (ms >= to) return length;
    for (const r of runs) {
      if (ms <= r.to) return r.pos + ((ms - r.from) / (r.to - r.from)) * r.size;
    }
    return length;
  };
  const atOf = (px: number): number => {
    const p = Math.max(0, Math.min(length, px));
    for (const r of runs) {
      if (p <= r.pos + r.size) return r.from + ((p - r.pos) / Math.max(1, r.size)) * (r.to - r.from);
    }
    return to;
  };

  const hours: { ms: number; pos: number; hour: number }[] = [];
  const midnights: { ms: number; pos: number }[] = [];
  for (const r of runs) {
    if (r.night) continue;
    for (let t = startOfHour(r.from + 3_599_999); t < r.to; t += 3_600_000) {
      if (t >= r.from) hours.push({ ms: t, pos: posOf(t), hour: new Date(t).getHours() });
    }
  }
  for (const r of runs) {
    const d = new Date(r.from);
    if (d.getHours() === 0 && d.getMinutes() === 0) midnights.push({ ms: r.from, pos: r.pos });
  }

  return { length, pxPerHour, runs, pos: posOf, at: atOf, hours, midnights };
}

/**
 * The gaps between events — HEY draws these at full scale and stamps each with its length, because
 * "your day is actually full" and you carve events out of free time rather than adding them to a
 * blank. Busy intervals are merged first, so two overlapping meetings leave one gap, not none.
 */
export function freeGaps(events: { starts_at: number; ends_at: number; all_day: boolean; busy: boolean }[], from: number, to: number): { from: number; to: number }[] {
  const busy = events
    .filter((e) => !e.all_day && e.busy && e.ends_at > from && e.starts_at < to)
    .map((e) => ({ a: Math.max(e.starts_at, from), b: Math.min(e.ends_at, to) }))
    .sort((x, y) => x.a - y.a);
  const merged: { a: number; b: number }[] = [];
  for (const s of busy) {
    const last = merged[merged.length - 1];
    if (last && s.a <= last.b) last.b = Math.max(last.b, s.b);
    else merged.push({ ...s });
  }
  const gaps: { from: number; to: number }[] = [];
  let cur = from;
  for (const m of merged) {
    if (m.a > cur) gaps.push({ from: cur, to: m.a });
    cur = Math.max(cur, m.b);
  }
  if (cur < to) gaps.push({ from: cur, to });
  return gaps;
}

/** "2hrs", "45min", "1hr 30min" — the stamp on a free-time band. */
export function spanLabel(ms: number): string {
  const mins = Math.round(ms / 60000);
  if (mins < 60) return `${mins}min`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m === 0 ? `${h}hr${h === 1 ? "" : "s"}` : `${h}hr ${m}min`;
}

/** HEY's compact clock: minutes dropped on the hour, a space after the dash but not before. */
export function heyTime(ms: number, format: "12" | "24"): string {
  const d = new Date(ms);
  const h = d.getHours();
  const m = d.getMinutes();
  if (format === "24") return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
  const hh = h % 12 === 0 ? 12 : h % 12;
  const ap = h < 12 ? "AM" : "PM";
  return m === 0 ? `${hh}${ap}` : `${hh}:${String(m).padStart(2, "0")}${ap}`;
}
export function heyRange(a: number, b: number, format: "12" | "24"): string {
  return `${heyTime(a, format)}- ${heyTime(b, format)}`;
}
