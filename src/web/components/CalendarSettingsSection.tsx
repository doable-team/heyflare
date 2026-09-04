import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { CalendarPlus, CalendarX2, Link2, Plus, RefreshCw, Trash2, Upload } from "lucide-react";
import { toast } from "sonner";
import type { Calendar, CalendarSettings, CalendarSource, CalendarView, GoogleCalendarAccount } from "@shared/types";
import {
  useCalendarConnectLink,
  useCalendarDisconnect,
  useCalendarSettings,
  useCalendarSettingsMutation,
  useCalendarSourceMutations,
  useCalendarSources,
} from "../api";
import { Section, Row, Danger, Toggle } from "../pages/Settings";
import { fmtRelative } from "../lib/format";
import { isNative, openExternalUrl } from "../lib/native";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";

/** The server accepts any six-digit hex; the ramp is what the app offers on its own. */
const HEX = /^#[0-9a-fA-F]{6}$/;
const RAMP = ["#111111", "#3d3d3d", "#5c5c5c", "#7a7a7a", "#9b9b9b", "#bcbcbc", "#d6d6d6", "#efefef"];

const SOURCE_ORDER: CalendarSource[] = ["local", "google", "ics"];
const SOURCE_LABEL: Record<CalendarSource, string> = { local: "In heyflare", google: "Google Calendar", ics: "Subscribed links" };

const VIEW_LABEL: Record<CalendarView, string> = { days: "Day", week: "Week", year: "Year" };
const VIEWS: CalendarView[] = ["days", "week", "year"];

/* ---------- colour ---------- */

function ColourPicker({ value, onChange }: { value: string; onChange: (hex: string) => void }) {
  const [hex, setHex] = useState(value);
  useEffect(() => setHex(value), [value]);
  const valid = HEX.test(hex);
  const apply = () => { if (valid) onChange(hex.toLowerCase()); };
  return (
    <Popover>
      <PopoverTrigger asChild>
        <button type="button" aria-label="Colour" title="Colour" className="size-4 shrink-0 rounded-full border border-border" style={{ background: value }} />
      </PopoverTrigger>
      <PopoverContent align="start" className="w-60 p-2.5">
        <div className="grid grid-cols-8 gap-1.5">
          {RAMP.map((c) => (
            <button
              key={c}
              type="button"
              aria-label={c}
              title={c}
              onClick={() => onChange(c)}
              className={cn("size-5 rounded-full border border-border", value.toLowerCase() === c && "ring-2 ring-ring")}
              style={{ background: c }}
            />
          ))}
        </div>
        <div className="mt-2.5 flex items-center gap-1.5">
          <Input
            value={hex}
            onChange={(e) => setHex(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); apply(); } }}
            placeholder="#767676"
            aria-label="Hex colour"
            spellCheck={false}
            autoCapitalize="none"
            autoCorrect="off"
            className="h-7 font-mono text-xs"
          />
          <Button type="button" size="sm" variant="outline" className="h-7 shrink-0" disabled={!valid} onClick={apply}>Use</Button>
        </div>
        {!valid && <p className="mt-1.5 text-[11px] text-muted-foreground">Six hex digits after a #, like #767676.</p>}
      </PopoverContent>
    </Popover>
  );
}

/* ---------- one calendar ---------- */

