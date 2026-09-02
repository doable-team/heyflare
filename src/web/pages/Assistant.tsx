import { useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { MoreHorizontal, Plus, Sparkles, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { useAiConversations, useAiMutations } from "../api";
import { AssistantChat } from "../components/AssistantChat";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { fmtRelative } from "../lib/format";
import { cn } from "@/lib/utils";

export default function Assistant() {
  const { id } = useParams();
  const nav = useNavigate();
  const convs = useAiConversations();
  const m = useAiMutations();
  const [renaming, setRenaming] = useState<{ id: string; title: string } | null>(null);
  return (
    <div className="max-w-5xl mx-auto grid grid-cols-[220px_minmax(0,1fr)] gap-6 h-[calc(100dvh-44px-48px)]">
      <aside className="min-h-0 flex flex-col">
        <div className="flex items-center justify-between px-2 mb-2">
          <div className="text-[13px] font-medium text-muted-foreground">Conversations</div>
          <Button size="icon-xs" variant="ghost" aria-label="New conversation" onClick={() => nav("/assistant")}><Plus /></Button>
        </div>
        <div className="flex-1 min-h-0 overflow-y-auto">
          {(convs.data ?? []).map((c) => (
            <div key={c.id} className={cn("group flex items-center gap-1 rounded-md pl-2 pr-1 h-8 text-[13px] hover:bg-muted", id === c.id && "bg-muted")}>
              {renaming?.id === c.id ? (
                <Input
                  autoFocus
                  value={renaming.title}
                  onChange={(e) => setRenaming({ id: c.id, title: e.target.value })}
                  onBlur={() => { m.renameConversation.mutate({ id: c.id, title: renaming.title }); setRenaming(null); }}
                  onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); if (e.key === "Escape") setRenaming(null); }}
                  className="h-6 text-[13px] px-1"
                />
              ) : (
                <button type="button" className="flex-1 min-w-0 text-left truncate" onClick={() => nav(`/assistant/${c.id}`)} title={c.title || "Untitled"}>
                  {c.title || "Untitled"}
                </button>
              )}
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button size="icon-xs" variant="ghost" className="opacity-0 group-hover:opacity-100 data-[state=open]:opacity-100 text-muted-foreground" aria-label="Conversation menu"><MoreHorizontal /></Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-40">
                  <DropdownMenuItem onSelect={() => setRenaming({ id: c.id, title: c.title })}>Rename</DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => m.deleteConversation.mutate(c.id, { onSuccess: () => { toast("Deleted"); if (id === c.id) nav("/assistant"); } })}><Trash2 /> Delete</DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
          ))}
          {convs.data && convs.data.length === 0 && <div className="px-2 text-[13px] text-muted-foreground">No conversations yet.</div>}
        </div>
        {convs.data?.length ? <div className="px-2 pt-2 text-[11px] text-muted-foreground">Last {fmtRelative(convs.data[0].updated_at)}</div> : null}
      </aside>
      <section className="min-h-0 flex flex-col">
        <div className="flex items-center gap-2 px-2 h-8 mb-1">
          <Sparkles className="size-4 text-muted-foreground" />
          <h1 className="text-[15px] font-semibold">Assistant</h1>
        </div>
        <div className="flex-1 min-h-0">
          <AssistantChat conversationId={id} onConversationId={(cid) => nav(`/assistant/${cid}`, { replace: true })} />
        </div>
      </section>
    </div>
  );
}
