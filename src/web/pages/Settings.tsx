import { useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { AlertTriangle, CalendarDays, Check, ChevronDown, Copy, FileText, Globe, Inbox, KeyRound, Mail, Monitor, Moon, Plus, RefreshCw, Rss, ShieldCheck, SlidersHorizontal, Sun, Trash2, Unplug, User, Sparkles, Loader2 } from "lucide-react";
import { toast } from "sonner";
import type { Account, Domain, UserSettings } from "@shared/types";
import { cn } from "@/lib/utils";
import { useAccount } from "../context/AccountContext";
import { DomainMxError, domainErrorMessage, useAccountMutations, useDomainMutations, useDomains, useMeMutations, useTwoFactor, useTwoFactorMutations, useImapMutations, api, useOAuthCredentials, useOAuthMutations, type OAuthCredentialStatus } from "../api";
import QRCode from "qrcode";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { PageHeader } from "../components/EmptyState";
import { fmtRelative } from "../lib/format";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Drawer, DrawerContent, DrawerDescription, DrawerFooter, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { AiSection } from "../components/AiSettingsSection";
import { CalendarSettingsSection } from "../components/CalendarSettingsSection";
import { useCardScroll } from "../lib/cardKeys";

type Tab = "profile" | "preferences" | "accounts" | "domains" | "calendar" | "ai" | "security";
const TABS: { key: Tab; label: string; icon: React.ReactNode }[] = [
  { key: "profile", label: "Profile", icon: <User /> },
  { key: "preferences", label: "Preferences", icon: <SlidersHorizontal /> },
  { key: "accounts", label: "Accounts", icon: <Mail /> },
  { key: "domains", label: "Domains", icon: <Globe /> },
  { key: "calendar", label: "Calendar", icon: <CalendarDays /> },
  { key: "ai", label: "AI", icon: <Sparkles /> },
  { key: "security", label: "Security", icon: <KeyRound /> },
];

/* ---------- small building blocks (Notion-style property rows) ---------- */

export function Section({ title, description, children, actions }: { title: string; description?: string; children: React.ReactNode; actions?: React.ReactNode }) {
  return (
    <section className="mb-10">
      <div className="flex items-start justify-between gap-4 mb-3 px-2">
        <div>
          <h2 className="text-base font-semibold">{title}</h2>
          {description && <p className="text-[13px] text-muted-foreground mt-0.5">{description}</p>}
        </div>
        {actions}
      </div>
      {children}
    </section>
  );
}

export function Row({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="grid sm:grid-cols-[minmax(0,1fr)_auto] gap-x-6 gap-y-2 items-center px-2 py-3 border-b border-border last:border-b-0">
      <div className="min-w-0">
        <div className="text-sm">{label}</div>
        {hint && <div className="text-xs text-muted-foreground mt-0.5">{hint}</div>}
      </div>
      <div className="min-w-0 sm:justify-self-end overflow-x-auto [scrollbar-width:none]"><div className="w-max max-w-full">{children}</div></div>
    </div>
  );
}

export function SavedMark({ show }: { show: boolean }) {
  return (
    <span className={cn("inline-flex items-center gap-1 text-xs text-muted-foreground transition-opacity duration-100", show ? "opacity-100" : "opacity-0")}>
      <Check size={12} /> Saved
    </span>
  );
}

export function Toggle({ value, options, onChange, className, itemClassName }: { value: string; options: { value: string; label: string; icon?: React.ReactNode }[]; onChange: (v: string) => void; className?: string; itemClassName?: string }) {
  return (
    <ToggleGroup type="single" size="sm" value={value} onValueChange={(v) => v && onChange(v)} className={className}>
      {options.map((o) => (
        <ToggleGroupItem key={o.value} value={o.value} className={cn("gap-1.5 text-muted-foreground data-[state=on]:bg-accent data-[state=on]:text-foreground [&>svg]:size-3.5", itemClassName)}>
          {o.icon}
          {o.label}
        </ToggleGroupItem>
      ))}
    </ToggleGroup>
  );
}

export function CopyButton({ text }: { text: string }) {
  const [ok, setOk] = useState(false);
  return (
    <Button
      variant="ghost"
      size="icon-xs"
      aria-label="Copy"
      className="text-muted-foreground"
      onClick={() => navigator.clipboard.writeText(text).then(() => { setOk(true); window.setTimeout(() => setOk(false), 1200); })}
    >
      {ok ? <Check /> : <Copy />}
    </Button>
  );
}

export function Danger({ open, onOpenChange, title, body, action, onConfirm }: { open: boolean; onOpenChange: (o: boolean) => void; title: string; body: string; action: string; onConfirm: () => void }) {
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>{body}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction onClick={onConfirm}>{action}</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

/** Dialog (desktop) or bottom Drawer (mobile) around a form. */
function FormShell({ open, onClose, title, description, footer, variant = "dialog", children }: { open: boolean; onClose: () => void; title: string; description?: string; footer: React.ReactNode; variant?: "dialog" | "drawer"; children: React.ReactNode }) {
  if (variant === "drawer") {
    return (
      <Drawer open={open} onOpenChange={(o) => !o && onClose()}>
        <DrawerContent className="pb-safe max-h-[92dvh]">
          <DrawerHeader className="text-left">
            <DrawerTitle>{title}</DrawerTitle>
            {description ? <DrawerDescription>{description}</DrawerDescription> : <DrawerDescription className="sr-only">Form</DrawerDescription>}
          </DrawerHeader>
          <div className="px-4 overflow-y-auto">{children}</div>
          <DrawerFooter className="pt-3 flex-col-reverse gap-2">{footer}</DrawerFooter>
        </DrawerContent>
      </Drawer>
    );
  }
  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          {description ? <DialogDescription>{description}</DialogDescription> : <DialogDescription className="sr-only">Form</DialogDescription>}
        </DialogHeader>
        <div className="my-5">{children}</div>
        <DialogFooter>{footer}</DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/* ---------- Accounts ---------- */

export function statusOf(a: Account): { label: string; spin?: boolean } {
  if (a.provider === "domain") return { label: "Mailbox · receives via Cloudflare" };
  if (a.provider === "imap" && a.sync_status === "idle") return { label: "Mailbox · IMAP" };
  if (a.sync_status === "disconnected") return { label: "Disconnected" };
  if (a.sync_status === "error") return { label: "Sync error" };
  if (!a.initial_sync_done) return { label: "Connecting", spin: true };
  if (a.sync_status === "syncing") return { label: "Syncing", spin: true };
  return { label: "Synced" };
}

function AccountBlock({ a }: { a: Account }) {
  const { glyphFor, multi } = useAccount();
  const { update, remove, sync, reset } = useAccountMutations();
  const [open, setOpen] = useState(false);
  const [confirmReset, setConfirmReset] = useState(false);
  const [signature, setSignature] = useState(a.signature);
  const [displayName, setDisplayName] = useState(a.display_name);
  const [confirm, setConfirm] = useState(false);
  const [saved, setSaved] = useState(false);
  const [editImap, setEditImap] = useState(false);
  useEffect(() => { setSignature(a.signature); setDisplayName(a.display_name); }, [a.signature, a.display_name]);
  const dirty = signature !== a.signature || displayName !== a.display_name;
  const st = statusOf(a);
  const isGmail = a.provider === "gmail" || a.provider === "outlook";
  const save = () =>
    update.mutate(
      { id: a.id, signature, display_name: displayName },
      { onSuccess: () => { setSaved(true); window.setTimeout(() => setSaved(false), 2000); }, onError: (e) => toast.error((e as Error).message) },
    );
  return (
    <Collapsible open={open} onOpenChange={setOpen} className="border-b border-border last:border-b-0">
      {a.provider === "imap" ? <EditImapDialog account={a} open={editImap} onOpenChange={setEditImap} /> : null}
      <div className="flex items-center gap-3 px-2 h-12">
        <Avatar email={a.email} name={a.display_name} src={a.avatar_url} size={24} />
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 min-w-0">
            {multi && <AccountGlyph glyph={glyphFor(a.id)} />}
            <span className="text-sm font-medium truncate">{a.email}</span>
            <Badge variant="outline" className="font-normal text-muted-foreground">{isGmail ? "Gmail" : "Mailbox"}</Badge>
          </div>
          <div className="text-xs text-muted-foreground truncate tnum flex items-center gap-1.5">
            {st.spin && <RefreshCw size={11} className="animate-spin" />}
            {st.label}
            {isGmail && a.last_synced_at && <span>· {fmtRelative(a.last_synced_at)}</span>}
            {a.sync_error && <span>· {a.sync_error}</span>}
            {a.sync_status === "disconnected" && <a className="underline underline-offset-2 hover:text-foreground" href="/auth/google/start">Reconnect</a>}
          </div>
          {isGmail && a.sync_status !== "disconnected" && !a.photos_synced_at && (
            <div className="text-xs text-muted-foreground flex items-center gap-2 mt-0.5">
              <span>Reconnect Gmail to enable contact photos.</span>
              <a className="underline underline-offset-2 hover:text-foreground" href={`/auth/google/start?login_hint=${encodeURIComponent(a.email)}`}>Reconnect</a>
            </div>
          )}
        </div>
        {isGmail && (
          <Button size="sm" variant="ghost" className="text-muted-foreground" disabled={sync.isPending} onClick={() => sync.mutate(a.id, { onSuccess: (r) => toast(`Synced${r.added != null ? ` · ${r.added} new` : ""}`), onError: (e) => toast.error((e as Error).message) })}>
            <RefreshCw /> Sync
          </Button>
        )}
        <CollapsibleTrigger asChild>
          <Button size="sm" variant="ghost" className="text-muted-foreground">
            Edit <ChevronDown className={cn("transition-transform duration-100", open && "rotate-180")} />
          </Button>
        </CollapsibleTrigger>
      </div>
      <CollapsibleContent>
        <div className="px-2 pt-2 pb-4 pl-11">
          <FieldGroup className="gap-4">
            <Field>
              <FieldLabel htmlFor={`dn-${a.id}`}>Display name</FieldLabel>
              <Input id={`dn-${a.id}`} value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="Shown as the sender name" className="max-w-sm" />
            </Field>
            <Field>
              <FieldLabel htmlFor={`sig-${a.id}`}>Signature</FieldLabel>
              <Textarea id={`sig-${a.id}`} rows={3} className="font-mono text-xs" value={signature} onChange={(e) => setSignature(e.target.value)} placeholder="HTML allowed. Added under new messages." />
            </Field>
          </FieldGroup>
          <div className="mt-3 flex items-center gap-2">
            <Button size="sm" onClick={save} disabled={!dirty || update.isPending}>Save</Button>
            <SavedMark show={saved && !dirty} />
            <span className="flex-1" />
            {a.provider === "imap" && (
              <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={() => setEditImap(true)}>
                <SlidersHorizontal /> Server settings
              </Button>
            )}
            {isGmail && (
              <Button size="sm" variant="ghost" className="text-muted-foreground" disabled={reset.isPending} onClick={() => setConfirmReset(true)}>
                <RefreshCw /> Start fresh
              </Button>
            )}
            <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={() => setConfirm(true)}>
              {isGmail ? <><Unplug /> Disconnect</> : <><Trash2 /> Delete mailbox</>}
            </Button>
          </div>
        </div>
      </CollapsibleContent>
      <Danger
        open={confirmReset}
        onOpenChange={setConfirmReset}
        title={`Start fresh with ${a.email}?`}
        body="This deletes everything heyflare has synced for this account — threads, contacts, screener decisions, clips, drafts. Gmail itself is untouched. New mail from now on will go through the Screener."
        action="Start fresh"
        onConfirm={() =>
          reset.mutate(a.id, {
            onSuccess: (r) => (r.sync_error ? toast.error(`Reset done, but the first sync failed: ${r.sync_error}`) : toast("Starting fresh — watching for new mail from now on")),
            onError: (e) => toast.error((e as Error).message),
          })
        }
      />
      <Danger
        open={confirm}
        onOpenChange={setConfirm}
        title={isGmail ? `Disconnect ${a.email}?` : `Delete ${a.email}?`}
        body={isGmail ? "This removes the account and all of its synced mail from heyflare. Nothing changes in Gmail." : "This deletes the mailbox and every message stored in it. Mail sent to this address will bounce (or land in the domain's catch-all)."}
        action={isGmail ? "Disconnect" : "Delete mailbox"}
        onConfirm={() => remove.mutate(a.id, { onError: (e) => toast.error((e as Error).message) })}
      />
    </Collapsible>
  );
}

/* ---------- Domains ---------- */

export function DomainBadges({ d }: { d: Domain }) {
  const status = d.status === "active" ? "Active" : d.status === "error" ? "Error" : "Pending";
  const routing = d.routing === "enabled" ? "Routing on" : d.routing === "manual" ? "Manual setup" : "Routing off";
  const sending = d.sending === "cloudflare" ? "Sends via Cloudflare" : d.sending === "resend" ? "Sends via Resend" : "No outbound";
  return (
    <span className="inline-flex items-center gap-1.5 flex-wrap">
      <Badge variant={d.status === "active" ? "default" : "outline"} className={cn("font-normal", d.status !== "active" && "text-muted-foreground")}>{status}</Badge>
      <Badge variant="outline" className="font-normal text-muted-foreground">{routing}</Badge>
      <Badge variant="outline" className="font-normal text-muted-foreground">{sending}</Badge>
    </span>
  );
}

export function NewMailboxDialog({ d, open, onOpenChange, variant = "dialog" }: { d: Domain; open: boolean; onOpenChange: (o: boolean) => void; variant?: "dialog" | "drawer" }) {
  const { createMailbox } = useDomainMutations();
  const [local, setLocal] = useState("");
  const [name, setName] = useState("");
  const [catchAll, setCatchAll] = useState(d.mailboxes.length === 0);
  const close = () => { onOpenChange(false); setLocal(""); setName(""); };
  const submit = () =>
    createMailbox.mutate({ domain_id: d.id, local_part: local.trim().toLowerCase(), display_name: name.trim(), catch_all: catchAll }, { onSuccess: (a) => { toast(`${a.email} is ready`); close(); }, onError: (er) => toast.error(domainErrorMessage(er)) });
  const mobile = variant === "drawer";
  return (
    <FormShell
      open={open}
      onClose={close}
      variant={variant}
      title={`New mailbox on ${d.name}`}
      description="Mail to this address lands in your unified Imbox like any other account."
      footer={
        <>
          <Button type="button" variant="ghost" size={mobile ? "lg" : "default"} onClick={close}>Cancel</Button>
          <Button type="button" size={mobile ? "lg" : "default"} disabled={!local.trim() || createMailbox.isPending} onClick={submit}>Create mailbox</Button>
        </>
      }
    >
      <form onSubmit={(e) => { e.preventDefault(); if (local.trim()) submit(); }}>
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="mb-local">Address</FieldLabel>
            <div className={cn("flex items-center rounded-md bg-input focus-within:bg-background focus-within:ring-1 focus-within:ring-ring", mobile && "h-11")}>
              <input id="mb-local" autoFocus={!mobile} value={local} onChange={(e) => setLocal(e.target.value)} placeholder="hello" className={cn("flex-1 min-w-0 bg-transparent px-2.5 outline-none placeholder:text-muted-foreground", mobile ? "h-11 text-[16px]" : "h-8 text-sm")} pattern="[A-Za-z0-9._+\-]{1,64}" required />
              <span className="pr-2.5 text-sm text-muted-foreground">@{d.name}</span>
            </div>
            <FieldDescription>Letters, numbers, dots, dashes, plus or underscores.</FieldDescription>
          </Field>
          <Field>
            <FieldLabel htmlFor="mb-name">Display name</FieldLabel>
            <Input id="mb-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Farhan" className={cn(mobile && "h-11 text-[16px]")} />
          </Field>
          <Field orientation="horizontal">
            <Switch id="mb-catch" checked={catchAll} onCheckedChange={setCatchAll} />
            <div>
              <FieldLabel htmlFor="mb-catch">Catch-all</FieldLabel>
              <FieldDescription>Also receive mail sent to any other address on {d.name}.</FieldDescription>
            </div>
          </Field>
        </FieldGroup>
      </form>
    </FormShell>
  );
}

function DomainBlock({ d }: { d: Domain }) {
  const { verify, patch, remove } = useDomainMutations();
  const [open, setOpen] = useState(d.status !== "active" || d.mailboxes.length === 0);
  const [newBox, setNewBox] = useState(false);
  const [del, setDel] = useState(false);
  const manual = d.routing !== "enabled";
  return (
    <Collapsible open={open} onOpenChange={setOpen} className="border-b border-border last:border-b-0">
      <div className="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-3 px-2 min-h-12 py-2">
        <div className="flex items-start gap-3 flex-1 min-w-0">
          <Globe size={16} className="text-muted-foreground shrink-0 mt-0.5" />
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-sm font-medium">{d.name}</span>
              <DomainBadges d={d} />
            </div>
            <div className="text-xs text-muted-foreground tnum mt-0.5">
              {d.mailboxes.length} mailbox{d.mailboxes.length === 1 ? "" : "es"}
              {d.error && <span> · {d.error}</span>}
            </div>
          </div>
        </div>
        <div className="flex items-center gap-1 pl-7 sm:pl-0 shrink-0">
        <Button size="sm" variant="ghost" className="text-muted-foreground" disabled={verify.isPending} onClick={() => verify.mutate(d.id, { onSuccess: (r) => toast(r.status === "active" ? `${d.name} is receiving mail` : `${d.name}: ${r.error ?? "still pending"}`), onError: (e) => toast.error(domainErrorMessage(e)) })}>
          <RefreshCw className={cn(verify.isPending && "animate-spin")} /> Verify
        </Button>
        <CollapsibleTrigger asChild>
          <Button size="sm" variant="ghost" className="text-muted-foreground">
            Details <ChevronDown className={cn("transition-transform duration-100", open && "rotate-180")} />
          </Button>
        </CollapsibleTrigger>
        </div>
      </div>
      <CollapsibleContent>
        <div className="pl-9 pr-2 pb-5 space-y-5">
          {manual && d.instructions.length > 0 && (
            <div>
              <div className="text-xs font-medium text-muted-foreground mb-1.5">Set up receiving</div>
              <ol className="list-decimal pl-5 space-y-1 text-[13px] text-foreground/90">
                {d.instructions.filter((s) => !/^Outbound/.test(s)).map((s, i) => <li key={i}>{s}</li>)}
              </ol>
            </div>
          )}
          {manual && d.dns.length > 0 && (
            <div>
              <div className="text-xs font-medium text-muted-foreground mb-1.5">DNS records Cloudflare adds when Email Routing is enabled</div>
              <div className="overflow-x-auto rounded-md bg-muted/40">
                <Table>
                  <TableHeader>
                    <TableRow className="border-0 hover:bg-transparent">
                      <TableHead className="h-7 text-xs font-normal text-muted-foreground w-16">Type</TableHead>
                      <TableHead className="h-7 text-xs font-normal text-muted-foreground">Name</TableHead>
                      <TableHead className="h-7 text-xs font-normal text-muted-foreground">Content</TableHead>
                      <TableHead className="h-7 text-xs font-normal text-muted-foreground w-14">Prio</TableHead>
                      <TableHead className="h-7 w-8" />
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {d.dns.map((r, i) => (
                      <TableRow key={i} className="border-0 hover:bg-transparent">
                        <TableCell className="py-1 font-mono text-xs">{r.type}</TableCell>
                        <TableCell className="py-1 font-mono text-xs truncate max-w-[160px]">{r.name}</TableCell>
                        <TableCell className="py-1 font-mono text-xs truncate max-w-[260px]" title={r.content}>{r.content}</TableCell>
                        <TableCell className="py-1 font-mono text-xs tnum">{r.priority ?? ""}</TableCell>
                        <TableCell className="py-1"><CopyButton text={r.content} /></TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            </div>
          )}

          <div>
            <div className="flex items-center gap-2 mb-1">
              <div className="text-xs font-medium text-muted-foreground flex-1">Mailboxes</div>
              <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={() => setNewBox(true)}>
                <Plus /> New mailbox
              </Button>
            </div>
            {d.mailboxes.length === 0 ? (
              <div className="text-[13px] text-muted-foreground py-1">No mailboxes yet. Create one to start receiving.</div>
            ) : (
              <div>
                {d.mailboxes.map((m) => (
                  <div key={m.id} className="flex items-center gap-2.5 h-9 text-sm">
                    <Avatar email={m.email} name={m.display_name} src={m.avatar_url} size={20} />
                    <span className="truncate">{m.email}</span>
                    {m.display_name && <span className="text-muted-foreground truncate">· {m.display_name}</span>}
                    {d.catch_all_account_id === m.id && <Badge variant="secondary" className="font-normal text-muted-foreground">catch-all</Badge>}
                  </div>
                ))}
                <div className="text-xs text-muted-foreground mt-1">Signatures, display names and deletion live under Accounts.</div>
              </div>
            )}
          </div>

          <div className="grid sm:grid-cols-[minmax(0,1fr)_auto] gap-x-6 gap-y-2 items-center">
            <div>
              <div className="text-sm">Catch-all mailbox</div>
              <div className="text-xs text-muted-foreground">Where mail to unknown addresses on {d.name} goes. Off means it bounces.</div>
            </div>
            <Select value={d.catch_all_account_id ?? "none"} onValueChange={(v) => patch.mutate({ id: d.id, catch_all_account_id: v === "none" ? null : v }, { onError: (e) => toast.error(domainErrorMessage(e)) })}>
              <SelectTrigger size="sm" className="min-w-40"><SelectValue /></SelectTrigger>
              <SelectContent align="end">
                <SelectItem value="none">Off (bounce)</SelectItem>
                {d.mailboxes.map((m) => <SelectItem key={m.id} value={m.id}>{m.email}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>

          <div className="text-[13px] text-muted-foreground">
            {d.sending === "cloudflare" && <>Outbound mail from these mailboxes goes through Cloudflare Email Sending.</>}
            {d.sending === "resend" && <>Outbound mail from these mailboxes goes through Resend. Make sure {d.name} is verified there.</>}
            {d.sending === "none" && <>Outbound isn't configured yet, so these mailboxes can receive but not send. Enable Cloudflare Email Sending (Workers Paid) and add the <code className="font-mono text-xs">send_email</code> binding, or set a <code className="font-mono text-xs">RESEND_API_KEY</code> secret — see README → Custom domain mailboxes.</>}
          </div>

          <div className="flex justify-end">
            <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={() => setDel(true)}><Trash2 /> Remove domain</Button>
          </div>
        </div>
      </CollapsibleContent>
      <NewMailboxDialog d={d} open={newBox} onOpenChange={setNewBox} />
      <Danger
        open={del}
        onOpenChange={setDel}
        title={`Remove ${d.name}?`}
        body="Deletes every mailbox on it and all of their mail from heyflare. Email Routing on Cloudflare is left as it is."
        action="Remove domain"
        onConfirm={() => remove.mutate(d.id, { onError: (e) => toast.error(domainErrorMessage(e)) })}
      />
    </Collapsible>
  );
}

export function AddDomainDialog({ open, onOpenChange, variant = "dialog" }: { open: boolean; onOpenChange: (o: boolean) => void; variant?: "dialog" | "drawer" }) {
  const { create } = useDomainMutations();
  const [name, setName] = useState("");
  const [mx, setMx] = useState<string[] | null>(null);
  const [confirm, setConfirm] = useState(false);
  const [err, setErr] = useState("");
  const close = () => { onOpenChange(false); setName(""); setMx(null); setConfirm(false); setErr(""); };
  const submit = () => {
    setErr("");
    create.mutate(
      { name: name.trim().toLowerCase(), confirm: mx ? confirm : undefined },
      {
        onSuccess: (d) => { toast(d.status === "active" ? `${d.name} is receiving mail` : `${d.name} added — finish the setup steps`); close(); },
        onError: (er) => {
          if (er instanceof DomainMxError) { setMx(er.mx); setConfirm(false); return; }
          setErr(domainErrorMessage(er));
        },
      },
    );
  };
  const mobile = variant === "drawer";
  return (
    <FormShell
      open={open}
      onClose={close}
      variant={variant}
      title="Add a domain"
      description="The domain must be on your Cloudflare account with Cloudflare nameservers."
      footer={
        <>
          <Button type="button" variant="ghost" size={mobile ? "lg" : "default"} onClick={close}>Cancel</Button>
          <Button type="button" size={mobile ? "lg" : "default"} disabled={!name.trim() || create.isPending || (!!mx && !confirm)} onClick={submit}>{mx ? "Take over domain" : "Add domain"}</Button>
        </>
      }
    >
      <form onSubmit={(e) => { e.preventDefault(); if (name.trim() && !(mx && !confirm)) submit(); }}>
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="dom-name">Domain</FieldLabel>
            <Input id="dom-name" autoFocus={!mobile} value={name} onChange={(e) => { setName(e.target.value); setMx(null); setConfirm(false); }} placeholder="example.com" required autoCapitalize="none" autoCorrect="off" inputMode="url" className={cn(mobile && "h-11 text-[16px]")} />
            {err && <FieldDescription className="text-foreground">{err}</FieldDescription>}
          </Field>
          {mx && (
            <div className="rounded-md bg-muted/60 p-3 space-y-2.5">
              <div className="flex items-start gap-2 text-sm">
                <AlertTriangle size={16} className="shrink-0 mt-0.5" />
                <div>
                  <div className="font-medium">This will take over ALL mail for {name.trim().toLowerCase()}.</div>
                  <div className="text-[13px] text-muted-foreground mt-1">
                    It currently goes to {mx.length ? mx.map((h, i) => <span key={h}><code className="font-mono text-xs">{h}</code>{i < mx.length - 1 ? ", " : ""}</span>) : "another provider"}.
                    Enabling Cloudflare Email Routing replaces those MX records, so mail stops arriving there.
                  </div>
                </div>
              </div>
              <label className="flex items-start gap-2 text-[13px] cursor-pointer">
                <Checkbox checked={confirm} onCheckedChange={(v) => setConfirm(v === true)} className="mt-0.5" />
                <span>I understand. Route all mail for this domain to heyflare.</span>
              </label>
            </div>
          )}
        </FieldGroup>
      </form>
    </FormShell>
  );
}

export function DomainsSection() {
  const q = useDomains();
  const [add, setAdd] = useState(false);
  const list = q.data ?? [];
  return (
    <Section
      title="Custom domains"
      description="Receive at your own addresses through Cloudflare Email Routing, and send from them."
      actions={<Button size="sm" variant="ghost" className="text-muted-foreground" onClick={() => setAdd(true)}><Plus /> Add domain</Button>}
    >
      {q.isLoading && (
        <div className="space-y-2 px-2">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-2/3" />
        </div>
      )}
      {q.error && <div className="px-2 text-[13px] text-muted-foreground">{(q.error as Error).message}</div>}
      {!q.isLoading && list.length === 0 && (
        <div className="px-2 py-2 text-[13px] text-muted-foreground">
          No domains yet. Add one that lives on your Cloudflare account, then create mailboxes like <span className="font-mono text-xs">you@yourdomain.com</span>.
        </div>
      )}
      <div>
        {list.map((d) => <DomainBlock key={d.id} d={d} />)}
      </div>
      <AddDomainDialog open={add} onOpenChange={setAdd} />
    </Section>
  );
}

/* ---------- Sections (shared by desktop tabs and the mobile screens) ---------- */

export function ProfileSection({ compact }: { compact?: boolean }) {
  const { user, accounts } = useAccount();
  const { update } = useMeMutations();
  const [name, setName] = useState(user?.name ?? "");
  const [nameSaved, setNameSaved] = useState(false);
  useEffect(() => { if (user) setName(user.name); }, [user]);
  if (!user) return null;
  const inputCls = compact ? "w-full h-11 text-[16px]" : "w-56";
  return (
    <Section title="Profile" description="Your name appears in the sidebar. Sending uses each account's own name.">
      <div className="flex items-center gap-3 px-2 mb-4">
        <Avatar email={user.email} name={user.name} src={accounts.find((a) => a.avatar_url)?.avatar_url} size={40} />
        <div className="min-w-0">
          <div className="text-sm font-medium truncate">{user.name || user.email}</div>
          <div className="text-xs text-muted-foreground truncate">{user.email} · <Badge variant="secondary" className="font-normal text-muted-foreground">Owner</Badge></div>
        </div>
      </div>
      <Row label="Name">
        <div className="flex items-center gap-2">
          <Input
            value={name}
            onChange={(e) => setName(e.target.value)}
            onBlur={() => name.trim() !== user.name && update.mutate({ name: name.trim() }, { onSuccess: () => { setNameSaved(true); window.setTimeout(() => setNameSaved(false), 2000); } })}
            className={inputCls}
            aria-label="Name"
          />
          {!compact && <SavedMark show={nameSaved} />}
        </div>
      </Row>
      <Row label="Email" hint="Used to log in. Can't be changed here.">
        <Input value={user.email} disabled className={inputCls} aria-label="Email" />
      </Row>
    </Section>
  );
}

export function PreferencesSection({ compact }: { compact?: boolean }) {
  const { user } = useAccount();
  const { update } = useMeMutations();
  const [settings, setSettings] = useState<UserSettings>(user?.settings ?? {});
  const [prefSaved, setPrefSaved] = useState(false);
  useEffect(() => { if (user) setSettings(user.settings ?? {}); }, [user]);
  if (!user) return null;
  const saveSettings = (s: UserSettings) => {
    setSettings(s);
    update.mutate({ settings: s }, { onSuccess: () => { setPrefSaved(true); window.setTimeout(() => setPrefSaved(false), 2000); }, onError: (e) => toast.error((e as Error).message) });
  };
  const toggleCls = compact ? "w-full grid grid-cols-3" : undefined;
  const itemCls = compact ? "h-10 text-[14px] justify-center" : undefined;
  return (
    <>
      <Section title="Appearance">
        <Row label="Theme" hint="System follows your device.">
          <Toggle
            className={toggleCls}
            itemClassName={itemCls}
            value={settings.theme ?? "system"}
            options={[
              { value: "system", label: "System", icon: <Monitor /> },
              { value: "light", label: "Light", icon: <Sun /> },
              { value: "dark", label: "Dark", icon: <Moon /> },
            ]}
            onChange={(v) => saveSettings({ ...settings, theme: v as UserSettings["theme"] })}
          />
        </Row>
        <Row label="Show previews in lists" hint="The first line of each message next to the subject.">
          <Switch checked={settings.showPreviews !== false} onCheckedChange={(v) => saveSettings({ ...settings, showPreviews: v })} />
        </Row>
      </Section>
      <Section title="Mail" actions={<SavedMark show={prefSaved} />}>
        <Row label="Default place for new senders" hint="Pre-selected when you say yes in the Screener.">
          <Toggle
            className={toggleCls}
            itemClassName={itemCls}
            value={settings.defaultScreenTarget ?? "imbox"}
            options={[
              { value: "imbox", label: "Imbox", icon: <Inbox /> },
              { value: "feed", label: "The Feed", icon: <Rss /> },
              { value: "paper_trail", label: "Paper Trail", icon: <FileText /> },
            ]}
            onChange={(v) => saveSettings({ ...settings, defaultScreenTarget: v as UserSettings["defaultScreenTarget"] })}
          />
        </Row>
        <Row label="Undo send window" hint="Seconds to change your mind after hitting Send. 0 turns it off.">
          <div className="flex items-center gap-2">
            <Input
              type="number"
              min={0}
              max={60}
              className={cn("w-20 text-right tnum", compact && "h-11 text-[16px]")}
              value={settings.undoSendSeconds ?? 10}
              onChange={(e) => setSettings({ ...settings, undoSendSeconds: Math.max(0, Math.min(60, Number(e.target.value) || 0)) })}
              onBlur={() => saveSettings(settings)}
              aria-label="Undo send seconds"
            />
            <span className="text-[13px] text-muted-foreground">sec</span>
          </div>
        </Row>
      </Section>
    </>
  );
}

/** Change an IMAP mailbox's server settings or password without losing its synced mail. */
export function EditImapDialog({ account, open, onOpenChange, variant = "dialog" }: { account: Account; open: boolean; onOpenChange: (o: boolean) => void; variant?: "dialog" | "drawer" }) {
  const { update, test } = useImapMutations();
  const [imapHost, setImapHost] = useState("");
  const [smtpHost, setSmtpHost] = useState("");
  const [imapPort, setImapPort] = useState(993);
  const [smtpPort, setSmtpPort] = useState(465);
  const [password, setPassword] = useState("");
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    if (!open || loaded) return;
    void (async () => {
      try {
        const r = await api.get<{ imap_host: string; imap_port: number; smtp_host: string; smtp_port: number }>(`/api/accounts/${account.id}/imap`);
        setImapHost(r.imap_host); setImapPort(r.imap_port); setSmtpHost(r.smtp_host); setSmtpPort(r.smtp_port);
        setLoaded(true);
      } catch (e) { toast.error((e as Error).message); }
    })();
  }, [open, loaded, account.id]);

  const close = () => { onOpenChange(false); setPassword(""); setLoaded(false); };
  const submit = () =>
    update.mutate(
      { id: account.id, imap_host: imapHost.trim(), imap_port: imapPort, imap_security: imapPort === 143 ? "starttls" : "tls",
        smtp_host: smtpHost.trim(), smtp_port: smtpPort, smtp_security: smtpPort === 587 ? "starttls" : "tls",
        ...(password.trim() ? { password: password.trim() } : {}) },
      { onSuccess: () => { toast(`${account.email} updated`); close(); },
        onError: (e: unknown) => toast.error("Couldn't connect", { description: (e as Error).message, duration: 12000 }) }
    );

  const mobile = variant === "drawer";
  return (
    <FormShell
      open={open}
      onClose={close}
      variant={variant}
      title={`Edit ${account.email}`}
      description="Checked against both servers before anything is saved. Your mail is kept."
      footer={
        <>
          <Button type="button" variant="ghost" size={mobile ? "lg" : "default"} onClick={close}>Cancel</Button>
          <Button type="button" size={mobile ? "lg" : "default"} disabled={!loaded || update.isPending} onClick={submit}>
            {update.isPending ? <Loader2 className="animate-spin" /> : null} Save
          </Button>
        </>
      }
    >
      <FieldGroup>
        <Field>
          <FieldLabel htmlFor="e-pass">Password</FieldLabel>
          <Input id="e-pass" type="password" autoComplete="off" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="Leave blank to keep the current one" className={cn(mobile && "h-11 text-[16px]")} />
          <FieldDescription>Set this when your provider's app password has been rotated.</FieldDescription>
        </Field>
        <Field>
          <FieldLabel htmlFor="e-imap">IMAP server</FieldLabel>
          <div className="flex gap-2">
            <Input id="e-imap" value={imapHost} onChange={(e) => setImapHost(e.target.value)} className={cn("flex-1", mobile && "h-11 text-[16px]")} />
            <Input aria-label="IMAP port" type="number" value={imapPort} onChange={(e) => setImapPort(Number(e.target.value))} className={cn("w-24", mobile && "h-11 text-[16px]")} />
          </div>
          <FieldDescription>993 for implicit TLS, or 143 for STARTTLS.</FieldDescription>
        </Field>
        <Field>
          <FieldLabel htmlFor="e-smtp">SMTP server</FieldLabel>
          <div className="flex gap-2">
            <Input id="e-smtp" value={smtpHost} onChange={(e) => setSmtpHost(e.target.value)} className={cn("flex-1", mobile && "h-11 text-[16px]")} />
            <Input aria-label="SMTP port" type="number" value={smtpPort} onChange={(e) => setSmtpPort(Number(e.target.value))} className={cn("w-24", mobile && "h-11 text-[16px]")} />
          </div>
          <FieldDescription>465 for implicit TLS, 587 for STARTTLS. Port 25 is blocked by Cloudflare.</FieldDescription>
        </Field>
        <div>
          <Button size="sm" variant="outline" disabled={test.isPending} onClick={() => test.mutate(account.id, {
            onSuccess: (r: { ok: boolean; error?: string }) => (r.ok ? toast("Both servers answered") : toast.error(r.error ?? "Failed")),
            onError: (e: unknown) => toast.error((e as Error).message),
          })}>
            {test.isPending ? <Loader2 className="animate-spin" /> : null} Test stored credentials
          </Button>
        </div>
      </FieldGroup>
    </FormShell>
  );
}

/**
 * Common providers, so nobody has to look up host names. "Other" leaves the fields blank for a
 * cPanel-style webmail host, which is usually mail.<your-domain>.
 */
const IMAP_PRESETS: { id: string; label: string; imap_host: string; smtp_host: string; note?: string }[] = [
  { id: "zoho", label: "Zoho Mail (personal @zohomail.com)", imap_host: "imap.zoho.com", smtp_host: "smtp.zoho.com", note: "Enable IMAP under Settings → Mail Accounts, and use an app password if two-factor is on. IMAP needs a paid plan — the free plan is browser-only." },
  { id: "zoho-pro", label: "Zoho Mail (your own domain)", imap_host: "imappro.zoho.com", smtp_host: "smtppro.zoho.com", note: "Organisation accounts on a custom domain use the 'pro' servers. On a non-US data centre swap .com for .eu, .in or .com.au." },
  { id: "fastmail", label: "Fastmail", imap_host: "imap.fastmail.com", smtp_host: "smtp.fastmail.com", note: "Create an app password in Fastmail under Settings → Privacy & Security." },
  { id: "migadu", label: "Migadu", imap_host: "imap.migadu.com", smtp_host: "smtp.migadu.com" },
  { id: "other", label: "Other / webmail", imap_host: "", smtp_host: "", note: "For cPanel-style hosting this is usually mail.yourdomain.com on 993 and 465." },
];

export function AddImapDialog({ open, onOpenChange, variant = "dialog" }: { open: boolean; onOpenChange: (o: boolean) => void; variant?: "dialog" | "drawer" }) {
  const { create } = useImapMutations();
  const [preset, setPreset] = useState("zoho");
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [imapHost, setImapHost] = useState("imap.zoho.com");
  const [smtpHost, setSmtpHost] = useState("smtp.zoho.com");
  const [imapPort, setImapPort] = useState(993);
  const [smtpPort, setSmtpPort] = useState(465);
  const [imapSecurity, setImapSecurity] = useState<"tls" | "starttls">("tls");
  const [smtpSecurity, setSmtpSecurity] = useState<"tls" | "starttls">("tls");
  const [advanced, setAdvanced] = useState(false);

  const pickPreset = (id: string) => {
    setPreset(id);
    const pr = IMAP_PRESETS.find((x) => x.id === id)!;
    setImapHost(pr.imap_host);
    setSmtpHost(pr.smtp_host);
    setImapPort(993);
    setSmtpPort(465);
    setImapSecurity("tls");
    setSmtpSecurity("tls");
  };

  const close = () => {
    onOpenChange(false);
    setEmail(""); setName(""); setPassword(""); setAdvanced(false);
  };

  const submit = () =>
    create.mutate(
      {
        email: email.trim().toLowerCase(),
        display_name: name.trim(),
        imap_host: imapHost.trim(),
        imap_port: imapPort,
        imap_security: imapSecurity,
        smtp_host: smtpHost.trim(),
        smtp_port: smtpPort,
        smtp_security: smtpSecurity,
        password,
      },
      {
        onSuccess: (r: { account: { email: string } }) => { toast(`${r.account.email} is connected`); close(); },
        onError: (e: unknown) => toast.error("Couldn't connect", { description: (e as Error).message, duration: 12000 }),
      }
    );

  const mobile = variant === "drawer";
  const note = IMAP_PRESETS.find((x) => x.id === preset)?.note;
  const ready = email.trim() && password && imapHost.trim() && smtpHost.trim();

  return (
    <FormShell
      open={open}
      onClose={close}
      variant={variant}
      title="Add a mailbox"
      description="Connect any mailbox that speaks IMAP and SMTP — Zoho, Fastmail, Migadu or your own webmail."
      footer={
        <>
          <Button type="button" variant="ghost" size={mobile ? "lg" : "default"} onClick={close}>Cancel</Button>
          <Button type="button" size={mobile ? "lg" : "default"} disabled={!ready || create.isPending} onClick={submit}>
            {create.isPending ? <Loader2 className="animate-spin" /> : null} Connect
          </Button>
        </>
      }
    >
      <form onSubmit={(e) => { e.preventDefault(); if (ready) submit(); }}>
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor="imap-preset">Provider</FieldLabel>
            <select id="imap-preset" value={preset} onChange={(e) => pickPreset(e.target.value)} className={cn("rounded-md bg-input px-2.5 outline-none focus:bg-background focus:ring-1 focus:ring-ring", mobile ? "h-11 text-[16px]" : "h-8 text-sm")}>
              {IMAP_PRESETS.map((pr) => <option key={pr.id} value={pr.id}>{pr.label}</option>)}
            </select>
            {note ? <FieldDescription>{note}</FieldDescription> : null}
          </Field>
          <Field>
            <FieldLabel htmlFor="imap-email">Email address</FieldLabel>
            <Input id="imap-email" type="email" autoComplete="off" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" className={cn(mobile && "h-11 text-[16px]")} required />
          </Field>
          <Field>
            <FieldLabel htmlFor="imap-name">Display name</FieldLabel>
            <Input id="imap-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Sanjay" className={cn(mobile && "h-11 text-[16px]")} />
          </Field>
          <Field>
            <FieldLabel htmlFor="imap-pass">Password</FieldLabel>
            <Input id="imap-pass" type="password" autoComplete="off" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="App password" className={cn(mobile && "h-11 text-[16px]")} required />
            <FieldDescription>Stored encrypted on your server and never shown again. Use an app-specific password where your provider offers one.</FieldDescription>
          </Field>

          <Field orientation="horizontal">
            <Switch id="imap-adv" checked={advanced} onCheckedChange={setAdvanced} />
            <div>
              <FieldLabel htmlFor="imap-adv">Server settings</FieldLabel>
              <FieldDescription>Only needed for a host that is not in the list above.</FieldDescription>
            </div>
          </Field>

          {advanced ? (
            <>
              <Field>
                <FieldLabel htmlFor="imap-host">IMAP server</FieldLabel>
                <div className="flex gap-2">
                  <Input id="imap-host" value={imapHost} onChange={(e) => setImapHost(e.target.value)} placeholder="imap.example.com" className={cn("flex-1", mobile && "h-11 text-[16px]")} />
                  <Input aria-label="IMAP port" type="number" value={imapPort} onChange={(e) => { const v = Number(e.target.value); setImapPort(v); setImapSecurity(v === 143 ? "starttls" : "tls"); }} className={cn("w-24", mobile && "h-11 text-[16px]")} />
                </div>
                <FieldDescription>993 for implicit TLS, or 143 for STARTTLS.</FieldDescription>
              </Field>
              <Field>
                <FieldLabel htmlFor="smtp-host">SMTP server</FieldLabel>
                <div className="flex gap-2">
                  <Input id="smtp-host" value={smtpHost} onChange={(e) => setSmtpHost(e.target.value)} placeholder="smtp.example.com" className={cn("flex-1", mobile && "h-11 text-[16px]")} />
                  <Input aria-label="SMTP port" type="number" value={smtpPort} onChange={(e) => { const v = Number(e.target.value); setSmtpPort(v); setSmtpSecurity(v === 587 ? "starttls" : "tls"); }} className={cn("w-24", mobile && "h-11 text-[16px]")} />
                </div>
                <FieldDescription>
                  465 for implicit TLS, or 587 for STARTTLS. Port 25 is blocked by Cloudflare and cannot be used.
                </FieldDescription>
              </Field>
            </>
          ) : null}
        </FieldGroup>
      </form>
    </FormShell>
  );
}

const PROVIDER_LABELS: Record<string, { name: string; hint: string; docs: string }> = {
  google: { name: "Google", hint: "Client ID and secret from the Google Cloud OAuth client.", docs: "https://console.cloud.google.com/apis/credentials" },
  microsoft: { name: "Microsoft", hint: "Application (client) ID and a client secret from your Entra app registration.", docs: "https://portal.azure.com" },
};

function CredentialRow({ c, compact }: { c: OAuthCredentialStatus; compact?: boolean }) {
  const { save } = useOAuthMutations();
  const meta = PROVIDER_LABELS[c.provider];
  // A Worker secret is used by default, but you can take over here — otherwise a deployment set up
  // with `wrangler secret put` could never rotate an expiring secret without the CLI.
  const managed = c.source === "env";
  const [takingOver, setTakingOver] = useState(false);
  const showForm = !managed || takingOver;
  const [clientId, setClientId] = useState(c.client_id);
  const [secret, setSecret] = useState("");
  const [dirty, setDirty] = useState(false);
  useEffect(() => { if (!dirty) setClientId(c.client_id); }, [c.client_id, dirty]);

  const submit = () =>
    save.mutate(
      { provider: c.provider, client_id: clientId.trim(), client_secret: secret.trim() ? secret.trim() : undefined },
      {
        onSuccess: () => { toast(`${meta.name} credentials saved`); setSecret(""); setDirty(false); setTakingOver(false); },
        onError: (e: unknown) => toast.error((e as Error).message),
      }
    );

  const revert = () =>
    save.mutate(
      { provider: c.provider, override_env: false },
      { onSuccess: () => { toast(`Using the Worker secret for ${meta.name} again`); setTakingOver(false); }, onError: (e: unknown) => toast.error((e as Error).message) }
    );

  return (
    <div className="px-2 py-3 border-b border-border last:border-b-0">
      <div className="flex items-center gap-2 mb-2">
        <span className="text-sm font-medium">{meta.name}</span>
        {c.configured ? <Badge variant="secondary">Connected</Badge> : <Badge variant="outline">Not set</Badge>}
        {managed ? <Badge variant="outline">Worker secret</Badge> : null}
        {c.overriding ? <Badge variant="outline">Overriding Worker secret</Badge> : null}
      </div>
      {managed && !takingOver ? (
        <div className="text-[13px] text-muted-foreground space-y-2">
          <div>
            Currently using the <code className="text-[12px]">{c.provider === "google" ? "GOOGLE_CLIENT_SECRET" : "MS_CLIENT_SECRET"}</code>{" "}
            Worker secret. Rotate it with <code className="text-[12px]">wrangler secret put</code>, or manage it here instead.
          </div>
          <Button size="sm" variant="outline" onClick={() => { setTakingOver(true); setClientId(c.client_id); }}>
            Manage here instead
          </Button>
        </div>
      ) : (
        <FieldGroup>
          <Field>
            <FieldLabel htmlFor={`cid-${c.provider}`}>Client ID</FieldLabel>
            <Input id={`cid-${c.provider}`} value={clientId} autoComplete="off" onChange={(e) => { setClientId(e.target.value); setDirty(true); }} className={cn(compact && "h-11 text-[16px]")} />
          </Field>
          <Field>
            <FieldLabel htmlFor={`csec-${c.provider}`}>Client secret</FieldLabel>
            <Input id={`csec-${c.provider}`} type="password" autoComplete="off" value={secret} onChange={(e) => { setSecret(e.target.value); setDirty(true); }} placeholder={c.secret_hint ? `Stored · ${c.secret_hint}` : "Client secret"} className={cn(compact && "h-11 text-[16px]")} />
            <FieldDescription className="flex flex-wrap items-center gap-2">
              <span>{meta.hint} Encrypted on your server and never shown again.</span>
              {c.secret_hint ? (
                <button type="button" className="underline underline-offset-2" onClick={() => save.mutate({ provider: c.provider, client_secret: null }, { onSuccess: () => toast("Secret removed") })}>Remove</button>
              ) : null}
            </FieldDescription>
          </Field>
          {managed && takingOver ? (
            <div className="rounded-md bg-muted/60 px-3 py-2 text-[13px]">
              Saving will use these credentials instead of the Worker secret. Enter both a client ID and a secret.
            </div>
          ) : null}
          <div className="flex items-center gap-2">
            <Button size={compact ? "lg" : "sm"} disabled={save.isPending || (!dirty && !secret)} onClick={submit}>
              {save.isPending ? <Loader2 className="animate-spin" /> : null} Save
            </Button>
            {takingOver ? <Button size={compact ? "lg" : "sm"} variant="ghost" onClick={() => { setTakingOver(false); setSecret(""); setDirty(false); }}>Cancel</Button> : null}
            {c.overriding ? <Button size={compact ? "lg" : "sm"} variant="ghost" onClick={revert} disabled={save.isPending}>Use the Worker secret</Button> : null}
          </div>
        </FieldGroup>
      )}
    </div>
  );
}

/** Manage the OAuth app credentials used to connect Gmail and Outlook. */
export function ConnectorCredentialsSection({ compact }: { compact?: boolean }) {
  const { data, isLoading } = useOAuthCredentials();
  return (
    <Section title="Provider credentials" description="The OAuth apps heyflare uses to connect Gmail and Outlook. Rotate a secret here without redeploying.">
      {isLoading ? (
        <div className="px-2 py-2"><Skeleton className="h-16 w-full" /></div>
      ) : (
        <div>{(data ?? []).map((c) => <CredentialRow key={c.provider} c={c} compact={compact} />)}</div>
      )}
    </Section>
  );
}

export function AccountsSection({ onNewMailbox }: { onNewMailbox?: () => void }) {
  const { accounts, googleConfigured, microsoftConfigured } = useAccount();
  const [addImap, setAddImap] = useState(false);
  const remote = accounts.filter((a) => a.provider !== "domain");
  const boxes = accounts.filter((a) => a.provider === "domain");
  return (
    <>
      <AddImapDialog open={addImap} onOpenChange={setAddImap} />
      <Section
        title="Connected accounts"
        description="What's connected, and how it signs off."
        actions={
          <div className="flex items-center gap-1">
            {googleConfigured ? (
              <Button size="sm" variant="ghost" className="text-muted-foreground" asChild><a href="/auth/google/start"><Plus /> Connect Gmail</a></Button>
            ) : null}
            {microsoftConfigured ? (
              <Button size="sm" variant="ghost" className="text-muted-foreground" asChild><a href="/auth/microsoft/start"><Plus /> Connect Outlook</a></Button>
            ) : null}
            <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={() => setAddImap(true)}><Plus /> Add mailbox</Button>
          </div>
        }
      >
        {!googleConfigured || !microsoftConfigured ? (
          <div className="mx-2 mb-3 rounded-md bg-muted/60 px-3 py-2 text-[13px] text-muted-foreground">
            {!googleConfigured && !microsoftConfigured ? "Gmail and Outlook need" : !googleConfigured ? "Gmail needs" : "Outlook needs"} an OAuth
            client before {!googleConfigured && !microsoftConfigured ? "they" : "it"} can be connected — add the credentials under{" "}
            <strong>Provider credentials</strong> below. IMAP mailboxes need no setup.
          </div>
        ) : null}
        {remote.length === 0 ? (
          <div className="px-2 py-2 text-[13px] text-muted-foreground">Nothing connected yet.</div>
        ) : (
          <div>{remote.map((a) => <AccountBlock key={a.id} a={a} />)}</div>
        )}
      </Section>
      <ConnectorCredentialsSection />
      <Section
        title="Domain mailboxes"
        description="Addresses on your own domains."
        actions={onNewMailbox ? <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={onNewMailbox}><Plus /> New mailbox</Button> : undefined}
      >
        {boxes.length === 0 ? (
          <div className="px-2 py-2 text-[13px] text-muted-foreground">No mailboxes yet. Add a domain first.</div>
        ) : (
          <div>{boxes.map((a) => <AccountBlock key={a.id} a={a} />)}</div>
        )}
      </Section>
    </>
  );
}

export function SecuritySection({ compact }: { compact?: boolean }) {
  const { password } = useMeMutations();
  const [cur, setCur] = useState("");
  const [next, setNext] = useState("");
  const inputCls = compact ? "h-11 text-[16px]" : undefined;
  return (
    <>
      <Section title="Password" description="Use at least 8 characters. Sessions on other devices stay signed in.">
        <form
          className={cn("px-2", !compact && "max-w-sm")}
          onSubmit={(e) => {
            e.preventDefault();
            password.mutate({ current: cur, next }, { onSuccess: () => { toast("Password changed"); setCur(""); setNext(""); }, onError: (er) => toast.error((er as Error).message) });
          }}
        >
          <FieldGroup className="gap-4">
            <Field>
              <FieldLabel htmlFor="pw-cur">Current password</FieldLabel>
              <Input id="pw-cur" type="password" value={cur} onChange={(e) => setCur(e.target.value)} autoComplete="current-password" required className={inputCls} />
            </Field>
            <Field>
              <FieldLabel htmlFor="pw-next">New password</FieldLabel>
              <Input id="pw-next" type="password" minLength={8} value={next} onChange={(e) => setNext(e.target.value)} autoComplete="new-password" required className={inputCls} />
              {next && next.length < 8 && <FieldDescription>{8 - next.length} more character{8 - next.length === 1 ? "" : "s"}</FieldDescription>}
            </Field>
          </FieldGroup>
          <Button type="submit" size={compact ? "lg" : "sm"} className={cn("mt-4", compact && "w-full")} disabled={!cur || next.length < 8 || password.isPending}>
            <KeyRound /> Change password
          </Button>
        </form>
      </Section>
      <TwoFactorBlock compact={compact} />
    </>
  );
}

/* ---------- Two-factor authentication ---------- */

function RecoveryCodes({ codes }: { codes: string[] }) {
  const [copied, setCopied] = useState(false);
  return (
    <div>
      <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 rounded-md bg-muted px-4 py-3 font-mono text-[13px] tnum">
        {codes.map((c) => <span key={c}>{c}</span>)}
      </div>
      <Button
        type="button"
        variant="ghost"
        size="sm"
        className="mt-2 text-muted-foreground"
        onClick={() => { navigator.clipboard.writeText(codes.join("\n")).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1500); }); }}
      >
        {copied ? <Check /> : <Copy />} {copied ? "Copied" : "Copy all"}
      </Button>
    </div>
  );
}

function TwoFactorBlock({ compact }: { compact?: boolean }) {
  const status = useTwoFactor();
  const { setup, enable, regenerate, disable } = useTwoFactorMutations();
  const variant = compact ? "drawer" : "dialog";
  const inputCls = compact ? "h-11 text-[16px]" : undefined;

  // Enable flow
  const [enableOpen, setEnableOpen] = useState(false);
  const [secret, setSecret] = useState("");
  const [qr, setQr] = useState("");
  const [code, setCode] = useState("");
  const [codes, setCodes] = useState<string[] | null>(null);
  const [copiedSecret, setCopiedSecret] = useState(false);
  // Regenerate / disable flows
  const [regenOpen, setRegenOpen] = useState(false);
  const [regenCode, setRegenCode] = useState("");
  const [disableOpen, setDisableOpen] = useState(false);
  const [dPassword, setDPassword] = useState("");
  const [dCode, setDCode] = useState("");

  const startEnable = () => {
    setCode(""); setCodes(null); setQr(""); setSecret("");
    setEnableOpen(true);
    setup.mutate(undefined, {
      onSuccess: async (r) => {
        setSecret(r.secret);
        try {
          setQr(await QRCode.toDataURL(r.otpauth_url, { margin: 1, width: 192, color: { dark: "#000000", light: "#ffffff" } }));
        } catch {
          setQr("");
        }
      },
      onError: (e) => { toast.error((e as Error).message); setEnableOpen(false); },
    });
  };

  const enabled = !!status.data?.enabled;
  const left = status.data?.recovery_left ?? 0;

  return (
    <Section title="Two-factor authentication" description="A second step at login using an authenticator app (Google Authenticator, 1Password, Authy…). Nothing leaves this server.">
      <div className={cn("px-2 flex items-center justify-between gap-4", compact && "flex-col items-stretch")}>
        <div className="flex items-center gap-3 min-w-0">
          <span className={cn("size-8 rounded-md flex items-center justify-center shrink-0", enabled ? "bg-foreground text-background" : "bg-muted text-muted-foreground")}><ShieldCheck size={16} /></span>
          <div className="min-w-0">
            <div className="text-sm font-medium">{status.isLoading ? "…" : enabled ? "On" : "Off"}</div>
            <div className="text-xs text-muted-foreground">
              {enabled ? `${left} recovery code${left === 1 ? "" : "s"} left` : "Protect your login with a one-time code."}
            </div>
          </div>
        </div>
        <div className={cn("flex items-center gap-2 shrink-0", compact && "flex-col items-stretch")}>
          {enabled ? (
            <>
              <Button type="button" variant="outline" size={compact ? "lg" : "sm"} onClick={() => { setRegenCode(""); setRegenOpen(true); }}>Regenerate recovery codes</Button>
              <Button type="button" variant="ghost" size={compact ? "lg" : "sm"} className="text-muted-foreground" onClick={() => { setDPassword(""); setDCode(""); setDisableOpen(true); }}>Turn off</Button>
            </>
          ) : (
            <Button type="button" size={compact ? "lg" : "sm"} onClick={startEnable} disabled={status.isLoading}>Turn on</Button>
          )}
        </div>
      </div>

      {/* Enable: QR + verify, then recovery codes */}
      <FormShell
        open={enableOpen}
        onClose={() => { if (!codes) setEnableOpen(false); }}
        variant={variant}
        title={codes ? "Save your recovery codes" : "Set up your authenticator"}
        description={codes ? "Each code works once if you lose your authenticator. Keep them somewhere safe — they won't be shown again." : "Scan the code with your authenticator app, then enter the 6-digit code it shows."}
        footer={
          codes ? (
            <Button type="button" size={compact ? "lg" : "default"} onClick={() => { setEnableOpen(false); setCodes(null); }}>I've saved these</Button>
          ) : (
            <>
              <Button type="button" variant="ghost" size={compact ? "lg" : "default"} onClick={() => setEnableOpen(false)}>Cancel</Button>
              <Button
                type="button"
                size={compact ? "lg" : "default"}
                disabled={!secret || code.replace(/\s/g, "").length !== 6 || enable.isPending}
                onClick={() => enable.mutate({ code }, { onSuccess: (r) => { setCodes(r.recovery_codes); toast("Two-factor authentication is on"); }, onError: (e) => toast.error(/invalid code/i.test((e as Error).message) ? "That code isn't right. Try the next one." : (e as Error).message) })}
              >
                Verify & turn on
              </Button>
            </>
          )
        }
      >
        {codes ? (
          <RecoveryCodes codes={codes} />
        ) : (
          <div className="space-y-4">
            <div className="flex items-center justify-center">
              {qr ? (
                <img src={qr} alt="Authenticator QR code" width={192} height={192} className="rounded-md bg-white p-1" />
              ) : (
                <Skeleton className="size-48 rounded-md" />
              )}
            </div>
            <div className="text-xs text-muted-foreground">Can't scan? Enter this key manually:</div>
            <div className="flex items-center gap-2">
              <code className="flex-1 min-w-0 truncate rounded-md bg-muted px-2.5 py-1.5 font-mono text-[12px] tracking-wider">{secret ? secret.replace(/(.{4})/g, "$1 ").trim() : "…"}</code>
              <Button type="button" variant="ghost" size="icon-sm" aria-label="Copy key" disabled={!secret} onClick={() => navigator.clipboard.writeText(secret).then(() => { setCopiedSecret(true); setTimeout(() => setCopiedSecret(false), 1500); })}>
                {copiedSecret ? <Check /> : <Copy />}
              </Button>
            </div>
            <Field>
              <FieldLabel htmlFor="tfa-code">6-digit code</FieldLabel>
              <Input id="tfa-code" inputMode="numeric" autoComplete="one-time-code" placeholder="123456" value={code} onChange={(e) => setCode(e.target.value)} className={cn("font-mono tracking-[0.3em]", inputCls)} autoFocus={!compact} />
            </Field>
          </div>
        )}
      </FormShell>

      {/* Regenerate recovery codes */}
      <FormShell
        open={regenOpen}
        onClose={() => { if (!codes) setRegenOpen(false); else { setRegenOpen(false); setCodes(null); } }}
        variant={variant}
        title={codes ? "Your new recovery codes" : "Regenerate recovery codes"}
        description={codes ? "The old codes no longer work." : "Enter a code from your authenticator to confirm. Your old codes stop working."}
        footer={
          codes ? (
            <Button type="button" size={compact ? "lg" : "default"} onClick={() => { setRegenOpen(false); setCodes(null); }}>I've saved these</Button>
          ) : (
            <>
              <Button type="button" variant="ghost" size={compact ? "lg" : "default"} onClick={() => setRegenOpen(false)}>Cancel</Button>
              <Button type="button" size={compact ? "lg" : "default"} disabled={regenCode.replace(/\s/g, "").length !== 6 || regenerate.isPending} onClick={() => regenerate.mutate({ code: regenCode }, { onSuccess: (r) => setCodes(r.recovery_codes), onError: (e) => toast.error(/invalid code/i.test((e as Error).message) ? "That code isn't right." : (e as Error).message) })}>
                Regenerate
              </Button>
            </>
          )
        }
      >
        {codes ? (
          <RecoveryCodes codes={codes} />
        ) : (
          <Field>
            <FieldLabel htmlFor="tfa-regen">Authenticator code</FieldLabel>
            <Input id="tfa-regen" inputMode="numeric" autoComplete="one-time-code" placeholder="123456" value={regenCode} onChange={(e) => setRegenCode(e.target.value)} className={cn("font-mono tracking-[0.3em]", inputCls)} autoFocus={!compact} />
          </Field>
        )}
      </FormShell>

      {/* Disable */}
      <FormShell
        open={disableOpen}
        onClose={() => setDisableOpen(false)}
        variant={variant}
        title="Turn off two-factor authentication"
        description="Confirm with your password and a code from your authenticator (or a recovery code)."
        footer={
          <>
            <Button type="button" variant="ghost" size={compact ? "lg" : "default"} onClick={() => setDisableOpen(false)}>Cancel</Button>
            <Button type="button" variant="outline" size={compact ? "lg" : "default"} disabled={!dPassword || !dCode.trim() || disable.isPending} onClick={() => disable.mutate({ password: dPassword, code: dCode }, { onSuccess: () => { setDisableOpen(false); toast("Two-factor authentication is off"); }, onError: (e) => toast.error((e as Error).message) })}>
              Turn off
            </Button>
          </>
        }
      >
        <FieldGroup className="gap-4">
          <Field>
            <FieldLabel htmlFor="tfa-dpw">Password</FieldLabel>
            <Input id="tfa-dpw" type="password" autoComplete="current-password" value={dPassword} onChange={(e) => setDPassword(e.target.value)} className={inputCls} autoFocus={!compact} />
          </Field>
          <Field>
            <FieldLabel htmlFor="tfa-dcode">Authenticator or recovery code</FieldLabel>
            <Input id="tfa-dcode" autoComplete="one-time-code" placeholder="123456 or xxxx-xxxx" value={dCode} onChange={(e) => setDCode(e.target.value)} className={cn("font-mono", inputCls)} />
          </Field>
        </FieldGroup>
      </FormShell>
    </Section>
  );
}

/* ---------- Page ---------- */

export default function SettingsPage() {
  useCardScroll();
  const { user } = useAccount();
  const loc = useLocation();
  const nav = useNavigate();
  const tab = ((loc.hash.replace("#", "") || "profile") as Tab);
  const setTab = (t: string) => nav({ hash: t }, { replace: true });
  if (!user) return null;

  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader title="Settings" />
      <Tabs value={TABS.some((t) => t.key === tab) ? tab : "profile"} onValueChange={setTab} className="gap-6">
        <div className="px-2 -mx-2 overflow-x-auto [scrollbar-width:none] border-b border-border">
          <TabsList variant="line" className="w-max px-2">
            {TABS.map((t) => (
              <TabsTrigger key={t.key} value={t.key} className="gap-1.5 px-2 text-muted-foreground data-active:text-foreground [&>svg]:size-3.5">
                {t.icon}
                {t.label}
              </TabsTrigger>
            ))}
          </TabsList>
        </div>
        <TabsContent value="profile"><ProfileSection /></TabsContent>
        <TabsContent value="preferences"><PreferencesSection /></TabsContent>
        <TabsContent value="accounts"><AccountsSection onNewMailbox={() => setTab("domains")} /></TabsContent>
        <TabsContent value="domains"><DomainsSection /></TabsContent>
        <TabsContent value="calendar"><CalendarSettingsSection /></TabsContent>
        <TabsContent value="ai"><AiSection /></TabsContent>
        <TabsContent value="security"><SecuritySection /></TabsContent>
      </Tabs>
    </div>
  );
}