function CalendarLine({ c }: { c: Calendar }) {
  const { update, remove, sync } = useCalendarSourceMutations();
  const [name, setName] = useState(c.name);
  const [del, setDel] = useState(false);
  useEffect(() => setName(c.name), [c.name]);
  const fail = (e: unknown) => toast.error((e as Error).message);

  const rename = () => {
    const v = name.trim();
    if (!v || v === c.name) { setName(c.name); return; }
    update.mutate({ id: c.id, name: v }, { onError: (e) => { setName(c.name); fail(e); } });
  };

  return (
    <div className="flex flex-col gap-2 border-b border-border px-2 py-2.5 last:border-b-0 sm:flex-row sm:items-center sm:gap-3">
      <div className="flex min-w-0 flex-1 items-center gap-2.5">
        <ColourPicker value={c.color} onChange={(hex) => update.mutate({ id: c.id, color: hex }, { onError: fail })} />
        <div className="min-w-0 flex-1">
          <Input
            value={name}
            onChange={(e) => setName(e.target.value)}
            onBlur={rename}
            onKeyDown={(e) => { if (e.key === "Enter") e.currentTarget.blur(); if (e.key === "Escape") { setName(c.name); e.currentTarget.blur(); } }}
            aria-label={`Name of ${c.name}`}
            className="h-7 border-transparent bg-transparent px-1.5 hover:bg-input focus-visible:bg-background"
          />
          <div className="mt-0.5 truncate px-1.5 text-xs text-muted-foreground tnum" title={c.source === "ics" ? c.url ?? undefined : undefined}>
            {c.source === "google" && <span>{c.account_email ?? "Google account"}</span>}
            {c.source === "ics" && <span>{c.url ?? "Subscribed link"}</span>}
            {c.source === "local" && <span>Made here{typeof c.event_count === "number" ? ` · ${c.event_count} event${c.event_count === 1 ? "" : "s"}` : ""}</span>}
            {c.source !== "local" && c.last_synced_at ? <span> · synced {fmtRelative(c.last_synced_at)}</span> : null}
            {c.source !== "local" && !c.last_synced_at ? <span> · not synced yet</span> : null}
          </div>
          {c.sync_error && <div className="mt-0.5 px-1.5 text-xs">Last sync failed: {c.sync_error}</div>}
        </div>
      </div>
      <div className="flex shrink-0 items-center gap-1 pl-6 sm:pl-0">
        {c.writable && (
          <label className="mr-1 flex cursor-pointer items-center gap-1.5 text-xs text-muted-foreground" title="New events go here">
            <input
              type="radio"
              name="calendar-default"
              className="size-3.5 accent-foreground"
              checked={c.is_default}
              onChange={() => update.mutate({ id: c.id, is_default: true }, { onError: fail })}
            />
            Default
          </label>
        )}
        <Switch checked={c.visible} aria-label={`Show ${c.name}`} onCheckedChange={(v) => update.mutate({ id: c.id, visible: v }, { onError: fail })} />
        {c.source !== "local" && (
          <Button
            size="sm"
            variant="ghost"
            className="text-muted-foreground"
            disabled={sync.isPending}
            onClick={() => sync.mutate(c.id, { onSuccess: (r) => (r.error ? toast.error(r.error) : toast(`${c.name} is up to date`)), onError: fail })}
          >
            <RefreshCw className={cn(sync.isPending && "animate-spin")} /> Sync
          </Button>
        )}
        <Button size="icon-sm" variant="ghost" className="text-muted-foreground" aria-label={`Remove ${c.name}`} onClick={() => setDel(true)}>
          <Trash2 />
        </Button>
      </div>
      <Danger
        open={del}
        onOpenChange={setDel}
        title={`Remove ${c.name}?`}
        body={
          c.source === "google"
            ? "This removes the calendar and its events from heyflare. Google Calendar itself is untouched — a re-sync brings it back."
            : c.source === "ics"
              ? "This stops following the link and deletes the events it brought in. The feed itself is untouched."
              : "This deletes the calendar and every event on it. There's no undo."
        }
        action="Remove calendar"
        onConfirm={() => remove.mutate(c.id, { onSuccess: () => toast(`${c.name} removed`), onError: (e) => toast.error((e as Error).message) })}
      />
    </div>
  );
}

/* ---------- connected calendars ---------- */

function ConnectedCalendars({ calendars, loading, error }: { calendars: Calendar[]; loading: boolean; error: string | null }) {
  const groups = SOURCE_ORDER.map((s) => ({ source: s, list: calendars.filter((c) => c.source === s) })).filter((g) => g.list.length > 0);
  return (
    <Section title="Calendars" description="Everything the calendar draws from. Hide one to keep it out of the views without losing it.">
      {loading && (
        <div className="space-y-2 px-2">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-2/3" />
        </div>
      )}
      {error && <div className="px-2 text-[13px] text-muted-foreground">{error}</div>}
      {!loading && !error && calendars.length === 0 && (
        <div className="px-2 py-2 text-[13px] text-muted-foreground">No calendars yet. Connect Google Calendar or subscribe to a link below.</div>
      )}
      {groups.map((g) => (
        <div key={g.source} className="mb-4 last:mb-0">
          <div className="mb-1 px-2 text-[12px] font-medium text-muted-foreground">{SOURCE_LABEL[g.source]}</div>
          <div>{g.list.map((c) => <CalendarLine key={c.id} c={c} />)}</div>
        </div>
      ))}
    </Section>
  );
}

