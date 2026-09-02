import { useEffect, useState, type ReactNode } from "react";
import { Link, Navigate, useNavigate, useParams } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { ChevronRight, Globe, KeyRound, LogOut, Mail, Monitor, Moon, Plus, RefreshCw, SlidersHorizontal, Sun, Trash2, Unplug, User } from "lucide-react";
import { toast } from "sonner";
import type { Account, Domain } from "@shared/types";
import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { api, domainErrorMessage, useAccountMutations, useDomainMutations, useDomains, useMeMutations } from "../api";
import { useAccount } from "../context/AccountContext";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { fmtRelative } from "../lib/format";
import { startGoogleConnect } from "../lib/connect";
import { AddDomainDialog, CopyButton, Danger, DomainBadges, NewMailboxDialog, PreferencesSection, ProfileSection, SecuritySection, statusOf } from "../pages/Settings";
import { Screen } from "./Screen";
import { ActionSheet } from "./ActionSheet";

/* ---------- list building blocks (iOS-style grouped rows) ---------- */

function Group({ title, children, footer }: { title?: string; children: ReactNode; footer?: ReactNode }) {
  return (
    <section className="mt-3">
      {title && <div className="px-4 h-8 flex items-center text-[12px] font-medium text-muted-foreground">{title}</div>}
      <div className="divide-y divide-border/60">{children}</div>
      {footer && <div className="px-4 pt-2 text-[12px] text-muted-foreground">{footer}</div>}
    </section>
  );
}

function Row({ to, icon, label, sub, count, hint, onClick, destructive, chevron = true, leading }: { to?: string; icon?: ReactNode; label: ReactNode; sub?: ReactNode; count?: number; hint?: ReactNode; onClick?: () => void; destructive?: boolean; chevron?: boolean; leading?: ReactNode }) {
  const inner = (
    <>
      {leading ?? (icon && <span className="text-muted-foreground [&>svg]:size-5 shrink-0">{icon}</span>)}
      <span className="flex-1 min-w-0">
        <span className={cn("block text-[15px] truncate", destructive ? "text-foreground" : "text-foreground")}>{label}</span>
        {sub && <span className="block text-[13px] text-muted-foreground truncate">{sub}</span>}
      </span>
      {count != null && count > 0 && <span className="text-[13px] text-muted-foreground tnum">{count}</span>}
      {hint && <span className="text-[13px] text-muted-foreground shrink-0 max-w-[45%] truncate">{hint}</span>}
      {chevron && <ChevronRight size={16} className="text-tertiary shrink-0" />}
    </>
  );
  const cls = cn("flex items-center gap-3 min-h-[52px] px-4 py-2 active:bg-muted w-full text-left", destructive && "font-medium");
  if (to) return <Link to={to} className={cls}>{inner}</Link>;
  return <button type="button" onClick={onClick} className={cls}>{inner}</button>;
}

function Sub({ title, children, back = "/settings", backLabel = "Settings" }: { title: ReactNode; children: ReactNode; back?: string; backLabel?: string }) {
  return (
    <Screen title={title} back={back} backLabel={backLabel} tabs>
      <div className="pb-6">{children}</div>
    </Screen>
  );
}

/* ---------- Root ---------- */

