import { Link } from "react-router-dom";
import { Check, ChevronRight, Video } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { useCalendarRange, useCalendarSettings, useHabitMutations } from "../api";
import { openExternalUrl } from "../lib/native";
import { addDays, countdownLabel, fmtTime, relativeDay, todayKey, weekdayLabel } from "../lib/caldate";

/**
 * HEY's "cover art": the next three days sitting at the top of the Imbox, so checking the day and
 * checking the mail are the same glance. Off by default; turned on in Settings → Calendar.
 */
export function CalendarCover() {
  const settings = useCalendarSettings();
  const on = settings.data?.cover_art ?? false;
  const today = todayKey();
  const range = useCalendarRange(today, addDays(today, 2), on);
  const { toggle } = useHabitMutations();
  if (!on) return null;

  const days = [today, addDays(today, 1), addDays(today, 2)];
  const fmt = settings.data?.time_format ?? "12";
  const habits = (range.data?.habits ?? []).filter((h) => !h.archived);
  const empty = (range.data?.events ?? []).length === 0;

  return (
    <section className="mb-5 rounded-md border border-border">
      <header className="flex items-center gap-2 border-b border-border px-3 py-1.5">
        <span className="text-[11px] uppercase tracking-wide text-tertiary">Next three days</span>
        <span className="flex-1" />
        <Link to="/calendar" className="inline-flex items-center gap-0.5 text-[11px] text-muted-foreground hover:text-foreground">
          Calendar <ChevronRight size={12} />
        </Link>
      </header>

      {habits.length > 0 && (
        <div className="flex flex-wrap items-center gap-1 border-b border-border px-3 py-1.5">
          {habits.map((h) => {
            const done = h.completions?.includes(today);
            return (
              <button
                key={h.id}
                type="button"
                onClick={() => toggle.mutate({ id: h.id, date: today })}
                aria-pressed={done}
                className={cn(
                  "inline-flex items-center gap-1 rounded-full border px-1.5 py-0.5 text-[11px] transition-colors",
                  done ? "border-transparent text-background" : "border-border text-muted-foreground hover:border-foreground/30",
                )}
                style={done ? { background: h.color || "currentColor" } : undefined}
              >
                {h.icon || <Check size={9} />}
                {h.name}
              </button>
            );
          })}
        </div>
      )}

      <div className="grid gap-px bg-border sm:grid-cols-3">
        {days.map((d) => {
          const list = (range.data?.events ?? [])
            .filter((e) => onDay(e, d))
            .sort((a, b) => Number(b.all_day) - Number(a.all_day) || a.starts_at - b.starts_at)
            .slice(0, 4);
          return (
            <div key={d} className="min-h-20 bg-background px-3 py-2">
              <Link to={`/calendar?d=${d}`} className="text-[11px] text-muted-foreground hover:text-foreground">
                {relativeDay(d) || weekdayLabel(d)}
              </Link>
              <div className="mt-1 space-y-1">
                {list.length === 0 && <div className="text-[11.5px] text-tertiary">Nothing scheduled.</div>}
                {list.map((e) => (
                  <EventLine key={e.id} e={e} format={fmt} date={d} />
                ))}
              </div>
            </div>
          );
        })}
      </div>

      {empty && <p className="px-3 py-2 text-[11.5px] text-tertiary">Connect a calendar in Settings to fill this in.</p>}
    </section>
  );
}

function EventLine({ e, format, date }: { e: CalEvent; format: "12" | "24"; date: string }) {
  const soon = !e.all_day && e.conference_url && e.starts_at - Date.now() < 15 * 60_000 && e.ends_at > Date.now();
  return (
    <div className="flex items-baseline gap-1.5 text-[11.5px]">
      <span className="w-12 shrink-0 tnum text-tertiary">{e.all_day ? "All day" : fmtTime(e.starts_at, format)}</span>
      <span className="min-w-0 flex-1 truncate">{e.title || "(no title)"}</span>
      {e.countdown && <span className="shrink-0 text-[10.5px] text-tertiary">{countdownLabel(e.start_date ?? date)}</span>}
      {soon && (
        <Button size="xs" variant="ghost" className="h-4 shrink-0 px-1 text-[10.5px]" onClick={() => openExternalUrl(e.conference_url)}>
          <Video /> Join
        </Button>
      )}
    </div>
  );
}

function onDay(e: CalEvent, date: string): boolean {
  if (e.all_day) return (e.start_date ?? "") <= date && date <= (e.end_date ?? e.start_date ?? "");
  const d = new Date(e.starts_at);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}` === date;
}
