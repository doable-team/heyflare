import { Link, useLocation } from "react-router-dom";
import { CalendarDays, Inbox, Menu, Rss, Shield } from "lucide-react";
import { cn } from "@/lib/utils";
import { useAccount } from "../context/AccountContext";
import { useCounts } from "../api";

/**
 * Five slots, and no more: a sixth would put every label under 54px on a small phone. Calendar
 * takes the slot Paper Trail had — the Paper Trail is an archive you go looking for, the calendar
 * is a surface you glance at daily — and Paper Trail moves to More, one tap away.
 */
const TABS = [
  { to: "/", label: "Imbox", icon: Inbox, end: true },
  { to: "/feed", label: "Feed", icon: Rss },
  { to: "/calendar", label: "Calendar", icon: CalendarDays },
  { to: "/screener", label: "Screener", icon: Shield },
  { to: "/more", label: "More", icon: Menu },
];

export const TAB_BAR_H = 56;

export function TabBar() {
  const loc = useLocation();
  const { accounts } = useAccount();
  const counts = useCounts(accounts.length > 0);
  const c = counts.data;
  const topLevel = TABS.map((t) => t.to);
  const activeTo = (() => {
    if (loc.pathname === "/") return "/";
    const hit = topLevel.find((p) => p !== "/" && loc.pathname.startsWith(p));
    return hit ?? "/more";
  })();
  const dots: Record<string, number | undefined> = { "/": c?.imbox_new, "/screener": c?.screener };
  return (
    <nav className="fixed inset-x-0 bottom-0 z-40 bg-background/95 backdrop-blur border-t border-border pb-safe" aria-label="Primary">
      <div className="grid grid-cols-5" style={{ height: TAB_BAR_H }}>
        {TABS.map((t) => {
          const active = activeTo === t.to;
          const Icon = t.icon;
          const n = dots[t.to];
          return (
            <Link key={t.to} to={t.to} className={cn("relative flex flex-col items-center justify-center gap-1 select-none", active ? "text-foreground" : "text-muted-foreground")} aria-current={active ? "page" : undefined}>
              <span className="relative">
                <Icon size={22} strokeWidth={active ? 2.2 : 1.8} />
                {!!n && <span className={cn("absolute -top-0.5 -right-1 size-2 rounded-full ring-2 ring-background", t.to === "/screener" ? "bg-foreground" : "bg-foreground/70")} />}
              </span>
              <span className={cn("text-[10px] leading-none", active ? "font-semibold" : "font-medium")}>{t.label}</span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