/* ---------- Google accounts ---------- */

/** What heyflare holds this account's token for, said plainly. */
function connectedFor(a: GoogleCalendarAccount): string {
  if (a.mail && a.calendar) return "Mail and calendar";
  if (a.calendar) return "Calendar only";
  if (a.mail) return "Mail only";
  return "Nothing yet";
}

function calendarCount(n: number): string {
  return n === 1 ? "1 calendar" : `${n} calendars`;
}

/** The key `pending` holds while the calendar-only flow is opening; no account owns it. */
const NEW_ACCOUNT = "__new__";

function GoogleAccountLine({ a, pending, onConnect }: { a: GoogleCalendarAccount; pending: string | null; onConnect: (a: GoogleCalendarAccount) => void }) {
  const disconnect = useCalendarDisconnect();
  const [confirm, setConfirm] = useState(false);
  const busy = pending === a.id;

  return (
    <div className="flex flex-col gap-2 border-b border-border px-2 py-2.5 last:border-b-0 sm:flex-row sm:items-center sm:gap-3">
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm">{a.email}</div>
        <div className="mt-0.5 text-xs text-muted-foreground">
          {connectedFor(a)}
          {a.calendar ? ` · ${calendarCount(a.calendar_count)} here` : " · no calendars here"}
        </div>
        {a.sync_error && <div className="mt-0.5 text-xs">Last sync failed: {a.sync_error}</div>}
      </div>
      <div className="flex shrink-0 items-center gap-1">
        <Button size="sm" variant="outline" disabled={busy} onClick={() => onConnect(a)}>
          {a.calendar ? <RefreshCw /> : <CalendarPlus />}
          {busy ? "Opening…" : a.calendar ? "Reconnect" : "Connect calendar"}
        </Button>
        {a.calendar && (
          <Button size="sm" variant="ghost" className="text-muted-foreground" disabled={disconnect.isPending} onClick={() => setConfirm(true)}>
            <CalendarX2 /> Disconnect calendar
          </Button>
        )}
      </div>
      <Danger
        open={confirm}
        onOpenChange={setConfirm}
        title={`Disconnect ${a.email}'s calendar?`}
        body={`This removes ${a.calendar_count ? calendarCount(a.calendar_count) : "this account's calendars"} and every event on them from heyflare. Nothing changes in Google, and its mail stays connected. You can connect the calendar again whenever you like.`}
        action="Disconnect calendar"
        onConfirm={() =>
          disconnect.mutate(a.id, {
            onSuccess: () => toast(`${a.email}'s calendar disconnected`),
            onError: (e) => toast.error((e as Error).message),
          })
        }
      />
    </div>
  );
}

function GoogleAccounts({ accounts }: { accounts: GoogleCalendarAccount[] }) {
  const link = useCalendarConnectLink();
  const [pending, setPending] = useState<string | null>(null);

  const open = (key: string, body: { account_id?: string; calendar_only?: boolean }) => {
    setPending(key);
    link.mutate(body, {
      onSuccess: ({ url }) => {
        // The consent screen has to run where the user's Google session lives: the real browser in
        // the Mac and iOS shells, this tab everywhere else.
        if (isNative) {
          openExternalUrl(url);
          toast("Finish in your browser, then come back.");
          setPending(null);
        } else {
          location.assign(url);
        }
      },
      onError: (e) => { setPending(null); toast.error((e as Error).message); },
    });
  };

  return (
    <Section title="Google accounts" description="heyflare asks for calendar access separately from mail, so an account connected for mail alone never touches its calendar.">
      {accounts.length === 0 ? (
        <div className="px-2 py-2 text-[13px] text-muted-foreground">
          No Google account is connected yet. Connect one for mail under{" "}
          <Link to="/settings#accounts" className="underline underline-offset-2 hover:text-foreground">Accounts</Link>, or connect one just for calendar below.
        </div>
      ) : (
        <div>
          {accounts.map((a) => (
            <GoogleAccountLine
              key={a.id}
              a={a}
              pending={pending}
              // An account we hold no mail scope for stays that way: reconnecting it must not quietly
              // ask for mail the owner never granted.
              onConnect={(acc) => open(acc.id, { account_id: acc.id, calendar_only: !acc.mail })}
            />
          ))}
        </div>
      )}
      <div className="mt-4 px-2">
        <Button size="sm" variant="outline" disabled={pending === NEW_ACCOUNT} onClick={() => open(NEW_ACCOUNT, { calendar_only: true })}>
          <CalendarPlus /> {pending === NEW_ACCOUNT ? "Opening…" : "Connect a Google account for calendar only"}
        </Button>
        <p className="mt-1.5 text-xs text-muted-foreground">Asks Google for calendar access and no mail access at all.</p>
        {accounts.some((a) => a.calendar) && (
          <p className="mt-1 text-xs text-muted-foreground">Reconnect runs Google's consent screen again — that's how you fix a grant Google has expired or you have revoked.</p>
        )}
      </div>
    </Section>
  );
}

