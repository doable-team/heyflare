import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { Link, Navigate, Outlet, useLocation, useNavigate } from "react-router-dom";
import { ArrowUpCircle, Bookmark, CalendarClock, Check, ChevronDown, ChevronRight, Clock, Eye, FileText, Files, FolderOpen, Inbox, Keyboard, Layers, LogOut, Mail, Monitor, Moon, PenSquare, Plus, Rss, Scissors, Search, Send, Settings, Shield, ShieldOff, Sun, Tag, Trash2, Users, Sparkles } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { cn } from "@/lib/utils";
import { Mark } from "./Logo";
import { startGoogleConnect } from "../lib/connect";
import { ALL, useAccount } from "../context/AccountContext";
import { useCompose } from "../context/ComposeContext";
import { api, useCounts, useMeMutations } from "../api";
import { useKeys } from "../lib/keys";
import { Avatar } from "./Avatar";
import { CommandPalette } from "./CommandPalette";
import { AssistantPanel } from "./AssistantPanel";
import { assistant, useAssistant } from "../lib/assistantStore";
import { ShortcutsOverlay } from "./ShortcutsOverlay";
import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup, SidebarGroupContent, SidebarGroupLabel, SidebarHeader, SidebarInset, SidebarMenu, SidebarMenuButton, SidebarMenuItem, SidebarProvider, SidebarRail, SidebarTrigger, useSidebar,
} from "@/components/ui/sidebar";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger, DropdownMenuRadioGroup, DropdownMenuRadioItem, DropdownMenuShortcut } from "@/components/ui/dropdown-menu";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import { Kbd } from "@/components/ui/kbd";

interface NavItem {
  to: string;
  label: string;
  icon: ReactNode;
  end?: boolean;
  count?: number;
  kbd?: string;
}

const TITLES: [string, string][] = [
  ["/feed", "The Feed"], ["/paper-trail", "Paper Trail"], ["/screener", "Screener"], ["/screened-out", "Screened out"], ["/reply-later", "Reply Later"],
  ["/set-aside", "Set Aside"], ["/bubble-up", "Bubble Up"], ["/previously-seen", "Previously Seen"], ["/contacts", "Contacts"], ["/clips", "Clips"],
  ["/collections", "Collections"], ["/files", "Files"], ["/labels", "Labels"], ["/sent", "Sent"], ["/drafts", "Drafts"], ["/scheduled", "Scheduled"],
  ["/everything", "Everything"], ["/trash", "Trash"], ["/settings", "Settings"], ["/search", "Search"], ["/compose", "New message"], ["/t/", "Thread"], ["/bundle/", "Bundle"], ["/assistant", "Assistant"],
];
function pageTitle(path: string): string {
  if (path === "/") return "Imbox";
  return TITLES.find(([p]) => path.startsWith(p))?.[1] ?? "heyflare";
}

function readOpen(): boolean {
  try {
    return localStorage.getItem("hey.rail") !== "collapsed";
  } catch {
    return true;
  }
}

/** Small monochrome wordmark mark. */
export function Shell() {
  const { user, loading, error } = useAccount();
  const loc = useLocation();
  const [open, setOpen] = useState<boolean>(readOpen);
  const aState = useAssistant();
  const docked = aState.open && aState.mode === "dock";
  if (loading) {
    return (
      <div className="min-h-screen flex flex-col items-center justify-center gap-4 text-muted-foreground text-sm">
        <Mark size={40} />
        <div className="flex items-center gap-2">
          <span className="inline-block size-3.5 rounded-full border-2 border-muted-foreground/40 border-t-foreground animate-spin" />
          {new URLSearchParams(loc.search).has("connected") ? "Connecting your Gmail…" : "Loading…"}
        </div>
      </div>
    );
  }
  if (error || !user) return <Navigate to={`/login?next=${encodeURIComponent(loc.pathname + loc.search)}`} replace />;
  return (
    <SidebarProvider
        open={open}
        onOpenChange={(o) => {
          setOpen(o);
          try {
            localStorage.setItem("hey.rail", o ? "expanded" : "collapsed");
          } catch {}
        }}
      >
        <AppSidebar />
        <SidebarInset className={cn("min-w-0 transition-[padding] duration-150", docked && "md:pr-[400px]")}>
          <TopBar />
          <main className="flex-1 w-full px-4 sm:px-8 pt-4 pb-24">
            <Outlet />
          </main>
        </SidebarInset>
        <Overlays />
        <AssistantPanel />
      </SidebarProvider>
  );
}

