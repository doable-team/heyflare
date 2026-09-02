import { useState } from "react";
import { Check, FolderOpen, Plus } from "lucide-react";
import type { Label, ThreadSummary } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCollectionMutations, useCollections, useLabelMutations, useLabels, useSearch } from "../api";
import { fmtTime } from "../lib/format";
import { Avatar } from "./Avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandSeparator } from "@/components/ui/command";
import { DropdownMenuCheckboxItem, DropdownMenuItem, DropdownMenuSeparator } from "@/components/ui/dropdown-menu";
import { Spinner } from "@/components/ui/spinner";

/** Grayscale only. */
export const LABEL_COLORS = ["#37352f", "#5c5a55", "#787774", "#9b9a97", "#b3b1ac", "#cfcdc8"];

export function LabelChip({ label, small }: { label: Label; small?: boolean }) {
  return (
    <Badge variant="outline" className={cn("font-normal text-foreground/90", small && "h-4 px-1.5 text-[10px]")}>
      <span className="size-1.5 rounded-full shrink-0" style={{ background: label.color }} />
      {label.name}
    </Badge>
  );
}

/** Command-style toggle list with an inline "Create" row. Shared by labels and collections. */
function TogglePicker({
  placeholder,
  items,
  current,
  loading,
  creating,
  onToggle,
  onCreate,
  onClose,
  icon,
  emptyText,
}: {
  placeholder: string;
  items: { id: string; name: string; dot?: string }[];
  current: Set<string>;
  loading?: boolean;
  creating?: boolean;
  onToggle: (id: string, on: boolean) => void;
  onCreate: (name: string) => void;
  onClose?: () => void;
  icon?: React.ReactNode;
  emptyText: string;
}) {
  const [q, setQ] = useState("");
  const exact = items.some((i) => i.name.toLowerCase() === q.trim().toLowerCase());
  return (
    <Command className="w-64" loop>
      <CommandInput placeholder={placeholder} value={q} onValueChange={setQ} />
      <CommandList className="max-h-64">
        {loading ? (
          <div className="flex items-center justify-center py-6 text-muted-foreground"><Spinner /></div>
        ) : (
          <>
            <CommandEmpty>{q.trim() ? "No matches." : emptyText}</CommandEmpty>
            <CommandGroup>
              {items.map((it) => {
                const on = current.has(it.id);
                return (
                  <CommandItem key={it.id} value={it.name} onSelect={() => onToggle(it.id, !on)}>
                    {it.dot ? <span className="size-2 rounded-full shrink-0 mx-1" style={{ background: it.dot }} /> : icon}
                    <span className="flex-1 truncate">{it.name}</span>
                    <Check className={cn("size-4", on ? "opacity-100" : "opacity-0")} />
                  </CommandItem>
                );
              })}
            </CommandGroup>
            {q.trim() && !exact && (
              <>
                <CommandSeparator />
                <CommandGroup forceMount>
                  <CommandItem value={`create-${q}`} forceMount onSelect={() => { onCreate(q.trim()); setQ(""); }} disabled={creating}>
                    {creating ? <Spinner /> : <Plus />}
                    <span className="truncate">Create “{q.trim()}”</span>
                  </CommandItem>
                </CommandGroup>
              </>
            )}
          </>
        )}
      </CommandList>
      {onClose && (
        <div className="flex justify-end border-t border-border p-1">
          <Button variant="ghost" size="xs" className="text-muted-foreground" onClick={onClose}>Done</Button>
        </div>
      )}
    </Command>
  );
}

/** Toggle labels for a set of threads. `current` = label ids applied to all selected threads. */
export function LabelPicker({ current, onToggle, onClose }: { current: Set<string>; onToggle: (id: string, on: boolean) => void; onClose?: () => void }) {
  const labels = useLabels();
  const { create } = useLabelMutations();
  const list = labels.data ?? [];
  return (
    <TogglePicker
      placeholder="Label…"
      items={list.map((l) => ({ id: l.id, name: l.name, dot: l.color }))}
      current={current}
      loading={labels.isLoading}
      creating={create.isPending}
      onToggle={onToggle}
      onCreate={(n) => create.mutate({ name: n, color: LABEL_COLORS[list.length % LABEL_COLORS.length] }, { onSuccess: (l) => onToggle(l.id, true) })}
      onClose={onClose}
      emptyText="No labels yet. Type to make one."
    />
  );
}

