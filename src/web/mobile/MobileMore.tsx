import { useState, type ReactNode } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { ArrowUpCircle, Bookmark, CalendarClock, ChevronRight, Clock, Eye, Files, FolderOpen, LogOut, Mail, Monitor, Moon, PenSquare, Scissors, Search, Send, Settings, ShieldOff, Sun, Tag, Trash2, Users, Sparkles } from "lucide-react";
import { api, useCounts, useMeMutations } from "../api";
import { useAccount } from "../context/AccountContext";
import { Avatar } from "../components/Avatar";
import { Screen } from "./Screen";
import { ActionSheet } from "./ActionSheet";
import { useUpdateCheck } from "../lib/update";
import { UpdateDialog } from "../components/UpdateDialog";

function Row({ to, icon, label, count, onClick, hint }: { to?: string; icon: ReactNode; label: string; count?: number; onClick?: () => void; hint?: string }) {
  const inner = (
    <>
      <span className="text-muted-foreground [&>svg]:size-5 shrink-0">{icon}</span>
      <span className="flex-1 text-[15px] text-foreground">{label}</span>
      {!!count && <span className="text-[13px] text-muted-foreground tnum">{count}</span>}
      {hint && <span className="text-[13px] text-muted-foreground">{hint}</span>}
      <ChevronRight size={16} className="text-tertiary" />
    </>
  );
  const cls = "flex items-center gap-3 h-12 px-4 active:bg-muted w-full text-left";
  return to ? (
    <Link to={to} className={cls}>{inner}</Link>
  ) : (
    <button type="button" onClick={onClick} className={cls}>{inner}</button>
  );
}

function Group({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <section className="mt-2">
      {title && <div className="px-4 h-8 flex items-center text-[12px] font-medium text-muted-foreground">{title}</div>}
      <div className="divide-y divide-border/60">{children}</div>
    </section>
  );
}

export default function MobileMore() {
  const { user, accounts } = useAccount();
  const counts = useCounts(accounts.length > 0);
  const c = counts.data;
  const { update } = useMeMutations();
  const theme = user?.settings?.theme ?? "system";
  const [themeOpen, setThemeOpen] = useState(false);
  const [updateOpen, setUpdateOpen] = useState(false);
  const upd = useUpdateCheck();
  const nav = useNavigate();
  const qc = useQueryClient();
  const logout = async () => {
    await api.post("/auth/logout");
    qc.clear();
    nav("/login");
  };
  const setTheme = (t: "light" | "dark" | "system") => update.mutate({ settings: { ...(user?.settings ?? {}), theme: t } });
  return (
    <Screen title="More" largeTitle>
      <Link to="/settings" className="mx-4 mb-2 flex items-center gap-3 rounded-lg bg-muted/50 active:bg-muted px-3 py-3">
        <Avatar email={user?.email ?? ""} name={user?.name} src={accounts.find((a) => a.avatar_url)?.avatar_url} size={40} />
        <div className="min-w-0 flex-1">
          <div className="text-[15px] font-medium truncate">{user?.name || user?.email}</div>
          <div className="text-[13px] text-muted-foreground truncate">{accounts.length ? `${accounts.length} ${accounts.length === 1 ? "account" : "accounts"} connected` : "No Gmail connected yet"}</div>
        </div>
        <ChevronRight size={16} className="text-tertiary" />
      </Link>
      <Group>
        <Row to="/assistant" icon={<Sparkles />} label="Assistant" />
        <Row to="/search" icon={<Search />} label="Search" />
        <Row icon={<PenSquare />} label="New message" onClick={() => nav("/compose")} />
      </Group>
      <Group title="Trays">
        <Row to="/reply-later" icon={<Clock />} label="Reply Later" count={c?.reply_later} />
        <Row to="/set-aside" icon={<Bookmark />} label="Set Aside" count={c?.set_aside} />
        <Row to="/bubble-up" icon={<ArrowUpCircle />} label="Bubble Up" />
      </Group>
      <Group title="Library">
        <Row to="/previously-seen" icon={<Eye />} label="Previously Seen" />
        <Row to="/contacts" icon={<Users />} label="Contacts" />
        <Row to="/clips" icon={<Scissors />} label="Clips" />
        <Row to="/collections" icon={<FolderOpen />} label="Collections" />
        <Row to="/files" icon={<Files />} label="Files" />
        <Row to="/labels" icon={<Tag />} label="Labels" />
        <Row to="/drafts" icon={<PenSquare />} label="Drafts" />
        <Row to="/scheduled" icon={<CalendarClock />} label="Scheduled" />
      </Group>
      <Group title="Everything else">
        <Row to="/sent" icon={<Send />} label="Sent" />
        <Row to="/everything" icon={<Mail />} label="Everything" />
        <Row to="/screened-out" icon={<ShieldOff />} label="Screened out" />
        <Row to="/trash" icon={<Trash2 />} label="Trash" />
      </Group>
      <Group title="App">
        <Row to="/settings" icon={<Settings />} label="Settings" />
        {upd.updateAvailable && <Row icon={<ArrowUpCircle />} label="Update available" hint={`v${upd.latest}`} onClick={() => setUpdateOpen(true)} />}
        <Row icon={theme === "dark" ? <Moon /> : theme === "light" ? <Sun /> : <Monitor />} label="Appearance" hint={theme === "system" ? "System" : theme === "dark" ? "Dark" : "Light"} onClick={() => setThemeOpen(true)} />
        <Row icon={<LogOut />} label="Log out" onClick={logout} />
      </Group>
      <div className="px-4 py-6 text-center text-[12px] text-muted-foreground">heyflare · {user?.email}</div>
      <UpdateDialog open={updateOpen} onClose={() => setUpdateOpen(false)} info={upd} />
      <ActionSheet
        open={themeOpen}
        onOpenChange={setThemeOpen}
        title="Appearance"
        actions={[
          { icon: <Sun />, label: "Light", checked: theme === "light", onSelect: () => setTheme("light") },
          { icon: <Moon />, label: "Dark", checked: theme === "dark", onSelect: () => setTheme("dark") },
          { icon: <Monitor />, label: "System", checked: theme === "system", onSelect: () => setTheme("system") },
        ]}
      />
    </Screen>
  );
}
