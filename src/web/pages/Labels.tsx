import { useState } from "react";
import { Link } from "react-router-dom";
import { ArrowRight, Check, Plus, Tag, Trash2 } from "lucide-react";
import { toast } from "sonner";
import type { Label } from "@shared/types";
import { cn } from "@/lib/utils";
import { useLabelMutations, useLabels } from "../api";
import { EmptyState, ErrorState, PageHeader, SkeletonRows } from "../components/EmptyState";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useCardScroll } from "../lib/cardKeys";

/** Strictly grayscale label shades (the "color" field stores one of these). */
export const LABEL_SHADES = ["#37352f", "#5f5b54", "#7d7972", "#9b978f", "#b5b1a9", "#cfcbc3", "#e2dfd8", "#f1efe9"];

function Swatch({ color, className }: { color: string; className?: string }) {
  return <span className={cn("inline-block size-3.5 rounded-[3px] ring-1 ring-inset ring-foreground/15", className)} style={{ background: color }} />;
}

function Shades({ value, onPick }: { value: string; onPick: (c: string) => void }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      {LABEL_SHADES.map((c) => (
        <button
          key={c}
          type="button"
          aria-label={`Shade ${c}`}
          className={cn("size-6 rounded-[4px] flex items-center justify-center ring-1 ring-inset ring-foreground/15", value === c && "outline-2 outline-offset-1 outline-foreground")}
          style={{ background: c }}
          onClick={() => onPick(c)}
        >
          {value === c && <Check size={12} strokeWidth={3} className="mix-blend-difference text-white" />}
        </button>
      ))}
    </div>
  );
}

function LabelRow({ l }: { l: Label }) {
  const { update, remove } = useLabelMutations();
  const [name, setName] = useState(l.name);
  const [del, setDel] = useState(false);
  const [open, setOpen] = useState(false);
  const commit = () => {
    const n = name.trim();
    if (!n) { setName(l.name); return; }
    if (n !== l.name) update.mutate({ id: l.id, name: n }, { onError: (e) => toast.error((e as Error).message) });
  };
  return (
    <div className="group flex items-center gap-3 px-2 h-10 rounded-md hover:bg-muted transition-colors duration-100">
      <Popover open={open} onOpenChange={setOpen}>
        <Tooltip>
          <TooltipTrigger asChild>
            <PopoverTrigger asChild>
              <button type="button" className="size-6 rounded-[4px] flex items-center justify-center hover:bg-accent" aria-label="Change shade">
                <Swatch color={l.color} />
              </button>
            </PopoverTrigger>
          </TooltipTrigger>
          <TooltipContent>Shade</TooltipContent>
        </Tooltip>
        <PopoverContent align="start" className="w-auto p-2">
          <Shades value={l.color} onPick={(c) => { update.mutate({ id: l.id, color: c }); setOpen(false); }} />
        </PopoverContent>
      </Popover>
      <input
        className="flex-1 min-w-0 bg-transparent outline-none text-sm font-medium"
        value={name}
        onChange={(e) => setName(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); if (e.key === "Escape") { setName(l.name); (e.target as HTMLInputElement).blur(); } }}
        aria-label="Label name"
      />
      <Link to={`/labels/${l.id}`} className="inline-flex items-center gap-1 text-[13px] text-muted-foreground hover:text-foreground">
        Threads <ArrowRight size={12} />
      </Link>
      <Tooltip>
        <TooltipTrigger asChild>
          <Button variant="ghost" size="icon-xs" aria-label="Delete label" className="text-muted-foreground opacity-0 group-hover:opacity-100 focus-visible:opacity-100" onClick={() => setDel(true)}>
            <Trash2 />
          </Button>
        </TooltipTrigger>
        <TooltipContent>Delete</TooltipContent>
      </Tooltip>
      <AlertDialog open={del} onOpenChange={setDel}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete “{l.name}”?</AlertDialogTitle>
            <AlertDialogDescription>It comes off every thread. The threads themselves stay put.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => remove.mutate(l.id)}>Delete label</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}

export default function Labels() {
  useCardScroll();
  const q = useLabels();
  const { create } = useLabelMutations();
  const [name, setName] = useState("");
  const [color, setColor] = useState(LABEL_SHADES[0]);
  const [open, setOpen] = useState(false);
  const list = q.data ?? [];
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader title="Labels" subtitle="Light-touch tags for cross-cutting stuff. Press b on any thread to add one." />
      <form
        className="flex items-center gap-3 px-2 h-10 rounded-md bg-muted/40 mb-4"
        onSubmit={(e) => {
          e.preventDefault();
          if (!name.trim()) return;
          create.mutate({ name: name.trim(), color }, { onSuccess: () => { setName(""); setColor(LABEL_SHADES[(list.length + 1) % LABEL_SHADES.length]); }, onError: (er) => toast.error((er as Error).message) });
        }}
      >
        <Popover open={open} onOpenChange={setOpen}>
          <PopoverTrigger asChild>
            <button type="button" className="size-6 rounded-[4px] flex items-center justify-center hover:bg-accent" aria-label="Pick a shade">
              <Swatch color={color} />
            </button>
          </PopoverTrigger>
          <PopoverContent align="start" className="w-auto p-2">
            <Shades value={color} onPick={(c) => { setColor(c); setOpen(false); }} />
          </PopoverContent>
        </Popover>
        <input
          className="flex-1 min-w-0 bg-transparent outline-none text-sm placeholder:text-muted-foreground"
          placeholder="New label…"
          value={name}
          onChange={(e) => setName(e.target.value)}
          aria-label="New label name"
        />
        <Button type="submit" size="sm" variant="ghost" disabled={!name.trim() || create.isPending} className="text-muted-foreground">
          <Plus /> Add
        </Button>
      </form>
      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && <SkeletonRows rows={4} compact />}
      {!q.isLoading && list.length === 0 && !q.error && <EmptyState compact icon={<Tag />} title="No labels yet." body="Make one above." />}
      <div>
        {list.map((l) => (
          <LabelRow key={l.id} l={l} />
        ))}
      </div>
    </div>
  );
}
