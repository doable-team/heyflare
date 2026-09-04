import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Link, Navigate, Outlet, useLocation, useNavigate } from "react-router-dom";
import { ArrowUpCircle, BookOpen, Bookmark, CalendarClock, CalendarDays, Repeat, Check, ChevronDown, ChevronRight, Clock, Eye, FileText, Files, FolderOpen, Inbox, Keyboard, Layers, LogOut, Mail, Monitor, Moon, PenSquare, Plus, Rss, Scissors, Search, Send, Settings, Shield, ShieldOff, Sun, Tag, Trash2, Users, Sparkles } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { cn } from "@/lib/utils";
import { Mark } from "./Logo";
import { isNative, isMac, native, onMenu, installExternalLinkHandler } from "../lib/native";
import { startGoogleConnect, startMicrosoftConnect } from "../lib/connect";
import { ALL, useAccount } from "../context/AccountContext";
import { useCompose } from "../context/ComposeContext";
import { api, useCounts, useMeMutations } from "../api";
import { useKeys } from "../lib/keys";
import { arrows, focus, overlayOpen, useFocusRegion } from "../lib/focusStore";
import { Avatar } from "./Avatar";
import { CommandPalette } from "./CommandPalette";
import { AssistantPanel } from "./AssistantPanel";
import { assistant, useAssistant } from "../lib/assistantStore";
import { ShortcutsOverlay } from "./ShortcutsOverlay";
import { UpdateDialog } from "./UpdateDialog";
import { useUpdateCheck } from "../lib/update";
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
  ["/feed", "The Feed"], ["/paper-trail", "Paper Trail"], ["/power-through", "Power through new"], ["/screener", "Screener"], ["/screened-out", "Screened out"], ["/reply-later", "Reply Later"],
  ["/set-aside", "Set Aside"], ["/bubble-up", "Bubble Up"], ["/previously-seen", "Previously Seen"], ["/contacts", "Contacts"], ["/clips", "Clips"],
  ["/collections", "Collections"], ["/files", "Files"], ["/labels", "Labels"], ["/sent", "Sent"], ["/drafts", "Drafts"], ["/scheduled", "Scheduled"],
  ["/everything", "Everything"], ["/trash", "Trash"], ["/settings", "Settings"], ["/search", "Search"], ["/compose", "New message"], ["/t/", "Thread"], ["/bundle/", "Bundle"], ["/assistant", "Assistant"], ["/calendar", "Calendar"], ["/journal", "Journal"], ["/habits", "Habits"],
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
  const fullHeight = loc.pathname.startsWith("/calendar");
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
        <SidebarInset className={cn("min-w-0 transition-[padding] duration-150", fullHeight && "h-svh overflow-hidden")} style={{ paddingRight: docked ? aState.width : undefined }}>
          <TopBar />
          {/* The calendar is a full-height app view that scrolls inside itself, so it gets the
              viewport exactly and no tall bottom padding — otherwise the page scrolls too and the
              toolbar drifts away under you. Every other page wants the room to grow. */}
          <main className={cn("w-full px-4 sm:px-8 pt-4", fullHeight ? "min-h-0 flex-1 overflow-hidden pb-3" : "flex-1 pb-24")}>
            <Outlet />
          </main>
        </SidebarInset>
        <Overlays />
        <AssistantPanel />
      </SidebarProvider>
  );
}

