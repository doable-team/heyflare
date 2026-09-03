import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { ArrowLeft, Check, PenSquare } from "lucide-react";
import type { ScreenStatus } from "@shared/types";
import { cn } from "@/lib/utils";
import { useContact, useUpdateContact } from "../api";
import { useAccount } from "../context/AccountContext";
import { useCompose } from "../context/ComposeContext";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { ErrorState, SectionTitle } from "../components/EmptyState";
import { ThreadList } from "../components/ThreadList";
import { STATUS_META } from "./Contacts";
import { fmtDate, fmtRelative } from "../lib/format";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Kbd } from "@/components/ui/kbd";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { Switch } from "@/components/ui/switch";
import { Layers } from "lucide-react";
import { useCardScroll } from "../lib/cardKeys";

const OPTIONS: ScreenStatus[] = ["imbox", "feed", "paper_trail", "screened_out"];

const BLURB: Record<ScreenStatus, string> = {
  pending: "Still waiting at the door. Decide in the Screener, or pick a place here.",
  imbox: "Their mail lands in your Imbox, front and centre.",
  feed: "Their mail goes to The Feed — browse it when you feel like it.",
  paper_trail: "Their mail files itself into the Paper Trail.",
  screened_out: "Their mail never reaches you. They won't know.",
};

function Property({ label, children, className }: { label: string; children: React.ReactNode; className?: string }) {
  return (
    <div className={cn("grid grid-cols-[112px_minmax(0,1fr)] items-start gap-3 min-h-9 py-1", className)}>
      <div className="text-[13px] text-muted-foreground pt-1.5">{label}</div>
      <div className="min-w-0">{children}</div>
    </div>
  );
}

