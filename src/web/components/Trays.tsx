import { Link } from "react-router-dom";
import { ArrowRight, Bookmark, Check, Clock } from "lucide-react";
import type { ThreadSummary } from "@shared/types";
import { useBulkAction } from "../api";
import { fmtTime } from "../lib/format";
import { Avatar, AvatarStack } from "./Avatar";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { cn } from "@/lib/utils";

/** One HEY-style pile: a literal stack of the latest cards, fanned out on click. */
function Pile({ threads, label, icon, link, linkLabel, removeLabel, onRemove, align }: {
  threads: ThreadSummary[];
  label: string;
  icon: React.ReactNode;
  link: string;
  linkLabel: string;
  removeLabel: string;
  onRemove: (id: string) => void;
  align: "start" | "end";
}) {
  if (threads.length === 0) return null;
  const stack = threads.slice(0, 3);
  return (
    <Popover>
      <PopoverTrigger asChild>
        <button
          type="button"
          className="group flex items-center gap-2 h-9 pl-2 pr-3 rounded-full text-[13px] text-muted-foreground hover:text-foreground hover:bg-muted data-[state=open]:bg-muted data-[state=open]:text-foreground outline-none focus-visible:ring-1 focus-visible:ring-ring"
          aria-label={`${label}, ${threads.length} ${threads.length === 1 ? "thread" : "threads"}`}
        >
          <AvatarStack people={stack.map((t) => t.last_from)} size={18} max={3} plus={false} />
          <span className="flex items-center gap-1.5">
            {icon}
            <span className="font-medium">{label}</span>
            <span className="tnum text-tertiary">{threads.length}</span>
          </span>
        </button>
      </PopoverTrigger>
      <PopoverContent side="top" align="center" className="w-[340px] p-1">
        <div className="flex items-center justify-between px-2 h-8">
          <span className="text-xs font-medium text-muted-foreground">{label}</span>
          <Link to={link} className="inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground">
            {linkLabel} <ArrowRight size={12} />
          </Link>
        </div>
        <div className="max-h-[320px] overflow-y-auto">
          {threads.map((t) => (
            <div key={t.id} className="group/row flex items-center gap-2.5 px-2 h-10 rounded-md hover:bg-accent">
              <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={20} />
              <Link to={`/t/${t.id}`} className="flex-1 min-w-0">
                <div className="text-[13px] truncate">{t.subject || "(no subject)"}</div>
                <div className="text-[11px] text-muted-foreground truncate">{t.last_from.name || t.last_from.email} · {fmtTime(t.last_message_at)}</div>
              </Link>
              <Button variant="ghost" size="xs" className="opacity-0 group-hover/row:opacity-100 focus-visible:opacity-100 text-muted-foreground" onClick={() => onRemove(t.id)}>
                <Check /> {removeLabel}
              </Button>
            </div>
          ))}
        </div>
      </PopoverContent>
    </Popover>
  );
}

/** Reply Later (left) and Set Aside (right) piles, pinned to the bottom of the Imbox like HEY. */
export function Piles({ replyLater, setAside }: { replyLater: ThreadSummary[]; setAside: ThreadSummary[] }) {
  const bulk = useBulkAction();
  if (replyLater.length === 0 && setAside.length === 0) return null;
  return (
    <div className="sticky bottom-0 z-20 mt-auto pt-8 pb-4 pointer-events-none flex justify-center">
      <div className="pointer-events-auto inline-flex items-center gap-0.5 p-1 rounded-full bg-background border border-border shadow-sm">
        {replyLater.length > 0 && (
          <Pile threads={replyLater} label="Reply later" icon={<Clock size={13} />} link="/reply-later" linkLabel="Focus & Reply" removeLabel="Done" align="start" onRemove={(id) => bulk.mutate({ thread_ids: [id], action: "reply_later", on: false })} />
        )}
        {setAside.length > 0 && (
          <Pile threads={setAside} label="Set aside" icon={<Bookmark size={13} />} link="/set-aside" linkLabel="Board" removeLabel="Done" align="end" onRemove={(id) => bulk.mutate({ thread_ids: [id], action: "set_aside", on: false })} />
        )}
      </div>
    </div>
  );
}
export { Piles as Trays };