/* ---------------- overlays (palette, shortcuts) share state via a tiny store ---------------- */
type OverlayState = { palette: boolean; help: boolean; update: boolean };
let overlayState: OverlayState = { palette: false, help: false, update: false };
const listeners = new Set<() => void>();
function setOverlay(patch: Partial<OverlayState>) {
  overlayState = { ...overlayState, ...patch };
  listeners.forEach((l) => l());
}
export function openUpdateDialog() {
  setOverlay({ update: true });
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
  const { palette, help, update } = useOverlay();
  const { openCompose } = useCompose();
  const { account, accounts } = useAccount();
  const { theme, toggleTheme } = useTheme();
  const updateInfo = useUpdateCheck();
  const nav = useNavigate();

  useKeys({
    c: () => openCompose(),
    "/": () => setOverlay({ palette: true }),
    s: () => setOverlay({ palette: true }),
    "?": () => setOverlay({ help: true }),
    i: () => nav("/"),
    "0": () => nav(location.pathname.startsWith("/calendar") ? "/" : "/calendar"),
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

  // Native shell: menu-bar actions (Mac only), external links, notification deep links.
  useEffect(() => {
    if (!isNative) return;
    const offMenu = !isMac ? () => {} : onMenu((id) => {
      if (id.startsWith("nav:")) return nav(id.slice(4));
      switch (id) {
        case "compose": return openCompose();
        case "palette": return setOverlay({ palette: true });
        case "assistant": return assistant.toggle();
        case "check-updates": return setOverlay({ update: true });
        case "toggle-sidebar": return window.dispatchEvent(new KeyboardEvent("keydown", { key: "b", metaKey: true, bubbles: true }));
        case "back": return history.back();
        case "forward": return history.forward();
      }
    });
    const offLinks = installExternalLinkHandler();
    const onFocus = () => { native.takePendingUrl().then((u) => { if (u) nav(u); }); };
    window.addEventListener("focus", onFocus);
    return () => { offMenu(); offLinks(); window.removeEventListener("focus", onFocus); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <>
      <CommandPalette open={palette} onClose={() => setOverlay({ palette: false })} onCompose={() => openCompose()} onToggleTheme={toggleTheme} onShortcuts={() => setOverlay({ help: true })} onAssistant={() => assistant.open()} theme={theme} hasAccount={!!account || accounts.length > 0} />
      <ShortcutsOverlay open={help} onClose={() => setOverlay({ help: false })} />
      <UpdateDialog open={update} onClose={() => setOverlay({ update: false })} info={updateInfo} />
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
    <header data-tauri-drag-region={isMac || undefined} className="sticky top-0 z-30 h-11 flex items-center gap-2 px-2 sm:px-3 bg-background/90 backdrop-blur">
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
  const { user, accounts, account, scope, setScope, glyphFor, googleConfigured, microsoftConfigured } = useAccount();
  const counts = useCounts(accounts.length > 0);
  const update = useUpdateCheck();
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
  const prevNew = useRef<number | null>(null);
  useEffect(() => {
    if (!isNative || !c) return;
    native.setBadge((c.imbox_new ?? 0) + (c.screener ?? 0));
    const prev = prevNew.current;
    prevNew.current = c.imbox_new ?? 0;
    if (prev != null && (c.imbox_new ?? 0) > prev && !document.hasFocus()) {
      api.get<{ new_threads: { id: string; subject: string; last_from: { name: string; email: string } }[] }>("/api/imbox")
        .then((d) => { const t = d.new_threads?.[0]; if (t) native.notify(t.last_from.name || t.last_from.email, t.subject || "(no subject)", `/t/${t.id}`); })
        .catch(() => {});
    }
  }, [c?.imbox_new, c?.screener]);
  const logout = async () => {
    await api.post("/auth/logout");
    qc.clear();
    nav("/login");
  };

  const primary: NavItem[] = [
    { to: "/", label: "Imbox", icon: <Inbox />, count: c?.imbox_new, end: true },
    { to: "/feed", label: "The Feed", icon: <Rss />, count: c?.feed_new },
    { to: "/paper-trail", label: "Paper Trail", icon: <FileText />, count: c?.paper_trail_new },
    { to: "/screener", label: "Screener", icon: <Shield />, count: c?.screener },
    { to: "/calendar", label: "Calendar", icon: <CalendarDays />, kbd: "0" },
  ];
  const trays: NavItem[] = [
    { to: "/reply-later", label: "Reply Later", icon: <Clock />, count: c?.reply_later },
    { to: "/set-aside", label: "Set Aside", icon: <Bookmark />, count: c?.set_aside },
    { to: "/bubble-up", label: "Bubble Up", icon: <ArrowUpCircle /> },
  ];
  const library: NavItem[] = [
    { to: "/previously-seen", label: "Previously Seen", icon: <Eye /> },
    { to: "/contacts", label: "Contacts", icon: <Users /> },
    { to: "/clips", label: "Clips", icon: <Scissors /> },
    { to: "/collections", label: "Collections", icon: <FolderOpen /> },
    { to: "/files", label: "Files", icon: <Files /> },
    { to: "/labels", label: "Labels", icon: <Tag /> },
    { to: "/drafts", label: "Drafts", icon: <PenSquare /> },
  ];
  const more: NavItem[] = [
    { to: "/journal", label: "Journal", icon: <BookOpen /> },
    { to: "/habits", label: "Habits", icon: <Repeat /> },
    { to: "/sent", label: "Sent", icon: <Send /> },
    { to: "/scheduled", label: "Scheduled", icon: <CalendarClock /> },
    { to: "/everything", label: "Everything", icon: <Mail /> },
    { to: "/screened-out", label: "Screened out", icon: <ShieldOff /> },
    { to: "/trash", label: "Trash", icon: <Trash2 /> },
  ];
  const isActive = (n: NavItem) => (n.end ? loc.pathname === n.to : loc.pathname.startsWith(n.to));
  const moreExpanded = moreOpen || more.some(isActive);

  /* ---- arrow-key focus: sidebar │ content │ assistant ---- */
  const region = useFocusRegion();
  const assistantState = useAssistant();
  const [focusIdx, setFocusIdx] = useState(0);
  const flatNav = useMemo(
    () => [...primary, ...trays, ...library, ...(moreExpanded ? more : [])],
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [c, moreExpanded, loc.pathname],
  );
  const activate = useCallback(
    (n: NavItem) => {
      if (n.to === "/assistant") assistant.open();
      else nav(n.to);
      focus.toContent();
    },
    [nav],
  );
  // Entering the sidebar starts on the item for the page you're looking at.
  useEffect(() => {
    if (region !== "sidebar") return;
    const i = flatNav.findIndex(isActive);
    setFocusIdx(i >= 0 ? i : 0);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [region]);
  useEffect(() => {
    if (region !== "sidebar") return;
    document.querySelector('[data-nav-focused="true"]')?.scrollIntoView({ block: "nearest" });
  }, [region, focusIdx]);

  const arrowsOk = () => !isMobile && !overlayOpen() && (region === "sidebar" || !arrows.claimed());
  useKeys({
    ArrowLeft: () => {
      if (!arrowsOk()) return;
      // Mirror of ArrowRight: leaving the assistant closes it, then content steps into the sidebar.
      if (assistantState.open && region !== "sidebar") {
        assistant.close();
        focus.toContent();
        return;
      }
      if (region === "content") focus.toSidebar();
    },
    ArrowRight: () => {
      if (!arrowsOk()) return;
      if (region === "sidebar") {
        const n = flatNav[focusIdx];
        if (n) activate(n);
      } else {
        assistant.open();
        // The panel mounts a tick later; keep trying briefly, then give up quietly.
        let tries = 0;
        const focusInput = () => {
          const el = document.querySelector<HTMLTextAreaElement>("[data-assistant-input]");
          if (el && !el.disabled) return el.focus();
          if (tries++ < 12) window.setTimeout(focusInput, 50);
        };
        window.setTimeout(focusInput, 30);
      }
    },
    ArrowDown: () => {
      if (!arrowsOk() || region !== "sidebar" || !flatNav.length) return;
      setFocusIdx((i) => (i + 1) % flatNav.length);
    },
    ArrowUp: () => {
      if (!arrowsOk() || region !== "sidebar" || !flatNav.length) return;
      setFocusIdx((i) => (i - 1 + flatNav.length) % flatNav.length);
    },
    Enter: () => {
      if (!arrowsOk() || region !== "sidebar") return;
      const n = flatNav[focusIdx];
      if (n) activate(n);
    },
    Escape: () => {
      if (region === "sidebar") focus.toContent();
    },
  });

  const Item = ({ n }: { n: NavItem }) => {
    const focused = region === "sidebar" && flatNav[focusIdx]?.to === n.to;
    return (
    <SidebarMenuItem>
      <SidebarMenuButton
        asChild
        isActive={isActive(n)}
        data-nav-focused={focused || undefined}
        tooltip={n.kbd ? `${n.label}  ${n.kbd}` : n.label}
        className={cn(
          "h-7 text-sm [&>svg]:text-muted-foreground data-[active=true]:font-medium data-[active=true]:[&>svg]:text-foreground",
          focused && "bg-sidebar-accent text-sidebar-accent-foreground ring-1 ring-ring",
        )}
      >
        <Link
          to={n.to}
          onClick={(e) => {
            focus.toContent();
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
  };

  const scopeTitle = scope === ALL ? (accounts.length > 1 ? "All accounts" : accounts[0]?.email ?? "No Gmail yet") : account?.email ?? "All accounts";

  return (
    <Sidebar collapsible="icon" className="border-r-0">
      <SidebarHeader data-tauri-drag-region={isMac || undefined} className={cn("gap-1 p-2", isMac && "pt-10")}>
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
            {accounts.length === 0 && <div className="px-2 py-1.5 text-xs text-muted-foreground">Nothing connected yet.</div>}
            <DropdownMenuSeparator />
{googleConfigured ? (
              <DropdownMenuItem onClick={() => startGoogleConnect()}>
                <Plus />
                Connect Gmail
              </DropdownMenuItem>
            ) : null}
            {microsoftConfigured ? (
              <DropdownMenuItem onClick={() => startMicrosoftConnect()}>
                <Plus />
                Connect Outlook
              </DropdownMenuItem>
            ) : null}
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
        <Collapsible open={moreExpanded} onOpenChange={(o) => { setMoreOpen(o); try { localStorage.setItem("hey.more", o ? "open" : "closed"); } catch {} }}>
          <SidebarGroup className="py-1">
            <CollapsibleTrigger asChild>
              <SidebarGroupLabel className="text-xs font-medium text-muted-foreground h-7 cursor-pointer hover:bg-sidebar-accent group-data-[collapsible=icon]:hidden">
                More
                <ChevronRight size={12} className="ml-auto transition-transform data-[open=true]:rotate-90" data-open={moreExpanded} />
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
          {update.updateAvailable && (
            <SidebarMenuItem>
              <SidebarMenuButton onClick={openUpdateDialog} tooltip={`Update available · v${update.latest}`} className="h-7 text-sm [&>svg]:text-muted-foreground">
                <ArrowUpCircle />
                <span className="flex-1 truncate">Update available</span>
                <span className="size-1.5 rounded-full bg-foreground shrink-0" aria-hidden />
              </SidebarMenuButton>
            </SidebarMenuItem>
          )}
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
