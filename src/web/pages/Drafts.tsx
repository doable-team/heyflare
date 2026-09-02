import { CalendarClock, PenSquare, Trash2, X } from "lucide-react";
import type { Draft } from "@shared/types";
import { useDraftMutations, useDrafts } from "../api";
import { useAccount } from "../context/AccountContext";
import { useCompose } from "../context/ComposeContext";
import { fmtFull, fmtTime } from "../lib/format";
import { Avatar, AccountGlyph, AvatarStack } from "../components/Avatar";
import { EmptyState, ErrorState, PageHeader, SkeletonRows } from "../components/EmptyState";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

function preview(html: string): string {
  return html
    .replace(/<div class="hey-signature">[\s\S]*$/i, "")
    .replace(/<div class="hey-quote">[\s\S]*$/i, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
}

function DraftRow({ d, mode, onOpen, onCancel, onDelete }: { d: Draft; mode: "draft" | "scheduled"; onOpen: () => void; onCancel: () => void; onDelete: () => void }) {
  const { multi, glyphFor, accountFor } = useAccount();
  const people = d.to.length ? d.to : d.cc;
  const snippet = preview(d.body_html);
  return (
    <div className="group flex items-center gap-2.5 px-2 h-11 rounded-md hover:bg-muted">
      <div className="size-5 shrink-0 flex items-center justify-center">
        {people.length > 1 ? <AvatarStack people={people} size={20} max={2} /> : people[0] ? <Avatar email={people[0].email} name={people[0].name} src={people[0].avatar_url} size={20} /> : <PenSquare size={14} className="text-muted-foreground" />}
      </div>
      <button type="button" className="flex-1 min-w-0 text-left leading-tight" onClick={onOpen}>
        <div className="flex items-center gap-1.5 min-w-0">
          <span className="text-[13px] font-medium text-foreground truncate">{people.length ? people.map((a) => a.name || a.email).join(", ") : <span className="text-muted-foreground">No recipients yet</span>}</span>
          {multi && <AccountGlyph glyph={glyphFor(d.account_id)} label={accountFor(d.account_id)?.email} />}
          {d.status === "failed" && <Badge variant="outline" className="h-4 px-1 text-[10px] font-normal text-muted-foreground">Failed</Badge>}
          {d.status === "sending" && <Badge variant="outline" className="h-4 px-1 text-[10px] font-normal text-muted-foreground">Sending</Badge>}
        </div>
        <div className="flex items-center gap-1.5 min-w-0 mt-0.5">
          <span className="text-[13px] text-foreground/80 truncate shrink-0 max-w-[60%]">{d.subject || "(no subject)"}</span>
          {snippet && <span className="hidden sm:inline text-xs text-muted-foreground truncate">— {snippet}</span>}
          {d.status === "failed" && d.error && <span className="text-xs text-muted-foreground truncate">· {d.error}</span>}
        </div>
      </button>
      <div className="shrink-0 flex items-center gap-2 text-muted-foreground">
        <span className="group-hover:hidden">
          {mode === "scheduled" && d.send_at ? (
            <Badge variant="secondary" className="font-normal text-muted-foreground"><CalendarClock /> {fmtFull(d.send_at)}</Badge>
          ) : (
            <span className="text-xs tnum">{fmtTime(d.updated_at)}</span>
          )}
        </span>
        <span className="hidden group-hover:flex items-center gap-0.5">
          {d.status === "scheduled" ? (
            <Button variant="ghost" size="xs" onClick={onCancel}><X /> Cancel</Button>
          ) : (
            <Tooltip>
              <TooltipTrigger asChild>
                <Button variant="ghost" size="icon-xs" aria-label="Delete draft" onClick={onDelete}><Trash2 /></Button>
              </TooltipTrigger>
              <TooltipContent>Delete draft</TooltipContent>
            </Tooltip>
          )}
        </span>
      </div>
    </div>
  );
}

export default function Drafts({ mode }: { mode: "draft" | "scheduled" }) {
  const q = useDrafts();
  const m = useDraftMutations();
  const { openCompose } = useCompose();
  const list = (q.data ?? []).filter((d) => (mode === "scheduled" ? d.status === "scheduled" || d.status === "sending" || d.status === "failed" : d.status === "draft"));
  const scheduled = mode === "scheduled";
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader
        className="px-2"
        title={scheduled ? "Scheduled" : "Drafts"}
        subtitle={scheduled ? "Going out later, automatically." : "Half-written thoughts, waiting."}
        actions={!scheduled && <Button variant="ghost" size="sm" onClick={() => openCompose()}><PenSquare /> New message</Button>}
      />
      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && <SkeletonRows rows={4} />}
      {!q.isLoading && list.length === 0 && !q.error && (
        <EmptyState
          icon={scheduled ? <CalendarClock /> : <PenSquare />}
          title={scheduled ? "Nothing scheduled." : "No drafts."}
          body={scheduled ? "Use the arrow next to Send to pick a time." : "Press c to start one. We'll keep it here until you send it."}
          action={!scheduled && <Button variant="ghost" size="sm" onClick={() => openCompose()}>Start writing</Button>}
        />
      )}
      {list.map((d) => (
        <DraftRow
          key={d.id}
          d={d}
          mode={mode}
          onOpen={() => openCompose({ draft_id: d.id, account_id: d.account_id, thread_id: d.thread_id, reply_to_message_id: d.reply_to_message_id, to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, body_html: d.body_html, title: d.status === "draft" ? "Draft" : "Scheduled message" })}
          onCancel={() => m.cancelScheduled.mutate(d.id)}
          onDelete={() => m.remove.mutate(d.id)}
        />
      ))}
    </div>
  );
}