/* ---------- subscribe / import ---------- */

function SubscribeBlock({ calendars }: { calendars: Calendar[] }) {
  const { subscribe, importIcs, create } = useCalendarSourceMutations();
  const [url, setUrl] = useState("");
  const [name, setName] = useState("");
  const [err, setErr] = useState("");
  const [dest, setDest] = useState("");
  const [importing, setImporting] = useState(false);
  const file = useRef<HTMLInputElement>(null);
  const writable = useMemo(() => calendars.filter((c) => c.writable), [calendars]);

  // Keep the destination pointing at a calendar that still exists; default to the default one.
  useEffect(() => {
    setDest((d) => {
      if (writable.some((c) => c.id === d)) return d;
      return writable.length === 0 ? "" : (writable.find((c) => c.is_default) ?? writable[0]).id;
    });
  }, [writable]);

  const submit = () => {
    const u = url.trim();
    if (!u) return;
    setErr("");
    subscribe.mutate(
      { url: u, name: name.trim() || undefined },
      {
        onSuccess: (c) => { toast(`Subscribed to ${c.name}`); setUrl(""); setName(""); },
        onError: (e) => setErr(feedMessage(e)),
      },
    );
  };

  const pick = async (f: File | null) => {
    if (!f) return;
    setImporting(true);
    try {
      const text = await f.text();
      importIcs.mutate(
        { ics: text, calendar_id: dest || undefined },
        {
          onSuccess: (r) => toast(`Imported ${r.imported} event${r.imported === 1 ? "" : "s"}`),
          onError: (e) => toast.error((e as Error).message),
          onSettled: () => setImporting(false),
        },
      );
    } catch {
      setImporting(false);
      toast.error("That file couldn't be read.");
    }
    if (file.current) file.current.value = "";
  };

  return (
    <Section title="Subscribe to a calendar link" description="Any .ics or webcal:// address — a team roster, a sports schedule, a public holiday feed.">
      <div className="px-2">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
          <Input
            value={url}
            onChange={(e) => { setUrl(e.target.value); setErr(""); }}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); submit(); } }}
            placeholder="https://example.com/calendar.ics"
            aria-label="Calendar link"
            spellCheck={false}
            autoCapitalize="none"
            autoCorrect="off"
            inputMode="url"
            className="sm:flex-1"
          />
          <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="Name (optional)" aria-label="Calendar name" className="sm:w-44" />
          <Button size="sm" variant="outline" className="shrink-0" disabled={!url.trim() || subscribe.isPending} onClick={submit}>
            <Link2 /> Subscribe
          </Button>
        </div>
        {err && <p className="mt-1.5 text-[13px]">{err}</p>}
        <p className="mt-1.5 text-xs text-muted-foreground">Subscribed calendars are read-only and refresh about once an hour. An imported file becomes fully editable instead.</p>

        <div className="mt-5 border-t border-border pt-4">
          <div className="text-sm">Import an .ics file</div>
          <p className="mt-0.5 text-xs text-muted-foreground">Its events are copied into the calendar you pick, where you can edit them like your own.</p>
          <div className="mt-2 flex flex-col gap-2 sm:flex-row sm:items-center">
            <Select value={dest} onValueChange={setDest} disabled={writable.length === 0}>
              <SelectTrigger size="sm" className="sm:w-56"><SelectValue placeholder="No calendar to import into" /></SelectTrigger>
              <SelectContent>
                {writable.map((c) => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}
              </SelectContent>
            </Select>
            <input ref={file} type="file" accept=".ics,text/calendar" className="hidden" onChange={(e) => void pick(e.target.files?.[0] ?? null)} />
            <Button size="sm" variant="outline" className="shrink-0" disabled={!dest || importing || importIcs.isPending} onClick={() => file.current?.click()}>
              <Upload /> {importing || importIcs.isPending ? "Importing…" : "Choose a file"}
            </Button>
            <Button
              size="sm"
              variant="ghost"
              className="shrink-0 text-muted-foreground"
              disabled={create.isPending}
              onClick={() =>
                create.mutate(
                  { name: "New calendar", color: "#111111" },
                  { onSuccess: (c) => { setDest(c.id); toast("Calendar added — rename it above."); }, onError: (e) => toast.error((e as Error).message) },
                )
              }
            >
              <Plus /> New calendar
            </Button>
          </div>
        </div>
      </div>
    </Section>
  );
}

