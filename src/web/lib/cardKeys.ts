import { useKeys } from "./keys";
import { overlayOpen, useFocusRegion } from "./focusStore";

/** The element that actually scrolls the page content (shadcn's SidebarInset, or the window). */
function scroller(): HTMLElement | Window {
  const main = document.querySelector("main");
  let el: HTMLElement | null = main;
  while (el) {
    const style = getComputedStyle(el);
    if (/(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight + 4) return el;
    el = el.parentElement;
  }
  return window;
}

/** Scroll the page by a fraction of a screen — used when a cursor has nowhere left to go. */
export function scrollPageBy(delta: number) {
  const s = scroller();
  const step = Math.round((s instanceof Window ? window.innerHeight : s.clientHeight) * delta);
  s.scrollBy({ top: step, behavior: "smooth" });
}

/**
 * Arrow keys on card layouts (The Feed, a bundle) scroll the page smoothly instead of hopping
 * between cards — these are made for reading, not triage.
 *
 * `arrows: false` keeps only the big jumps (Page Up/Down, Space) for pages that give the arrows
 * to a cursor of their own, like the message cursor inside a thread.
 */
export function useCardScroll(enabled = true, opts: { arrows?: boolean } = {}) {
  const region = useFocusRegion();
  const arrows = opts.arrows ?? true;

  const by = (delta: number) => {
    if (overlayOpen()) return;
    scrollPageBy(delta);
  };

  useKeys(
    {
      ...(arrows
        ? {
            ArrowDown: () => by(0.25),
            ArrowUp: () => by(-0.25),
            j: () => by(0.25),
            k: () => by(-0.25),
          }
        : {}),
      PageDown: () => by(0.9),
      PageUp: () => by(-0.9),
      " ": () => by(0.9),
    },
    enabled && region === "content",
  );
}
