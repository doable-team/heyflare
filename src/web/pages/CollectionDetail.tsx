import { useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { ArrowLeft, FolderOpen, MoreHorizontal, Paperclip, Pencil, Trash2, X, MessagesSquare } from "lucide-react";
import { toast } from "sonner";
import { useBulkAction, useCollection, useCollectionMutations } from "../api";
import { ErrorState, SectionTitle } from "../components/EmptyState";
import { ThreadList } from "../components/ThreadList";
import { FileTile } from "./Files";
import { fmtRelative } from "../lib/format";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Field, FieldGroup, FieldLabel } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";

export default function CollectionDetail() {
  const { id } = useParams();
  const nav = useNavigate();
  const q = useCollection(id);
  const { update, remove } = useCollectionMutations();
  const bulk = useBulkAction();
  const [edit, setEdit] = useState(false);
  const [del, setDel] = useState(false);
  const [name, setName] = useState("");
  const [desc, setDesc] = useState("");
  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  if (!q.data) {
    return (
      <div className="max-w-3xl mx-auto px-2">
        <Skeleton className="h-6 w-24 mb-6" />
        <Skeleton className="h-8 w-1/2 mb-3" />
        <Skeleton className="h-4 w-1/3 mb-8" />
        <Skeleton className="h-10 w-full mb-1" />
        <Skeleton className="h-10 w-full" />
      </div>
    );
  }
  const { collection: c, threads, files } = q.data;
  const removeThread = (tid: string, subject: string) =>
    bulk.mutate({ thread_ids: [tid], action: "collections", remove: [c.id] }, { onSuccess: () => toast(`Removed “${subject || "(no subject)"}”`), onError: (e) => toast.error((e as Error).message) });
  return (
    <div className="max-w-3xl mx-auto">
      <Button variant="ghost" size="sm" className="mb-4 text-muted-foreground" onClick={() => nav("/collections")}>
        <ArrowLeft /> Collections
      </Button>
      <header className="flex items-start gap-3 px-2 mb-6">
        <FolderOpen size={22} className="text-muted-foreground mt-1.5 shrink-0" />
        <div className="flex-1 min-w-0">
          <h1 className="text-2xl font-semibold tracking-[-0.02em] break-words">{c.name}</h1>
          {c.description && <p className="text-sm text-muted-foreground mt-1">{c.description}</p>}
          <div className="flex items-center gap-2 mt-2 flex-wrap text-xs text-muted-foreground tnum">
            <Badge variant="secondary" className="gap-1 font-normal text-muted-foreground"><MessagesSquare className="size-3" /> {threads.length} thread{threads.length === 1 ? "" : "s"}</Badge>
            <Badge variant="secondary" className="gap-1 font-normal text-muted-foreground"><Paperclip className="size-3" /> {files.length} file{files.length === 1 ? "" : "s"}</Badge>
            <span>updated {fmtRelative(c.updated_at)}</span>
          </div>
        </div>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon-sm" aria-label="More" className="text-muted-foreground"><MoreHorizontal /></Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-48">
            <DropdownMenuItem onClick={() => { setName(c.name); setDesc(c.description); setEdit(true); }}><Pencil /> Rename & describe</DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={() => setDel(true)}><Trash2 /> Delete collection</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </header>

      <section>
        <SectionTitle count={threads.length}>Threads</SectionTitle>
        <ThreadList showBucket sections={[{ threads, emptyTitle: "Nothing in here yet.", emptyBody: "Add threads from any thread's More menu, or select a few and use the bulk bar." }]} />
        {threads.length > 0 && (
          <div className="mt-2 px-2 flex flex-wrap gap-1">
            {threads.map((t) => (
              <Badge key={t.id} variant="outline" asChild>
                <button type="button" className="max-w-[260px] gap-1 font-normal text-muted-foreground hover:text-foreground" onClick={() => removeThread(t.id, t.subject)} title="Remove from collection">
                  <span className="truncate">{t.subject || "(no subject)"}</span>
                  <X className="size-3 shrink-0" />
                </button>
              </Badge>
            ))}
          </div>
        )}
      </section>

      <section className="mt-8">
        <SectionTitle count={files.length}>Files</SectionTitle>
        {files.length === 0 ? (
          <div className="px-2 py-3 text-[13px] text-muted-foreground">No attachments in these threads.</div>
        ) : (
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3 px-2">
            {files.map((f) => (
              <FileTile key={f.id} f={f} />
            ))}
          </div>
        )}
      </section>

      <Dialog open={edit} onOpenChange={setEdit}>
        <DialogContent className="sm:max-w-md">
          <form onSubmit={(e) => { e.preventDefault(); if (!name.trim()) return; update.mutate({ id: c.id, name: name.trim(), description: desc.trim() }, { onSuccess: () => setEdit(false) }); }}>
            <DialogHeader><DialogTitle>Edit collection</DialogTitle></DialogHeader>
            <FieldGroup className="my-5">
              <Field>
                <FieldLabel htmlFor="ec-name">Name</FieldLabel>
                <Input id="ec-name" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
              </Field>
              <Field>
                <FieldLabel htmlFor="ec-desc">Description</FieldLabel>
                <Textarea id="ec-desc" rows={3} value={desc} onChange={(e) => setDesc(e.target.value)} />
              </Field>
            </FieldGroup>
            <DialogFooter>
              <Button type="button" variant="ghost" onClick={() => setEdit(false)}>Cancel</Button>
              <Button type="submit" disabled={update.isPending}>Save</Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
      <AlertDialog open={del} onOpenChange={setDel}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete this collection?</AlertDialogTitle>
            <AlertDialogDescription>Threads and files stay where they are; only the grouping goes away.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => remove.mutate(c.id, { onSuccess: () => nav("/collections") })}>Delete</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