export function CollectionPicker({ current, onToggle, onClose }: { current: Set<string>; onToggle: (id: string, on: boolean) => void; onClose?: () => void }) {
  const cols = useCollections();
  const { create } = useCollectionMutations();
  const list = cols.data ?? [];
  return (
    <TogglePicker
      placeholder="Collection…"
      items={list.map((c) => ({ id: c.id, name: c.name }))}
      current={current}
      loading={cols.isLoading}
      creating={create.isPending}
      onToggle={onToggle}
      onCreate={(n) => create.mutate({ name: n }, { onSuccess: (c) => onToggle(c.id, true) })}
      onClose={onClose}
      icon={<FolderOpen className="text-muted-foreground" />}
      emptyText="No collections yet. Type to start one."
    />
  );
}

/** Checkbox items for use inside a DropdownMenuSubContent. */
export function LabelMenuItems({ current, onToggle, onManage }: { current: Set<string>; onToggle: (id: string, on: boolean) => void; onManage?: () => void }) {
  const labels = useLabels();
  const list = labels.data ?? [];
  return (
    <>
      {list.length === 0 && <DropdownMenuItem disabled>No labels yet</DropdownMenuItem>}
      {list.map((l) => (
        <DropdownMenuCheckboxItem key={l.id} checked={current.has(l.id)} onCheckedChange={(on) => onToggle(l.id, !!on)} onSelect={(e) => e.preventDefault()}>
          <span className="size-2 rounded-full shrink-0" style={{ background: l.color }} />
          {l.name}
        </DropdownMenuCheckboxItem>
      ))}
      {onManage && (
        <>
          <DropdownMenuSeparator />
          <DropdownMenuItem onSelect={onManage}><Plus /> New label…</DropdownMenuItem>
        </>
      )}
    </>
  );
}

export function CollectionMenuItems({ current, onToggle, onManage }: { current: Set<string>; onToggle: (id: string, on: boolean) => void; onManage?: () => void }) {
  const cols = useCollections();
  const list = cols.data ?? [];
  return (
    <>
      {list.length === 0 && <DropdownMenuItem disabled>No collections yet</DropdownMenuItem>}
      {list.map((c) => (
        <DropdownMenuCheckboxItem key={c.id} checked={current.has(c.id)} onCheckedChange={(on) => onToggle(c.id, !!on)} onSelect={(e) => e.preventDefault()}>
          {c.name}
        </DropdownMenuCheckboxItem>
      ))}
      {onManage && (
        <>
          <DropdownMenuSeparator />
          <DropdownMenuItem onSelect={onManage}><Plus /> New collection…</DropdownMenuItem>
        </>
      )}
    </>
  );
}

/** Search & pick threads (used for Merge). */
export function ThreadPicker({ exclude, onPick, placeholder = "Search threads to merge…", hint = "Type to find the thread you want to fold into this one." }: { exclude: string[]; onPick: (t: ThreadSummary) => void; placeholder?: string; hint?: string }) {
  const [q, setQ] = useState("");
  const res = useSearch(q);
  const threads = (res.data?.pages.flatMap((p) => p.threads) ?? []).filter((t) => !exclude.includes(t.id));
  return (
    <Command shouldFilter={false} className="bg-transparent" loop>
      <CommandInput autoFocus placeholder={placeholder} value={q} onValueChange={setQ} />
      <CommandList className="max-h-80">
        {!q.trim() && <div className="py-8 text-center text-[13px] text-muted-foreground">{hint}</div>}
        {q.trim() && res.isFetching && threads.length === 0 && <div className="flex justify-center py-8 text-muted-foreground"><Spinner /></div>}
        {q.trim() && res.isFetched && threads.length === 0 && !res.isFetching && <div className="py-8 text-center text-[13px] text-muted-foreground">No matches.</div>}
        {threads.length > 0 && (
          <CommandGroup>
            {threads.map((t) => (
              <CommandItem key={t.id} value={t.id} onSelect={() => onPick(t)} className="h-11 gap-2.5">
                <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={20} />
                <span className="flex-1 min-w-0">
                  <span className="block text-[13px] truncate">{t.subject || "(no subject)"}</span>
                  <span className="block text-xs text-muted-foreground truncate">{t.last_from.name || t.last_from.email} · {t.snippet}</span>
                </span>
                <span className="text-xs text-muted-foreground tnum shrink-0">{fmtTime(t.last_message_at)}</span>
              </CommandItem>
            ))}
          </CommandGroup>
        )}
      </CommandList>
    </Command>
  );
}
