/**
 * Geometry for the day timeline.
 *
 * A day column is not a plain linear scale: the night hours collapse into a thin band so the part
 * of the day you actually live in fills the screen. That makes the mapping from a wall-clock minute
 * to a y offset piecewise linear across three segments — night, day, night — and every event block,
 * the hour rules and the "now" line all have to agree on it.
 */

export const PX_PER_HOUR = 56;
/** Height of a collapsed night band, whole segment. */
export const NIGHT_PX = 26;
/** Nothing shorter than this reads as a block. */
export const MIN_EVENT_PX = 18;

export interface ScaleOpts {
  /** Hour the night band starts, e.g. 22. */
  nightStart: number;
  /** Hour the night band ends, e.g. 6. */
  nightEnd: number;
  collapse: boolean;
  pxPerHour?: number;
}

export interface Segment {
  /** Minutes past midnight. */
  from: number;
  to: number;
  y: number;
  height: number;
  night: boolean;
}

export interface TimeScale {
  height: number;
  segments: Segment[];
  /** y offset, in px, of a wall-clock minute. */
  y(minutes: number): number;
  /** Inverse: the minute at a y offset, for click-to-create. */
  minutes(y: number): number;
  /** Hour marks that get a rule and a label. */
  hours: { hour: number; y: number }[];
  nightTop: Segment | null;
  nightBottom: Segment | null;
}

export function makeScale({ nightStart, nightEnd, collapse, pxPerHour = PX_PER_HOUR }: ScaleOpts): TimeScale {
  const perMin = pxPerHour / 60;
  // Guard against a night window that would swallow the whole day.
  const ns = collapse && nightStart > nightEnd && nightEnd >= 0 && nightStart <= 24 ? nightStart : 24;
  const ne = ns === 24 ? 0 : nightEnd;
  const bounds = [0, ne * 60, ns * 60, 1440].filter((v, i, a) => i === 0 || v > a[i - 1]);

  const segments: Segment[] = [];
  let y = 0;
  for (let i = 0; i < bounds.length - 1; i++) {
    const from = bounds[i];
    const to = bounds[i + 1];
    const night = from < ne * 60 || to > ns * 60;
    const height = night && collapse ? NIGHT_PX : (to - from) * perMin;
    segments.push({ from, to, y, height, night: night && collapse });
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

  // Hour rules are drawn only inside the open part of the day; a collapsed band gets one label.
  const hours: { hour: number; y: number }[] = [];
  for (let h = 0; h <= 24; h++) {
    const inNight = segments.some((s) => s.night && h * 60 > s.from && h * 60 < s.to);
    if (!inNight) hours.push({ hour: h, y: yOf(h * 60) });
  }

  return {
    height,
    segments,
    y: yOf,
    minutes: minutesOf,
    hours,
    nightTop: segments.find((s) => s.night && s.from === 0) ?? null,
    nightBottom: segments.find((s) => s.night && s.to === 1440) ?? null,
  };
}

/** Snap a minute to the nearest 15 for click-and-drag creation. */
export function snap(minutes: number, step = 15): number {
  return Math.round(minutes / step) * step;
}
