import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { ArrowLeft, ArrowUpCircle, Bookmark, Check, ChevronDown, ChevronsDownUp, Clock, Download, FileText, FolderOpen, Forward, GitMerge, Inbox, Mail, MoreHorizontal, Paperclip, Pencil, Pin, Reply, ReplyAll, Rss, Scissors, CalendarPlus, ScrollText, StickyNote, Tag, Trash2, X, Layers, Sparkles } from "lucide-react";
import { toast } from "sonner";
import type { Address, Message, ThreadDetail } from "@shared/types";
import { cn } from "@/lib/utils";
import { useAssistant } from "../lib/assistantStore";
import { attachmentUrl, useClipMutations, useEventFromThread, useThread, useThreadAction } from "../api";
import { useAccount } from "../context/AccountContext";
import { HtmlBody } from "../components/HtmlBody";
import { Composer, fileIcon, type ComposerInitial } from "../components/Composer";
import { DateTimePicker } from "../components/DatePicker";
import { CollectionMenuItems, LabelChip, LabelMenuItems, ThreadPicker } from "../components/Pickers";
import { bucketName } from "../components/BulkBar";
import { Avatar, AvatarStack, AccountGlyph } from "../components/Avatar";
import { ErrorState } from "../components/EmptyState";
import { useKeys } from "../lib/keys";
import { useCardScroll } from "../lib/cardKeys";
import { overlayOpen } from "../lib/focusStore";
import { escapeHtml, fmtFull, fmtRelative, fmtSize, fmtTime, textToHtml } from "../lib/format";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { ButtonGroup, ButtonGroupSeparator } from "@/components/ui/button-group";
import { Kbd } from "@/components/ui/kbd";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { AiReplyButton, AiSummaryPanel, useThreadSummary } from "../components/AiReply";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuShortcut, DropdownMenuSub, DropdownMenuSubContent, DropdownMenuSubTrigger, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Item, ItemContent, ItemDescription, ItemMedia, ItemTitle, ItemActions } from "@/components/ui/item";

export type ReplyMode = "reply" | "replyAll" | "forward";

export function replyInitial(thread: ThreadDetail, m: Message, mode: ReplyMode, myEmail?: string): ComposerInitial {
  const me = (myEmail ?? "").toLowerCase();
  const quoted = `<div>On ${fmtFull(m.date)}, ${escapeHtml(m.from.name || m.from.email)} &lt;${escapeHtml(m.from.email)}&gt; wrote:</div>${m.html_body || textToHtml(m.text_body)}`;
  const subj = thread.original_subject || thread.subject || m.subject;
  if (mode === "forward") {
    const header = `<div>---------- Forwarded message ----------<br>From: ${escapeHtml(m.from.name)} &lt;${escapeHtml(m.from.email)}&gt;<br>Date: ${fmtFull(m.date)}<br>Subject: ${escapeHtml(m.subject)}<br>To: ${escapeHtml(m.to.map((a) => a.email).join(", "))}</div><br>`;
    return { account_id: thread.account_id, thread_id: null, reply_to_message_id: null, subject: /^fwd?:/i.test(subj) ? subj : `Fwd: ${subj}`, body_html: "", quoted_html: header + (m.html_body || textToHtml(m.text_body)), title: "Forward" };
  }
  const replyTo: Address = m.reply_to ? { email: m.reply_to.toLowerCase(), name: m.from.name } : m.from;
  let to: Address[] = m.is_from_me ? m.to : [replyTo];
  let cc: Address[] = [];
  if (mode === "replyAll") {
    const seen = new Set(to.map((a) => a.email));
    const extra = [...m.to, ...m.cc].filter((a) => a.email.toLowerCase() !== me && !seen.has(a.email));
    cc = extra.filter((a, i) => extra.findIndex((b) => b.email === a.email) === i);
  }
  to = to.filter((a) => a.email.toLowerCase() !== me || m.is_from_me);
  return { account_id: thread.account_id, thread_id: thread.id, reply_to_message_id: m.id, to, cc, subject: /^re:/i.test(subj) ? subj : `Re: ${subj}`, body_html: "", quoted_html: quoted, title: mode === "replyAll" ? "Reply all" : "Reply" };
}

const modeLabel: Record<ReplyMode, string> = { reply: "Reply", replyAll: "Reply all", forward: "Forward" };

