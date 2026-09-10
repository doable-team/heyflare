import { CalendarDays, ChevronLeft, ChevronRight, Eye, EyeOff, Plus, RefreshCw, Settings2 } from "lucide-react";
import { useNavigate } from "react-router-dom";
import type { CalendarView } from "@shared/types";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { useCalendar } from "./CalendarContext";
import { useCalendarSourceMutations } from "../api";
import { addDays, addMonths, keyToDate, monthLabel, msAt, weekDays } from "../lib/caldate";

const VIEWS: { id: CalendarView; label: string; key: string }[] = [
  { id: "days", label: "Day", key: "d" },
  { id: "week", label: "Week", key: "w" },
  { id: "month", label: "Month", key: "m" },
  { id: "year", label: "Year", key: "y" },
];

/** Step size for ‹ › in each view. */
export function step(view: CalendarView, date: string, delta: number): string {
  if (view === "week") return addDays(date, delta * 7);
  if (view === "month") return addMonths(date, delta);
  if (view === "year") return addMonths(date, delta * 12);
  return addDays(date, delta);
}

/** The month and year of what is on screen: the week's Thursday names the week. */
export function periodTitle(view: CalendarView, cursor: string, weekStart: number): string {
  if (view === "year") return cursor.slice(0, 4);
  if (view === "week") return monthLabel(weekDays(cursor, weekStart).find((d) => keyToDate(d).getDay() === 4) ?? cursor);
  return monthLabel(cursor);
}

export function CalendarToolbar() {
  const { view, setView, cursor, today, settings, calendars, createEvent, loading, reveal } = useCalendar();
  const { update, syncAll } = useCalendarSourceMutations();
  const nav = useNavigate();
  const syncing = calendars.some((c) => c.sync_status === "syncing");
  const broken = calendars.filter((c) => c.sync_status === "error");

  return (
    <div className="flex h-11 shrink-0 items-center gap-2 border-b border-border">
      <div className="flex items-center">
        <Button variant="ghost" size="icon-sm" onClick={() => reveal(step(view, cursor, -1))} aria-label="Previous">
          <ChevronLeft />
        </Button>
        <Button variant="ghost" size="icon-sm" onClick={() => reveal(step(view, cursor, 1))} aria-label="Next">
          <ChevronRight />
        </Button>
      </div>
      {/* `reveal`, not `setCursor`: Today has to bring you back even when the cursor already sits on it. */}
      <Button variant="ghost" size="sm" onClick={() => reveal(today)}>
        Today
      </Button>
      <h1 className="text-[15px] font-semibold text-foreground tnum">{periodTitle(view, cursor, settings.week_start)}</h1>

      <span className="flex-1" />

      <div className="flex items-center rounded-[6px] bg-muted p-0.5">
        {VIEWS.map((v) => (
          <button
            key={v.id}
            type="button"
            onClick={() => setView(v.id)}
            title={`${v.label}  ${v.key}`}
            className={cn("h-7 rounded-[4px] px-3 text-[13px] transition-colors", view === v.id ? "bg-background text-foreground shadow-sm" : "text-muted-foreground")}
          >
            {v.label}
          </button>
        ))}
      </div>

      <Popover>
        <PopoverTrigger asChild>
          <Button variant="ghost" size="icon-sm" aria-label="Calendars">
            <CalendarDays />
          </Button>
        </PopoverTrigger>
        <PopoverContent align="end" className="w-72 p-1.5">
          <div className="px-1.5 pb-1 text-xs text-muted-foreground">Calendars</div>
          {calendars.length === 0 && <div className="px-1.5 py-2 text-xs text-muted-foreground">Nothing connected yet.</div>}
          {calendars.map((c) => (
            <button
              key={c.id}
              type="button"
              onClick={() => update.mutate({ id: c.id, visible: !c.visible })}
              className="flex w-full items-center gap-2 rounded-md px-1.5 py-1 text-left text-sm hover:bg-accent"
            >
              <span className="size-2 shrink-0 rounded-full" style={{ background: c.color }} />
              <span className={cn("min-w-0 flex-1 truncate", !c.visible && "text-muted-foreground")}>{c.name}</span>
              {c.sync_status === "error" && <span className="shrink-0 text-[10px] text-muted-foreground">error</span>}
              {c.visible ? <Eye size={13} className="shrink-0 text-tertiary" /> : <EyeOff size={13} className="shrink-0 text-tertiary" />}
            </button>
          ))}
          <div className="mt-1 flex items-center gap-1 border-t border-border pt-1">
            <Button variant="ghost" size="sm" className="h-7 flex-1 justify-start text-xs" onClick={() => syncAll.mutate()} disabled={syncAll.isPending}>
              <RefreshCw className={cn(syncAll.isPending && "animate-spin")} />
              Refresh all
            </Button>
            <Button variant="ghost" size="sm" className="h-7 flex-1 justify-start text-xs" onClick={() => nav("/settings#calendar")}>
              <Settings2 />
              Manage
            </Button>
          </div>
          {broken.length > 0 && <p className="px-1.5 pt-1 text-[11px] text-muted-foreground">{broken[0].sync_error}</p>}
        </PopoverContent>
      </Popover>

      <Button className="h-8 px-3 text-[13px]" onClick={() => createEvent({ starts_at: msAt(cursor, nextHalfHour()), ends_at: msAt(cursor, nextHalfHour() + 60) })}>
        <Plus />
        New
      </Button>
      {(loading || syncing) && <span className="size-3 animate-spin rounded-full border-2 border-muted-foreground/30 border-t-foreground" aria-label="Syncing" />}
    </div>
  );
}

function nextHalfHour(): number {
  const d = new Date();
  return (d.getHours() * 60 + (d.getMinutes() < 30 ? 30 : 60)) % 1440;
}