export default function MobileSettings() {
  const { user, accounts } = useAccount();
  const domains = useDomains();
  const { update } = useMeMutations();
  const nav = useNavigate();
  const qc = useQueryClient();
  const [themeOpen, setThemeOpen] = useState(false);
  const theme = user?.settings?.theme ?? "system";
  const setTheme = (t: "light" | "dark" | "system") => update.mutate({ settings: { ...(user?.settings ?? {}), theme: t } });
  const logout = async () => {
    await api.post("/auth/logout");
    qc.clear();
    nav("/login");
  };
  if (!user) return null;
  return (
    <Screen title="Settings" largeTitle back="/more" backLabel="More">
      <Link to="/settings/profile" className="mx-4 mb-1 flex items-center gap-3 rounded-lg bg-muted/50 active:bg-muted px-3 py-3">
        <Avatar email={user.email} name={user.name} src={accounts.find((a) => a.avatar_url)?.avatar_url} size={44} />
        <div className="min-w-0 flex-1">
          <div className="text-[16px] font-medium truncate">{user.name || user.email}</div>
          <div className="text-[13px] text-muted-foreground truncate">{user.email}</div>
        </div>
        <ChevronRight size={16} className="text-tertiary" />
      </Link>
      <Group>
        <Row to="/settings/profile" icon={<User />} label="Profile" />
        <Row to="/settings/preferences" icon={<SlidersHorizontal />} label="Preferences" />
        <Row to="/settings/accounts" icon={<Mail />} label="Accounts" count={accounts.length} />
        <Row to="/settings/domains" icon={<Globe />} label="Domains" count={domains.data?.length} />
        <Row to="/settings/security" icon={<KeyRound />} label="Security" />
      </Group>
      <Group title="App">
        <Row icon={theme === "dark" ? <Moon /> : theme === "light" ? <Sun /> : <Monitor />} label="Appearance" hint={theme === "system" ? "System" : theme === "dark" ? "Dark" : "Light"} onClick={() => setThemeOpen(true)} />
        <Row icon={<LogOut />} label="Log out" onClick={logout} chevron={false} />
      </Group>
      <div className="px-4 py-6 text-center text-[12px] text-muted-foreground">heyflare · {user.email}</div>
      <ActionSheet
        open={themeOpen}
        onOpenChange={setThemeOpen}
        title="Appearance"
        actions={[
          { icon: <Sun />, label: "Light", checked: theme === "light", onSelect: () => setTheme("light") },
          { icon: <Moon />, label: "Dark", checked: theme === "dark", onSelect: () => setTheme("dark") },
          { icon: <Monitor />, label: "System", checked: theme === "system", onSelect: () => setTheme("system") },
        ]}
      />
    </Screen>
  );
}

/* ---------- Simple sub-screens (sections restyled for touch) ---------- */

const sectionCls = "px-4 pt-3 [&_section]:mb-6 [&_h2]:text-[15px] [&_input]:text-[16px] [&_textarea]:text-[16px]";

export function MobileSettingsProfile() {
  return (
    <Sub title="Profile">
      <div className={sectionCls}><ProfileSection compact /></div>
    </Sub>
  );
}
export function MobileSettingsPreferences() {
  return (
    <Sub title="Preferences">
      <div className={sectionCls}><PreferencesSection compact /></div>
    </Sub>
  );
}
export function MobileSettingsSecurity() {
  return (
    <Sub title="Security">
      <div className={sectionCls}><SecuritySection compact /></div>
    </Sub>
  );
}

/* ---------- Accounts ---------- */

function AccountRow({ a }: { a: Account }) {
  const { glyphFor, multi } = useAccount();
  const st = statusOf(a);
  return (
    <Row
      to={`/settings/accounts/${a.id}`}
      leading={<Avatar email={a.email} name={a.display_name} src={a.avatar_url} size={36} />}
      label={
        <span className="inline-flex items-center gap-1.5 min-w-0">
          {multi && <AccountGlyph glyph={glyphFor(a.id)} />}
          <span className="truncate">{a.email}</span>
        </span>
      }
      sub={
        <span className="inline-flex items-center gap-1.5">
          {st.spin && <RefreshCw size={11} className="animate-spin" />}
          {st.label}
          {a.provider === "gmail" && a.last_synced_at && <span>· {fmtRelative(a.last_synced_at)}</span>}
        </span>
      }
    />
  );
}

export function MobileSettingsAccounts() {
  const { accounts } = useAccount();
  const gmail = accounts.filter((a) => a.provider !== "domain");
  const boxes = accounts.filter((a) => a.provider === "domain");
  return (
    <Sub title="Accounts">
      <Group title="Gmail" footer={gmail.length === 0 ? "No Gmail connected yet." : undefined}>
        {gmail.map((a) => <AccountRow key={a.id} a={a} />)}
        <Row icon={<Plus />} label="Connect Gmail" onClick={() => startGoogleConnect()} chevron={false} />
      </Group>
      <Group title="Domain mailboxes" footer={boxes.length === 0 ? "No mailboxes yet. Add a domain first." : undefined}>
        {boxes.map((a) => <AccountRow key={a.id} a={a} />)}
        <Row to="/settings/domains" icon={<Globe />} label="Manage domains" />
      </Group>
    </Sub>
  );
}