function AttachmentItem({ a }: { a: { id: string; message_id: string; filename: string; mime_type: string; size: number } }) {
  const [broken, setBroken] = useState(false);
  const isImg = a.mime_type.startsWith("image/") && !broken;
  return (
    <Item variant="muted" size="xs" className="group/att" asChild>
      <a href={attachmentUrl(a.message_id, a.id)} target="_blank" rel="noopener">
        <ItemMedia variant={isImg ? "image" : "icon"} className={cn(!isImg && "text-muted-foreground")}>
          {isImg ? <img src={attachmentUrl(a.message_id, a.id)} alt={a.filename} onError={() => setBroken(true)} loading="lazy" /> : fileIcon(a.mime_type, a.filename)}
        </ItemMedia>
        <ItemContent>
          <ItemTitle className="text-[13px] truncate">{a.filename || "attachment"}</ItemTitle>
          <ItemDescription className="text-xs tnum">{fmtSize(a.size)}</ItemDescription>
        </ItemContent>
        <ItemActions>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button asChild variant="ghost" size="icon-xs" className="text-muted-foreground opacity-0 group-hover/att:opacity-100 focus-visible:opacity-100">
                <a href={attachmentUrl(a.message_id, a.id, true)} aria-label={`Download ${a.filename}`} onClick={(e) => e.stopPropagation()}>
                  <Download />
                </a>
              </Button>
            </TooltipTrigger>
            <TooltipContent>Download</TooltipContent>
          </Tooltip>
        </ItemActions>
      </a>
    </Item>
  );
}

function MessageRow({ m, expanded, focused, index, onToggle, onReply, onClip, onMarkUnread, isLast }: { m: Message; expanded: boolean; focused: boolean; index: number; onToggle: () => void; onReply: (mode: ReplyMode, m: Message) => void; onClip: (text: string) => void; onMarkUnread: () => void; isLast: boolean }) {
  const [plain, setPlain] = useState(false);
  const [mounted, setMounted] = useState(expanded);
  useEffect(() => {
    if (expanded) setMounted(true);
  }, [expanded]);
  const files = m.attachments.filter((a) => !a.is_inline);
  const who = m.is_from_me ? "You" : m.from.name || m.from.email;
  const recipients = m.to.map((a) => a.name || a.email);
  return (
    <article
      data-msg-index={index}
      className={cn("py-3 scroll-mt-20", (!expanded || focused) && "rounded-md px-2 -mx-2", !expanded && "cursor-pointer hover:bg-muted", focused && "ring-1 ring-ring")}
      onClick={!expanded ? onToggle : undefined}
    >
      <header className="flex items-start gap-2.5">
        <Avatar email={m.from.email} name={m.from.name} src={m.from.avatar_url} size={24} strong={m.unread} className="mt-px" />
        <div className="flex-1 min-w-0 leading-tight">
          <div className="flex items-baseline gap-1.5 min-w-0 flex-wrap">
            {m.is_from_me ? (
              <span className="text-[13px] font-semibold text-foreground">You</span>
            ) : (
              <Link to={`/contacts/email/${encodeURIComponent(m.from.email)}?account=${encodeURIComponent(m.account_id)}&name=${encodeURIComponent(m.from.name ?? "")}`} className="text-[13px] font-semibold text-foreground hover:underline underline-offset-2 truncate" onClick={(e) => e.stopPropagation()}>
                {who}
              </Link>
            )}
            <span className="text-xs text-muted-foreground truncate">{m.from.email}</span>
            {m.unread && <span className="size-1.5 rounded-full bg-foreground self-center" aria-label="Unread" />}
          </div>
          <div className="text-xs text-muted-foreground truncate mt-0.5">
            {expanded ? (
              <>
                to {recipients.join(", ") || "—"}
                {m.cc.length > 0 && <> · cc {m.cc.map((a) => a.name || a.email).join(", ")}</>}
              </>
            ) : (
              m.snippet
            )}
          </div>
        </div>
        <div className="flex items-center gap-0.5 shrink-0 -mt-1">
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="xs" className="text-muted-foreground tnum font-normal" onClick={(e) => { e.stopPropagation(); onToggle(); }}>
                {fmtTime(m.date)}
              </Button>
            </TooltipTrigger>
            <TooltipContent>{fmtFull(m.date)}</TooltipContent>
          </Tooltip>
          {expanded && (
            <>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button variant="ghost" size="icon-xs" aria-label="Reply" className="hidden sm:inline-flex text-muted-foreground" onClick={() => onReply("reply", m)}>
                    <Reply />
                  </Button>
                </TooltipTrigger>
                <TooltipContent>Reply <Kbd className="ml-1">r</Kbd></TooltipContent>
              </Tooltip>
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="ghost" size="icon-xs" aria-label="More" className="text-muted-foreground" onClick={(e) => e.stopPropagation()}>
                    <MoreHorizontal />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-48">
                  <DropdownMenuItem onSelect={() => onReply("reply", m)}><Reply /> Reply <DropdownMenuShortcut>r</DropdownMenuShortcut></DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => onReply("replyAll", m)}><ReplyAll /> Reply all</DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => onReply("forward", m)}><Forward /> Forward <DropdownMenuShortcut>f</DropdownMenuShortcut></DropdownMenuItem>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem onSelect={onMarkUnread}><Mail /> Mark unread</DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => setPlain((p) => !p)}><FileText /> {plain ? "Rich text" : "Plain text"}</DropdownMenuItem>
                  {!isLast && <DropdownMenuItem onSelect={onToggle}><ChevronsDownUp /> Collapse</DropdownMenuItem>}
                </DropdownMenuContent>
              </DropdownMenu>
            </>
          )}
        </div>
      </header>
      {expanded && mounted && (
        <div className="pl-[34px] pt-3">
          <HtmlBody html={m.html_body} text={m.text_body} trackers={m.trackers} onClip={onClip} plain={plain} />
          {files.length > 0 && (
            <div className="mt-4">
              <div className="text-xs text-muted-foreground mb-1.5 flex items-center gap-1.5">
                <Paperclip size={12} /> {files.length} attachment{files.length === 1 ? "" : "s"}
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-1.5">
                {files.map((a) => (
                  <AttachmentItem key={a.id} a={a} />
                ))}
              </div>
            </div>
          )}
        </div>
      )}
    </article>
  );
}