/** `bad_feed`/`bad_url` reach the client as the bare code; say what actually went wrong. */
function feedMessage(e: unknown): string {
  const m = e instanceof Error ? e.message : String(e ?? "");
  if (/^bad url$/i.test(m)) return "That link should start with https:// or webcal://.";
  if (/^bad feed$/i.test(m)) return "That link didn't return a calendar. Open it in a browser to check it's an .ics feed.";
  return m || "That link couldn't be subscribed to.";
}

/* ---------- preferences ---------- */

const FALLBACK_ZONES = [
  "UTC", "Europe/London", "Europe/Dublin", "Europe/Lisbon", "Europe/Madrid", "Europe/Paris", "Europe/Berlin", "Europe/Amsterdam",
  "Europe/Zurich", "Europe/Stockholm", "Europe/Warsaw", "Europe/Athens", "Europe/Istanbul", "Europe/Moscow", "Africa/Lagos",
  "Africa/Cairo", "Africa/Johannesburg", "Africa/Nairobi", "Asia/Jerusalem", "Asia/Dubai", "Asia/Karachi", "Asia/Kolkata",
  "Asia/Dhaka", "Asia/Bangkok", "Asia/Jakarta", "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Singapore", "Asia/Tokyo", "Asia/Seoul",
  "Australia/Perth", "Australia/Brisbane", "Australia/Sydney", "Pacific/Auckland", "America/Sao_Paulo", "America/Argentina/Buenos_Aires",
  "America/Bogota", "America/Mexico_City", "America/New_York", "America/Toronto", "America/Chicago", "America/Denver",
  "America/Phoenix", "America/Los_Angeles", "America/Vancouver", "America/Anchorage", "Pacific/Honolulu",
];

/** `Intl.supportedValuesOf` is recent; older engines fall back to a short list. */
function zoneList(current: string): string[] {
  let all: string[] = [];
  try {
    const f = (Intl as unknown as { supportedValuesOf?: (k: string) => string[] }).supportedValuesOf;
    if (typeof f === "function") all = f.call(Intl, "timeZone");
  } catch {
    all = [];
  }
  if (!all || all.length === 0) all = FALLBACK_ZONES;
  return current && !all.includes(current) ? [current, ...all] : all;
}

function deviceZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "your device";
  } catch {
    return "your device";
  }
}

function hourLabel(h: number, fmt: "12" | "24"): string {
  if (fmt === "24") return `${String(h).padStart(2, "0")}:00`;
  const suffix = h < 12 ? "AM" : "PM";
  return `${h % 12 === 0 ? 12 : h % 12} ${suffix}`;
}

const HOURS = Array.from({ length: 24 }, (_, i) => i);
const DEVICE = "__device__";