export function MobileSettingsAccountDetail() {
  const { id } = useParams();
  const { accounts, glyphFor, multi } = useAccount();
  const { update, remove, sync, reset } = useAccountMutations();
  const nav = useNavigate();
  const a = accounts.find((x) => x.id === id);
  const [signature, setSignature] = useState(a?.signature ?? "");
  const [displayName, setDisplayName] = useState(a?.display_name ?? "");
  const [confirmReset, setConfirmReset] = useState(false);
  const [confirm, setConfirm] = useState(false);
  useEffect(() => { if (a) { setSignature(a.signature); setDisplayName(a.display_name); } }, [a?.signature, a?.display_name]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!a) return <Navigate to="/settings/accounts" replace />;
  const st = statusOf(a);
  const isGmail = a.provider === "gmail";
  const dirty = signature !== a.signature || displayName !== a.display_name;
  const save = () => update.mutate({ id: a.id, signature, display_name: displayName }, { onSuccess: () => toast("Saved"), onError: (e) => toast.error((e as Error).message) });
  return (
    <Sub title={isGmail ? "Gmail account" : "Mailbox"} back="/settings/accounts" backLabel="Accounts">
      <div className="px-4 pt-3 pb-2 flex items-center gap-3">
        <Avatar email={a.email} name={a.display_name} src={a.avatar_url} size={56} />
        <div className="min-w-0 flex-1">
          <div className="text-[16px] font-medium truncate flex items-center gap-1.5">{multi && <AccountGlyph glyph={glyphFor(a.id)} />}<span className="truncate">{a.email}</span></div>
          <div className="text-[13px] text-muted-foreground flex items-center gap-1.5 flex-wrap">
            <Badge variant="outline" className="font-normal text-muted-foreground">{isGmail ? "Gmail" : "Mailbox"}</Badge>
            <span className="inline-flex items-center gap-1">{st.spin && <RefreshCw size={11} className="animate-spin" />}{st.label}</span>
            {isGmail && a.last_synced_at && <span>· {fmtRelative(a.last_synced_at)}</span>}
          </div>
          {a.sync_error && <div className="text-[12px] text-muted-foreground mt-0.5">{a.sync_error}</div>}
        </div>
      </div>
      {isGmail && (
        <Group>
          <Row icon={<RefreshCw className={cn(sync.isPending && "animate-spin")} />} label="Sync now" chevron={false} onClick={() => sync.mutate(a.id, { onSuccess: (r) => toast(`Synced${r.added != null ? ` · ${r.added} new` : ""}`), onError: (e) => toast.error((e as Error).message) })} />
          {(a.sync_status === "disconnected" || !a.photos_synced_at) && (
            <Row icon={<Mail />} label="Reconnect Gmail" sub={a.sync_status === "disconnected" ? "The connection expired." : "Enables contact photos."} chevron={false} onClick={() => startGoogleConnect(a.email)} />
          )}
        </Group>
      )}
      <Group title="Sending">
        <div className="px-4 py-3 space-y-4">
          <label className="block">
            <span className="block text-[13px] text-muted-foreground mb-1.5">Display name</span>
            <Input value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="Shown as the sender name" className="h-11 text-[16px]" />
          </label>
          <label className="block">
            <span className="block text-[13px] text-muted-foreground mb-1.5">Signature</span>
            <Textarea rows={4} className="font-mono text-[14px]" value={signature} onChange={(e) => setSignature(e.target.value)} placeholder="HTML allowed. Added under new messages." />
          </label>
          <Button size="lg" className="w-full" onClick={save} disabled={!dirty || update.isPending}>Save</Button>
        </div>
      </Group>
      <Group title="Danger zone">
        {isGmail && <Row icon={<RefreshCw />} label="Start fresh" sub="Wipe synced mail, keep the connection" chevron={false} onClick={() => setConfirmReset(true)} />}
        <Row icon={isGmail ? <Unplug /> : <Trash2 />} label={isGmail ? "Disconnect account" : "Delete mailbox"} chevron={false} destructive onClick={() => setConfirm(true)} />
      </Group>
      <Danger
        open={confirmReset}
        onOpenChange={setConfirmReset}
        title={`Start fresh with ${a.email}?`}
        body="This deletes everything heyflare has synced for this account — threads, contacts, screener decisions, clips, drafts. Gmail itself is untouched. New mail from now on will go through the Screener."
        action="Start fresh"
        onConfirm={() => reset.mutate(a.id, { onSuccess: (r) => (r.sync_error ? toast.error(`Reset done, but the first sync failed: ${r.sync_error}`) : toast("Starting fresh — watching for new mail from now on")), onError: (e) => toast.error((e as Error).message) })}
      />
      <Danger
        open={confirm}
        onOpenChange={setConfirm}
        title={isGmail ? `Disconnect ${a.email}?` : `Delete ${a.email}?`}
        body={isGmail ? "This removes the account and all of its synced mail from heyflare. Nothing changes in Gmail." : "This deletes the mailbox and every message stored in it. Mail sent to this address will bounce (or land in the domain's catch-all)."}
        action={isGmail ? "Disconnect" : "Delete mailbox"}
        onConfirm={() => remove.mutate(a.id, { onSuccess: () => nav("/settings/accounts", { replace: true }), onError: (e) => toast.error((e as Error).message) })}
      />
    </Sub>
  );
}

