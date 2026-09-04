import { useEffect, useMemo, useRef, useState } from "react";
import { Check, Flame, Plus, Trash2 } from "lucide-react";
import { toast } from "sonner";
import type { Habit } from "@shared/types";
import { cn } from "@/lib/utils";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { useHabitMutations, useHabits } from "../api";
import { EmptyState, ErrorState, SkeletonRows } from "../components/EmptyState";
import { useItemCursor } from "../lib/cardKeys";
import { addDays, keyToDate, longDayLabel, todayKey } from "../lib/caldate";
import { LABEL_SHADES } from "./Labels";

const WEEKS = 12;
const SPAN = WEEKS * 7;
const HEX = /^#[0-9a-fA-F]{6}$/;
/** 0 = Sunday, matching `Habit.days` and `Date#getDay`. */
const WEEKDAYS = [
  { d: 0, short: "S", long: "Sunday" },
  { d: 1, short: "M", long: "Monday" },
  { d: 2, short: "T", long: "Tuesday" },
  { d: 3, short: "W", long: "Wednesday" },
  { d: 4, short: "T", long: "Thursday" },
  { d: 5, short: "F", long: "Friday" },
  { d: 6, short: "S", long: "Saturday" },
];

/** An emoji can be several code points (skin tones, ZWJ sequences), so take one *grapheme*. */
function firstGlyph(s: string): string {
  const t = s.trim();
  if (!t) return "";
  const Seg = (Intl as unknown as { Segmenter?: new (l?: string, o?: { granularity: string }) => { segment: (s: string) => Iterable<{ segment: string }> } }).Segmenter;
  if (Seg) {
    for (const g of new Seg(undefined, { granularity: "grapheme" }).segment(t)) return g.segment.slice(0, 16);
    return "";
  }
  return [...t][0] ?? "";
}

/* --------------------------------- colours --------------------------------- */

function Swatch({ color, className }: { color: string; className?: string }) {
  return <span className={cn("inline-block size-3.5 rounded-[3px] ring-1 ring-inset ring-foreground/15", className)} style={{ background: color }} />;
}

function ColorPicker({ value, onPick }: { value: string; onPick: (c: string) => void }) {
  const [open, setOpen] = useState(false);
  const [hex, setHex] = useState(value);
  useEffect(() => setHex(value), [value]);
  const valid = HEX.test(hex.trim());
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button type="button" aria-label="Colour" className="size-6 rounded-[4px] inline-flex items-center justify-center hover:bg-muted shrink-0">
          <Swatch color={value} />
        </button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-auto p-2">
        <div className="flex flex-wrap gap-1.5 max-w-[184px]">
          {LABEL_SHADES.map((c) => (
            <button
              key={c}
              type="button"
              aria-label={`Shade ${c}`}
              className={cn("size-6 rounded-[4px] flex items-center justify-center ring-1 ring-inset ring-foreground/15", value.toLowerCase() === c.toLowerCase() && "outline-2 outline-offset-1 outline-foreground")}
              style={{ background: c }}
              onClick={() => {
                onPick(c);
                setOpen(false);
              }}
            >
              {value.toLowerCase() === c.toLowerCase() && <Check size={12} strokeWidth={3} className="mix-blend-difference text-white" />}
            </button>
          ))}
        </div>
        <form
          className="flex items-center gap-1.5 mt-2 pt-2 border-t border-border"
          onSubmit={(e) => {
            e.preventDefault();
            if (!valid) return;
            onPick(hex.trim().toLowerCase());
            setOpen(false);
          }}
        >
          <Input value={hex} onChange={(e) => setHex(e.target.value)} placeholder="#37352f" aria-label="Hex colour" className={cn("h-6 w-24 text-[12px] font-mono", hex.trim() && !valid && "text-destructive")} />
          <Button type="submit" size="xs" disabled={!valid}>
            Use
          </Button>
        </form>
      </PopoverContent>
    </Popover>
  );
}

/* ----------------------------------- grid ----------------------------------- */

