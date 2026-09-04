import { forwardRef, useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState, type ReactNode } from "react";
import { Bold, ChevronDown, Check, File, FileArchive, FileImage, FileText, Italic, Link2, List, ListOrdered, Paperclip, Quote, RemoveFormatting, Send, Underline, X, Trash2 } from "lucide-react";
import { toast } from "sonner";
import type { Address } from "@shared/types";
import { cn } from "@/lib/utils";
import { useAccount } from "../context/AccountContext";
import { sendMail, useDraftMutations, type SendPayload } from "../api";
import { AddressInput } from "./AddressInput";
import { DateTimePicker } from "./DatePicker";
import { fmtSize } from "../lib/format";
import { useCompose } from "../context/ComposeContext";
import { Avatar, AccountGlyph } from "./Avatar";
import { Button } from "@/components/ui/button";
import { ButtonGroup } from "@/components/ui/button-group";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { Kbd } from "@/components/ui/kbd";
import { Item, ItemActions, ItemContent, ItemDescription, ItemMedia, ItemTitle } from "@/components/ui/item";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";

export interface ComposerInitial {
  draft_id?: string;
  /** From account. Defaults to the thread's account for replies, else the default account. */
  account_id?: string | null;
  thread_id?: string | null;
  reply_to_message_id?: string | null;
  to?: Address[];
  cc?: Address[];
  bcc?: Address[];
  subject?: string;
  body_html?: string;
  quoted_html?: string; // appended below the body when sending (collapsed in editor)
  title?: string;
}

export interface ComposerHandle {
  /** Save a draft if there is anything worth saving, then close. */
  saveAndClose: () => Promise<void>;
  isEmpty: () => boolean;
  /** Send now (same as the Send button). */
  send: () => void;
}

const MAX_ATTACH = 20 * 1024 * 1024;

interface Att {
  filename: string;
  mime_type: string;
  size: number;
  data_base64: string;
}

function readFile(f: File): Promise<Att> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onerror = () => reject(new Error("Could not read file"));
    r.onload = () => resolve({ filename: f.name, mime_type: f.type || "application/octet-stream", size: f.size, data_base64: String(r.result).split(",")[1] ?? "" });
    r.readAsDataURL(f);
  });
}

export function fileIcon(mime: string, name = ""): ReactNode {
  if (mime.startsWith("image/")) return <FileImage />;
  if (/zip|rar|7z|tar|gzip/.test(mime) || /\.(zip|rar|7z|tgz)$/i.test(name)) return <FileArchive />;
  if (/pdf|text|word|document|sheet|presentation|csv/.test(mime)) return <FileText />;
  return <File />;
}

function AttachmentItem({ a, onRemove }: { a: Att; onRemove: () => void }) {
  const isImg = a.mime_type.startsWith("image/");
  return (
    <Item variant="muted" size="xs" className="group/att">
      <ItemMedia variant={isImg ? "image" : "icon"}>
        {isImg ? <img src={`data:${a.mime_type};base64,${a.data_base64}`} alt="" className="size-8 rounded-sm object-cover" /> : fileIcon(a.mime_type, a.filename)}
      </ItemMedia>
      <ItemContent>
        <ItemTitle className="text-[13px] truncate">{a.filename}</ItemTitle>
        <ItemDescription className="text-xs tnum">{fmtSize(a.size)}</ItemDescription>
      </ItemContent>
      <ItemActions>
        <Button variant="ghost" size="icon-xs" aria-label="Remove attachment" onClick={onRemove} className="text-muted-foreground opacity-0 group-hover/att:opacity-100 focus-visible:opacity-100">
          <X />
        </Button>
      </ItemActions>
    </Item>
  );
}

type SaveState = { kind: "idle" } | { kind: "saving" } | { kind: "saved"; at: number } | { kind: "error"; message: string };

function savedLabel(s: SaveState, now: number): string {
  if (s.kind === "saving") return "Saving…";
  if (s.kind === "error") return "Couldn't save draft";
  if (s.kind === "saved") {
    const secs = Math.round((now - s.at) / 1000);
    if (secs < 8) return "Saved";
    if (secs < 60) return `Saved ${secs}s ago`;
    return `Saved ${Math.round(secs / 60)}m ago`;
  }
  return "";
}

