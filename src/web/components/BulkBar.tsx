import { useState } from "react";
import { ArrowUpCircle, Bookmark, Clock, FolderPlus, GitMerge, Mail, MailOpen, MoveRight, Tag, Trash2, X, Inbox, Rss, FileText, Loader2 } from "lucide-react";
import type { Bucket, ThreadSummary } from "@shared/types";
import { useQueryClient } from "@tanstack/react-query";
import { api, invalidateMail, useBulkAction, type ThreadAction } from "../api";
import { useToast } from "./Toast";
import { DateTimePicker } from "./DatePicker";
import { CollectionPicker, LabelPicker } from "./Pickers";
import { Button } from "@/components/ui/button";
import { Kbd } from "@/components/ui/kbd";
import { Separator } from "@/components/ui/separator";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

export function bucketName(b: Bucket | string): string {
  return { imbox: "Imbox", feed: "The Feed", paper_trail: "Paper Trail", trash: "Trash", screener: "Screener", screened_out: "Screened out" }[b] ?? b;
}

function IconAct({ label, kbd, icon, onClick }: { label: string; kbd?: string; icon: React.ReactNode; onClick?: () => void }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button variant="ghost" size="icon-sm" aria-label={label} onClick={onClick} className="text-muted-foreground hover:text-foreground">
          {icon}
        </Button>
      </TooltipTrigger>
      <TooltipContent>
        {label} {kbd && <Kbd className="ml-1">{kbd}</Kbd>}
      </TooltipContent>
    </Tooltip>
  );
}

/** Sticky, borderless context bar shown while threads are selected. */
export function BulkBar({
  selected,
  threads,
  onClear,
  onAct,
}: {
  selected: Set<string>;
  threads: ThreadSummary[];
  onClear: () => void;
  onAct?: (a: ThreadAction, msg?: string, removes?: boolean) => void;
}) {
  const ids = [...selected];
  const bulk = useBulkAction();
  const qc = useQueryClient();
  const { toast } = useToast();
  const [busy, setBusy] = useState(false);
  const [bubble, setBubble] = useState(false);
  const [labels, setLabels] = useState(false);
  const [collect, setCollect] = useState(false);
  const sel = threads.filter((t) => selected.has(t.id));
  const allRead = sel.every((t) => !t.unread);
  const commonLabels = new Set(sel.length ? sel[0].labels.map((l) => l.id).filter((id) => sel.every((t) => t.labels.some((l) => l.id === id))) : []);

  const run = (a: ThreadAction, msg?: string, removes = true) => {
    if (onAct) return onAct(a, msg, removes);
    bulk.mutate({ thread_ids: ids, ...a }, {
      onSuccess: () => msg && toast(msg, { kind: "success" }),
      onError: (e) => toast((e as Error).message, { kind: "error" }),
    });
    onClear();
  };

  const merge = async () => {
    if (ids.length < 2) return;
    setBusy(true);
    try {
      const sorted = [...sel].sort((a, b) => b.last_message_at - a.last_message_at);
      const target = sorted[0];
      await api.post(`/api/threads/${target.id}/actions`, { action: "merge", thread_ids: sorted.slice(1).map((t) => t.id) });
      invalidateMail(qc);
      toast(`Merged ${ids.length} threads`, { kind: "success" });
      onClear();
    } catch (e) {
      toast((e as Error).message, { kind: "error" });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="sticky top-11 z-20 -mx-2 px-2 mb-1 h-10 flex items-center gap-0.5 bg-background/90 backdrop-blur border-b overflow-x-auto">
      <IconAct label="Clear selection" kbd="esc" icon={<X />} onClick={onClear} />
      <span className="text-[13px] font-medium px-1 tnum whitespace-nowrap">{ids.length} selected</span>
      <Separator orientation="vertical" className="mx-1 !h-4" />
      <IconAct label={allRead ? "Mark unread" : "Mark read"} kbd="u" icon={allRead ? <Mail /> : <MailOpen />} onClick={() => run({ action: allRead ? "mark_unread" : "mark_read" }, undefined, false)} />
      <IconAct label="Reply later" kbd="l" icon={<Clock />} onClick={() => run({ action: "reply_later", on: true }, "Added to Reply Later")} />
      <IconAct label="Set aside" kbd="a" icon={<Bookmark />} onClick={() => run({ action: "set_aside", on: true }, "Set aside")} />
      <Popover open={bubble} onOpenChange={setBubble}>
        <PopoverTrigger asChild>
          <span><IconAct label="Bubble up" kbd="z" icon={<ArrowUpCircle />} /></span>
        </PopoverTrigger>
        <PopoverContent align="start" className="w-auto p-0">
          <DateTimePicker onPick={(at) => { setBubble(false); run({ action: "bubble_up", at }, "Will bubble up later"); }} onCancel={() => setBubble(false)} />
        </PopoverContent>
      </Popover>
      <Separator orientation="vertical" className="mx-1 !h-4" />
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="sm" className="text-muted-foreground hover:text-foreground"><MoveRight /> Move</Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start">
          {([["imbox", <Inbox key="i" />], ["feed", <Rss key="f" />], ["paper_trail", <FileText key="p" />]] as [Bucket, React.ReactNode][]).map(([b, icon]) => (
            <DropdownMenuItem key={b} onClick={() => run({ action: "move", bucket: b }, `Moved to ${bucketName(b)}`)}>
              {icon}
              {bucketName(b)}
            </DropdownMenuItem>
          ))}
        </DropdownMenuContent>
      </DropdownMenu>
      <Popover open={labels} onOpenChange={setLabels}>
        <PopoverTrigger asChild>
          <Button variant="ghost" size="sm" className="text-muted-foreground hover:text-foreground"><Tag /> Label</Button>
        </PopoverTrigger>
        <PopoverContent align="start" className="w-auto p-0">
          <LabelPicker current={commonLabels} onToggle={(id, on) => bulk.mutate({ thread_ids: ids, action: "labels", ...(on ? { add: [id] } : { remove: [id] }) })} onClose={() => setLabels(false)} />
        </PopoverContent>
      </Popover>
      <Popover open={collect} onOpenChange={setCollect}>
        <PopoverTrigger asChild>
          <Button variant="ghost" size="sm" className="text-muted-foreground hover:text-foreground"><FolderPlus /> Collect</Button>
        </PopoverTrigger>
        <PopoverContent align="start" className="w-auto p-0">
          <CollectionPicker current={new Set()} onToggle={(id, on) => bulk.mutate({ thread_ids: ids, action: "collections", ...(on ? { add: [id] } : { remove: [id] }) })} onClose={() => setCollect(false)} />
        </PopoverContent>
      </Popover>
      {ids.length >= 2 && (
        <Button variant="ghost" size="sm" onClick={merge} disabled={busy} className="text-muted-foreground hover:text-foreground">
          {busy ? <Loader2 className="animate-spin" /> : <GitMerge />} Merge
        </Button>
      )}
      <span className="flex-1" />
      <IconAct label="Trash" kbd="#" icon={<Trash2 />} onClick={() => run({ action: "move", bucket: "trash" }, "Moved to trash")} />
    </div>
  );
}
