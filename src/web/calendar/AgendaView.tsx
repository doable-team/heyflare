import { useMemo } from "react";
import { CalendarDays, MapPin, Repeat, Users, Video } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { EmptyState } from "../components/EmptyState";
import { useItemCursor } from "../lib/cardKeys";
import { addDays, countdownLabel, dateKey, fmtTimeRange, isToday, relativeDay, weekdayLabel } from "../lib/caldate";

/**
 * The flat "what's next" list: every day from the cursor forward that actually has something on it.
 *
 * Empty days are dropped rather than printed as "nothing" — a list of nothings is not information,
 * and the point of this view is that the next thing is always the next line.
 *
 * ↑/↓ walk the rows and Enter opens one. The calendar page has already claimed ←/→ for walking
 * days, so only the vertical cursor lives here.
 */
export function AgendaView() {
  const { settings, cursor, to, eventsOn, openEvent } = useCalendar();

  // One pass over the loaded window: days with something on them, each event carrying the flat
  // index the keyboard cursor addresses it by.
  const { groups, flat } = useMemo(() => {
    const groups: { date: string; items: { e: CalEvent; index: number }[] }[] = [];
    const flat: CalEvent[] = [];
    for (let d = cursor; d <= to; d = addDays(d, 1)) {
      const { allDay, timed } = eventsOn(d);
      if (allDay.length === 0 && timed.length === 0) continue;
      const ordered = [...allDay, ...[...timed].sort((a, b) => a.starts_at - b.starts_at || a.ends_at - b.ends_at)];
      groups.push({ date: d, items: ordered.map((e) => ({ e, index: flat.push(e) - 1 })) });
    }
    return { groups, flat };
  }, [cursor, to, eventsOn]);

  const { cursor: focused } = useItemCursor({
    count: flat.length,
    onOpen: (i) => flat[i] && openEvent(flat[i]),
  });

  return (
    <div className="min-h-0 flex-1 overflow-auto rounded-md border border-border bg-background px-1.5 pb-4">
      {groups.length === 0 ? (
        <EmptyState icon={<CalendarDays />} title="Nothing ahead." body="The next few months are clear. Press n to put something in them." />
      ) : (
        groups.map((g) => (
          <section key={g.date}>
            <h2
              className={cn(
                "sticky top-0 z-10 flex items-baseline gap-1.5 border-b border-border bg-background px-1 pb-1 pt-2.5 text-[11px]",
                isToday(g.date) ? "text-foreground" : "text-muted-foreground",
              )}
            >
              <span className="font-medium">{heading(g.date)}</span>
              <span className="tnum text-tertiary">{g.items.length}</span>
            </h2>
            <ul className="py-0.5">
              {g.items.map(({ e, index }) => (
                <li key={e.id} data-item-index={index} data-focused={focused === index || undefined} className="scroll-mt-20">
                  <Row e={e} format={settings.time_format} focused={focused === index} onOpen={() => openEvent(e)} />
                </li>
              ))}
            </ul>
          </section>
        ))
      )}
    </div>
  );
}

function Row({
  e,
  format,
  focused,
  onOpen,
}: {
  e: CalEvent;
  format: "12" | "24";
  focused: boolean;
  onOpen: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onOpen}
      className={cn(
        "flex w-full items-start gap-2 rounded-md px-1 py-1 text-left transition-colors hover:bg-accent",
        focused && "bg-muted",
        e.rsvp === "declined" && "opacity-45",
      )}
    >
      <span className="w-[104px] shrink-0 pt-px text-[11px] tnum leading-[17px] text-tertiary">
        {fmtTimeRange(e.starts_at, e.ends_at, e.all_day, format)}
      </span>
      <span className="min-w-0 flex-1 border-l-2 pl-2" style={{ borderLeftColor: accent(e) }}>
        <span className="flex items-center gap-1.5">
          {e.emoji && <span className="shrink-0 text-[12px] leading-[17px]">{e.emoji}</span>}
          <span className={cn("min-w-0 truncate text-[13px] leading-[17px]", e.done && "text-muted-foreground line-through")}>
            {e.title || "(no title)"}
          </span>
          {e.recurring && <Repeat size={10} className="shrink-0 text-tertiary" />}
          {e.status === "tentative" && <span className="shrink-0 text-[10px] text-tertiary">tentative</span>}
        </span>
        <span className="mt-px flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] leading-[15px] text-muted-foreground">
          {e.location && (
            <span className="flex min-w-0 items-center gap-1">
              <MapPin size={10} className="shrink-0 text-tertiary" />
              <span className="truncate">{e.location}</span>
            </span>
          )}
          {e.conference_url && (
            <span className="flex items-center gap-1">
              <Video size={10} className="shrink-0 text-tertiary" />
              Video
            </span>
          )}
          {e.attendees.length > 0 && (
            <span className="flex items-center gap-1 tnum">
              <Users size={10} className="shrink-0 text-tertiary" />
              {e.attendees.length}
            </span>
          )}
          {e.calendar_name && <span className="truncate text-tertiary">{e.calendar_name}</span>}
          {e.countdown && <span className="text-tertiary">{countdownLabel(e.start_date ?? dateKey(e.starts_at))}</span>}
        </span>
      </span>
    </button>
  );
}

/** "Today · Thursday 4 September" — the relative word only when there is one. */
function heading(date: string): string {
  const rel = relativeDay(date);
  const long = `${weekdayLabel(date)} ${Number(date.slice(8))} ${new Date(`${date}T00:00:00`).toLocaleString(undefined, { month: "long" })}`;
  return rel ? `${rel} · ${long}` : long;
}

/** A calendar's colour is data, not chrome: a hairline, never a wash. */
function accent(e: CalEvent): string {
  return e.calendar_color && /^#[0-9a-fA-F]{6}$/.test(e.calendar_color) ? e.calendar_color : "currentColor";
}
