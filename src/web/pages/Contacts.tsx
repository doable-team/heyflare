import { useState } from "react";
import { Link } from "react-router-dom";
import { FileText, Inbox, Rss, Search, Shield, ShieldOff } from "lucide-react";
import type { MergedContact, ScreenStatus } from "@shared/types";
import { cn } from "@/lib/utils";
import { useContacts, useUpdateContact } from "../api";
import { useAccount } from "../context/AccountContext";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { EmptyState, ErrorState, PageHeader, SectionTitle, SkeletonRows } from "../components/EmptyState";
import { fmtTime } from "../lib/format";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useCardScroll } from "../lib/cardKeys";

export const STATUS_META: Record<ScreenStatus, { label: string; short: string; icon: React.ReactNode }> = {
  pending: { label: "In Screener", short: "Screener", icon: <Shield /> },
  imbox: { label: "Imbox", short: "Imbox", icon: <Inbox /> },
  feed: { label: "The Feed", short: "Feed", icon: <Rss /> },
  paper_trail: { label: "Paper Trail", short: "Paper Trail", icon: <FileText /> },
  screened_out: { label: "Screened out", short: "Out", icon: <ShieldOff /> },
};

export function StatusChip({ s, small }: { s: ScreenStatus; small?: boolean }) {
  const m = STATUS_META[s];
  return (
    <Badge variant="secondary" className={cn("gap-1 font-normal text-muted-foreground [&>svg]:size-3", small && "text-[11px] px-1.5")}>
      {m.icon}
      {m.label}
    </Badge>
  );
}

const CHOICES: ScreenStatus[] = ["imbox", "feed", "paper_trail", "screened_out"];

