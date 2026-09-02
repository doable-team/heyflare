import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { ArrowUpCircle, Bookmark, Clock, Download, FileText, FolderOpen, Forward, GitMerge, Inbox, Mail, MoreHorizontal, Paperclip, Pencil, Pin, Reply, ReplyAll, Rss, Scissors, StickyNote, Tag, Trash2, X, Layers } from "lucide-react";
import { toast } from "sonner";
import type { Message } from "@shared/types";
import { cn } from "@/lib/utils";
import { attachmentUrl, useClipMutations, useThread, useThreadAction } from "../api";
import { useAccount } from "../context/AccountContext";
import { useCompose } from "../context/ComposeContext";
import { HtmlBody } from "../components/HtmlBody";
import { fileIcon } from "../components/Composer";
import { DateTimePicker } from "../components/DatePicker";
import { CollectionPicker, LabelChip, LabelPicker, ThreadPicker } from "../components/Pickers";
import { bucketName } from "../components/BulkBar";
import { Avatar, AvatarStack, AccountGlyph } from "../components/Avatar";
import { ErrorState } from "../components/EmptyState";
import { replyInitial, type ReplyMode } from "../pages/Thread";
import { fmtRelative, fmtSize, fmtTime } from "../lib/format";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { Drawer, DrawerContent, DrawerDescription, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Screen } from "./Screen";
import { ActionSheet } from "./ActionSheet";

const BAR_H = 56;

function MessageBlock({ m, expanded, onToggle, onClip }: { m: Message; expanded: boolean; onToggle: () => void; onClip: (t: string) => void }) {
  const [mounted, setMounted] = useState(expanded);
  useEffect(() => {
    if (expanded) setMounted(true);
  }, [expanded]);
  const files = m.attachments.filter((a) => !a.is_inline);
  const who = m.is_from_me ? "You" : m.from.name || m.from.email;
  return (
    <article className="px-4">
      <button type="button" onClick={onToggle} className="w-full flex items-start gap-3 py-3 text-left active:bg-muted -mx-4 px-4">
        <Avatar email={m.from.email} name={m.from.name} src={m.from.avatar_url} size={36} strong={m.unread} />
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-1.5 min-w-0">
            <span className={cn("text-[15px] truncate", m.unread ? "font-semibold" : "font-medium")}>{who}</span>
            {m.unread && <span className="size-1.5 rounded-full bg-foreground" />}
            <span className="flex-1" />
            <span className="text-[12px] text-muted-foreground tnum shrink-0">{fmtTime(m.date)}</span>
          </div>
          <div className="text-[13px] text-muted-foreground truncate">{expanded ? `to ${m.to.map((a) => a.name || a.email).join(", ") || "—"}${m.cc.length ? ` · cc ${m.cc.map((a) => a.name || a.email).join(", ")}` : ""}` : m.snippet}</div>
        </div>
      </button>
      {expanded && mounted && (
        <div className="pb-4">
          <HtmlBody html={m.html_body} text={m.text_body} trackers={m.trackers} onClip={onClip} />
          {files.length > 0 && (
            <div className="mt-4">
              <div className="text-[12px] text-muted-foreground mb-1.5 flex items-center gap-1.5">
                <Paperclip size={12} /> {files.length} attachment{files.length === 1 ? "" : "s"}
              </div>
              <div className="space-y-1.5">
                {files.map((a) => (
                  <a key={a.id} href={attachmentUrl(a.message_id, a.id)} target="_blank" rel="noopener" className="flex items-center gap-3 rounded-lg bg-muted/50 active:bg-muted px-3 h-14">
                    <span className="text-muted-foreground [&>svg]:size-5">{fileIcon(a.mime_type, a.filename)}</span>
                    <span className="flex-1 min-w-0">
                      <span className="block text-[14px] truncate">{a.filename || "attachment"}</span>
                      <span className="block text-[12px] text-muted-foreground tnum">{fmtSize(a.size)}</span>
                    </span>
                    <a href={attachmentUrl(a.message_id, a.id, true)} aria-label="Download" className="size-10 flex items-center justify-center text-muted-foreground" onClick={(e) => e.stopPropagation()}>
                      <Download size={18} />
                    </a>
                  </a>
                ))}
              </div>
            </div>
          )}
        </div>
      )}
    </article>
  );
}