export default function ContactDetail() {
  useCardScroll();
  const { id } = useParams();
  const nav = useNavigate();
  const q = useContact(id);
  const update = useUpdateContact();
  const { openCompose } = useCompose();
  const { multi, glyphFor, accountFor } = useAccount();
  const c = q.data?.contact;
  const [name, setName] = useState("");
  const [notes, setNotes] = useState("");
  const [saveState, setSaveState] = useState<"idle" | "saving" | "saved">("idle");
  const timer = useRef<number | null>(null);
  const loadedFor = useRef<string | null>(null);

  useEffect(() => {
    if (c && loadedFor.current !== c.id) {
      loadedFor.current = c.id;
      setName(c.name);
      setNotes(c.notes);
    }
  }, [c]);

  const autosave = (n: string) => {
    setNotes(n);
    setSaveState("saving");
    if (timer.current) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => {
      if (!c) return;
      update.mutate(
        { id: c.id, notes: n },
        {
          onSuccess: () => {
            setSaveState("saved");
            window.setTimeout(() => setSaveState((s) => (s === "saved" ? "idle" : s)), 2000);
          },
          onError: () => setSaveState("idle"),
        },
      );
    }, 600);
  };

  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  if (!c) {
    return (
      <div className="max-w-3xl mx-auto px-2">
        <Skeleton className="h-6 w-20 mb-6" />
        <div className="flex gap-4">
          <Skeleton className="size-10 rounded-[4px] shrink-0" />
          <div className="flex-1 space-y-3">
            <Skeleton className="h-7 w-1/2" />
            <Skeleton className="h-4 w-1/3" />
          </div>
        </div>
      </div>
    );
  }

  const status = c.screen_status;
  const acc = accountFor(c.account_id);
  return (
    <div className="max-w-3xl mx-auto">
      <Button variant="ghost" size="sm" className="mb-4 text-muted-foreground" onClick={() => nav(-1)}>
        <ArrowLeft /> Back <Kbd className="ml-1">esc</Kbd>
      </Button>

      <header className="flex items-start gap-4 px-2">
        <Avatar email={c.email} name={c.name} src={c.avatar_url} size={40} />
        <div className="flex-1 min-w-0">
          <input
            className="w-full bg-transparent text-2xl font-semibold tracking-[-0.02em] outline-none placeholder:text-tertiary"
            value={name}
            placeholder={c.email.split("@")[0]}
            aria-label="Name"
            onChange={(e) => setName(e.target.value)}
            onBlur={() => name.trim() !== c.name && update.mutate({ id: c.id, name: name.trim() })}
          />
          <div className="mt-1 flex items-center gap-2 flex-wrap text-sm text-muted-foreground">
            <a href={`mailto:${c.email}`} className="hover:text-foreground">{c.email}</a>
            <Badge variant="outline" className="font-normal text-muted-foreground">{c.email.split("@")[1]}</Badge>
            {multi && acc && (
              <span className="inline-flex items-center gap-1 text-xs">
                <AccountGlyph glyph={glyphFor(c.account_id)} /> {acc.email}
              </span>
            )}
          </div>
        </div>
        <Button variant="outline" size="sm" onClick={() => openCompose({ to: [{ email: c.email, name: c.name }] })}>
          <PenSquare /> Write
        </Button>
      </header>

      <section className="mt-6 px-2 border-b border-border pb-4">
        <Property label="Messages">
          <div className="text-sm pt-1.5 tnum">
            {c.message_count} · first seen {fmtDate(c.first_seen_at)} · last {fmtRelative(c.last_seen_at)}
          </div>
        </Property>
        <Property label="Mail goes to">
          <ToggleGroup type="single" size="sm" value={status === "pending" ? "" : status} onValueChange={(v) => v && update.mutate({ id: c.id, screen_status: v as ScreenStatus })} className="flex-wrap">
            {OPTIONS.map((s) => (
              <ToggleGroupItem key={s} value={s} aria-label={STATUS_META[s].label} className="gap-1.5 text-muted-foreground data-[state=on]:bg-accent data-[state=on]:text-foreground [&>svg]:size-3.5">
                {STATUS_META[s].icon}
                {STATUS_META[s].label}
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
          <p className="mt-1.5 text-[13px] text-muted-foreground">{BLURB[status]}</p>
        </Property>
        <Property label="Bundled up">
          <label className={cn("flex items-center gap-3 pt-1.5", status !== "imbox" && status !== "paper_trail" && "opacity-60")}>
            <Switch checked={c.bundled} disabled={status !== "imbox" && status !== "paper_trail"} onCheckedChange={(on) => update.mutate({ id: c.id, bundled: on })} aria-label="Bundle up this sender" />
            <span className="text-sm inline-flex items-center gap-1.5"><Layers size={14} className="text-muted-foreground" /> {c.bundled ? "Bundled up" : "Not bundled"}</span>
          </label>
          <p className="mt-1.5 text-[13px] text-muted-foreground">
            {status === "imbox" || status === "paper_trail"
              ? `All their mail shows as one row in the ${status === "imbox" ? "Imbox" : "Paper Trail"}, no matter how much they send.`
              : "Bundles work for senders delivered to the Imbox or the Paper Trail."}
          </p>
        </Property>
        <Property label="Notes">
          <div className="relative">
            <Textarea
              className="min-h-[72px] bg-muted/40 text-sm"
              placeholder="Met at the conference. Owes me a coffee."
              value={notes}
              onChange={(e) => autosave(e.target.value)}
            />
            <span className={cn("absolute right-2 top-2 inline-flex items-center gap-1 text-[11px] text-muted-foreground transition-opacity", saveState === "idle" ? "opacity-0" : "opacity-100")}>
              {saveState === "saving" ? "Saving…" : <><Check size={11} /> Saved</>}
            </span>
          </div>
        </Property>
      </section>

      <section className="mt-6">
        <SectionTitle count={q.data?.threads.length}>Conversations</SectionTitle>
        <ThreadList showBucket sections={[{ threads: q.data?.threads ?? [], emptyTitle: "Nothing between you two yet.", emptyBody: "Threads with this person will collect here." }]} />
      </section>
    </div>
  );
}
