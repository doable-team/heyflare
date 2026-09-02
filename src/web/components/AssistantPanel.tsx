import { useEffect, useMemo, useRef, useState } from "react";
import { useLocation } from "react-router-dom";
import { Check, ChevronDown, Sparkles, SquarePen, Trash2, X } from "lucide-react";
import { toast } from "sonner";
import type { AiConversation } from "@shared/types";
import { useAiConversations, useAiMutations, useBundle, useThread } from "../api";
import { assistant, useAssistant, type ContextChip } from "../lib/assistantStore";
import { AssistantChat } from "./AssistantChat";
import { cn } from "@/lib/utils";
import { ThreadPicker } from "./Pickers";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { Kbd } from "@/components/ui/kbd";

/* ---------- grouping helpers ---------- */

function groupByDate(list: AiConversation[]): { label: string; items: AiConversation[] }[] {
  const now = new Date();
  const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const today = startOfDay(now);
  const yesterday = today - 86_400_000;
  const week = today - 7 * 86_400_000;
  const groups: Record<string, AiConversation[]> = { Today: [], Yesterday: [], "Previous 7 days": [], Older: [] };
  for (const c of list) {
    const t = c.updated_at ?? c.created_at;
    const key = t >= today ? "Today" : t >= yesterday ? "Yesterday" : t >= week ? "Previous 7 days" : "Older";
    groups[key].push(c);
  }
  return Object.entries(groups).filter(([, items]) => items.length).map(([label, items]) => ({ label, items }));
}

/** Adds the thread on the current page (`/t/:id` or `/bundle/:id`) as a context chip. Returns whether one was found. */
function useCurrentThreadChip(): ContextChip | null {
  const loc = useLocation();
  const tMatch = /^\/t\/([^/]+)/.exec(loc.pathname);
  const bMatch = /^\/bundle\/([^/]+)/.exec(loc.pathname);
  const thread = useThread(tMatch?.[1], true);
  const bundle = useBundle(bMatch?.[1]);
  return useMemo(() => {
    if (thread.data) return { id: thread.data.id, subject: thread.data.subject, from: thread.data.last_from.name || thread.data.last_from.email };
    const latest = bundle.data?.bundle.latest;
    if (latest) return { id: latest.id, subject: latest.subject, from: latest.last_from.name || latest.last_from.email };
    return null;
  }, [thread.data, bundle.data]);
}

/* ---------- panel ---------- */