/** Keeps a fixed element horizontally centered within the <main> column rather than the viewport. */
function useMainColumn() {
  const [pos, setPos] = useState<{ left: number; width: number } | null>(null);
  // When the floating assistant panel is open (desktop), keep the bar centred in the space it leaves free.
  const aState = useAssistant();
  const assistantOpen = aState.open && aState.mode === "float";
  const docked = aState.open && aState.mode === "dock";
  useEffect(() => {
    const main = document.querySelector("main");
    if (!main) return;
    const upd = () => {
      // `main` here is the SidebarInset (it renders a <main>); use its content box so a docked assistant's padding counts.
      const r = main.getBoundingClientRect();
      const cs = getComputedStyle(main);
      const padL = parseFloat(cs.paddingLeft) || 0;
      const padR = parseFloat(cs.paddingRight) || 0;
      const reserve = assistantOpen && window.innerWidth >= 768 ? 416 : 0;
      setPos({ left: r.left + padL, width: Math.max(320, r.width - padL - padR - reserve) });
    };
    upd();
    const ro = new ResizeObserver(upd);
    ro.observe(main);
    window.addEventListener("resize", upd);
    return () => {
      ro.disconnect();
      window.removeEventListener("resize", upd);
    };
  }, [assistantOpen, docked]);
  return pos ? { ...pos, compact: assistantOpen || docked } : pos;
}

const bucketIcon = { imbox: <Inbox />, feed: <Rss />, paper_trail: <ScrollText /> } as const;

function Bar({ label, kbd, children }: { label: string; kbd?: string; children: React.ReactElement }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>{children}</TooltipTrigger>
      <TooltipContent>
        {label} {kbd && <Kbd className="ml-1">{kbd}</Kbd>}
      </TooltipContent>
    </Tooltip>
  );
}

