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
 */
export function WeekTasks() {
  const { cursor, settings } = useCalendar();
  const week = weekStartOf(cursor, settings.week_start);
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
    <div className="mb-1.5 flex items-center gap-1.5 overflow-x-auto pb-0.5">
      <span className="shrink-0 text-[10.5px] uppercase tracking-wide text-tertiary">Sometime this week</span>
      {items.map((t) => (
        <span
          key={t.id}
          className={cn(
            "group/t inline-flex shrink-0 items-center gap-1 rounded-full border border-border py-0.5 pl-1.5 pr-1 text-[11px]",
            t.done && "text-muted-foreground line-through",
          )}
        >
          <button type="button" onClick={() => update.mutate({ id: t.id, done: !t.done })} className="text-tertiary hover:text-foreground" aria-label={t.done ? "Not done" : "Done"}>
            <Check size={10} className={cn(!t.done && "opacity-40")} />
          </button>
          <span className="max-w-48 truncate">{t.title}</span>
          <button type="button" onClick={() => remove.mutate(t.id)} className="text-transparent group-hover/t:text-tertiary hover:!text-foreground" aria-label="Remove">
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
        <button type="button" onClick={() => setAdding(true)} className="inline-flex shrink-0 items-center gap-0.5 rounded-full border border-dashed border-border px-1.5 py-0.5 text-[11px] text-tertiary hover:border-foreground/30 hover:text-foreground">
          <Plus size={10} />
          {items.length === 0 && "Add"}
        </button>
      )}
    </div>
  );
}
