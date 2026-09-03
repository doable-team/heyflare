import { useState } from "react";
import { Link } from "react-router-dom";
import { FolderOpen, Paperclip, MessagesSquare, Plus } from "lucide-react";
import { toast } from "sonner";
import type { Collection } from "@shared/types";
import { useCollectionMutations, useCollections } from "../api";
import { EmptyState, ErrorState, PageHeader, SkeletonRows } from "../components/EmptyState";
import { fmtRelative } from "../lib/format";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { useCardScroll } from "../lib/cardKeys";

function CollectionRow({ c }: { c: Collection }) {
  return (
    <Link to={`/collections/${c.id}`} className="group grid grid-cols-[20px_minmax(0,1fr)_auto] items-center gap-3 rounded-md px-2 h-11 hover:bg-muted transition-colors duration-100">
      <FolderOpen size={16} className="text-muted-foreground" />
      <div className="min-w-0 flex items-baseline gap-2">
        <span className="text-sm font-medium truncate">{c.name}</span>
        {c.description && <span className="text-[13px] text-muted-foreground truncate hidden sm:inline">{c.description}</span>}
      </div>
      <div className="flex items-center gap-3 text-xs text-muted-foreground tnum">
        <span className="inline-flex items-center gap-1"><MessagesSquare size={12} /> {c.thread_count}</span>
        <span className="inline-flex items-center gap-1"><Paperclip size={12} /> {c.file_count}</span>
        <span className="hidden sm:inline w-20 text-right">{fmtRelative(c.updated_at)}</span>
      </div>
    </Link>
  );
}

export function NewCollectionModal({ open, onClose, onCreated }: { open: boolean; onClose: () => void; onCreated?: (c: Collection) => void }) {
  const { create } = useCollectionMutations();
  const [name, setName] = useState("");
  const [desc, setDesc] = useState("");
  const close = () => { onClose(); setName(""); setDesc(""); };
  return (
    <Dialog open={open} onOpenChange={(o) => !o && close()}>
      <DialogContent className="sm:max-w-md">
        <form
          onSubmit={(e) => {
            e.preventDefault();
            if (!name.trim()) return;
            create.mutate({ name: name.trim(), description: desc.trim() }, { onSuccess: (c) => { close(); onCreated?.(c); }, onError: (er) => toast.error((er as Error).message) });
          }}
        >
          <DialogHeader>
            <DialogTitle>New collection</DialogTitle>
            <DialogDescription>A project, a trip, a house move — anything with a lot of email around it.</DialogDescription>
          </DialogHeader>
          <FieldGroup className="my-5">
            <Field>
              <FieldLabel htmlFor="col-name">Name</FieldLabel>
              <Input id="col-name" autoFocus placeholder="Kitchen renovation" value={name} onChange={(e) => setName(e.target.value)} />
            </Field>
            <Field>
              <FieldLabel htmlFor="col-desc">What's it for?</FieldLabel>
              <Textarea id="col-desc" placeholder="Quotes, contractor threads, the permit saga…" rows={3} value={desc} onChange={(e) => setDesc(e.target.value)} />
              <FieldDescription>Optional.</FieldDescription>
            </Field>
          </FieldGroup>
          <DialogFooter>
            <Button type="button" variant="ghost" onClick={close}>Cancel</Button>
            <Button type="submit" disabled={!name.trim() || create.isPending}>Create</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

export default function Collections() {
  useCardScroll();
  const q = useCollections();
  const [open, setOpen] = useState(false);
  const list = q.data ?? [];
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader
        title="Collections"
        subtitle="Bundle related threads and files into one tidy place."
        actions={
          <Button variant="ghost" size="sm" onClick={() => setOpen(true)} className="text-muted-foreground">
            <Plus /> New
          </Button>
        }
      />
      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && <SkeletonRows rows={4} compact />}
      {!q.isLoading && list.length === 0 && !q.error && (
        <EmptyState
          icon={<FolderOpen />}
          title="No collections yet."
          body="Gather every thread and attachment about one thing, so you stop hunting across your mail."
          action={<Button variant="outline" size="sm" onClick={() => setOpen(true)}><Plus /> Start one</Button>}
        />
      )}
      <div>
        {list.map((c) => (
          <CollectionRow key={c.id} c={c} />
        ))}
      </div>
      <NewCollectionModal open={open} onClose={() => setOpen(false)} />
    </div>
  );
}