function Grid({ habit, days, onToggle }: { habit: Habit; days: string[]; onToggle: (date: string) => void }) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const done = useMemo(() => new Set(habit.completions ?? []), [habit.completions]);
  const scheduled = useMemo(() => new Set(habit.days.length ? habit.days : [0, 1, 2, 3, 4, 5, 6]), [habit.days]);

  // Today sits at the right-hand end; that's the end you want to be looking at.
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollLeft = el.scrollWidth;
  }, []);

  const count = days.reduce((n, d) => n + (done.has(d) ? 1 : 0), 0);

  return (
    <div className="min-w-0">
      <div className="flex items-center gap-3 text-[11px] text-tertiary tnum mb-1">
        <span className="inline-flex items-center gap-1">
          <Flame size={11} /> {habit.streak ?? 0} day{(habit.streak ?? 0) === 1 ? "" : "s"}
        </span>
        <span>
          {count} in {WEEKS} weeks
        </span>
      </div>
      <div ref={scrollRef} className="overflow-x-auto -mx-1 px-1 pb-1">
        <div className="flex gap-[2px] w-max">
          {days.map((d) => {
            const isDone = done.has(d);
            const isFor = scheduled.has(keyToDate(d).getDay());
            return (
              <button
                key={d}
                type="button"
                onClick={() => onToggle(d)}
                aria-pressed={isDone}
                title={`${longDayLabel(d)}${isDone ? " · done" : isFor ? " · missed" : ""}`}
                aria-label={`${habit.name} on ${longDayLabel(d)}`}
                className={cn(
                  "size-[10px] rounded-[2px] shrink-0 transition-colors",
                  isDone ? "border border-transparent" : isFor ? "border border-border hover:border-foreground/40" : "border border-transparent hover:bg-muted",
                )}
                style={isDone ? { background: habit.color || "var(--foreground)" } : undefined}
              />
            );
          })}
        </div>
      </div>
    </div>
  );
}

/* ----------------------------------- row ----------------------------------- */

