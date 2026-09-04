import { cn } from "@/lib/utils";

/**
 * The ink ring you draw round something on a paper calendar, which is where HEY got it: an
 * imperfect ellipse that overshoots itself, drawn over and *beyond* the event's edges rather than
 * neatly inside them. That overshoot is the whole effect — a tidy border would just look like a
 * selected row.
 *
 * Ink, not the calendar's colour: the same dark pen mark on every block, so a circle means the same
 * thing wherever it is. `currentColor` off the foreground token, so it flips with the theme.
 *
 * The viewBox is stretched to the block with `preserveAspectRatio="none"`, so the ring follows a
 * tall box or a wide one; `vectorEffect` keeps the stroke an even weight despite that stretch.
 */
const LOOP =
  "M 52 7 C 22 7, 6 27, 6 51 C 6 75, 24 96, 52 95 C 79 94, 96 73, 95 49 " +
  "C 94 27, 75 6, 46 7 C 28 7.5, 12 19, 8 39";

/** How far the ring oversteps the block on every side. */
const OVERSHOOT = 7;

export function InkCircle({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 100 100"
      preserveAspectRatio="none"
      aria-hidden
      // Sized explicitly: an <svg> with a viewBox and auto height takes its aspect ratio from the
      // viewBox, so `inset` alone leaves it square and it swallows the events either side.
      style={{
        left: -OVERSHOOT,
        top: -OVERSHOOT,
        width: `calc(100% + ${OVERSHOOT * 2}px)`,
        height: `calc(100% + ${OVERSHOOT * 2}px)`,
      }}
      className={cn("pointer-events-none absolute z-30 overflow-visible text-foreground/75", className)}
    >
      <path d={LOOP} fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}
