import { useEffect, useState } from "react";
import { useKeys } from "./keys";
import { overlayOpen, useFocusRegion } from "./focusStore";

/**
 * Arrow-key cursor for card layouts (The Feed, a bundle). Same grammar as the mail list:
 * ↑/↓ (or k/j) walk the cards and scroll them into view, Enter/o opens the focused one.
 * Nothing is focused until the first keypress, so the page scrolls normally with the mouse.
 * Mark each card with `data-card-index={i}` for the scroll-into-view to find it.
 */
export function useCardCursor(count: number, opts: { onOpen?: (index: number) => void; enabled?: boolean } = {}) {
  const [cursor, setCursor] = useState(-1);
  const region = useFocusRegion();
  const enabled = (opts.enabled ?? true) && region === "content" && count > 0;

  useEffect(() => {
    setCursor((c) => (c >= count ? count - 1 : c));
  }, [count]);

  const move = (delta: number) => {
    if (overlayOpen()) return;
    setCursor((c) => Math.min(Math.max(c + delta, 0), count - 1));
  };
  const open = () => {
    if (overlayOpen() || cursor < 0) return;
    opts.onOpen?.(cursor);
  };

  useKeys(
    {
      ArrowDown: () => move(1),
      ArrowUp: () => move(-1),
      j: () => move(1),
      k: () => move(-1),
      Enter: open,
      o: open,
    },
    enabled,
  );

  useEffect(() => {
    if (cursor < 0) return;
    document.querySelector(`[data-card-index="${cursor}"]`)?.scrollIntoView({ block: "nearest" });
  }, [cursor]);

  return { cursor, setCursor };
}
