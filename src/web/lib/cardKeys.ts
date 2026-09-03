import { useEffect, useState } from "react";
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

/**
 * Arrow-key cursor for pages that are lists of things rather than something to read: Set Aside,
 * Drafts, Clips, Files… ↑/↓ (or j/k) walk the items, Enter/o opens the focused one. Nothing is
 * focused until the first press, and an empty page falls back to scrolling so the keys never feel dead.
 *
 * Mark each item with `data-item-index={i}` (and `scroll-mt-20`, so the sticky header doesn't clip it).
 */
export function useItemCursor({ count, onOpen, enabled = true }: { count: number; onOpen?: (index: number) => void; enabled?: boolean }) {
  const [cursor, setCursor] = useState(-1);
  const region = useFocusRegion();

  // Keep the cursor inside the list when items disappear (a draft sent, a thread put back).
  useEffect(() => {
    setCursor((c) => (c >= count ? count - 1 : c));
  }, [count]);

  useEffect(() => {
    if (cursor < 0) return;
    document.querySelector(`[data-item-index="${cursor}"]`)?.scrollIntoView({ block: "nearest" });
  }, [cursor]);

  const step = (delta: number) => {
    if (overlayOpen()) return;
    if (count === 0) {
      scrollPageBy(delta * 0.25);
      return;
    }
    setCursor((c) => Math.min(Math.max(c + delta, 0), count - 1));
  };
  const open = () => {
    if (overlayOpen() || cursor < 0) return;
    onOpen?.(cursor);
  };

  useKeys(
    {
      ArrowDown: () => step(1),
      ArrowUp: () => step(-1),
      j: () => step(1),
      k: () => step(-1),
      Enter: open,
      o: open,
      PageDown: () => !overlayOpen() && scrollPageBy(0.9),
      PageUp: () => !overlayOpen() && scrollPageBy(-0.9),
    },
    enabled && region === "content",
  );

  return { cursor, setCursor };
}