function HabitRow({ h, days, focused }: { h: Habit; days: string[]; focused?: boolean }) {
  const { update, remove, toggle } = useHabitMutations();
  const [name, setName] = useState(h.name);
  const [editingName, setEditingName] = useState(false);
  const [icon, setIcon] = useState(h.icon);
  const [editingIcon, setEditingIcon] = useState(false);
  const [del, setDel] = useState(false);
  const scheduled = h.days.length ? h.days : [0, 1, 2, 3, 4, 5, 6];

  useEffect(() => setName(h.name), [h.name]);
  useEffect(() => setIcon(h.icon), [h.icon]);

  const fail = (e: unknown) => toast.error((e as Error).message);

  const saveName = () => {
    setEditingName(false);
    const n = name.trim();
    if (!n) {
      setName(h.name);
      return;
    }
    if (n !== h.name) update.mutate({ id: h.id, name: n }, { onError: fail });
  };
  const saveIcon = () => {
    setEditingIcon(false);
    const g = firstGlyph(icon);
    setIcon(g);
    if (g !== h.icon) update.mutate({ id: h.id, icon: g }, { onError: fail });
  };
  const toggleDay = (d: number) => {
    const next = scheduled.includes(d) ? scheduled.filter((x) => x !== d) : [...scheduled, d].sort((a, b) => a - b);
    // The server reads an empty list as "no change", so a habit always keeps at least one day.
    if (!next.length) return;
    update.mutate({ id: h.id, days: next }, { onError: fail });
  };

  return (
    <div className={cn("relative py-3 px-2 border-b border-border scroll-mt-20", focused && "bg-muted")}>
      {focused && <span className="absolute left-0 top-3 bottom-3 w-0.5 rounded-full bg-foreground" />}
      <div className="flex flex-col gap-2.5 lg:flex-row lg:items-center lg:gap-4">
        <div className="flex items-center gap-2 min-w-0 lg:w-[46%] lg:shrink-0">
          {editingIcon ? (
            <input
              autoFocus
              value={icon}
              onChange={(e) => setIcon(e.target.value)}
              onBlur={saveIcon}
              onKeyDown={(e) => {
                if (e.key === "Enter") (e.target as HTMLInputElement).blur();
                if (e.key === "Escape") {
                  setIcon(h.icon);
                  setEditingIcon(false);
                }
              }}
              maxLength={16}
              aria-label={`Icon for ${h.name}`}
              className="size-6 shrink-0 rounded-[4px] bg-muted text-center text-[13px] leading-none outline-none"
            />
          ) : (
            <button
              type="button"
              onClick={() => setEditingIcon(true)}
              aria-label={`Change the icon for ${h.name}`}
              className="size-6 shrink-0 rounded-[4px] inline-flex items-center justify-center text-[13px] leading-none hover:bg-muted"
            >
              {h.icon || <span className="text-tertiary text-[11px]">{h.name.slice(0, 1).toUpperCase()}</span>}
            </button>
          )}

          {editingName ? (
            <input
              autoFocus
              value={name}
              onChange={(e) => setName(e.target.value)}
              onBlur={saveName}
              onKeyDown={(e) => {
                if (e.key === "Enter") (e.target as HTMLInputElement).blur();
                if (e.key === "Escape") {
                  setName(h.name);
                  setEditingName(false);
                }
              }}
              aria-label="Habit name"
              className="flex-1 min-w-0 bg-transparent outline-none text-[13px] font-medium"
            />
          ) : (
            <button type="button" onClick={() => setEditingName(true)} className="flex-1 min-w-0 text-left text-[13px] font-medium truncate hover:text-foreground">
              {h.name}
            </button>
          )}

          <div className="flex items-center gap-px shrink-0">
            {WEEKDAYS.map((w) => {
              const on = scheduled.includes(w.d);
              return (
                <button
                  key={w.d}
                  type="button"
                  onClick={() => toggleDay(w.d)}
                  aria-pressed={on}
                  aria-label={`${w.long}${on ? " — expected" : " — off"}`}
                  title={w.long}
                  className={cn(
                    "size-[18px] rounded-[3px] text-[9.5px] leading-none inline-flex items-center justify-center transition-colors",
                    on ? "bg-foreground text-background" : "text-tertiary hover:bg-muted",
                  )}
                >
                  {w.short}
                </button>
              );
            })}
          </div>

          <ColorPicker value={h.color || "#37352f"} onPick={(c) => update.mutate({ id: h.id, color: c }, { onError: fail })} />

          <Button variant="ghost" size="icon-xs" aria-label={`Delete ${h.name}`} onClick={() => setDel(true)} className="text-muted-foreground hover:text-foreground shrink-0">
            <Trash2 />
          </Button>
        </div>

        <div className="min-w-0 lg:flex-1">
          <Grid habit={h} days={days} onToggle={(d) => toggle.mutate({ id: h.id, date: d })} />
        </div>
      </div>

      <AlertDialog open={del} onOpenChange={setDel}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete “{h.name}”?</AlertDialogTitle>
            <AlertDialogDescription>Every tick you've ever made on it goes too. There's no undo.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Keep it</AlertDialogCancel>
            <AlertDialogAction onClick={() => remove.mutate(h.id, { onError: fail })}>Delete habit</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

/* ----------------------------------- page ----------------------------------- */

export default function Habits() {
  const to = todayKey();
  const from = addDays(to, -(SPAN - 1));
  const q = useHabits(from, to);
  const { create, toggle } = useHabitMutations();
  const [name, setName] = useState("");
  const [color, setColor] = useState(LABEL_SHADES[0]);

  const days = useMemo(() => Array.from({ length: SPAN }, (_, i) => addDays(from, i)), [from]);
  const list = useMemo(() => (q.data ?? []).filter((h) => !h.archived), [q.data]);

  // Enter on the focused row ticks today off — the one thing you come to this page to do.
  const { cursor } = useItemCursor({ count: list.length, onOpen: (i) => list[i] && toggle.mutate({ id: list[i].id, date: to }) });

  return (
    <div className="max-w-3xl mx-auto px-1">
      <header className="pb-3 mb-1 border-b border-border">
        <h1 className="text-[15px] font-semibold tracking-[-0.01em] text-foreground">Habits</h1>
        <p className="text-[12px] text-muted-foreground mt-0.5">The last {WEEKS} weeks, a square a day. Click one to tick it off.</p>
      </header>

      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && <SkeletonRows rows={4} />}
      {!q.isLoading && !q.error && list.length === 0 && (
        <EmptyState icon={<Flame />} title="No habits yet." body="Name one below. Pick the days you mean to do it, then keep the row filled in." />
      )}

      <div>
        {list.map((h, i) => (
          <div key={h.id} data-item-index={i} data-focused={cursor === i || undefined}>
            <HabitRow h={h} days={days} focused={cursor === i} />
          </div>
        ))}
      </div>

      <form
        className="flex items-center gap-2 px-2 h-11"
        onSubmit={(e) => {
          e.preventDefault();
          const n = name.trim();
          if (!n) return;
          create.mutate(
            { name: n, color, days: [0, 1, 2, 3, 4, 5, 6] },
            {
              onSuccess: () => {
                setName("");
                setColor(LABEL_SHADES[(list.length + 1) % LABEL_SHADES.length]);
              },
              onError: (er) => toast.error((er as Error).message),
            },
          );
        }}
      >
        <ColorPicker value={color} onPick={setColor} />
        <input
          className="flex-1 min-w-0 bg-transparent outline-none text-[13px] placeholder:text-tertiary"
          placeholder="Add habit…"
          value={name}
          onChange={(e) => setName(e.target.value)}
          aria-label="New habit name"
        />
        <Button type="submit" size="sm" variant="ghost" disabled={!name.trim() || create.isPending} className="text-muted-foreground">
          <Plus /> Add
        </Button>
      </form>
    </div>
  );
}