export function AssistantPanel() {
  const st = useAssistant();
  const convs = useAiConversations();
  const m = useAiMutations();
  const loc = useLocation();
  const current = useCurrentThreadChip();
  const [pickerOpen, setPickerOpen] = useState(false);
  const panelRef = useRef<HTMLDivElement>(null);
  const openedFrom = useRef<string | null>(null);

  // When the panel opens on a thread/bundle page, attach that thread once (removable).
  useEffect(() => {
    if (!st.open) {
      openedFrom.current = null;
      return;
    }
    if (current && openedFrom.current !== current.id) {
      openedFrom.current = current.id;
      assistant.addContext(current);
    }
  }, [st.open, current?.id]);

  // Escape closes when focus is inside the panel.
  useEffect(() => {
    if (!st.open) return;
    const fn = (e: KeyboardEvent) => {
      if (e.key === "Escape" && panelRef.current?.contains(document.activeElement)) {
        e.stopPropagation();
        assistant.close();
      }
    };
    window.addEventListener("keydown", fn, true);
    return () => window.removeEventListener("keydown", fn, true);
  }, [st.open]);

  const title = useMemo(() => convs.data?.find((c) => c.id === st.conversationId)?.title || (st.conversationId ? "Untitled" : "New chat"), [convs.data, st.conversationId]);
  const groups = useMemo(() => groupByDate(convs.data ?? []), [convs.data]);

  if (!st.open) {
    return (
      <Tooltip>
        <TooltipTrigger asChild>
          <button
            type="button"
            onClick={() => assistant.open()}
            aria-label="Assistant"
            className="fixed bottom-4 right-4 z-40 size-10 rounded-full bg-foreground text-background shadow-md flex items-center justify-center hover:opacity-90 active:scale-95 transition-transform outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            <Sparkles className="size-[18px]" />
          </button>
        </TooltipTrigger>
        <TooltipContent side="left">
          Assistant <Kbd className="ml-1">⌘J</Kbd>
        </TooltipContent>
      </Tooltip>
    );
  }

  return (
    <div
      ref={panelRef}
      role="dialog"
      aria-label="Assistant"
      className={cn(
        "fixed z-50 flex flex-col text-popover-foreground",
        st.mode === "dock"
          ? "top-0 right-0 bottom-0 max-w-[100vw] border-l border-border bg-background"
          : "bottom-4 right-4 w-[400px] max-w-[calc(100vw-32px)] rounded-xl border border-border bg-popover shadow-lg"
      )}
      style={st.mode === "dock" ? { width: st.width } : { height: "min(560px, calc(100vh - 32px))" }}
    >
      {/* resize handle (drag the left edge; double-click resets) */}
      {st.mode === "dock" && (
        <div
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize assistant"
          title="Drag to resize · double-click to reset"
          className="absolute left-0 top-0 bottom-0 w-1.5 -ml-[3px] cursor-col-resize hover:bg-border active:bg-border z-10"
          onDoubleClick={() => assistant.setWidth(400)}
          onPointerDown={(e) => {
            e.preventDefault();
            const startX = e.clientX;
            const startW = st.width;
            const target = e.currentTarget;
            target.setPointerCapture(e.pointerId);
            document.body.style.cursor = "col-resize";
            document.body.style.userSelect = "none";
            const move = (ev: PointerEvent) => assistant.setWidth(startW + (startX - ev.clientX));
            const up = () => {
              document.body.style.cursor = "";
              document.body.style.userSelect = "";
              target.removeEventListener("pointermove", move);
              target.removeEventListener("pointerup", up);
              target.removeEventListener("pointercancel", up);
            };
            target.addEventListener("pointermove", move);
            target.addEventListener("pointerup", up);
            target.addEventListener("pointercancel", up);
          }}
        />
      )}
      {/* header */}
      <div className="h-11 shrink-0 flex items-center gap-1 pl-2 pr-1.5 border-b border-border">
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <button type="button" className="group flex items-center gap-1 min-w-0 max-w-[260px] h-8 rounded-md px-2 text-[13px] font-medium hover:bg-muted data-[state=open]:bg-muted outline-none focus-visible:ring-1 focus-visible:ring-ring">
              <span className="truncate">{title}</span>
              <ChevronDown className="size-3.5 text-muted-foreground shrink-0" />
            </button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="w-[340px] max-h-[320px] overflow-y-auto p-1">
            {groups.length === 0 && <div className="px-2 py-3 text-[13px] text-muted-foreground">No conversations yet.</div>}
            {groups.map((g, gi) => (
              <div key={g.label}>
                {gi > 0 && <DropdownMenuSeparator />}
                <DropdownMenuLabel className="text-[12px] font-medium text-muted-foreground px-2 py-1.5">{g.label}</DropdownMenuLabel>
                {g.items.map((c) => (
                  <DropdownMenuItem
                    key={c.id}
                    onSelect={() => assistant.setConversation(c.id)}
                    className="group/row h-10 gap-2 pr-1"
                  >
                    <span className="flex-1 min-w-0 truncate text-[13px]">{c.title || "Untitled"}</span>
                    {c.id === st.conversationId && <Check className="size-3.5 text-muted-foreground shrink-0" />}
                    <button
                      type="button"
                      aria-label="Delete conversation"
                      className="size-7 rounded-md flex items-center justify-center text-muted-foreground opacity-0 group-hover/row:opacity-100 focus-visible:opacity-100 hover:bg-background hover:text-foreground"
                      onClick={(e) => {
                        e.preventDefault();
                        e.stopPropagation();
                        m.deleteConversation.mutate(c.id, {
                          onSuccess: () => {
                            toast("Deleted");
                            if (st.conversationId === c.id) assistant.newChat();
                          },
                        });
                      }}
                    >
                      <Trash2 className="size-3.5" />
                    </button>
                  </DropdownMenuItem>
                ))}
              </div>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>
        <span className="flex-1" />
        <Tooltip>
          <TooltipTrigger asChild>
            <Button size="icon-sm" variant="ghost" className="text-muted-foreground" aria-label="New chat" onClick={() => assistant.newChat()}>
              <SquarePen />
            </Button>
          </TooltipTrigger>
          <TooltipContent>New chat</TooltipContent>
        </Tooltip>
        
        <Button size="icon-sm" variant="ghost" className="text-muted-foreground" aria-label="Close" onClick={() => assistant.close()}>
          <X />
        </Button>
      </div>

      {/* body */}
      <div className="flex-1 min-h-0 relative">
        <AssistantChat
          conversationId={st.conversationId ?? undefined}
          onConversationId={(id) => assistant.setConversation(id)}
          compact
          autoFocus
          context={st.context}
          onRemoveContext={(id) => assistant.removeContext(id)}
          onAddContext={() => {
            if (current && !st.context.some((c) => c.id === current.id) && (loc.pathname.startsWith("/t/") || loc.pathname.startsWith("/bundle/"))) {
              assistant.addContext(current);
              return;
            }
            setPickerOpen(true);
          }}
        />
        {/* thread picker (anchored above the composer) */}
        <Popover open={pickerOpen} onOpenChange={setPickerOpen}>
          <PopoverTrigger asChild>
            <span className="absolute left-4 bottom-14 size-px" aria-hidden />
          </PopoverTrigger>
          <PopoverContent side="top" align="start" className="w-[360px] p-0" onOpenAutoFocus={(e) => e.preventDefault()}>
            <ThreadPicker
              placeholder="Search a thread to attach…"
              hint="Pick a thread to give the assistant as context."
              exclude={st.context.map((c) => c.id)}
              onPick={(t) => {
                assistant.addContext({ id: t.id, subject: t.subject, from: t.last_from.name || t.last_from.email });
                setPickerOpen(false);
              }}
            />
          </PopoverContent>
        </Popover>
      </div>
    </div>
  );
}

