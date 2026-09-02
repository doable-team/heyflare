import { useEffect, useRef } from "react";

export function isTyping(e: KeyboardEvent): boolean {
  const t = e.target as HTMLElement | null;
  if (!t) return false;
  if (t.isContentEditable) return true;
  const tag = t.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
}

export type KeyMap = Record<string, (e: KeyboardEvent) => void>;

/** Global keyboard shortcuts. Ignored while typing in inputs or with modifiers. */
export function useKeys(map: KeyMap, enabled = true) {
  const ref = useRef(map);
  ref.current = map;
  useEffect(() => {
    if (!enabled) return;
    const fn = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (isTyping(e) && e.key !== "Escape") return;
      const h = ref.current[e.key];
      if (h) {
        e.preventDefault();
        h(e);
      }
    };
    window.addEventListener("keydown", fn);
    return () => window.removeEventListener("keydown", fn);
  }, [enabled]);
}
