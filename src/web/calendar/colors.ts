/**
 * A calendar's colour is the one place colour enters this otherwise monochrome UI. Events wear it
 * the way Apple Calendar draws them: a translucent wash of the colour, a solid bar of it down the
 * left edge, and the title in the colour itself — pulled toward black on a light ground and toward
 * white on a dark one so it always reads.
 */
import { useSyncExternalStore } from "react";

/** What a calendar gets when it has no colour of its own. */
export const DEFAULT_COLOR = "#6b6b6b";

export function normalizeHex(hex: string | null | undefined): string | null {
  if (!hex) return null;
  const v = hex.trim();
  if (/^#[0-9a-fA-F]{6}$/.test(v)) return v.toLowerCase();
  if (/^#[0-9a-fA-F]{3}$/.test(v)) return `#${v[1]}${v[1]}${v[2]}${v[2]}${v[3]}${v[3]}`.toLowerCase();
  return null;
}

function rgb(hex: string | null | undefined): [number, number, number] {
  const h = normalizeHex(hex) ?? DEFAULT_COLOR;
  return [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
}

function toHex(r: number, g: number, b: number): string {
  return `#${[r, g, b].map((c) => Math.round(Math.max(0, Math.min(255, c))).toString(16).padStart(2, "0")).join("")}`;
}

/** The colour at 22% alpha — the block and pill background. */
export function eventFill(hex: string | null | undefined, alpha = 0.22): string {
  const [r, g, b] = rgb(hex);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

/** The colour itself — the bar down the left edge, the dot in the month grid. */
export function eventBar(hex: string | null | undefined): string {
  return normalizeHex(hex) ?? DEFAULT_COLOR;
}

/** The colour mixed 25% toward white (dark mode) or toward black (light mode) — the text on a block. */
export function eventInk(hex: string | null | undefined, dark: boolean): string {
  const [r, g, b] = rgb(hex);
  const mix = (c: number) => (dark ? c + (255 - c) * 0.25 : c * 0.75);
  return toHex(mix(r), mix(g), mix(b));
}

/** Legacy solid fill with a contrasting text colour — still what the mobile views draw. */
export function eventColors(hex: string | null | undefined): { background: string; color: string } {
  const background = normalizeHex(hex) ?? "#1f1f1f";
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(background.slice(i, i + 2), 16) / 255);
  const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  const L = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  return { background, color: 1.05 / (L + 0.05) >= (L + 0.05) / 0.05 ? "#fbfbfa" : "#131313" };
}

// ---------- Dark mode ----------

/** The app's theme is the `dark` class on <html>; one observer serves every subscriber. */
const listeners = new Set<() => void>();
let observing = false;
function subscribe(l: () => void) {
  listeners.add(l);
  if (!observing && typeof MutationObserver !== "undefined") {
    observing = true;
    new MutationObserver(() => listeners.forEach((f) => f())).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
  }
  return () => {
    listeners.delete(l);
  };
}
function isDark() {
  return typeof document !== "undefined" && document.documentElement.classList.contains("dark");
}

/** True while the app is in dark mode. */
export function useDark(): boolean {
  return useSyncExternalStore(subscribe, isDark, () => false);
}
