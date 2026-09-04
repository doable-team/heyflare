import { startGoogleConnect, startMicrosoftConnect } from "../lib/connect";
import { useAccount } from "../context/AccountContext";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowUpCircle, Bookmark, CalendarClock, CalendarDays, Clock, Eye, FileText, Files, FolderOpen, Inbox, Keyboard, Mail, Moon, NotebookPen, PenSquare, Plus, Repeat, Rss, Scissors, Send, Settings, Shield, ShieldOff, Sparkles, Sun, Tag, Trash2, Users } from "lucide-react";
import { useSearch } from "../api";
import { fmtTime } from "../lib/format";
import { Avatar } from "./Avatar";
import { Command, CommandDialog, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandSeparator, CommandShortcut } from "@/components/ui/command";

const DESTINATIONS: { to: string; label: string; icon: ReactNode; kbd?: string; keywords?: string }[] = [
  { to: "/", label: "Imbox", icon: <Inbox /> },
  { to: "/feed", label: "The Feed", icon: <Rss />, keywords: "newsletters" },
  { to: "/paper-trail", label: "Paper Trail", icon: <FileText />, keywords: "receipts" },
  { to: "/screener", label: "Screener", icon: <Shield />, keywords: "new senders" },
  { to: "/reply-later", label: "Reply Later", icon: <Clock />, keywords: "focus reply" },
  { to: "/set-aside", label: "Set Aside", icon: <Bookmark /> },
  { to: "/bubble-up", label: "Bubble Up", icon: <ArrowUpCircle />, keywords: "snooze" },
  { to: "/previously-seen", label: "Previously Seen", icon: <Eye /> },
  { to: "/contacts", label: "Contacts", icon: <Users /> },
  { to: "/clips", label: "Clips", icon: <Scissors /> },
  { to: "/collections", label: "Collections", icon: <FolderOpen /> },
  { to: "/files", label: "Files", icon: <Files />, keywords: "attachments" },
  { to: "/labels", label: "Labels", icon: <Tag /> },
  { to: "/sent", label: "Sent", icon: <Send /> },
  { to: "/drafts", label: "Drafts", icon: <PenSquare /> },
  { to: "/scheduled", label: "Scheduled", icon: <CalendarClock />, keywords: "send later" },
  { to: "/everything", label: "Everything", icon: <Mail /> },
  { to: "/screened-out", label: "Screened out", icon: <ShieldOff /> },
  { to: "/trash", label: "Trash", icon: <Trash2 /> },
  { to: "/calendar", label: "Calendar", icon: <CalendarDays />, kbd: "0", keywords: "events schedule meetings agenda" },
  { to: "/journal", label: "Journal", icon: <NotebookPen />, keywords: "diary write day" },
  { to: "/habits", label: "Habits", icon: <Repeat />, keywords: "streak daily routine" },
  { to: "/settings", label: "Settings", icon: <Settings /> },
];

function useDebounced<T>(v: T, ms: number): T {
  const [d, setD] = useState(v);
  useEffect(() => {
    const t = window.setTimeout(() => setD(v), ms);
    return () => window.clearTimeout(t);
  }, [v, ms]);
  return d;
}

