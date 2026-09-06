import { useCallback, useRef, useState } from "react";

/**
 * Horizontal swipe with a vertical-intent guard (so it never fights scrolling),
 * plus optional long-press. Attach the returned handlers to the swiped element,
 * which must have `touch-action: pan-y`.
 */
export function useSwipe({
  onLeft,
  onRight,
  threshold = 96,
  disabled,
  onLongPress,
  longPressMs = 450,
  keepsLeft,
  keepsRight,
}: {
  onLeft?: () => void;
  onRight?: () => void;
  threshold?: number;
  disabled?: boolean;
  onLongPress?: () => void;
  longPressMs?: number;
  /**
   * True when the action leaves the row in the list — ticking a box, turning read state
   * over. Such a row settles straight back instead of flying off the screen, because
   * nothing is going to remove it from under the finger.
   */
  keepsLeft?: boolean;
  keepsRight?: boolean;
}) {
  const [dx, setDx] = useState(0);
  const [dragging, setDragging] = useState(false);
  const dxRef = useRef(0);
  const st = useRef<{ x: number; y: number; axis: "none" | "h" | "v"; moved: boolean } | null>(null);
  const lp = useRef<number | null>(null);
  const suppress = useRef(false);

  const clearLp = () => {
    if (lp.current) {
      clearTimeout(lp.current);
      lp.current = null;
    }
  };
  const set = (v: number) => {
    dxRef.current = v;
    setDx(v);
  };

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      if (disabled) return;
      if (e.pointerType === "mouse" && e.button !== 0) return;
      st.current = { x: e.clientX, y: e.clientY, axis: "none", moved: false };
      suppress.current = false;
      clearLp();
      if (onLongPress) {
        lp.current = window.setTimeout(() => {
          const s = st.current;
          if (s && !s.moved) {
            suppress.current = true;
            st.current = null;
            try {
              navigator.vibrate?.(8);
            } catch {}
            onLongPress();
          }
        }, longPressMs);
      }
    },
    [disabled, onLongPress, longPressMs],
  );

  const onPointerMove = useCallback(
    (e: React.PointerEvent) => {
      const s = st.current;
      if (!s) return;
      const dX = e.clientX - s.x;
      const dY = e.clientY - s.y;
      if (s.axis === "none") {
        if (Math.abs(dX) < 6 && Math.abs(dY) < 6) return;
        s.moved = true;
        clearLp();
        s.axis = Math.abs(dX) > Math.abs(dY) * 1.2 ? "h" : "v";
        if (s.axis === "h") {
          try {
            (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
          } catch {}
          setDragging(true);
        }
      }
      if (s.axis !== "h") return;
      const limit = threshold * 1.8;
      let v = Math.max(-limit, Math.min(limit, dX));
      if ((v > 0 && !onRight) || (v < 0 && !onLeft)) v *= 0.2;
      set(v);
    },
    [threshold, onLeft, onRight],
  );

  const finish = useCallback(
    (cancelled: boolean) => {
      const s = st.current;
      clearLp();
      st.current = null;
      if (!s) return;
      if (s.axis !== "h") {
        if (s.moved) suppress.current = true;
        return;
      }
      suppress.current = true;
      setDragging(false);
      const v = dxRef.current;
      const buzz = () => {
        try {
          navigator.vibrate?.(6);
        } catch {}
      };
      if (!cancelled && v >= threshold && onRight) {
        buzz();
        if (keepsRight) set(0);
        else {
          set(window.innerWidth);
          window.setTimeout(() => set(0), 260);
        }
        onRight();
      } else if (!cancelled && v <= -threshold && onLeft) {
        buzz();
        if (keepsLeft) set(0);
        else {
          set(-window.innerWidth);
          window.setTimeout(() => set(0), 260);
        }
        onLeft();
      } else set(0);
    },
    [threshold, onLeft, onRight, keepsLeft, keepsRight],
  );

  const handlers = {
    onPointerDown,
    onPointerMove,
    onPointerUp: () => finish(false),
    onPointerCancel: () => finish(true),
    onContextMenu: (e: React.MouseEvent) => {
      if (onLongPress) e.preventDefault();
    },
  };

  /** True (once) if the last gesture should swallow the click. */
  const consumeClick = () => {
    const v = suppress.current;
    suppress.current = false;
    return v;
  };

  return { dx, dragging, handlers, consumeClick, past: Math.abs(dx) >= threshold };
}