const bucketIcon = { imbox: <Inbox />, feed: <Rss />, paper_trail: <FileText /> } as const;

export default function MobileThread() {
  const { id = "" } = useParams();
  const [sp] = useSearchParams();
  const peek = sp.get("peek") === "1";
  const nav = useNavigate();
  const { accountFor, glyphFor, multi } = useAccount();
  const { openCompose } = useCompose();
  const q = useThread(id, peek);
  const act = useThreadAction(id);
  const clips = useClipMutations();
  const t = q.data;
  const account = accountFor(t?.account_id);

  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [more, setMore] = useState(false);
  const [bubble, setBubble] = useState(false);
  const [rename, setRename] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [labelsOpen, setLabelsOpen] = useState(false);
  const [collOpen, setCollOpen] = useState(false);
  const [mergeOpen, setMergeOpen] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);

  useEffect(() => {
    if (!t) return;
    setExpanded((prev) => {
      if (prev.size) return prev;
      const s = new Set<string>();
      const last = t.messages[t.messages.length - 1];
      if (last) s.add(last.id);
      for (const m of t.messages) if (m.unread) s.add(m.id);
      return s;
    });
  }, [t]);

  const lastIncoming = useMemo(() => (t ? [...t.messages].reverse().find((m) => !m.is_from_me) ?? t.messages[t.messages.length - 1] : undefined), [t]);
  const run = (a: Parameters<typeof act.mutate>[0], msg?: string) => act.mutate(a, { onSuccess: () => msg && toast(msg), onError: (e) => toast.error((e as Error).message) });
  const reply = (mode: ReplyMode) => t && lastIncoming && openCompose(replyInitial(t, lastIncoming, mode, account?.email));

  if (q.error)
    return (
      <Screen title="Thread" back tabs={false}>
        <ErrorState error={q.error} onRetry={() => q.refetch()} />
      </Screen>
    );
  if (!t)
    return (
      <Screen title="" back tabs={false}>
        <div className="px-4 pt-2 space-y-3">
          <Skeleton className="h-7 w-3/4" />
          <Skeleton className="h-4 w-1/3" />
          <Skeleton className="h-24 w-full mt-6" />
          <Skeleton className="h-48 w-full" />
        </div>
      </Screen>
    );

  const renamed = !!t.subject && t.subject !== t.original_subject;
  const others = t.participants.filter((p) => p.email.toLowerCase() !== (account?.email ?? "").toLowerCase());
  const names = (others.length ? others : t.participants).map((p) => p.name?.trim()?.split(" ")[0] || p.email);

  return (
    <Screen
      title={t.subject || "(no subject)"}
      titleOnScroll
      back
      tabs={false}
      bottomInset={BAR_H}
      right={
        <Button variant="ghost" size="icon" aria-label="More" className="size-10 text-foreground" onClick={() => setMore(true)}>
          <MoreHorizontal />
        </Button>
      }
    >
      <div className="px-4 pt-2">
        <h1 className="text-[22px] leading-7 font-bold tracking-[-0.02em] break-words">{t.subject || <span className="text-tertiary">(no subject)</span>}</h1>
        {renamed && <div className="text-[12px] text-muted-foreground mt-0.5">originally “{t.original_subject}”</div>}
        <div className="flex items-center gap-2 mt-2 flex-wrap text-[13px]">
          <AvatarStack people={t.participants} size={20} max={4} />
          <span className="text-foreground/80 truncate">{names.slice(0, 3).join(", ")}{names.length > 3 ? ` +${names.length - 3}` : ""}</span>
          <span className="text-muted-foreground tnum">· {t.message_count}</span>
          {multi && account && <span className="inline-flex items-center gap-1 text-[12px] text-muted-foreground"><AccountGlyph glyph={glyphFor(account.id)} /> {account.email.split("@")[0]}</span>}
        </div>
        <div className="flex items-center gap-1.5 mt-2 flex-wrap">
          {t.bucket !== "imbox" && t.bucket !== "trash" && <Badge variant="outline" className="font-normal text-muted-foreground">{bucketName(t.bucket)}</Badge>}
          {t.bucket === "trash" && <Badge variant="outline" className="font-normal text-muted-foreground"><Trash2 />Trash</Badge>}
          {t.reply_later && <Badge variant="secondary" className="font-normal"><Clock />Reply later</Badge>}
          {t.set_aside && <Badge variant="secondary" className="font-normal"><Bookmark />Set aside</Badge>}
          {t.bubble_up_at && <Badge variant="secondary" className="font-normal"><ArrowUpCircle />Bubbles up {fmtRelative(t.bubble_up_at)}</Badge>}
          {t.labels.map((l) => <LabelChip key={l.id} label={l} />)}
          {t.collections.map((c) => <Badge key={c.id} variant="outline" className="font-normal"><FolderOpen />{c.name}</Badge>)}
        </div>
        {t.note && (
          <button type="button" onClick={() => setNote(t.note)} className="mt-3 w-full text-left rounded-lg bg-muted px-3 py-2.5 flex items-start gap-2">
            <Pin size={14} className="text-muted-foreground mt-0.5 shrink-0" />
            <span className="text-[14px] leading-relaxed whitespace-pre-wrap flex-1">{t.note}</span>
          </button>
        )}
        {t.clips.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-1.5">
            {t.clips.map((c) => (
              <Badge key={c.id} variant="secondary" className="max-w-full font-normal h-7 pr-1">
                <Scissors className="text-muted-foreground" />
                <span className="truncate max-w-56">“{c.text}”</span>
                <button type="button" aria-label="Delete clip" className="size-6 flex items-center justify-center text-muted-foreground" onClick={() => clips.remove.mutate(c.id, { onSuccess: () => toast("Clip removed") })}>
                  <X size={12} />
                </button>
              </Badge>
            ))}
          </div>
        )}
      </div>

      <div className="mt-3 divide-y divide-border">
        {t.messages.map((m) => (
          <MessageBlock
            key={m.id}
            m={m}
            expanded={expanded.has(m.id)}
            onToggle={() =>
              setExpanded((s) => {
                const n = new Set(s);
                if (n.has(m.id)) n.delete(m.id);
                else n.add(m.id);
                return n;
              })
            }
            onClip={(text) => clips.create.mutate({ thread_id: t.id, message_id: m.id, text }, { onSuccess: () => toast("Clip saved") })}
          />
        ))}
      </div>
      {t.merged_threads.length > 0 && (
        <div className="px-4 py-3 text-[12px] text-muted-foreground flex items-center gap-1.5">
          <GitMerge size={12} /> Includes merged: {t.merged_threads.map((m) => m.subject).join(", ")}
        </div>
      )}

      {/* docked action bar */}
      <div className="fixed inset-x-0 bottom-0 z-40 bg-background/95 backdrop-blur border-t border-border pb-safe">
        <div className="flex items-center gap-1 px-2" style={{ height: BAR_H }}>
          <Button className="h-10 rounded-full px-4 text-[15px]" onClick={() => reply("reply")}>
            <Reply /> Reply
          </Button>
          <span className="flex-1" />
          <Button variant="ghost" size="icon" aria-label="Reply later" className={cn("size-11 text-muted-foreground", t.reply_later && "bg-muted text-foreground")} onClick={() => run({ action: "reply_later", on: !t.reply_later }, t.reply_later ? "Removed from Reply Later" : "Added to Reply Later")}>
            <Clock className="size-5!" />
          </Button>
          <Button variant="ghost" size="icon" aria-label="Set aside" className={cn("size-11 text-muted-foreground", t.set_aside && "bg-muted text-foreground")} onClick={() => run({ action: "set_aside", on: !t.set_aside }, t.set_aside ? "Removed from Set Aside" : "Set aside")}>
            <Bookmark className="size-5!" />
          </Button>
          <Button variant="ghost" size="icon" aria-label="Bubble up" className={cn("size-11 text-muted-foreground", t.bubble_up_at && "bg-muted text-foreground")} onClick={() => setBubble(true)}>
            <ArrowUpCircle className="size-5!" />
          </Button>
          <Button variant="ghost" size="icon" aria-label="More" className="size-11 text-muted-foreground" onClick={() => setMore(true)}>
            <MoreHorizontal className="size-5!" />
          </Button>
        </div>
      </div>

      <ActionSheet
        open={more}
        onOpenChange={setMore}
        actions={[
          { icon: <ReplyAll />, label: "Reply all", onSelect: () => reply("replyAll") },
          { icon: <Forward />, label: "Forward", onSelect: () => reply("forward") },
          ...(["imbox", "feed", "paper_trail"] as const).filter((b) => b !== t.bucket).map((b) => ({ icon: bucketIcon[b], label: `Move to ${bucketName(b)}`, onSelect: () => run({ action: "move", bucket: b }, `Moved to ${bucketName(b)}`) })),
          { icon: <Pencil />, label: "Rename subject", onSelect: () => setRename(t.subject) },
          { icon: <StickyNote />, label: t.note ? "Edit note" : "Stick a note on it", onSelect: () => setNote(t.note) },
          { icon: <Tag />, label: "Labels", onSelect: () => setLabelsOpen(true) },
          { icon: <FolderOpen />, label: "Collections", onSelect: () => setCollOpen(true) },
          { icon: <GitMerge />, label: "Merge with…", onSelect: () => setMergeOpen(true) },
          ...(t.bucket === "imbox" || t.bucket === "paper_trail" ? [{ icon: <Layers />, label: t.sender_bundled ? "Unbundle sender" : "Bundle up sender", onSelect: () => run({ action: "bundle", on: !t.sender_bundled }, t.sender_bundled ? "Unbundled sender" : "Bundled up sender") }] : []),
          { icon: <Mail />, label: "Mark unread", onSelect: () => run({ action: "mark_unread" }, "Marked unread") },
          ...(t.bucket !== "trash" ? [{ icon: <Trash2 />, label: "Trash", onSelect: () => { run({ action: "move", bucket: "trash" }, "Moved to trash"); nav(-1); } }] : []),
          { icon: <Trash2 />, label: "Delete forever", destructive: true, onSelect: () => setConfirmDelete(true) },
        ]}
      />

      <Drawer open={bubble} onOpenChange={setBubble}>
        <DrawerContent className="pb-safe">
          <DrawerHeader className="pb-0">
            <DrawerTitle>Bubble up</DrawerTitle>
            <DrawerDescription>Out of sight until the moment you pick.</DrawerDescription>
          </DrawerHeader>
          <div className="px-2 pb-2 max-h-[70vh] overflow-y-auto">
            <DateTimePicker embedded onPick={(at) => { setBubble(false); run({ action: "bubble_up", at }, `Will bubble up ${fmtRelative(at)}`); }} onCancel={() => setBubble(false)} />
            {t.bubble_up_at && (
              <Button variant="ghost" className="w-full justify-start h-12 text-muted-foreground" onClick={() => { setBubble(false); run({ action: "bubble_up", at: null }, "Bubble up cancelled"); }}>
                <X /> Cancel bubble up
              </Button>
            )}
          </div>
        </DrawerContent>
      </Drawer>

      <Drawer open={rename !== null} onOpenChange={(o) => !o && setRename(null)}>
        <DrawerContent className="pb-safe">
          <DrawerHeader className="pb-1 text-left">
            <DrawerTitle>Rename subject</DrawerTitle>
            <DrawerDescription>Only you see this name.</DrawerDescription>
          </DrawerHeader>
          <form className="px-4 pb-4 space-y-3" onSubmit={(e) => { e.preventDefault(); const s = (rename ?? "").trim(); run({ action: "rename", subject: s && s !== t.original_subject ? s : null }, s ? "Renamed" : "Name restored"); setRename(null); }}>
            <input autoFocus value={rename ?? ""} onChange={(e) => setRename(e.target.value)} placeholder={t.original_subject} className="w-full h-11 rounded-lg bg-muted px-3 text-[16px] outline-none" />
            <Button type="submit" size="lg" className="w-full h-11">Save</Button>
          </form>
        </DrawerContent>
      </Drawer>

      <Drawer open={note !== null} onOpenChange={(o) => !o && setNote(null)}>
        <DrawerContent className="pb-safe">
          <DrawerHeader className="pb-1 text-left">
            <DrawerTitle>Note</DrawerTitle>
            <DrawerDescription>A private note, just for you.</DrawerDescription>
          </DrawerHeader>
          <div className="px-4 pb-4 space-y-3">
            <Textarea autoFocus value={note ?? ""} onChange={(e) => setNote(e.target.value)} className="min-h-28 text-[16px]" placeholder="Phone numbers, reminders, context…" />
            <div className="flex gap-2">
              {t.note && (
                <Button variant="outline" size="lg" className="h-11" onClick={() => { run({ action: "note", note: "" }, "Note removed"); setNote(null); }}>
                  Remove
                </Button>
              )}
              <Button size="lg" className="h-11 flex-1" onClick={() => { run({ action: "note", note: note ?? "" }, "Note saved"); setNote(null); }}>
                Save note
              </Button>
            </div>
          </div>
        </DrawerContent>
      </Drawer>

      <Drawer open={labelsOpen} onOpenChange={setLabelsOpen}>
        <DrawerContent className="pb-safe">
          <DrawerTitle className="sr-only">Labels</DrawerTitle>
          <DrawerDescription className="sr-only">Toggle labels on this thread</DrawerDescription>
          <div className="p-2 max-h-[70vh] overflow-y-auto">
            <LabelPicker current={new Set(t.labels.map((l) => l.id))} onToggle={(lid, on) => run({ action: "labels", ...(on ? { add: [lid] } : { remove: [lid] }) })} onClose={() => setLabelsOpen(false)} />
          </div>
        </DrawerContent>
      </Drawer>
      <Drawer open={collOpen} onOpenChange={setCollOpen}>
        <DrawerContent className="pb-safe">
          <DrawerTitle className="sr-only">Collections</DrawerTitle>
          <DrawerDescription className="sr-only">Add this thread to collections</DrawerDescription>
          <div className="p-2 max-h-[70vh] overflow-y-auto">
            <CollectionPicker current={new Set(t.collections.map((c) => c.id))} onToggle={(cid, on) => run({ action: "collections", ...(on ? { add: [cid] } : { remove: [cid] }) })} onClose={() => setCollOpen(false)} />
          </div>
        </DrawerContent>
      </Drawer>
      <Drawer open={mergeOpen} onOpenChange={setMergeOpen}>
        <DrawerContent className="pb-safe">
          <DrawerHeader className="pb-0 text-left">
            <DrawerTitle>Merge into this thread</DrawerTitle>
            <DrawerDescription>Fold another conversation into this one.</DrawerDescription>
          </DrawerHeader>
          <div className="p-2 max-h-[70vh] overflow-y-auto">
            <ThreadPicker exclude={[t.id]} onPick={(other) => { setMergeOpen(false); run({ action: "merge", thread_ids: [other.id] }, `Merged “${other.subject}”`); }} />
          </div>
        </DrawerContent>
      </Drawer>

      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent size="sm">
          <AlertDialogHeader>
            <AlertDialogTitle>Delete this thread forever?</AlertDialogTitle>
            <AlertDialogDescription>It'll be removed here and trashed in {account?.provider === "domain" ? "your mailbox" : "Gmail"}. There's no undo.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => { run({ action: "delete" }, "Deleted"); nav("/"); }}>Delete forever</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Screen>
  );
}
