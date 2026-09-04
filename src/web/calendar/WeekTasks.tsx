import { useState } from "react";
import { Check, Plus, X } from "lucide-react";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { useFlexTaskMutations, useFlexTasks } from "../api";
import { weekStartOf } from "../lib/caldate";

/**
 * "Sometime this week" — the things that have to happen but not at any particular hour. Anything
 * still unticked when the week turns rolls forward, so the list is a standing promise rather than
 * another place to declare bankruptcy.
 *
 * The week view stacks many weeks on top of one another and gives every row its own strip, so the
 * week is a prop; left off, it falls back to the week the cursor is in, which is what a single
 * global bar wants.
 */
export function WeekTasks({ weekStart }: { weekStart?: string } = {}) {
  const { cursor, settings } = useCalendar();
  const week = weekStart ?? weekStartOf(cursor, settings.week_start);
  const tasks = useFlexTasks(week);
  const { create, update, remove } = useFlexTaskMutations();
  const [draft, setDraft] = useState("");
  const [adding, setAdding] = useState(false);

  const items = tasks.data ?? [];
  const submit = () => {
    const title = draft.trim();
    if (title) create.mutate({ week_start: week, title });
    setDraft("");
    setAdding(false);
  };

  return (
    <div className="flex h-full min-w-0 items-center gap-1.5 overflow-x-auto overflow-y-hidden px-1">
      <span className="shrink-0 text-[10.5px] uppercase leading-none tracking-[0.11em] text-tertiary">Sometime this week:</span>
      {items.map((t) => (
        <span
          key={t.id}
          className={cn(
            "group/t inline-flex shrink-0 items-center gap-1 rounded-full border border-border py-[2px] pl-[3px] pr-1.5 text-[11px] leading-none",
            t.done && "text-muted-foreground line-through",
          )}
        >
          {/* A round box, ticked — the same checkbox the todos wear everywhere else. */}
          <button
            type="button"
            onClick={() => update.mutate({ id: t.id, done: !t.done })}
            aria-label={t.done ? "Not done" : "Done"}
            className={cn(
              "inline-flex size-[13px] shrink-0 items-center justify-center rounded-full border transition-colors",
              t.done ? "border-foreground bg-foreground text-background" : "border-border text-transparent hover:border-foreground/50",
            )}
          >
            <Check size={9} strokeWidth={3} />
          </button>
          <span className="max-w-48 truncate">{t.title}</span>
          <button
            type="button"
            onClick={() => remove.mutate(t.id)}
            className="text-transparent group-hover/t:text-tertiary hover:!text-foreground"
            aria-label="Remove"
          >
            <X size={10} />
          </button>
        </span>
      ))}
      {adding ? (
        <input
          autoFocus
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={submit}
          onKeyDown={(e) => {
            if (e.key === "Enter") submit();
            if (e.key === "Escape") {
              setDraft("");
              setAdding(false);
            }
          }}
          placeholder="Oil change, call the bank…"
          className="h-5 w-52 shrink-0 rounded-full border border-border bg-transparent px-2 text-[11px] outline-none placeholder:text-tertiary focus:border-foreground/30"
        />
      ) : (
        <button
          type="button"
          onClick={() => setAdding(true)}
          className="inline-flex size-[17px] shrink-0 items-center justify-center rounded-full border border-dashed border-border text-tertiary hover:border-foreground/30 hover:text-foreground"
          aria-label="Add something for this week"
        >
          <Plus size={10} />
        </button>
      )}
    </div>
  );
}
