import { Link, useNavigate } from "react-router-dom";
import { ChevronDown, FileText, Inbox, Rss, ShieldOff } from "lucide-react";
import { useScreenedOut, useUpdateContact } from "../api";
import { useAccount } from "../context/AccountContext";
import { fmtTime } from "../lib/format";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { EmptyState, ErrorState, PageHeader, SkeletonRows } from "../components/EmptyState";
import { useToast } from "../components/Toast";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { useItemCursor } from "../lib/cardKeys";
import { cn } from "@/lib/utils";

export default function ScreenedOut() {
  const q = useScreenedOut();
  const nav = useNavigate();
  const update = useUpdateContact();
  const { toast } = useToast();
  const { multi, glyphFor, accountFor } = useAccount();
  const contacts = q.data?.contacts ?? [];
  const { cursor } = useItemCursor({ count: contacts.length, onOpen: (i) => contacts[i] && nav(`/contacts/${contacts[i].id}`) });
  const admit = (c: (typeof contacts)[number], status: "imbox" | "feed" | "paper_trail", label: string) =>
    update.mutate({ id: c.id, screen_status: status }, { onSuccess: () => toast(`${c.name || c.email} → ${label}`, { kind: "success" }) });
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader
        className="px-2"
        title="Screened out"
        subtitle={contacts.length ? `${contacts.length} ${contacts.length === 1 ? "sender" : "senders"} you said no to. Change your mind any time.` : "People you said no to. Change your mind any time."}
        actions={
          <Button variant="ghost" size="sm" className="text-muted-foreground" asChild>
            <Link to="/screener">
              <ShieldOff /> Screener
            </Link>
          </Button>
        }
      />
      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && <SkeletonRows compact />}
      {!q.isLoading && contacts.length === 0 && !q.error && <EmptyState icon={<ShieldOff />} title="Nobody's screened out." body="Say no in the Screener and they'll be listed here." />}
      {contacts.length > 0 && (
        <ul>
          {contacts.map((c, i) => {
            const acct = accountFor(c.account_id);
            return (
              <li key={c.id} data-item-index={i} data-focused={cursor === i || undefined} className={cn("group relative flex items-center gap-3 px-2 h-11 rounded-md scroll-mt-20 hover:bg-accent", cursor === i && "bg-muted")}>
                {cursor === i && <span className="absolute left-0 top-2 bottom-2 w-0.5 rounded-full bg-foreground" />}
                <Avatar email={c.email} name={c.name} src={c.avatar_url} size={20} />
                <Link to={`/contacts/${c.id}`} className="flex-1 min-w-0 flex items-center gap-2">
                  <span className="text-sm truncate">{c.name || c.email}</span>
                  {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
                  <span className="text-xs text-muted-foreground truncate tnum hidden sm:inline">
                    {c.name ? `${c.email} · ` : ""}
                    {c.message_count} message{c.message_count === 1 ? "" : "s"}
                    {c.screened_at ? ` · screened out ${fmtTime(c.screened_at)}` : ""}
                  </span>
                </Link>
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <Button size="sm" variant="ghost" className="text-muted-foreground" disabled={update.isPending && update.variables?.id === c.id}>
                      Let them in <ChevronDown />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end" className="w-52">
                    <DropdownMenuLabel className="text-xs text-muted-foreground font-normal">Deliver their mail to</DropdownMenuLabel>
                    <DropdownMenuItem onClick={() => admit(c, "imbox", "Imbox")}>
                      <Inbox /> Imbox
                    </DropdownMenuItem>
                    <DropdownMenuItem onClick={() => admit(c, "feed", "The Feed")}>
                      <Rss /> The Feed
                    </DropdownMenuItem>
                    <DropdownMenuItem onClick={() => admit(c, "paper_trail", "Paper Trail")}>
                      <FileText /> Paper Trail
                    </DropdownMenuItem>
                  </DropdownMenuContent>
                </DropdownMenu>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