/* ---------------- overlays (palette, shortcuts) share state via a tiny store ---------------- */
type OverlayState = { palette: boolean; help: boolean };
let overlayState: OverlayState = { palette: false, help: false };
const listeners = new Set<() => void>();
function setOverlay(patch: Partial<OverlayState>) {
  overlayState = { ...overlayState, ...patch };
  listeners.forEach((l) => l());
}
function useOverlay() {
  const [, force] = useState(0);
  useEffect(() => {
    const l = () => force((x) => x + 1);
    listeners.add(l);
    return () => void listeners.delete(l);
  }, []);
  return overlayState;
}

function useTheme() {
  const { user } = useAccount();
  const { update } = useMeMutations();
  const theme = user?.settings?.theme ?? "system";
  const resolvedDark = theme === "dark" || (theme === "system" && typeof window !== "undefined" && window.matchMedia?.("(prefers-color-scheme: dark)").matches);
  const setTheme = useCallback((t: "light" | "dark" | "system") => update.mutate({ settings: { ...(user?.settings ?? {}), theme: t } }), [update, user?.settings]);
  const toggleTheme = useCallback(() => setTheme(resolvedDark ? "light" : "dark"), [resolvedDark, setTheme]);
  return { theme, setTheme, toggleTheme };
}

function Overlays() {
  const { palette, help } = useOverlay();
  const { openCompose } = useCompose();
  const { account, accounts } = useAccount();
  const { theme, toggleTheme } = useTheme();
  const nav = useNavigate();

  useKeys({
    "1": () => nav("/"),
    "2": () => nav("/feed"),
    "3": () => nav("/paper-trail"),
    "4": () => nav("/screener"),
    "5": () => nav("/reply-later"),
    "6": () => nav("/set-aside"),
    "7": () => nav("/bubble-up"),
    "8": () => nav("/previously-seen"),
    "9": () => nav("/contacts"),
    c: () => openCompose(),
    "/": () => setOverlay({ palette: true }),
    s: () => setOverlay({ palette: true }),
    "?": () => setOverlay({ help: true }),
    i: () => nav("/"),
  });
  useEffect(() => {
    const fn = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOverlay({ palette: !overlayState.palette });
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "j") {
        e.preventDefault();
        assistant.toggle();
      }
    };
    window.addEventListener("keydown", fn);
    return () => window.removeEventListener("keydown", fn);
  }, []);

  return (
    <>
      <CommandPalette open={palette} onClose={() => setOverlay({ palette: false })} onCompose={() => openCompose()} onToggleTheme={toggleTheme} onShortcuts={() => setOverlay({ help: true })} onAssistant={() => assistant.open()} theme={theme} hasAccount={!!account || accounts.length > 0} />
      <ShortcutsOverlay open={help} onClose={() => setOverlay({ help: false })} />
    </>
  );
}