function ToolButton({ label, kbd, onClick, children, active }: { label: string; kbd?: string; onClick: () => void; children: ReactNode; active?: boolean }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button variant="ghost" size="icon-sm" aria-label={label} onMouseDown={(e) => e.preventDefault()} onClick={onClick} className={cn("text-muted-foreground hover:text-foreground", active && "bg-muted text-foreground")}>
          {children}
        </Button>
      </TooltipTrigger>
      <TooltipContent>
        {label} {kbd && <Kbd className="ml-1">{kbd}</Kbd>}
      </TooltipContent>
    </Tooltip>
  );
}

export const Composer = forwardRef<ComposerHandle, { initial?: ComposerInitial; inline?: boolean; onDone?: () => void; onCancel?: () => void; autoFocusBody?: boolean }>(function Composer(
  { initial = {}, inline, onDone, onCancel, autoFocusBody },
  ref,
) {
  const { accounts, defaultAccount, user, glyphFor, multi } = useAccount();
  const { queueSend } = useCompose();
  const drafts = useDraftMutations();
  const [fromId, setFromId] = useState<string>(() => initial.account_id ?? defaultAccount?.id ?? "");
  const account = useMemo(() => accounts.find((a) => a.id === fromId) ?? defaultAccount ?? null, [accounts, fromId, defaultAccount]);
  const [to, setTo] = useState<Address[]>(initial.to ?? []);
  const [cc, setCc] = useState<Address[]>(initial.cc ?? []);
  const [bcc, setBcc] = useState<Address[]>(initial.bcc ?? []);
  const [showCc, setShowCc] = useState((initial.cc?.length ?? 0) > 0);
  const [showBcc, setShowBcc] = useState((initial.bcc?.length ?? 0) > 0);
  const [subject, setSubject] = useState(initial.subject ?? "");
  const [atts, setAtts] = useState<Att[]>([]);
  const [includeQuote, setIncludeQuote] = useState(true);
  const [showQuote, setShowQuote] = useState(false);
  const [draftId, setDraftId] = useState(initial.draft_id);
  const [busy, setBusy] = useState(false);
  const [ask, setAsk] = useState<null | "discard" | "subject">(null);
  const [dragging, setDragging] = useState(false);
  const [bodyVersion, setBodyVersion] = useState(0);
  const [save, setSave] = useState<SaveState>({ kind: "idle" });
  const [now, setNow] = useState(Date.now());
  const [linkUrl, setLinkUrl] = useState("");
  const [linkOpen, setLinkOpen] = useState(false);
  const [laterOpen, setLaterOpen] = useState(false);
  const savedRange = useRef<Range | null>(null);
  const dirty = useRef(false);
  const bodyRef = useRef<HTMLDivElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const isReply = !!initial.thread_id;

  // The default account can arrive after mount (fresh page load).
  useEffect(() => {
    if (!fromId && defaultAccount) setFromId(defaultAccount.id);
  }, [fromId, defaultAccount]);

  useEffect(() => {
    if (!bodyRef.current) return;
    let html = initial.body_html ?? "";
    if (!initial.draft_id && account?.signature && !html.includes("hey-signature")) html += `<br><br><div class="hey-signature">${account.signature}</div>`;
    bodyRef.current.innerHTML = html;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // If the account (and its signature) arrives after mount, drop the signature into a still-empty body.
  useEffect(() => {
    const el = bodyRef.current;
    if (!el || initial.draft_id || !account?.signature) return;
    if (el.innerText.trim() === "" && !el.innerHTML.includes("hey-signature")) el.innerHTML = `<br><br><div class="hey-signature">${account.signature}</div>`;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account?.signature]);

  useEffect(() => {
    if (isReply || autoFocusBody) {
      const t = setTimeout(() => {
        const el = bodyRef.current;
        if (!el) return;
        el.focus();
        const r = document.createRange();
        r.setStart(el, 0);
        r.collapse(true);
        const s = window.getSelection();
        s?.removeAllRanges();
        s?.addRange(r);
      }, 60);
      return () => clearTimeout(t);
    }
  }, [isReply, autoFocusBody]);

  useEffect(() => {
    if (save.kind !== "saved") return;
    const i = window.setInterval(() => setNow(Date.now()), 5000);
    return () => window.clearInterval(i);
  }, [save.kind]);

  const exec = (cmd: string, val?: string) => {
    bodyRef.current?.focus();
    document.execCommand(cmd, false, val);
    markDirty();
  };

  const bodyHtml = useCallback(() => {
    let html = bodyRef.current?.innerHTML ?? "";
    if (includeQuote && initial.quoted_html) html += `<br><br><div class="hey-quote"><blockquote style="border-left:2px solid #d3d1cb;margin:0;padding-left:1em;color:#787774">${initial.quoted_html}</blockquote></div>`;
    return html;
  }, [includeQuote, initial.quoted_html]);
  const isEmpty = useCallback(() => {
    const txt = (bodyRef.current?.innerText ?? "").trim();
    const sig = (account?.signature ?? "").replace(/<[^>]+>/g, "").trim();
    const bodyEmpty = !txt || txt === sig;
    return bodyEmpty && !subject.trim() && !to.length && !cc.length && !bcc.length && !atts.length;
  }, [account?.signature, subject, to, cc, bcc, atts]);

  const draftBody = useCallback(
    () => ({ account_id: account?.id, thread_id: initial.thread_id ?? null, reply_to_message_id: initial.reply_to_message_id ?? null, to, cc, bcc, subject, body_html: bodyHtml() }),
    [account?.id, initial.thread_id, initial.reply_to_message_id, to, cc, bcc, subject, bodyHtml],
  );

  const saveDraft = useCallback(
    async (quiet = true) => {
      if (isEmpty()) return null;
      setSave({ kind: "saving" });
      try {
        let id = draftId;
        if (id) await drafts.update.mutateAsync({ id, ...draftBody() });
        else {
          const d = await drafts.create.mutateAsync(draftBody());
          id = d.id;
          setDraftId(id);
        }
        dirty.current = false;
        setSave({ kind: "saved", at: Date.now() });
        setNow(Date.now());
        if (!quiet) toast.success("Draft saved");
        return id;
      } catch (e) {
        setSave({ kind: "error", message: (e as Error).message });
        if (!quiet) toast.error((e as Error).message);
        return null;
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [draftId, draftBody, isEmpty],
  );

  const markDirty = () => {
    dirty.current = true;
    setBodyVersion((v) => v + 1);
  };
  useEffect(() => {
    if (!dirty.current) return;
    const t = window.setTimeout(() => {
      if (dirty.current && !busy) saveDraft(true);
    }, 1800);
    return () => window.clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [to, cc, bcc, subject, bodyVersion, fromId]);

  const payload = (send_at?: number): SendPayload => ({
    draft_id: draftId,
    account_id: account?.id,
    thread_id: initial.thread_id ?? null,
    reply_to_message_id: initial.reply_to_message_id ?? null,
    to,
    cc,
    bcc,
    subject,
    body_html: bodyHtml(),
    send_at: send_at ?? null,
    attachments: atts.map(({ filename, mime_type, data_base64 }) => ({ filename, mime_type, data_base64 })),
  });

  const validate = () => {
    if (!to.length && !cc.length && !bcc.length) {
      toast.error("Add at least one recipient.");
      return false;
    }
    if (!account) {
      toast.error("Connect an account first.");
      return false;
    }
    return true;
  };

  const doSend = (skipSubjectCheck = false) => {
    if (!validate()) return;
    // The app's webview blocks window.confirm(), so ask with a real dialog instead.
    if (!skipSubjectCheck && !subject.trim() && !isReply) {
      setAsk("subject");
      return;
    }
    const undo = user?.settings?.undoSendSeconds ?? 10;
    dirty.current = false;
    queueSend(payload(), undo);
    onDone?.();
  };
  const doSendLater = async (at: number) => {
    if (!validate()) return;
    setBusy(true);
    try {
      await sendMail(payload(at));
      dirty.current = false;
      toast.success(`Scheduled for ${new Date(at).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}`);
      onDone?.();
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const reallyDiscard = () => {
    dirty.current = false;
    if (draftId) drafts.remove.mutate(draftId);
    onCancel?.();
  };
  const discard = () => {
    if (isEmpty()) {
      reallyDiscard();
      return;
    }
    setAsk("discard");
  };
  useImperativeHandle(ref, () => ({
    send: () => doSend(),
    saveAndClose: async () => {
      if (isEmpty()) {
        if (draftId) drafts.remove.mutate(draftId);
      } else if (dirty.current || !draftId) {
        const id = await saveDraft(true);
        if (id) toast("Saved as a draft", { duration: 3000 });
      }
      onCancel?.();
    },
    isEmpty,
  }));

  const addFiles = async (files: FileList | File[] | null) => {
    if (!files) return;
    const next = [...atts];
    for (const f of Array.from(files)) {
      if (next.reduce((s, a) => s + a.size, 0) + f.size > MAX_ATTACH) {
        toast.error("Attachments are capped at 20 MB total.");
        break;
      }
      next.push(await readFile(f));
    }
    setAtts(next);
    markDirty();
  };

  const openLink = () => {
    const s = window.getSelection();
    savedRange.current = s && s.rangeCount ? s.getRangeAt(0).cloneRange() : null;
    setLinkUrl("");
    setLinkOpen(true);
  };
  const insertLink = () => {
    let url = linkUrl.trim();
    if (!url) return;
    if (!/^[a-z]+:/i.test(url)) url = "https://" + url;
    bodyRef.current?.focus();
    const s = window.getSelection();
    if (savedRange.current && s) {
      s.removeAllRanges();
      s.addRange(savedRange.current);
    }
    if (s && s.isCollapsed) document.execCommand("insertHTML", false, `<a href="${url.replace(/"/g, "&quot;")}">${url}</a>`);
    else document.execCommand("createLink", false, url);
    markDirty();
    setLinkOpen(false);
  };

  const rowLabel = (t: string) => <span className="w-14 shrink-0 text-[13px] text-muted-foreground select-none">{t}</span>;
  const status = savedLabel(save, now);
  const fromLabel = (a: { email: string; display_name: string; provider?: string }) => a.display_name || user?.name || a.email;

  return (
    <div
      onKeyDown={(e) => {
        // ⌘/Ctrl + Enter sends from anywhere in the composer.
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && !busy && account) {
          e.preventDefault();
          e.stopPropagation();
          doSend();
        }
      }}
      className={cn("flex flex-col relative", !inline && "min-h-full")}
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes("Files")) {
          e.preventDefault();
          setDragging(true);
        }
      }}
      onDragLeave={() => setDragging(false)}
      onDrop={(e) => {
        if (e.dataTransfer.files?.length) {
          e.preventDefault();
          setDragging(false);
          addFiles(e.dataTransfer.files);
        }
      }}
    >
      {dragging && (
        <div className="absolute inset-1 z-20 rounded-lg border border-dashed border-ring bg-background/90 flex items-center justify-center text-sm text-muted-foreground pointer-events-none">
          <Paperclip size={14} className="mr-2" /> Drop to attach
        </div>
      )}
      <div className={cn("px-4", inline ? "pt-0.5" : "pt-1")}>
        {/* From */}
        <div className="flex items-center gap-3 py-1.5 border-b border-border">
          {rowLabel("From")}
          {accounts.length === 0 ? (
            <span className="text-[13px] text-muted-foreground">No account connected</span>
          ) : (
            <Select value={fromId} onValueChange={(v) => { setFromId(v); markDirty(); }}>
              <SelectTrigger size="sm" className="h-7 border-0 bg-transparent px-1.5 -ml-1.5 shadow-none hover:bg-muted data-[state=open]:bg-muted [&>svg]:text-muted-foreground max-w-full" aria-label="From account">
                <SelectValue>
                  {account && (
                    <span className="inline-flex items-center gap-2 min-w-0 text-[13px]">
                      <Avatar email={account.email} name={fromLabel(account)} src={account.avatar_url} size={16} />
                      <span className="truncate">{fromLabel(account)}</span>
                      <span className="text-muted-foreground truncate">{account.email}</span>
                      {multi && <AccountGlyph glyph={glyphFor(account.id)} />}
                    </span>
                  )}
                </SelectValue>
              </SelectTrigger>
              <SelectContent align="start">
                {accounts.map((a) => (
                  <SelectItem key={a.id} value={a.id}>
                    <span className="inline-flex items-center gap-2 min-w-0">
                      <Avatar email={a.email} name={fromLabel(a)} src={a.avatar_url} size={16} />
                      <span className="truncate">{a.email}</span>
                      <span className="text-xs text-muted-foreground">{a.provider === "domain" ? "Domain" : a.provider === "outlook" ? "Outlook" : "Gmail"}</span>
                      {multi && <AccountGlyph glyph={glyphFor(a.id)} />}
                    </span>
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        </div>
        <AddressInput
          label="To"
          value={to}
          onChange={(v) => { setTo(v); dirty.current = true; }}
          autoFocus={!isReply && !to.length}
          trailing={
            (!showCc || !showBcc) && (
              <>
                {!showCc && <Button variant="ghost" size="xs" className="text-muted-foreground h-6" onClick={() => setShowCc(true)}>Cc</Button>}
                {!showBcc && <Button variant="ghost" size="xs" className="text-muted-foreground h-6" onClick={() => setShowBcc(true)}>Bcc</Button>}
              </>
            )
          }
        />
        {showCc && <AddressInput label="Cc" value={cc} onChange={(v) => { setCc(v); dirty.current = true; }} autoFocus={!cc.length} />}
        {showBcc && <AddressInput label="Bcc" value={bcc} onChange={(v) => { setBcc(v); dirty.current = true; }} autoFocus={!bcc.length} />}
        <div className="flex items-center gap-3 py-1.5 border-b border-border">
          {rowLabel("Subject")}
          <input
            className={cn("flex-1 min-w-0 bg-transparent outline-none text-foreground placeholder:text-tertiary py-0.5", isReply || inline ? "text-[14px]" : "text-[16px] font-semibold tracking-[-0.01em]")}
            value={subject}
            onChange={(e) => { setSubject(e.target.value); dirty.current = true; }}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); bodyRef.current?.focus(); } }}
            placeholder={isReply ? "" : "Subject"}
          />
        </div>
      </div>

      <div className={cn("px-4 py-3", inline ? "" : "flex-1")}>
        <div
          ref={bodyRef}
          contentEditable
          suppressContentEditableWarning
          data-placeholder={isReply ? "Write your reply…" : "Write something…"}
          className={cn("prose-mail outline-none text-[15px] leading-[1.6] text-foreground empty:before:content-[attr(data-placeholder)] empty:before:text-tertiary [&_a]:underline [&_blockquote]:border-l-2 [&_blockquote]:border-border [&_blockquote]:pl-3 [&_blockquote]:text-muted-foreground [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5", inline ? "min-h-24" : "min-h-48")}
          onInput={markDirty}
          onPaste={(e) => {
            if (e.clipboardData.files?.length) {
              e.preventDefault();
              addFiles(e.clipboardData.files);
            }
          }}
        />
        {initial.quoted_html && (
          <div className="mt-3">
            <div className="flex items-center gap-3 flex-wrap">
              <Button variant="ghost" size="xs" className="text-muted-foreground" onClick={() => setShowQuote((s) => !s)}>
                <ChevronDown className={cn("transition-transform", showQuote && "rotate-180")} />
                {showQuote ? "Hide" : "Show"} quoted text
              </Button>
              <label className="inline-flex items-center gap-2 text-xs text-muted-foreground select-none">
                <Switch size="sm" checked={includeQuote} onCheckedChange={(v) => { setIncludeQuote(v); markDirty(); }} />
                Include when sending
              </label>
            </div>
            {showQuote && <div className="mt-2 border-l-2 border-border pl-3 text-muted-foreground text-[13px] max-h-64 overflow-y-auto [&_img]:max-w-full" dangerouslySetInnerHTML={{ __html: initial.quoted_html }} />}
          </div>
        )}
        {atts.length > 0 && (
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-1.5 mt-4">
            {atts.map((a, i) => (
              <AttachmentItem key={i} a={a} onRemove={() => { setAtts(atts.filter((_, j) => j !== i)); markDirty(); }} />
            ))}
          </div>
        )}
      </div>

      <div className={cn("flex items-center gap-1 px-2 py-2 border-t border-border", !inline && "sticky bottom-0 z-10 bg-background")}>
        <div className="flex items-center gap-0.5 min-w-0">
          <ToolButton label="Bold" kbd="⌘B" onClick={() => exec("bold")}><Bold /></ToolButton>
          <ToolButton label="Italic" kbd="⌘I" onClick={() => exec("italic")}><Italic /></ToolButton>
          <ToolButton label="Underline" kbd="⌘U" onClick={() => exec("underline")}><Underline /></ToolButton>
          <Popover open={linkOpen} onOpenChange={setLinkOpen}>
            <PopoverTrigger asChild>
              <Button variant="ghost" size="icon-sm" aria-label="Link" onMouseDown={(e) => e.preventDefault()} onClick={openLink} className={cn("text-muted-foreground hover:text-foreground", linkOpen && "bg-muted text-foreground")}>
                <Link2 />
              </Button>
            </PopoverTrigger>
            <PopoverContent side="top" align="start" className="w-72 p-1.5">
              <form className="flex items-center gap-1.5" onSubmit={(e) => { e.preventDefault(); insertLink(); }}>
                <Input autoFocus value={linkUrl} onChange={(e) => setLinkUrl(e.target.value)} placeholder="https://" className="h-7 text-[13px]" />
                <Button type="submit" size="sm" disabled={!linkUrl.trim()}><Check /> Add</Button>
              </form>
            </PopoverContent>
          </Popover>
          <span className="hidden sm:flex items-center gap-0.5">
            <ToolButton label="Bulleted list" onClick={() => exec("insertUnorderedList")}><List /></ToolButton>
            <ToolButton label="Numbered list" onClick={() => exec("insertOrderedList")}><ListOrdered /></ToolButton>
            <ToolButton label="Quote" onClick={() => exec("formatBlock", "blockquote")}><Quote /></ToolButton>
            <span className="hidden md:inline-flex"><ToolButton label="Clear formatting" onClick={() => exec("removeFormat")}><RemoveFormatting /></ToolButton></span>
          </span>
          <ToolButton label="Attach files" onClick={() => fileRef.current?.click()}><Paperclip /></ToolButton>
          <input ref={fileRef} type="file" multiple className="hidden" onChange={(e) => { addFiles(e.target.files); e.target.value = ""; }} />
        </div>
        <span className="flex-1" />
        {status && (
          <span className="text-xs tnum mr-1 hidden sm:inline text-tertiary" aria-live="polite">
            {status}
          </span>
        )}
        <Tooltip>
          <TooltipTrigger asChild>
            <Button variant="ghost" size="icon-sm" aria-label={isEmpty() ? "Close" : "Discard"} className="text-muted-foreground hover:text-foreground" onClick={discard}>
              <Trash2 />
            </Button>
          </TooltipTrigger>
          <TooltipContent>{isEmpty() ? "Close" : "Discard"}</TooltipContent>
        </Tooltip>
        <ButtonGroup className="ml-1">
          <Button onClick={() => doSend()} disabled={busy || !account} title="Send (⌘↵)">
            <Send /> Send
          </Button>
          <Popover open={laterOpen} onOpenChange={setLaterOpen}>
            <PopoverTrigger asChild>
              <Button size="icon" aria-label="Send later" disabled={busy || !account} className="w-7">
                <ChevronDown />
              </Button>
            </PopoverTrigger>
            <PopoverContent side="top" align="end" className="w-auto p-1">
              <div className="px-2 h-7 flex items-center text-xs font-medium text-muted-foreground">Send later</div>
              <DateTimePicker embedded verb="Schedule" onPick={(at) => { setLaterOpen(false); doSendLater(at); }} />
            </PopoverContent>
          </Popover>
        </ButtonGroup>
      </div>
      <AlertDialog open={ask !== null} onOpenChange={(o) => !o && setAsk(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{ask === "discard" ? "Discard this message?" : "Send without a subject?"}</AlertDialogTitle>
            <AlertDialogDescription>
              {ask === "discard" ? "The draft is deleted and the text is gone." : "The recipient will see “(no subject)”."}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{ask === "discard" ? "Keep writing" : "Add a subject"}</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                const which = ask;
                setAsk(null);
                if (which === "discard") reallyDiscard();
                else doSend(true);
              }}
            >
              {ask === "discard" ? "Discard" : "Send"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
});