/** Inline "where their mail goes" property, Notion-style: a quiet select that mutates on change. */
export function StatusSelect({ c, className }: { c: MergedContact; className?: string }) {
  const update = useUpdateContact();
  if (c.screen_status === "pending") {
    return (
      <Link to="/screener" className={cn("inline-flex", className)}>
        <StatusChip s="pending" small />
      </Link>
    );
  }
  return (
    <Select value={c.screen_status} onValueChange={(v) => update.mutate({ id: c.id, screen_status: v as ScreenStatus })}>
      <SelectTrigger size="sm" className={cn("h-7 border-transparent bg-transparent px-1.5 text-[13px] text-muted-foreground hover:bg-muted hover:text-foreground data-[state=open]:bg-muted [&>svg]:opacity-0 hover:[&>svg]:opacity-100", className)} aria-label="Where their mail goes">
        <SelectValue />
      </SelectTrigger>
      <SelectContent align="end">
        {CHOICES.map((s) => (
          <SelectItem key={s} value={s}>
            <span className="inline-flex items-center gap-2 [&>svg]:size-3.5 [&>svg]:text-muted-foreground">
              {STATUS_META[s].icon}
              {STATUS_META[s].label}
            </span>
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

function Rows({ list, multi }: { list: MergedContact[]; multi: boolean }) {
  const { glyphFor, accountFor } = useAccount();
  return (
    <Table className="table-fixed">
      <TableHeader>
        <TableRow className="border-0 hover:bg-transparent">
          <TableHead className="h-7 pl-2 text-xs font-normal text-muted-foreground w-[46%] sm:w-[28%]">Name</TableHead>
          <TableHead className="hidden sm:table-cell h-7 text-xs font-normal text-muted-foreground">Email</TableHead>
          {multi && <TableHead className="hidden md:table-cell h-7 w-[12%] text-xs font-normal text-muted-foreground">Accounts</TableHead>}
          <TableHead className="h-7 w-[34%] sm:w-[24%] text-xs font-normal text-muted-foreground">Goes to</TableHead>
          <TableHead className="hidden sm:table-cell h-7 w-[11%] pr-2 text-right text-xs font-normal text-muted-foreground">Last</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {list.map((c) => (
          <TableRow key={c.email} className="border-0 hover:bg-muted h-10">
            <TableCell className="py-0 pl-2">
              <Link to={`/contacts/${c.id}`} className="flex items-center gap-2.5 min-w-0 h-10">
                <Avatar email={c.email} name={c.name} src={c.avatar_url} size={20} />
                <span className="truncate text-sm font-medium">{c.name || c.email.split("@")[0]}</span>
                {c.message_count > 0 && <span className="text-xs text-tertiary tnum shrink-0">{c.message_count}</span>}
              </Link>
            </TableCell>
            <TableCell className="hidden sm:table-cell py-0 text-muted-foreground truncate">
              <Link to={`/contacts/${c.id}`} className="block truncate">{c.email}</Link>
            </TableCell>
            {multi && (
              <TableCell className="hidden md:table-cell py-0 text-xs text-muted-foreground">
                <Tooltip>
                  <TooltipTrigger asChild>
                    <span className="inline-flex items-center gap-1">
                      {c.accounts.slice(0, 4).map((a) => (
                        <AccountGlyph key={a.account_id} glyph={glyphFor(a.account_id)} />
                      ))}
                      {c.accounts.length > 4 && <span className="tnum">+{c.accounts.length - 4}</span>}
                    </span>
                  </TooltipTrigger>
                  <TooltipContent>
                    {c.accounts.map((a) => accountFor(a.account_id)?.email ?? a.account_id).join(", ")}
                  </TooltipContent>
                </Tooltip>
              </TableCell>
            )}
            <TableCell className="py-0 overflow-hidden">
              <span className="flex items-center gap-1.5 min-w-0">
                <StatusSelect c={c} className="min-w-0" />
                {c.mixed && (
                  <Tooltip>
                    <TooltipTrigger asChild>
                      <Badge variant="outline" className="shrink-0 font-normal text-muted-foreground text-[11px] px-1.5">Mixed</Badge>
                    </TooltipTrigger>
                    <TooltipContent>
                      {c.accounts.map((a) => `${accountFor(a.account_id)?.email ?? a.account_id}: ${STATUS_META[a.screen_status].label}`).join(" · ")}
                    </TooltipContent>
                  </Tooltip>
                )}
              </span>
            </TableCell>
            <TableCell className="hidden sm:table-cell py-0 pr-2 text-right text-xs text-muted-foreground tnum">{fmtTime(c.last_seen_at)}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

export default function Contacts() {
  useCardScroll();
  const [q, setQ] = useState("");
  const { multi } = useAccount();
  const res = useContacts(q);
  const list = res.data ?? [];
  const screened = list.filter((c) => c.screen_status !== "pending");
  const pending = list.filter((c) => c.screen_status === "pending");
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader
        title="Contacts"
        subtitle="Everyone who's written to you, and where their mail goes."
        actions={
          <div className="relative w-56 max-w-full">
            <Search size={14} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground" />
            <Input placeholder="Search people…" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search contacts" className="pl-8" />
          </div>
        }
      />
      {res.error && <ErrorState error={res.error} onRetry={() => res.refetch()} />}
      {res.isLoading && <SkeletonRows rows={8} compact />}
      {!res.isLoading && list.length === 0 && !res.error && (
        <EmptyState
          icon={<Shield />}
          title={q ? "Nobody by that name." : "No one's written yet."}
          body={q ? "Try a different spelling, or just part of the address." : "People show up here as their mail arrives, along with where you've decided it goes."}
        />
      )}
      {screened.length > 0 && (
        <section>
          <SectionTitle count={screened.length}>People</SectionTitle>
          <Rows list={screened} multi={multi} />
        </section>
      )}
      {pending.length > 0 && (
        <section className={cn(screened.length > 0 && "mt-8")}>
          <SectionTitle count={pending.length}>Waiting in the Screener</SectionTitle>
          <Rows list={pending} multi={multi} />
        </section>
      )}
    </div>
  );
}