function CalendarPreferences({ compact }: { compact?: boolean }) {
  const q = useCalendarSettings();
  const m = useCalendarSettingsMutation();
  const [s, setS] = useState<CalendarSettings | null>(null);
  useEffect(() => { if (q.data) setS(q.data); }, [q.data]);
  const zones = useMemo(() => zoneList(s?.timezone ?? ""), [s?.timezone]);
  const device = useMemo(deviceZone, []);

  if (!s) {
    return (
      <Section title="Calendar preferences">
        <div className="space-y-2 px-2">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-1/2" />
        </div>
      </Section>
    );
  }

  const save = (patch: Partial<CalendarSettings>) => {
    const next = { ...s, ...patch };
    setS(next);
    m.mutate(patch, { onError: (e) => { setS(s); toast.error((e as Error).message); } });
  };
  const toggleCls = compact ? "w-full grid grid-cols-2" : undefined;
  const itemCls = compact ? "h-10 text-[14px] justify-center" : undefined;

  return (
    <Section title="Calendar preferences" description="How the calendar reads. Changes save as you make them.">
      <Row label="Week starts on">
        <Toggle
          className={toggleCls}
          itemClassName={itemCls}
          value={String(s.week_start)}
          options={[{ value: "0", label: "Sunday" }, { value: "1", label: "Monday" }]}
          onChange={(v) => save({ week_start: Number(v) })}
        />
      </Row>
      <Row label="Time format">
        <Toggle
          className={toggleCls}
          itemClassName={itemCls}
          value={s.time_format}
          options={[{ value: "12", label: "12-hour" }, { value: "24", label: "24-hour" }]}
          onChange={(v) => save({ time_format: v as CalendarSettings["time_format"] })}
        />
      </Row>
      <Row label="Default view" hint="What opens when you go to the calendar.">
        <Select value={s.default_view} onValueChange={(v) => save({ default_view: v as CalendarView })}>
          <SelectTrigger size="sm" className="min-w-36"><SelectValue /></SelectTrigger>
          <SelectContent align="end">
            {VIEWS.map((v) => <SelectItem key={v} value={v}>{VIEW_LABEL[v]}</SelectItem>)}
          </SelectContent>
        </Select>
      </Row>
      <Row label="Collapse the night" hint="Folds the sleeping hours into one band you can click open, so the day is mostly waking hours.">
        <Switch checked={s.collapse_night} onCheckedChange={(v) => save({ collapse_night: v })} />
      </Row>
      <Row label="Night runs from" hint={s.collapse_night ? undefined : "Turn collapsing on to set these."}>
        <div className="flex items-center gap-2">
          <Select value={String(s.night_start)} disabled={!s.collapse_night} onValueChange={(v) => save({ night_start: Number(v) })}>
            <SelectTrigger size="sm" className="w-24" aria-label="Night starts"><SelectValue /></SelectTrigger>
            <SelectContent align="end">
              {HOURS.map((h) => <SelectItem key={h} value={String(h)}>{hourLabel(h, s.time_format)}</SelectItem>)}
            </SelectContent>
          </Select>
          <span className="text-[13px] text-muted-foreground">to</span>
          <Select value={String(s.night_end)} disabled={!s.collapse_night} onValueChange={(v) => save({ night_end: Number(v) })}>
            <SelectTrigger size="sm" className="w-24" aria-label="Night ends"><SelectValue /></SelectTrigger>
            <SelectContent align="end">
              {HOURS.map((h) => <SelectItem key={h} value={String(h)}>{hourLabel(h, s.time_format)}</SelectItem>)}
            </SelectContent>
          </Select>
        </div>
      </Row>
      <Row label="Show events you've declined" hint="Off hides anything you said no to.">
        <Switch checked={s.show_declined} onCheckedChange={(v) => save({ show_declined: v })} />
      </Row>
      <Row label="Timezone" hint="Used to place events on a day. Events keep their own time either way.">
        <Select value={s.timezone || DEVICE} onValueChange={(v) => save({ timezone: v === DEVICE ? "" : v })}>
          <SelectTrigger size="sm" className="min-w-56"><SelectValue /></SelectTrigger>
          <SelectContent align="end" className="max-h-72">
            <SelectItem value={DEVICE}>Same as this device ({device})</SelectItem>
            {zones.map((z) => <SelectItem key={z} value={z}>{z.replace(/_/g, " ")}</SelectItem>)}
          </SelectContent>
        </Select>
      </Row>
    </Section>
  );
}

/* ---------- the tab ---------- */

export function CalendarSettingsSection({ compact }: { compact?: boolean }) {
  const q = useCalendarSources();
  const calendars = q.data?.calendars ?? [];
  return (
    <>
      <ConnectedCalendars calendars={calendars} loading={q.isLoading} error={q.error ? (q.error as Error).message : null} />
      <GoogleAccounts accounts={q.data?.google_accounts ?? []} />
      <SubscribeBlock calendars={calendars} />
      <CalendarPreferences compact={compact} />
    </>
  );
}
