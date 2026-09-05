import { lazy, Suspense, useMemo, useState } from "react";
import { CalendarClock, CalendarDays, Coffee, Moon, Sunrise, Sun } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
// react-day-picker and the date-fns it drags in are 170 KB — for a month grid that is behind a
// "Pick a date…" button most people never press.
const Calendar = lazy(() => import("@/components/ui/calendar").then((m) => ({ default: m.Calendar })));
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";

function at(d: Date, h: number, m = 0) {
  const x = new Date(d);
  x.setHours(h, m, 0, 0);
  return x.getTime();
}
const fmtHint = (ms: number) => {
  const d = new Date(ms);
  const today = new Date();
  const time = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  if (d.toDateString() === today.toDateString()) return `Today, ${time}`;
  return `${d.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" })}, ${time}`;
};

export function bubblePresets(): { label: string; at: number; hint: string; icon: React.ReactNode }[] {
  const now = new Date();
  const out: { label: string; at: number; hint: string; icon: React.ReactNode }[] = [];
  const laterToday = at(now, Math.min(now.getHours() + 3, 22));
  if (laterToday > Date.now() + 15 * 60_000) out.push({ label: "Later today", at: laterToday, hint: fmtHint(laterToday), icon: <Coffee /> });
  else {
    const tonight = at(now, 20);
    if (tonight > Date.now()) out.push({ label: "This evening", at: tonight, hint: fmtHint(tonight), icon: <Moon /> });
  }
  const tomorrow = new Date(now);
  tomorrow.setDate(now.getDate() + 1);
  out.push({ label: "Tomorrow morning", at: at(tomorrow, 8), hint: fmtHint(at(tomorrow, 8)), icon: <Sunrise /> });
  const weekend = new Date(now);
  const daysToSat = (6 - now.getDay() + 7) % 7 || 7;
  weekend.setDate(now.getDate() + daysToSat);
  out.push({ label: "This weekend", at: at(weekend, 9), hint: fmtHint(at(weekend, 9)), icon: <Sun /> });
  const nextWeek = new Date(now);
  const daysToMon = (1 - now.getDay() + 7) % 7 || 7;
  nextWeek.setDate(now.getDate() + daysToMon);
  out.push({ label: "Next week", at: at(nextWeek, 8), hint: fmtHint(at(nextWeek, 8)), icon: <CalendarDays /> });
  const month = new Date(now);
  month.setMonth(now.getMonth() + 1);
  out.push({ label: "In a month", at: at(month, 8), hint: fmtHint(at(month, 8)), icon: <CalendarClock /> });
  return out;
}

const TIMES = Array.from({ length: 24 * 2 }, (_, i) => {
  const h = Math.floor(i / 2);
  const m = i % 2 ? 30 : 0;
  const label = new Date(2000, 0, 1, h, m).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  return { value: `${h}:${m}`, label };
});

/** Date/time chooser for Bubble Up and Send Later. Presets + calendar + time. Returns a ms timestamp. */
export function DateTimePicker({ onPick, onCancel, title = "Bubble up", verb = "Bubble up", embedded }: { onPick: (ms: number) => void; onCancel?: () => void; title?: string; verb?: string; embedded?: boolean }) {
  const presets = useMemo(bubblePresets, []);
  const [day, setDay] = useState<Date | undefined>(() => {
    const d = new Date();
    d.setDate(d.getDate() + 1);
    return d;
  });
  const [time, setTime] = useState("9:0");
  const [showCal, setShowCal] = useState(false);
  const pickCustom = () => {
    if (!day) return;
    const [h, m] = time.split(":").map(Number);
    onPick(at(day, h, m));
  };
  return (
    <div className={cn("w-[300px] max-w-[92vw]", embedded ? "" : "p-1")}>
      {!embedded && <div className="px-2 h-8 flex items-center text-xs font-medium text-muted-foreground">{title}</div>}
      <div className="flex flex-col">
        {presets.map((p) => (
          <Button key={p.label} variant="ghost" size="sm" className="justify-start gap-2 h-8 font-normal [&>svg]:text-muted-foreground" onClick={() => onPick(p.at)}>
            {p.icon}
            <span className="flex-1 text-left">{p.label}</span>
            <span className="text-xs text-muted-foreground tnum">{p.hint}</span>
          </Button>
        ))}
        <Button variant="ghost" size="sm" className="justify-start gap-2 h-8 font-normal [&>svg]:text-muted-foreground" onClick={() => setShowCal((s) => !s)}>
          <CalendarDays />
          <span className="flex-1 text-left">Pick a date…</span>
        </Button>
      </div>
      {showCal && (
        <>
          <Separator className="my-1" />
          <Suspense fallback={<div className="h-[290px]" aria-busy="true" />}>
            <Calendar mode="single" selected={day} onSelect={setDay} disabled={{ before: new Date() }} className="p-1" />
          </Suspense>
          <div className="flex items-center gap-1.5 px-1 pb-1">
            <Select value={time} onValueChange={setTime}>
              <SelectTrigger size="sm" className="flex-1"><SelectValue /></SelectTrigger>
              <SelectContent className="max-h-64">
                {TIMES.map((t) => <SelectItem key={t.value} value={t.value}>{t.label}</SelectItem>)}
              </SelectContent>
            </Select>
            <Button size="sm" onClick={pickCustom} disabled={!day}>{verb}</Button>
          </div>
        </>
      )}
      {onCancel && !embedded && (
        <div className="flex justify-end px-1 pb-1">
          <Button variant="ghost" size="xs" className="text-muted-foreground" onClick={onCancel}>Cancel</Button>
        </div>
      )}
    </div>
  );
}
