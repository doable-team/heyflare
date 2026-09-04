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
