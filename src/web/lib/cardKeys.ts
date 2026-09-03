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

/**
 * Arrow keys on card layouts (The Feed, a bundle) scroll the page smoothly instead of hopping
 * between cards — these are made for reading, not triage.
 */
export function useCardScroll(enabled = true) {
  const region = useFocusRegion();

  const by = (delta: number) => {
    if (overlayOpen()) return;
    const s = scroller();
    const step = Math.round((s instanceof Window ? window.innerHeight : s.clientHeight) * delta);
    s.scrollBy({ top: step, behavior: "smooth" });
  };

  useKeys(
    {
      ArrowDown: () => by(0.25),
      ArrowUp: () => by(-0.25),
      j: () => by(0.25),
      k: () => by(-0.25),
      PageDown: () => by(0.9),
      PageUp: () => by(-0.9),
      " ": () => by(0.9),
    },
    enabled && region === "content",
  );
}
