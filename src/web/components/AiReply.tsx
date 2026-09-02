import { useState } from "react";
import { Link } from "react-router-dom";
import { ChevronDown, ChevronUp, Loader2, Sparkles } from "lucide-react";
import { toast } from "sonner";
import { useAiMutations, useAiSettings } from "../api";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Drawer, DrawerContent, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { cn } from "@/lib/utils";

export type AiTone = "match" | "formal" | "friendly" | "brief";
const TONES: { value: AiTone; label: string }[] = [
  { value: "match", label: "My tone" },
  { value: "formal", label: "Formal" },
  { value: "friendly", label: "Friendly" },
  { value: "brief", label: "Brief" },
];

export interface AiReplyResult {
  body_html: string;
  body_text: string;
  subject: string | null;
  reply_to_message_id: string | null;
}

function AiReplyForm({ threadId, onResult, onClose, compact }: { threadId: string; onResult: (r: AiReplyResult) => void; onClose: () => void; compact?: boolean }) {
  const settings = useAiSettings();
  const { reply } = useAiMutations();
  const [brief, setBrief] = useState("");
  const [tone, setTone] = useState<AiTone>("match");
  const notConfigured = settings.data && !settings.data.configured;
  const go = () => {
    if (!brief.trim()) return;
    reply.mutate(
      { thread_id: threadId, brief: brief.trim(), tone },
      {
        onSuccess: (r) => { onResult(r); onClose(); },
        onError: (e) => toast.error((e as Error).message),
      }
    );
  };
  return (
    <div className={cn("space-y-3", compact ? "px-4 pb-4" : "")}>
      {notConfigured ? (
        <div className="text-[13px] text-muted-foreground">
          <Link to="/settings#ai" className="underline underline-offset-2">Add your Anthropic API key</Link> in Settings → AI to write replies with AI.
        </div>
      ) : (
        <>
          <textarea
            autoFocus
            value={brief}
            onChange={(e) => setBrief(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); go(); } }}
            rows={compact ? 4 : 3}
            placeholder="What do you want to say? e.g. “Yes, Tuesday at 3 works — ask them to send the agenda.”"
            className="w-full resize-none rounded-md bg-muted/60 focus:bg-muted px-3 py-2 text-[14px] leading-6 outline-none placeholder:text-muted-foreground"
          />
          <div className="flex items-center gap-2 flex-wrap">
            <ToggleGroup type="single" size="sm" value={tone} onValueChange={(v) => v && setTone(v as AiTone)} variant="outline">
              {TONES.map((t) => <ToggleGroupItem key={t.value} value={t.value} className="text-[12px]">{t.label}</ToggleGroupItem>)}
            </ToggleGroup>
            <span className="flex-1" />
            <Button size={compact ? "lg" : "sm"} className={cn(compact && "w-full")} onClick={go} disabled={!brief.trim() || reply.isPending}>
              {reply.isPending ? <Loader2 className="animate-spin" /> : <Sparkles />} Write reply
            </Button>
          </div>
          <div className="text-[11px] text-muted-foreground">Reads the whole thread and what I know about how you write. You review before sending.</div>
        </>
      )}
    </div>
  );
}

/** Desktop: popover on a button. */
export function AiReplyButton({ threadId, onResult, className }: { threadId: string; onResult: (r: AiReplyResult) => void; className?: string }) {
  const [open, setOpen] = useState(false);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button size="sm" variant="outline" className={className}><Sparkles /><span className="hidden sm:inline">Reply with AI</span></Button>
      </PopoverTrigger>
      <PopoverContent side="top" align="start" className="w-[380px] p-3">
        <AiReplyForm threadId={threadId} onResult={onResult} onClose={() => setOpen(false)} />
      </PopoverContent>
    </Popover>
  );
}

/** Mobile: bottom drawer controlled by the caller. */
export function AiReplyDrawer({ threadId, open, onOpenChange, onResult }: { threadId: string; open: boolean; onOpenChange: (o: boolean) => void; onResult: (r: AiReplyResult) => void }) {
  return (
    <Drawer open={open} onOpenChange={onOpenChange}>
      <DrawerContent className="pb-safe">
        <DrawerHeader className="text-left">
          <DrawerTitle className="flex items-center gap-2"><Sparkles className="size-4" /> Reply with AI</DrawerTitle>
        </DrawerHeader>
        <AiReplyForm threadId={threadId} onResult={onResult} onClose={() => onOpenChange(false)} compact />
      </DrawerContent>
    </Drawer>
  );
}

/* ---------- summary ---------- */

const summaryCache = new Map<string, string>();

export function useThreadSummary(threadId: string) {
  const { summarize } = useAiMutations();
  const [summary, setSummary] = useState<string | null>(() => summaryCache.get(threadId) ?? null);
  const run = () =>
    summarize.mutate(threadId, {
      onSuccess: (r) => { summaryCache.set(threadId, r.summary); setSummary(r.summary); },
      onError: (e) => toast.error((e as Error).message),
    });
  return { summary, run, pending: summarize.isPending, clear: () => { summaryCache.delete(threadId); setSummary(null); } };
}

export function AiSummaryPanel({ summary, onClose, className }: { summary: string; onClose: () => void; className?: string }) {
  const [open, setOpen] = useState(true);
  const lines = summary.split("\n").map((l) => l.trim()).filter(Boolean);
  return (
    <div className={cn("rounded-lg bg-muted/50 px-3 py-2 mb-4", className)}>
      <button type="button" onClick={() => setOpen((o) => !o)} className="w-full flex items-center gap-2 text-[13px] font-medium h-7">
        <Sparkles className="size-3.5 text-muted-foreground" /> Summary
        <span className="flex-1" />
        {open ? <ChevronUp className="size-3.5 text-muted-foreground" /> : <ChevronDown className="size-3.5 text-muted-foreground" />}
      </button>
      {open && (
        <div className="pb-1">
          <ul className="space-y-1 pl-4 list-disc marker:text-muted-foreground text-[13px] leading-5">
            {lines.map((l, i) => <li key={i}>{l.replace(/^[-*•]\s*/, "")}</li>)}
          </ul>
          <button type="button" onClick={onClose} className="mt-2 text-[11px] text-muted-foreground hover:text-foreground">Hide</button>
        </div>
      )}
    </div>
  );
}