/* ---------- Domains ---------- */

export function MobileSettingsDomains() {
  const q = useDomains();
  const [add, setAdd] = useState(false);
  const list = q.data ?? [];
  return (
    <Sub title="Domains">
      <div className="px-4 pt-3 pb-1 text-[13px] text-muted-foreground">Receive at your own addresses through Cloudflare Email Routing, and send from them.</div>
      <Group footer={!q.isLoading && list.length === 0 ? "No domains yet. Add one that lives on your Cloudflare account, then create mailboxes on it." : undefined}>
        {list.map((d) => (
          <Row
            key={d.id}
            to={`/settings/domains/${d.id}`}
            icon={<Globe />}
            label={d.name}
            sub={<span className="inline-flex items-center gap-1.5">{d.status === "active" ? "Active" : d.status === "error" ? "Error" : "Pending"} · {d.mailboxes.length} mailbox{d.mailboxes.length === 1 ? "" : "es"}</span>}
          />
        ))}
        <Row icon={<Plus />} label="Add domain" chevron={false} onClick={() => setAdd(true)} />
      </Group>
      <AddDomainDialog open={add} onOpenChange={setAdd} variant="drawer" />
    </Sub>
  );
}

export function MobileSettingsDomainDetail() {
  const { id } = useParams();
  const q = useDomains();
  const { verify, patch, remove } = useDomainMutations();
  const nav = useNavigate();
  const [newBox, setNewBox] = useState(false);
  const [del, setDel] = useState(false);
  const [catchOpen, setCatchOpen] = useState(false);
  const d: Domain | undefined = q.data?.find((x) => x.id === id);
  if (q.isLoading) return <Sub title="Domain" back="/settings/domains" backLabel="Domains"><div className="px-4 pt-4 text-[13px] text-muted-foreground">Loading…</div></Sub>;
  if (!d) return <Navigate to="/settings/domains" replace />;
  const manual = d.routing !== "enabled";
  const catchAll = d.mailboxes.find((m) => m.id === d.catch_all_account_id);
  return (
    <Sub title={d.name} back="/settings/domains" backLabel="Domains">
      <div className="px-4 pt-3 pb-1">
        <DomainBadges d={d} />
        {d.error && <div className="text-[13px] text-muted-foreground mt-2">{d.error}</div>}
      </div>
      <Group>
        <Row icon={<RefreshCw className={cn(verify.isPending && "animate-spin")} />} label="Verify setup" sub="Re-check routing on Cloudflare" chevron={false} onClick={() => verify.mutate(d.id, { onSuccess: (r) => toast(r.status === "active" ? `${d.name} is receiving mail` : `${d.name}: ${r.error ?? "still pending"}`), onError: (e) => toast.error(domainErrorMessage(e)) })} />
      </Group>
      {manual && d.instructions.length > 0 && (
        <Group title="Set up receiving">
          <ol className="list-decimal pl-9 pr-4 py-2 space-y-2 text-[14px] leading-5">
            {d.instructions.filter((s) => !/^Outbound/.test(s)).map((s, i) => <li key={i}>{s}</li>)}
          </ol>
        </Group>
      )}
      {manual && d.dns.length > 0 && (
        <Group title="DNS records">
          {d.dns.map((r, i) => (
            <div key={i} className="flex items-start gap-3 px-4 py-2.5">
              <span className="font-mono text-[11px] text-muted-foreground w-9 shrink-0 pt-0.5">{r.type}</span>
              <div className="min-w-0 flex-1">
                <div className="font-mono text-[12px] truncate">{r.name}</div>
                <div className="font-mono text-[12px] text-muted-foreground break-all">{r.content}{r.priority != null && <span className="ml-1">· {r.priority}</span>}</div>
              </div>
              <CopyButton text={r.content} />
            </div>
          ))}
        </Group>
      )}
      <Group title="Mailboxes" footer={d.mailboxes.length === 0 ? "No mailboxes yet. Create one to start receiving." : "Signatures, display names and deletion live under Accounts."}>
        {d.mailboxes.map((m) => (
          <Row
            key={m.id}
            to={`/settings/accounts/${m.id}`}
            leading={<Avatar email={m.email} name={m.display_name} src={m.avatar_url} size={36} />}
            label={m.email}
            sub={m.display_name || undefined}
            hint={d.catch_all_account_id === m.id ? <Badge variant="secondary" className="font-normal text-muted-foreground">catch-all</Badge> : undefined}
          />
        ))}
        <Row icon={<Plus />} label="New mailbox" chevron={false} onClick={() => setNewBox(true)} />
      </Group>
      <Group title="Delivery" footer={`Where mail to unknown addresses on ${d.name} goes. Off means it bounces.`}>
        <Row icon={<Mail />} label="Catch-all mailbox" hint={catchAll ? catchAll.email : "Off"} onClick={() => setCatchOpen(true)} />
      </Group>
      <div className="px-4 pt-3 text-[13px] text-muted-foreground">
        {d.sending === "cloudflare" && <>Outbound mail from these mailboxes goes through Cloudflare Email Sending.</>}
        {d.sending === "resend" && <>Outbound mail from these mailboxes goes through Resend. Make sure {d.name} is verified there.</>}
        {d.sending === "none" && <>Outbound isn't configured yet, so these mailboxes can receive but not send. Enable Cloudflare Email Sending and add the <code className="font-mono text-xs">send_email</code> binding, or set a <code className="font-mono text-xs">RESEND_API_KEY</code> secret — see README.</>}
      </div>
      <Group title="Danger zone">
        <Row icon={<Trash2 />} label="Remove domain" chevron={false} destructive onClick={() => setDel(true)} />
      </Group>
      <NewMailboxDialog d={d} open={newBox} onOpenChange={setNewBox} variant="drawer" />
      <ActionSheet
        open={catchOpen}
        onOpenChange={setCatchOpen}
        title="Catch-all mailbox"
        actions={[
          { label: "Off (bounce)", checked: !d.catch_all_account_id, onSelect: () => patch.mutate({ id: d.id, catch_all_account_id: null }, { onError: (e) => toast.error(domainErrorMessage(e)) }) },
          ...d.mailboxes.map((m) => ({ label: m.email, checked: d.catch_all_account_id === m.id, onSelect: () => patch.mutate({ id: d.id, catch_all_account_id: m.id }, { onError: (e) => toast.error(domainErrorMessage(e)) }) })),
        ]}
      />
      <Danger
        open={del}
        onOpenChange={setDel}
        title={`Remove ${d.name}?`}
        body="Deletes every mailbox on it and all of their mail from heyflare. Email Routing on Cloudflare is left as it is."
        action="Remove domain"
        onConfirm={() => remove.mutate(d.id, { onSuccess: () => nav("/settings/domains", { replace: true }), onError: (e) => toast.error(domainErrorMessage(e)) })}
      />
    </Sub>
  );
}