/* ---------------- top bar ---------------- */
function TopBar() {
  const loc = useLocation();
  const { scope, account, accounts } = useAccount();
  const title = pageTitle(loc.pathname);
  const scopeLabel = accounts.length > 1 ? (scope === ALL ? "All accounts" : account?.email) : undefined;
  return (
    <header className="sticky top-0 z-30 h-11 flex items-center gap-2 px-2 sm:px-3 bg-background/90 backdrop-blur">
      <SidebarTrigger className="text-muted-foreground" />
      <div className="flex items-center gap-1.5 min-w-0 text-sm">
        <span className="font-medium truncate">{title}</span>
        {scopeLabel && (
          <>
            <ChevronRight size={12} className="text-tertiary shrink-0" />
            <span className="text-muted-foreground truncate">{scopeLabel}</span>
          </>
        )}
      </div>
      <span className="flex-1" />
      <button type="button" onClick={() => setOverlay({ palette: true })} className="md:hidden size-8 inline-flex items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground" aria-label="Search">
        <Search size={16} />
      </button>
    </header>
  );
}

/* ---------------- sidebar ---------------- */
function AppSidebar() {
  const { user, accounts, account, scope, setScope, glyphFor } = useAccount();
  const counts = useCounts(accounts.length > 0);
  const { openCompose } = useCompose();
  const { theme, setTheme } = useTheme();
  const nav = useNavigate();
  const loc = useLocation();
  const qc = useQueryClient();
  const { isMobile, setOpenMobile, state } = useSidebar();
  const collapsed = state === "collapsed" && !isMobile;
  const [moreOpen, setMoreOpen] = useState<boolean>(() => {
    try {
      return localStorage.getItem("hey.more") === "open";
    } catch {
      return false;
    }
  });
  useEffect(() => {
    if (isMobile) setOpenMobile(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loc.pathname]);

  const c = counts.data;
  const logout = async () => {
    await api.post("/auth/logout");
    qc.clear();
    nav("/login");
  };

  const primary: NavItem[] = [
    { to: "/", label: "Imbox", icon: <Inbox />, count: c?.imbox_new, end: true, kbd: "1" },
    { to: "/feed", label: "The Feed", icon: <Rss />, count: c?.feed_new, kbd: "2" },
    { to: "/paper-trail", label: "Paper Trail", icon: <FileText />, count: c?.paper_trail_new, kbd: "3" },
    { to: "/screener", label: "Screener", icon: <Shield />, count: c?.screener, kbd: "4" },
  ];
  const trays: NavItem[] = [
    { to: "/reply-later", label: "Reply Later", icon: <Clock />, count: c?.reply_later, kbd: "5" },
    { to: "/set-aside", label: "Set Aside", icon: <Bookmark />, count: c?.set_aside, kbd: "6" },
    { to: "/bubble-up", label: "Bubble Up", icon: <ArrowUpCircle />, kbd: "7" },
  ];
  const library: NavItem[] = [
    { to: "/assistant", label: "Assistant", icon: <Sparkles />, kbd: "⌘J" },
    { to: "/previously-seen", label: "Previously Seen", icon: <Eye />, kbd: "8" },
    { to: "/contacts", label: "Contacts", icon: <Users />, kbd: "9" },
    { to: "/clips", label: "Clips", icon: <Scissors /> },
    { to: "/collections", label: "Collections", icon: <FolderOpen /> },
    { to: "/files", label: "Files", icon: <Files /> },
    { to: "/labels", label: "Labels", icon: <Tag /> },
    { to: "/drafts", label: "Drafts", icon: <PenSquare /> },
  ];
  const more: NavItem[] = [
    { to: "/sent", label: "Sent", icon: <Send /> },
    { to: "/scheduled", label: "Scheduled", icon: <CalendarClock /> },
    { to: "/everything", label: "Everything", icon: <Mail /> },
    { to: "/screened-out", label: "Screened out", icon: <ShieldOff /> },
    { to: "/trash", label: "Trash", icon: <Trash2 /> },
  ];
  const isActive = (n: NavItem) => (n.end ? loc.pathname === n.to : loc.pathname.startsWith(n.to));

  const Item = ({ n }: { n: NavItem }) => (
    <SidebarMenuItem>
      <SidebarMenuButton asChild isActive={isActive(n)} tooltip={n.kbd ? `${n.label}  ${n.kbd}` : n.label} className="h-7 text-sm [&>svg]:text-muted-foreground data-[active=true]:font-medium data-[active=true]:[&>svg]:text-foreground">
        <Link
          to={n.to}
          onClick={(e) => {
            if (n.to === "/assistant") {
              e.preventDefault();
              assistant.open();
            }
          }}
        >
          {n.icon}
          <span className="flex-1 truncate">{n.label}</span>
          {!!n.count && <span className="text-xs text-muted-foreground tnum">{n.count}</span>}
        </Link>
      </SidebarMenuButton>
    </SidebarMenuItem>
  );

  const scopeTitle = scope === ALL ? (accounts.length > 1 ? "All accounts" : accounts[0]?.email ?? "No Gmail yet") : account?.email ?? "All accounts";

  return (
    <Sidebar collapsible="icon" className="border-r-0">
      <SidebarHeader className="gap-1 p-2">
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <SidebarMenuButton size="lg" className="h-9 data-[state=open]:bg-sidebar-accent group-data-[collapsible=icon]:!p-1">
              <Mark />
              <span className="flex-1 min-w-0 text-left leading-tight group-data-[collapsible=icon]:hidden">
                <span className="block text-sm font-semibold truncate">heyflare</span>
                <span className="block text-[11px] text-muted-foreground truncate">{scopeTitle}</span>
              </span>
              <ChevronDown size={14} className="text-muted-foreground group-data-[collapsible=icon]:hidden" />
            </SidebarMenuButton>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="w-64" side={collapsed ? "right" : "bottom"}>
            <DropdownMenuLabel className="text-xs text-muted-foreground">Inbox scope</DropdownMenuLabel>
            <DropdownMenuRadioGroup value={scope} onValueChange={(v) => { setScope(v); nav("/"); }}>
              <DropdownMenuRadioItem value={ALL}>
                <Layers className="text-muted-foreground" />
                All accounts
                {accounts.length > 1 && <DropdownMenuShortcut>{accounts.length}</DropdownMenuShortcut>}
              </DropdownMenuRadioItem>
              {accounts.map((a) => (
                <DropdownMenuRadioItem key={a.id} value={a.id}>
                  <span className="w-4 text-center text-[10px] text-muted-foreground">{glyphFor(a.id)}</span>
                  <span className="truncate">{a.email}</span>
                </DropdownMenuRadioItem>
              ))}
            </DropdownMenuRadioGroup>
            {accounts.length === 0 && <div className="px-2 py-1.5 text-xs text-muted-foreground">No Gmail connected yet.</div>}
            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={() => startGoogleConnect()}>
              <Plus />
              Connect Gmail
            </DropdownMenuItem>
            <DropdownMenuItem onClick={() => nav("/settings#accounts")}>
              <Settings />
              Manage accounts
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <SidebarMenu className="mt-3">
          <SidebarMenuItem>
            <SidebarMenuButton onClick={() => openCompose()} tooltip="Compose  c" className="h-7 text-sm [&>svg]:text-muted-foreground">
              <PenSquare />
              <span className="flex-1">New message</span>
              <Kbd className="group-data-[collapsible=icon]:hidden">c</Kbd>
            </SidebarMenuButton>
          </SidebarMenuItem>
          <SidebarMenuItem>
            <SidebarMenuButton onClick={() => setOverlay({ palette: true })} tooltip="Search  ⌘K" className="h-7 text-sm [&>svg]:text-muted-foreground">
              <Search />
              <span className="flex-1">Search</span>
              <Kbd className="group-data-[collapsible=icon]:hidden">⌘K</Kbd>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>

      <SidebarContent className="gap-0">
        <SidebarGroup className="py-1">
          <SidebarGroupContent>
            <SidebarMenu>{primary.map((n) => <Item key={n.to} n={n} />)}</SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
        <SidebarGroup className="py-1">
          <SidebarGroupLabel className="text-xs font-medium text-muted-foreground h-7">Trays</SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu>{trays.map((n) => <Item key={n.to} n={n} />)}</SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
        <SidebarGroup className="py-1">
          <SidebarGroupLabel className="text-xs font-medium text-muted-foreground h-7">Library</SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu>{library.map((n) => <Item key={n.to} n={n} />)}</SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
        <Collapsible open={moreOpen || more.some(isActive)} onOpenChange={(o) => { setMoreOpen(o); try { localStorage.setItem("hey.more", o ? "open" : "closed"); } catch {} }}>
          <SidebarGroup className="py-1">
            <CollapsibleTrigger asChild>
              <SidebarGroupLabel className="text-xs font-medium text-muted-foreground h-7 cursor-pointer hover:bg-sidebar-accent group-data-[collapsible=icon]:hidden">
                More
                <ChevronRight size={12} className="ml-auto transition-transform data-[open=true]:rotate-90" data-open={moreOpen || more.some(isActive)} />
              </SidebarGroupLabel>
            </CollapsibleTrigger>
            <CollapsibleContent>
              <SidebarGroupContent>
                <SidebarMenu>{more.map((n) => <Item key={n.to} n={n} />)}</SidebarMenu>
              </SidebarGroupContent>
            </CollapsibleContent>
          </SidebarGroup>
        </Collapsible>
      </SidebarContent>

      <SidebarFooter className="p-2">
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton asChild isActive={loc.pathname.startsWith("/settings")} tooltip="Settings" className="h-7 text-sm [&>svg]:text-muted-foreground">
              <Link to="/settings">
                <Settings />
                <span>Settings</span>
              </Link>
            </SidebarMenuButton>
          </SidebarMenuItem>
          <SidebarMenuItem>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <SidebarMenuButton className="h-8 text-sm data-[state=open]:bg-sidebar-accent" tooltip={user?.name || user?.email}>
                  <Avatar email={user!.email} name={user!.name} src={accounts.find((a) => a.avatar_url)?.avatar_url} size={20} />
                  <span className="flex-1 truncate">{user!.name || user!.email}</span>
                  <ChevronDown size={14} className="text-muted-foreground" />
                </SidebarMenuButton>
              </DropdownMenuTrigger>
              <DropdownMenuContent side={collapsed ? "right" : "top"} align="start" className="w-56">
                <DropdownMenuLabel className="font-normal">
                  <div className="text-sm">{user!.name || user!.email}</div>
                  <div className="text-xs text-muted-foreground truncate">{user!.email}</div>
                </DropdownMenuLabel>
                <DropdownMenuSeparator />
                <DropdownMenuLabel className="text-xs text-muted-foreground">Theme</DropdownMenuLabel>
                <DropdownMenuRadioGroup value={theme} onValueChange={(v) => setTheme(v as "light" | "dark" | "system")}>
                  <DropdownMenuRadioItem value="light"><Sun /> Light</DropdownMenuRadioItem>
                  <DropdownMenuRadioItem value="dark"><Moon /> Dark</DropdownMenuRadioItem>
                  <DropdownMenuRadioItem value="system"><Monitor /> System</DropdownMenuRadioItem>
                </DropdownMenuRadioGroup>
                <DropdownMenuSeparator />
                <DropdownMenuItem onClick={() => setOverlay({ help: true })}>
                  <Keyboard /> Keyboard shortcuts <DropdownMenuShortcut>?</DropdownMenuShortcut>
                </DropdownMenuItem>
                <DropdownMenuItem onClick={() => nav("/settings")}>
                  <Settings /> Settings
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem onClick={logout}>
                  <LogOut /> Log out
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
      <SidebarRail />
    </Sidebar>
  );
}

// Keep an export some pages may reference for the check icon in account lists.
export { Check as _Check };
