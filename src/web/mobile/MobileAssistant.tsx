import { useNavigate, useParams } from "react-router-dom";
import {MessageSquare, Plus, Bot, Trash2 } from "lucide-react";
import { useAiConversations, useAiMutations } from "../api";
import { AssistantChat } from "../components/AssistantChat";
import { Screen } from "./Screen";
import { Button } from "@/components/ui/button";
import { fmtRelative } from "../lib/format";

export function MobileAssistantList() {
  const convs = useAiConversations();
  const m = useAiMutations();
  const nav = useNavigate();
  return (
    <Screen title="Assistant" largeTitle back="/more" backLabel="More" tabs titleRight={<Button size="icon" variant="ghost" aria-label="New conversation" className="size-11" onClick={() => nav("/assistant/new")}><Plus className="size-5!" /></Button>}>
      <div className="px-4">
        <button type="button" onClick={() => nav("/assistant/new")} className="w-full flex items-center gap-3 rounded-lg bg-muted/50 active:bg-muted px-3 py-3 text-left mb-4">
          <Bot className="size-5 text-muted-foreground" />
          <div>
            <div className="text-[15px] font-medium">New conversation</div>
            <div className="text-[13px] text-muted-foreground">Ask about your mail or have something written.</div>
          </div>
        </button>
        {(convs.data ?? []).map((c) => (
          <div key={c.id} className="flex items-center gap-3 h-14 border-b border-border last:border-b-0">
            <button type="button" className="flex-1 min-w-0 flex items-center gap-3 text-left h-full" onClick={() => nav(`/assistant/${c.id}`)}>
              <MessageSquare className="size-5 text-muted-foreground shrink-0" />
              <div className="min-w-0">
                <div className="text-[15px] truncate">{c.title || "Untitled"}</div>
                <div className="text-[12px] text-muted-foreground">{fmtRelative(c.updated_at)}</div>
              </div>
            </button>
            <Button size="icon" variant="ghost" aria-label="Delete" className="text-muted-foreground" onClick={() => m.deleteConversation.mutate(c.id)}><Trash2 /></Button>
          </div>
        ))}
      </div>
    </Screen>
  );
}

export function MobileAssistantChat() {
  const { id } = useParams();
  const nav = useNavigate();
  const cid = id === "new" ? undefined : id;
  return (
    <Screen title="Assistant" back="/assistant" backLabel="Chats" tabs={false}>
      <div className="h-[calc(100dvh-44px-env(safe-area-inset-top))] flex flex-col">
        <AssistantChat conversationId={cid} onConversationId={(c) => nav(`/assistant/${c}`, { replace: true })} compact />
      </div>
    </Screen>
  );
}
