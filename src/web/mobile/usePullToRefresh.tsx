import { useRef, useState } from "react";
import { Loader2 } from "lucide-react";
import { cn } from "@/lib/utils";

const TRIGGER = 64;

/** Touch-driven pull-to-refresh for window-scrolled screens. */
export function usePullToRefresh(onRefresh: () => Promise<unknown> | unknown, enabled = true) {
  const [pull, setPull] = useState(0);
  const [refreshing, setRefreshing] = useState(false);
  const start = useRef<number | null>(null);
  const pullRef = useRef(0);
  const set = (v: number) => {
    pullRef.current = v;
    setPull(v);
  };
  const handlers = {
    onTouchStart: (e: React.TouchEvent) => {
      if (!enabled || refreshing) return;
      start.current = window.scrollY <= 0 ? e.touches[0].clientY : null;
    },
    onTouchMove: (e: React.TouchEvent) => {
      if (start.current == null) return;
      const dy = e.touches[0].clientY - start.current;
      if (dy > 0 && window.scrollY <= 0) set(Math.min(110, dy * 0.45));
      else set(0);
    },
    onTouchEnd: async () => {
      if (start.current == null) return;
      start.current = null;
      if (pullRef.current >= TRIGGER) {
        setRefreshing(true);
        set(44);
        try {
          await onRefresh();
        } finally {
          setRefreshing(false);
          set(0);
        }
      } else set(0);
    },
  };
  const indicator =
    pull > 0 || refreshing ? (
      <div style={{ height: pull }} className="flex items-end justify-center overflow-hidden transition-[height] duration-150">
        <Loader2 className={cn("size-4 mb-3 text-muted-foreground", (refreshing || pull >= TRIGGER) && "animate-spin")} style={{ opacity: Math.min(1, pull / TRIGGER) }} />
      </div>
    ) : null;
  return { handlers, indicator, refreshing };
}
