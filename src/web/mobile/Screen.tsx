import { useEffect, useRef, useState, type ReactNode } from "react";
import { useLocation, useNavigate, useNavigationType } from "react-router-dom";
import { ChevronLeft, PenSquare } from "lucide-react";
import { cn } from "@/lib/utils";
import { useCompose } from "../context/ComposeContext";
import { TabBar, TAB_BAR_H } from "./TabBar";

export function Fab({ bottom }: { bottom?: number }) {
  const { openCompose } = useCompose();
  return (
    <button
      type="button"
      onClick={() => openCompose()}
      aria-label="New message"
      className="fixed right-4 z-40 size-12 rounded-full bg-foreground text-background shadow-md flex items-center justify-center active:scale-95 transition-transform"
      style={{ bottom: `calc(${bottom ?? TAB_BAR_H + 16}px + env(safe-area-inset-bottom))` }}
    >
      <PenSquare size={20} />
    </button>
  );
}

/**
 * A mobile screen: fixed top bar (with a large title that collapses on scroll),
 * push/pop slide, edge-swipe back, optional tab bar + compose FAB.
 */
export function Screen({
  title,
  largeTitle,
  subtitle,
  back,
  backLabel,
  left,
  right,
  titleRight,
  tabs = true,
  fab = false,
  fabBottom,
  children,
  className,
  onTitleTap,
  below,
  bottomInset,
  titleOnScroll,
}: {
  title: ReactNode;
  largeTitle?: boolean;
  subtitle?: ReactNode;
  back?: boolean | string;
  backLabel?: ReactNode;
  left?: ReactNode;
  right?: ReactNode;
  /** Rendered to the right of the large title (e.g. a search button). */
  titleRight?: ReactNode;
  tabs?: boolean;
  fab?: boolean;
  fabBottom?: number;
  children: ReactNode;
  className?: string;
  onTitleTap?: () => void;
  /** Rendered under the top bar row, inside the fixed header (e.g. a search field). */
  below?: ReactNode;
  /** Extra bottom padding in px (e.g. for a docked action bar). */
  bottomInset?: number;
  /** Keep the bar title hidden until the page scrolls (the content has its own heading). */
  titleOnScroll?: boolean;
}) {
  const nav = useNavigate();
  const loc = useLocation();
  const navType = useNavigationType();
  const [scrolled, setScrolled] = useState(false);
  const [anim] = useState(() => (back ? (navType === "POP" ? "animate-in fade-in slide-in-from-left-4 duration-150" : "animate-in fade-in slide-in-from-right-8 duration-200") : "animate-in fade-in duration-100"));
  const [edge, setEdge] = useState(0);
  const edgeStart = useRef<number | null>(null);
  const goBack = () => (typeof back === "string" ? nav(back) : nav(-1));

  useEffect(() => {
    if (navType === "PUSH") window.scrollTo(0, 0);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loc.key]);

  useEffect(() => {
    if (!largeTitle && !titleOnScroll) return;
    const fn = () => setScrolled(window.scrollY > 36);
    fn();
    window.addEventListener("scroll", fn, { passive: true });
    return () => window.removeEventListener("scroll", fn);
  }, [largeTitle, titleOnScroll]);

  const bottomPad = (tabs ? TAB_BAR_H : 0) + (bottomInset ?? 0) + 16;

  return (
    <div
      className={cn("min-h-dvh flex flex-col bg-background", anim, className)}
      style={edge ? { transform: `translateX(${edge}px)`, transition: "none" } : undefined}
      onPointerDown={(e) => {
        if (back && e.clientX < 22 && e.pointerType !== "mouse") edgeStart.current = e.clientX;
      }}
      onPointerMove={(e) => {
        if (edgeStart.current == null) return;
        setEdge(Math.max(0, Math.min(140, e.clientX - edgeStart.current)));
      }}
      onPointerUp={() => {
        if (edgeStart.current == null) return;
        const v = edge;
        edgeStart.current = null;
        setEdge(0);
        if (v > 70) goBack();
      }}
      onPointerCancel={() => {
        edgeStart.current = null;
        setEdge(0);
      }}
    >
      <header className="fixed top-0 inset-x-0 z-40 bg-background/92 backdrop-blur pt-safe">
        <div className="h-11 flex items-center px-1">
          <div className="min-w-11 flex items-center">
            {back ? (
              <button type="button" onClick={goBack} className="h-11 pl-1 pr-2 flex items-center gap-0.5 text-[15px] text-foreground active:opacity-60" aria-label="Back">
                <ChevronLeft size={24} />
                {backLabel && <span className="truncate max-w-24">{backLabel}</span>}
              </button>
            ) : (
              left
            )}
          </div>
          <div className={cn("flex-1 min-w-0 text-center text-[17px] font-semibold truncate transition-opacity duration-150", (largeTitle || titleOnScroll) && !scrolled ? "opacity-0" : "opacity-100")}>{title}</div>
          <div className="min-w-11 flex items-center justify-end pr-1">{right}</div>
        </div>
        {below}
      </header>

      <main className="flex-1 flex flex-col" style={{ paddingTop: `calc(44px + env(safe-area-inset-top))`, paddingBottom: `calc(${bottomPad}px + env(safe-area-inset-bottom))` }}>
        {largeTitle && (
          <div className="px-4 pt-2 pb-2 flex items-start justify-between gap-3">
            <div className="min-w-0">
              <h1 onClick={onTitleTap} className={cn("text-[28px] leading-8 font-bold tracking-[-0.02em] text-foreground", onTitleTap && "active:opacity-60 inline-flex items-center gap-1")}>
                {title}
              </h1>
              {subtitle && <div className="text-[13px] text-muted-foreground mt-0.5">{subtitle}</div>}
            </div>
            {titleRight && <div className="shrink-0 -mr-2 -mt-1 flex items-center">{titleRight}</div>}
          </div>
        )}
        {children}
      </main>

      {tabs && <TabBar />}
      {fab && <Fab bottom={fabBottom} />}
    </div>
  );
}