export function CommandPalette({
  open,
  onClose,
  onCompose,
  onToggleTheme,
  onShortcuts,
  onAssistant,
  theme,
  hasAccount,
}: {
  open: boolean;
  onClose: () => void;
  onCompose: () => void;
  onToggleTheme: () => void;
  onShortcuts: () => void;
  onAssistant?: () => void;
  theme: "light" | "dark" | "system";
  hasAccount?: boolean;
}) {
  const nav = useNavigate();
  const { googleConfigured, microsoftConfigured } = useAccount();
  const [q, setQ] = useState("");
  const dq = useDebounced(q.trim(), 200);
  const search = useSearch(hasAccount && open ? dq : "");
  useEffect(() => {
    if (open) setQ("");
  }, [open]);

  const actions = useMemo(
    () => [
      { id: "compose", label: "Compose a new message", icon: <PenSquare />, kbd: "c", run: onCompose, keywords: "write new email" },
      ...(onAssistant ? [{ id: "assistant", label: "Open the Assistant", icon: <Sparkles />, kbd: "⌘J", run: onAssistant, keywords: "ai chat help" }] : []),
      ...(googleConfigured ? [{ id: "connect", label: "Connect a Gmail account", icon: <Plus />, run: () => startGoogleConnect(), keywords: "google add account" }] : []),
      ...(microsoftConfigured ? [{ id: "connect-ms", label: "Connect an Outlook account", icon: <Plus />, run: () => startMicrosoftConnect(), keywords: "microsoft outlook office365 add account" }] : []),
      { id: "theme", label: theme === "dark" ? "Switch to light theme" : "Switch to dark theme", icon: theme === "dark" ? <Sun /> : <Moon />, run: onToggleTheme, keywords: "dark light mode appearance" },
      { id: "shortcuts", label: "Keyboard shortcuts", icon: <Keyboard />, kbd: "?", run: onShortcuts },
    ],
    [onCompose, onToggleTheme, onShortcuts, onAssistant, theme, googleConfigured, microsoftConfigured],
  );
  const mail = dq ? (search.data?.pages.flatMap((p) => p.threads) ?? []).slice(0, 8) : [];
  const go = (fn: () => void) => {
    onClose();
    fn();
  };

  return (
    <CommandDialog open={open} onOpenChange={(o) => !o && onClose()} title="Search & commands" description="Search mail, jump anywhere, or run an action." showCloseButton={false} className="sm:max-w-[600px]">
      <Command loop>
      <CommandInput value={q} onValueChange={setQ} placeholder={hasAccount ? "Search mail, jump anywhere, or run an action…" : "Jump anywhere or run an action…"} />
      <CommandList>
        <CommandEmpty>
          {search.isFetching ? "Searching…" : dq ? (
            <button type="button" className="text-sm text-muted-foreground hover:text-foreground" onClick={() => go(() => nav(`/search?q=${encodeURIComponent(dq)}`))}>
              Search everything for “{dq}”
            </button>
          ) : "Nothing here."}
        </CommandEmpty>
        {mail.length > 0 && (
          <CommandGroup heading="Mail">
            {mail.map((t) => (
              <CommandItem key={t.id} value={`mail ${t.id} ${t.subject} ${t.last_from.name} ${t.last_from.email}`} onSelect={() => go(() => nav(`/t/${t.id}`))}>
                <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={20} />
                <span className="truncate font-medium max-w-[40%]">{t.last_from.name || t.last_from.email}</span>
                <span className="truncate text-muted-foreground">{t.subject || "(no subject)"}</span>
                <CommandShortcut>{fmtTime(t.last_message_at)}</CommandShortcut>
              </CommandItem>
            ))}
            {dq && (
              <CommandItem value={`search-all ${dq}`} onSelect={() => go(() => nav(`/search?q=${encodeURIComponent(dq)}`))}>
                <Mail />
                <span>See all results for “{dq}”</span>
              </CommandItem>
            )}
          </CommandGroup>
        )}
        {mail.length > 0 && <CommandSeparator />}
        <CommandGroup heading="Jump to">
          {DESTINATIONS.map((d) => (
            <CommandItem key={d.to} value={`go ${d.label} ${d.keywords ?? ""}`} onSelect={() => go(() => nav(d.to))}>
              {d.icon}
              <span>{d.label}</span>
              {d.kbd && <CommandShortcut>{d.kbd}</CommandShortcut>}
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandSeparator />
        <CommandGroup heading="Actions">
          {actions.map((a) => (
            <CommandItem key={a.id} value={`act ${a.label} ${a.keywords ?? ""}`} onSelect={() => go(a.run)}>
              {a.icon}
              <span>{a.label}</span>
              {a.kbd && <CommandShortcut>{a.kbd}</CommandShortcut>}
            </CommandItem>
          ))}
        </CommandGroup>
      </CommandList>
      </Command>
    </CommandDialog>
  );
}