export default function Thread() {
  const { id = "" } = useParams();
  const [sp] = useSearchParams();
  const peek = sp.get("peek") === "1";
  const nav = useNavigate();
  const { user, accountFor, glyphFor, multi } = useAccount();
  const q = useThread(id, peek);
  const act = useThreadAction(id);
  const toEvent = useEventFromThread();
  const clips = useClipMutations();
  const t = q.data;
  const col = useMainColumn();
  const account = accountFor(t?.account_id);

  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [msgCursor, setMsgCursor] = useState(-1);
  const [reply, setReply] = useState<{ mode: ReplyMode; m: Message; key: number; body_html?: string } | null>(null);
  const summ = useThreadSummary(id ?? "");
  const [renaming, setRenaming] = useState(false);
  const [subjectDraft, setSubjectDraft] = useState("");
  const [noteOpen, setNoteOpen] = useState(false);
  const [noteDraft, setNoteDraft] = useState("");
  const [mergeOpen, setMergeOpen] = useState(false);
  const [bubbleOpen, setBubbleOpen] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const noteRef = useRef<HTMLTextAreaElement>(null);

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
    setNoteDraft(t.note);
  }, [t]);

  useEffect(() => {
    if (noteOpen) setTimeout(() => noteRef.current?.focus(), 30);
  }, [noteOpen]);

  // Nothing is focused until the first arrow press; a new thread starts over.
  useEffect(() => setMsgCursor(-1), [id]);

  const lastIncoming = useMemo(() => (t ? [...t.messages].reverse().find((m) => !m.is_from_me) ?? t.messages[t.messages.length - 1] : undefined), [t]);
  const openReply = (mode: ReplyMode, m?: Message) => {
    const msg = m ?? lastIncoming;
    if (!msg) return;
    setReply({ mode, m: msg, key: Date.now() });
    setTimeout(() => document.getElementById("reply-box")?.scrollIntoView({ behavior: "smooth", block: "nearest" }), 60);
  };

  const run = (a: Parameters<typeof act.mutate>[0], msg?: string) =>
    act.mutate(a, {
      onSuccess: () => msg && toast(msg),
      onError: (e) => toast.error((e as Error).message),
    });

  const toggleReplyLater = () => t && run({ action: "reply_later", on: !t.reply_later }, t.reply_later ? "Removed from Reply Later" : "Added to Reply Later");
  const toggleSetAside = () => t && run({ action: "set_aside", on: !t.set_aside }, t.set_aside ? "Removed from Set Aside" : "Set aside");

  useCardScroll(true, { arrows: false });

  const msgCount = t?.messages.length ?? 0;
  const moveMsg = (delta: number) => {
    if (overlayOpen() || msgCount === 0) return;
    setMsgCursor((c) => {
      const next = c < 0 ? (delta > 0 ? 0 : msgCount - 1) : Math.min(Math.max(c + delta, 0), msgCount - 1);
      requestAnimationFrame(() => document.querySelector(`[data-msg-index="${next}"]`)?.scrollIntoView({ block: "nearest" }));
      return next;
    });
  };
  const toggleFocusedMsg = () => {
    if (overlayOpen() || msgCursor < 0 || !t) return;
    const m = t.messages[msgCursor];
    if (!m) return;
    setExpanded((prev) => {
      const n = new Set(prev);
      if (n.has(m.id)) n.delete(m.id);
      else n.add(m.id);
      return n;
    });
  };

  useKeys(
    {
      ArrowDown: () => moveMsg(1),
      ArrowUp: () => moveMsg(-1),
      j: () => moveMsg(1),
      k: () => moveMsg(-1),
      Enter: toggleFocusedMsg,
      o: toggleFocusedMsg,
      r: () => openReply("reply"),
      f: () => openReply("forward"),
      l: toggleReplyLater,
      a: toggleSetAside,
      z: () => setBubbleOpen(true),
      u: () => run({ action: "mark_unread" }, "Marked unread"),
      n: () => setNoteOpen(true),
      "#": () => {
        run({ action: "move", bucket: "trash" }, "Moved to trash");
        nav(-1);
      },
      Escape: () => {
        // Let open menus/popovers/dialogs consume Escape first.
        if (document.querySelector('[role="menu"],[role="dialog"],[role="alertdialog"],[role="listbox"],[data-slot="popover-content"]')) return;
        if (reply) setReply(null);
        else nav(-1);
      },
    },
    !renaming && !noteOpen && !mergeOpen && !confirmDelete,
  );

  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  if (!t) {
    return (
      <div className="max-w-2xl mx-auto px-2">
        <Skeleton className="h-6 w-16 mb-6" />
        <Skeleton className="h-7 w-3/4 mb-3" />
        <Skeleton className="h-3.5 w-1/3 mb-8" />
        <Skeleton className="h-24 w-full mb-3" />
        <Skeleton className="h-48 w-full" />
      </div>
    );
  }

  const renamed = !!t.subject && t.subject !== t.original_subject;
  const others = t.participants.filter((p) => p.email.toLowerCase() !== (account?.email ?? "").toLowerCase());
  const names = (others.length ? others : t.participants).map((p) => p.name?.trim() || p.email);
  const replyTarget = lastIncoming ? (lastIncoming.is_from_me ? lastIncoming.to[0]?.name || lastIncoming.to[0]?.email : lastIncoming.from.name || lastIncoming.from.email) : "";
  const allExpanded = expanded.size >= t.messages.length;

  const saveRename = () => {
    const s = subjectDraft.trim();
    run({ action: "rename", subject: s && s !== t.original_subject ? s : null }, s ? "Renamed" : "Name restored");
    setRenaming(false);
  };
  const saveNote = () => {
    run({ action: "note", note: noteDraft }, "Note saved");
    setNoteOpen(false);
  };

  const meta = (
    <>
      {t.bucket !== "imbox" && t.bucket !== "trash" && (
        <Badge variant="outline" className="font-normal text-muted-foreground">{t.bucket in bucketIcon ? bucketIcon[t.bucket as keyof typeof bucketIcon] : null}{bucketName(t.bucket)}</Badge>
      )}
      {t.bucket === "trash" && <Badge variant="outline" className="font-normal text-muted-foreground"><Trash2 />Trash</Badge>}
      {t.reply_later && <Badge variant="secondary" className="font-normal"><Clock />Reply later</Badge>}
      {t.set_aside && <Badge variant="secondary" className="font-normal"><Bookmark />Set aside</Badge>}
      {t.bubble_up_at && <Badge variant="secondary" className="font-normal"><ArrowUpCircle />Bubbles up {fmtRelative(t.bubble_up_at)}</Badge>}
    </>
  );

  return (
    <div className="max-w-2xl mx-auto px-2 pb-32">
      {/* Top row */}
      <div className="flex items-center gap-2 mb-4 -ml-2">
        <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => nav(-1)}>
          <ArrowLeft /> Back <Kbd>esc</Kbd>
        </Button>
        <span className="flex-1" />
        <div className="flex items-center gap-1.5 flex-wrap justify-end">{meta}</div>
      </div>

      {/* Title */}
      {renaming ? (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            saveRename();
          }}
        >
          <input
            autoFocus
            className="w-full bg-transparent outline-none text-[24px] leading-[30px] font-semibold tracking-[-0.02em] text-foreground border-b border-ring pb-1"
            value={subjectDraft}
            onChange={(e) => setSubjectDraft(e.target.value)}
            onKeyDown={(e) => e.key === "Escape" && setRenaming(false)}
            placeholder={t.original_subject}
          />
          <div className="flex items-center gap-1 mt-2">
            <Button type="submit" size="sm"><Check /> Save</Button>
            <Button type="button" size="sm" variant="ghost" onClick={() => setRenaming(false)}>Cancel</Button>
            <span className="text-xs text-muted-foreground ml-2">Only you see this name.</span>
          </div>
        </form>
      ) : (
        <h1 className="group flex items-start gap-1 min-w-0 text-[24px] leading-[30px] font-semibold tracking-[-0.02em] text-foreground">
          <span className="min-w-0 break-words">{t.subject || <span className="text-tertiary">(no subject)</span>}</span>
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label="Rename subject"
            className="opacity-0 group-hover:opacity-100 focus-visible:opacity-100 mt-1 shrink-0 text-muted-foreground"
            onClick={() => {
              setSubjectDraft(t.subject);
              setRenaming(true);
            }}
          >
            <Pencil />
          </Button>
        </h1>
      )}
      {renamed && !renaming && <div className="text-xs text-muted-foreground mt-1">originally “{t.original_subject}”</div>}

      {/* Meta row */}
      <div className="flex items-center gap-2 mt-2.5 flex-wrap min-w-0 text-[13px]">
        <AvatarStack people={t.participants} size={20} max={4} />
        <span className="text-foreground/80 truncate min-w-0">{names.slice(0, 3).join(", ")}{names.length > 3 ? ` +${names.length - 3}` : ""}</span>
        <span className="text-muted-foreground tnum">· {t.message_count} message{t.message_count === 1 ? "" : "s"}</span>
        {multi && account && (
          <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
            <AccountGlyph glyph={glyphFor(account.id)} /> {account.email}
          </span>
        )}
        {t.labels.map((l) => (
          <Link key={l.id} to={`/labels/${l.id}`} className="hover:opacity-80">
            <LabelChip label={l} />
          </Link>
        ))}
        {t.collections.map((c) => (
          <Link key={c.id} to={`/collections/${c.id}`} className="hover:opacity-80">
            <Badge variant="outline" className="font-normal text-foreground/90"><FolderOpen />{c.name}</Badge>
          </Link>
        ))}
      </div>

      {/* Sticky note */}
      {(t.note || noteOpen) && (
        <div className={cn("relative mt-4 rounded-md bg-muted px-3 py-2.5", !noteOpen && "cursor-text")} onClick={() => !noteOpen && setNoteOpen(true)}>
          <div className="flex items-start gap-2">
            <Pin size={13} className="text-muted-foreground mt-1 shrink-0" />
            {noteOpen ? (
              <div className="flex-1 min-w-0">
                <Textarea
                  ref={noteRef}
                  className="bg-transparent focus-visible:bg-transparent border-0 focus-visible:border-transparent p-0 min-h-14 text-[13px] rounded-none"
                  value={noteDraft}
                  onChange={(e) => setNoteDraft(e.target.value)}
                  placeholder="A private note, just for you."
                  onKeyDown={(e) => {
                    if (e.key === "Escape") { setNoteOpen(false); setNoteDraft(t.note); }
                    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) saveNote();
                  }}
                />
                <div className="flex items-center gap-1 mt-1.5">
                  {t.note && (
                    <Button variant="ghost" size="xs" className="text-muted-foreground mr-auto" onClick={() => { run({ action: "note", note: "" }, "Note removed"); setNoteOpen(false); }}>
                      Remove note
                    </Button>
                  )}
                  <span className="flex-1" />
                  <Button variant="ghost" size="xs" onClick={() => { setNoteOpen(false); setNoteDraft(t.note); }}>Cancel</Button>
                  <Button size="xs" onClick={saveNote}>Save <Kbd className="ml-1 bg-background/20 text-background">⌘↵</Kbd></Button>
                </div>
              </div>
            ) : (
              <div className="group flex items-start gap-2 flex-1 min-w-0">
                <div className="text-[13px] leading-relaxed whitespace-pre-wrap flex-1 min-w-0">{t.note}</div>
                <Pencil size={12} className="text-muted-foreground opacity-0 group-hover:opacity-100 mt-1 shrink-0" />
              </div>
            )}
          </div>
        </div>
      )}

      {/* Clips */}
      {t.clips.length > 0 && (
        <div className="mt-3 flex flex-wrap gap-1.5">
          {t.clips.map((c) => (
            <Badge key={c.id} variant="secondary" className="group max-w-full font-normal pr-0.5 h-6" title={c.text}>
              <Scissors className="text-muted-foreground" />
              <span className="truncate max-w-72">“{c.text}”</span>
              <Button variant="ghost" size="icon-xs" className="size-5 text-muted-foreground" aria-label="Delete clip" onClick={() => clips.remove.mutate(c.id, { onSuccess: () => toast("Clip removed") })}>
                <X />
              </Button>
            </Badge>
          ))}
        </div>
      )}

      {summ.summary && <AiSummaryPanel summary={summ.summary} onClose={summ.clear} className="mt-4" />}
      {summ.pending && !summ.summary && <div className="mt-4 flex items-center gap-2 text-[13px] text-muted-foreground"><Sparkles className="size-3.5" /> Summarising…</div>}

      {/* Messages */}
      <div className="mt-5">
        {t.messages.length > 2 && (
          <div className="flex justify-end">
            <Button variant="ghost" size="xs" className="text-muted-foreground" onClick={() => setExpanded(allExpanded ? new Set([t.messages[t.messages.length - 1].id]) : new Set(t.messages.map((m) => m.id)))}>
              <ChevronsDownUp /> {allExpanded ? "Collapse older" : `Expand all ${t.messages.length}`}
            </Button>
          </div>
        )}
        <div className="divide-y divide-border">
          {t.messages.map((m, i) => (
            <MessageRow
              key={m.id}
              m={m}
              index={i}
              focused={i === msgCursor}
              isLast={i === t.messages.length - 1}
              expanded={expanded.has(m.id)}
              onToggle={() =>
                setExpanded((s) => {
                  const n = new Set(s);
                  if (n.has(m.id)) n.delete(m.id);
                  else n.add(m.id);
                  return n;
                })
              }
              onReply={(mode, msg) => openReply(mode, msg)}
              onClip={(text) => clips.create.mutate({ thread_id: t.id, message_id: m.id, text }, { onSuccess: () => toast("Clip saved") })}
              onMarkUnread={() => run({ action: "mark_unread" }, "Marked unread")}
            />
          ))}
        </div>
        {t.merged_threads.length > 0 && (
          <div className="text-xs text-muted-foreground mt-2 flex items-center gap-1.5">
            <GitMerge size={12} /> Includes merged: {t.merged_threads.map((m) => m.subject).join(", ")}
          </div>
        )}
      </div>

      {/* Reply box */}
      <div id="reply-box" className="mt-4 scroll-mt-6">
        {reply ? (
          <div className="rounded-lg ring-1 ring-border overflow-hidden bg-background">
            <div className="flex items-center gap-2 px-3 h-9 border-b border-border text-[13px]">
              <span className="text-muted-foreground [&>svg]:size-3.5">{reply.mode === "forward" ? <Forward /> : reply.mode === "replyAll" ? <ReplyAll /> : <Reply />}</span>
              <span className="font-medium">{modeLabel[reply.mode]}</span>
              {reply.mode !== "forward" && <span className="text-muted-foreground truncate">to {reply.m.is_from_me ? reply.m.to.map((a) => a.name || a.email).join(", ") : reply.m.from.name || reply.m.from.email}</span>}
              <span className="flex-1" />
              <Button variant="ghost" size="icon-xs" aria-label="Close" className="text-muted-foreground" onClick={() => setReply(null)}>
                <X />
              </Button>
            </div>
            <Composer key={reply.key} inline initial={{ ...replyInitial(t, reply.m, reply.mode, account?.email), ...(reply.body_html ? { body_html: reply.body_html } : {}) }} onDone={() => setReply(null)} onCancel={() => setReply(null)} />
          </div>
        ) : (
          <button type="button" onClick={() => openReply("reply")} className="w-full flex items-center gap-2.5 rounded-md px-2 h-10 text-left hover:bg-muted group">
            <Avatar email={account?.email ?? ""} name={account?.display_name || user?.name} src={account?.avatar_url} size={20} />
            <span className="text-[13px] text-muted-foreground group-hover:text-foreground truncate">Reply to {replyTarget || "this thread"}…</span>
            <span className="flex-1" />
            <Kbd>r</Kbd>
          </button>
        )}
      </div>

      {/* Docked action bar (hidden while the reply composer is open; it has its own Send) */}
      <div className={cn("fixed z-40 bottom-4 flex justify-center pointer-events-none px-3", reply && "hidden")} style={col ? { left: col.left, width: col.width } : { left: 0, right: 0 }}>
        <div data-compact-bar={col?.compact || undefined} className="pointer-events-auto flex items-center gap-1 rounded-lg bg-background/90 backdrop-blur ring-1 ring-border shadow-md p-1 max-w-full overflow-x-auto">
          <ButtonGroup>
            <Button size="sm" onClick={() => openReply("reply")}><Reply /> Reply</Button>
            <Bar label="Reply all"><Button size="sm" variant="outline" onClick={() => openReply("replyAll")}><ReplyAll /><span className="hidden sm:inline">All</span></Button></Bar>
            <Bar label="Forward" kbd="f"><Button size="sm" variant="outline" onClick={() => openReply("forward")}><Forward /><span className="hidden sm:inline">Forward</span></Button></Bar>
            <AiReplyButton threadId={t.id} onResult={(r) => { if (lastIncoming) { setReply({ mode: "reply", m: lastIncoming, key: Date.now(), body_html: r.body_html }); setTimeout(() => document.getElementById("reply-box")?.scrollIntoView({ behavior: "smooth", block: "nearest" }), 60); } }} />
          </ButtonGroup>
          <ButtonGroup>
            <Bar label={t.reply_later ? "Remove from Reply Later" : "Reply later"} kbd="l">
              <Button size="sm" variant="outline" onClick={toggleReplyLater} className={cn(t.reply_later && "bg-muted")}><Clock /><span className="hidden sm:inline">Reply later</span></Button>
            </Bar>
            <Bar label={t.set_aside ? "Remove from Set Aside" : "Set aside"} kbd="a">
              <Button size="sm" variant="outline" onClick={toggleSetAside} className={cn(t.set_aside && "bg-muted")}><Bookmark /><span className="hidden sm:inline">Set aside</span></Button>
            </Bar>
            <Popover open={bubbleOpen} onOpenChange={setBubbleOpen}>
              <Bar label="Bubble up" kbd="z">
                <PopoverTrigger asChild>
                  <Button size="sm" variant="outline" className={cn(t.bubble_up_at && "bg-muted")}><ArrowUpCircle /><span className="hidden sm:inline">Bubble up</span></Button>
                </PopoverTrigger>
              </Bar>
              <PopoverContent side="top" align="center" className="w-auto p-1">
                <div className="px-2 h-7 flex items-center text-xs font-medium text-muted-foreground">Bubble up · out of sight until then</div>
                <DateTimePicker embedded onPick={(at) => { setBubbleOpen(false); run({ action: "bubble_up", at }, `Will bubble up ${fmtRelative(at)}`); }} />
                {t.bubble_up_at && (
                  <>
                    <ButtonGroupSeparator orientation="horizontal" className="my-1" />
                    <Button variant="ghost" size="sm" className="w-full justify-start text-muted-foreground" onClick={() => { setBubbleOpen(false); run({ action: "bubble_up", at: null }, "Bubble up cancelled"); }}>
                      <X /> Cancel bubble up
                    </Button>
                  </>
                )}
              </PopoverContent>
            </Popover>
          </ButtonGroup>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button size="sm" variant="ghost" className="text-muted-foreground"><MoreHorizontal /><span className="hidden sm:inline">More</span><ChevronDown className="size-3!" /></Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" side="top" className="w-56">
              <DropdownMenuLabel className="text-xs text-muted-foreground">Move to</DropdownMenuLabel>
              {(["imbox", "feed", "paper_trail"] as const)
                .filter((b) => b !== t.bucket)
                .map((b) => (
                  <DropdownMenuItem key={b} onSelect={() => run({ action: "move", bucket: b }, `Moved to ${bucketName(b)}`)}>
                    {bucketIcon[b]} {bucketName(b)}
                  </DropdownMenuItem>
                ))}
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => summ.run()} disabled={summ.pending}><Sparkles /> {summ.pending ? "Summarising…" : "Summarise with AI"}</DropdownMenuItem>
              <DropdownMenuItem
                disabled={toEvent.isPending}
                onSelect={async () => {
                  try {
                    const prefill = await toEvent.mutateAsync(t.id);
                    nav("/calendar", { state: { newEvent: prefill } });
                  } catch {
                    /* the calendar page will still open empty if this fails */
                  }
                }}
              >
                <CalendarPlus /> Create event
              </DropdownMenuItem>
              <DropdownMenuItem onSelect={() => { setSubjectDraft(t.subject); setRenaming(true); }}><Pencil /> Rename subject</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => setNoteOpen(true)}><StickyNote /> {t.note ? "Edit note" : "Stick a note on it"} <DropdownMenuShortcut>n</DropdownMenuShortcut></DropdownMenuItem>
              <DropdownMenuSub>
                <DropdownMenuSubTrigger><Tag /> Labels</DropdownMenuSubTrigger>
                <DropdownMenuSubContent className="w-52">
                  <LabelMenuItems current={new Set(t.labels.map((l) => l.id))} onToggle={(lid, on) => run({ action: "labels", ...(on ? { add: [lid] } : { remove: [lid] }) })} onManage={() => nav("/labels")} />
                </DropdownMenuSubContent>
              </DropdownMenuSub>
              <DropdownMenuSub>
                <DropdownMenuSubTrigger><FolderOpen /> Collections</DropdownMenuSubTrigger>
                <DropdownMenuSubContent className="w-52">
                  <CollectionMenuItems current={new Set(t.collections.map((c) => c.id))} onToggle={(cid, on) => run({ action: "collections", ...(on ? { add: [cid] } : { remove: [cid] }) })} onManage={() => nav("/collections")} />
                </DropdownMenuSubContent>
              </DropdownMenuSub>
              <DropdownMenuItem onSelect={() => setMergeOpen(true)}><GitMerge /> Merge with…</DropdownMenuItem>
              {(t.bucket === "imbox" || t.bucket === "paper_trail") && (
                <DropdownMenuItem onSelect={() => run({ action: "bundle", on: !t.sender_bundled }, t.sender_bundled ? "Unbundled sender" : "Bundled up sender")}>
                  <Layers /> {t.sender_bundled ? "Unbundle sender" : "Bundle up sender"}
                </DropdownMenuItem>
              )}
              <DropdownMenuItem onSelect={() => run({ action: "mark_unread" }, "Marked unread")}><Mail /> Mark unread <DropdownMenuShortcut>u</DropdownMenuShortcut></DropdownMenuItem>
              <DropdownMenuSeparator />
              {t.bucket !== "trash" && (
                <DropdownMenuItem onSelect={() => { run({ action: "move", bucket: "trash" }, "Moved to trash"); nav(-1); }}><Trash2 /> Trash <DropdownMenuShortcut>#</DropdownMenuShortcut></DropdownMenuItem>
              )}
              <DropdownMenuItem onSelect={() => setConfirmDelete(true)}><Trash2 /> Delete forever</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      <Dialog open={mergeOpen} onOpenChange={setMergeOpen}>
        <DialogContent className="sm:max-w-md p-0 gap-0" showCloseButton={false}>
          <DialogHeader className="px-3 pt-3 pb-1">
            <DialogTitle className="text-sm">Merge into this thread</DialogTitle>
            <DialogDescription className="text-xs">Fold another conversation into this one. Their messages join this thread.</DialogDescription>
          </DialogHeader>
          <ThreadPicker exclude={[t.id]} onPick={(other) => { setMergeOpen(false); run({ action: "merge", thread_ids: [other.id] }, `Merged “${other.subject}”`); }} />
        </DialogContent>
      </Dialog>

      <AlertDialog open={confirmDelete} onOpenChange={setConfirmDelete}>
        <AlertDialogContent size="sm">
          <AlertDialogHeader>
            <AlertDialogTitle>Delete this thread forever?</AlertDialogTitle>
            <AlertDialogDescription>It'll be removed here and trashed in {account?.provider === "domain" || account?.provider === "imap" ? "your mailbox" : account?.provider === "outlook" ? "Outlook" : "Gmail"}. There's no undo.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => { run({ action: "delete" }, "Deleted"); nav("/"); }}>Delete forever</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
