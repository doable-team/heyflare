import { useEffect, useState } from "react";

export interface ContextChip {
  id: string;
  subject: string;
  from: string;
}

interface AssistantState {
  open: boolean;
  conversationId: string | null;
  context: ContextChip[];
}

const KEY = "hey.assistant";
function load(): AssistantState {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) {
      const j = JSON.parse(raw) as Partial<AssistantState>;
      return { open: !!j.open, conversationId: j.conversationId ?? null, context: [] };
    }
  } catch {}
  return { open: false, conversationId: null, context: [] };
}

let state: AssistantState = load();
const listeners = new Set<() => void>();
function emit() {
  try {
    localStorage.setItem(KEY, JSON.stringify({ open: state.open, conversationId: state.conversationId }));
  } catch {}
  listeners.forEach((l) => l());
}
function set(patch: Partial<AssistantState>) {
  state = { ...state, ...patch };
  emit();
}

export const assistant = {
  get: () => state,
  open(conversationId?: string | null, context?: ContextChip[]) {
    set({ open: true, conversationId: conversationId === undefined ? state.conversationId : conversationId, context: context ?? state.context });
  },
  close: () => set({ open: false }),
  toggle: () => set({ open: !state.open }),
  setConversation: (id: string | null) => set({ conversationId: id, context: id === state.conversationId ? state.context : [] }),
  newChat: () => set({ conversationId: null, context: [] }),
  addContext(chip: ContextChip) {
    if (state.context.some((c) => c.id === chip.id)) return;
    set({ context: [...state.context, chip].slice(-3) });
  },
  removeContext: (id: string) => set({ context: state.context.filter((c) => c.id !== id) }),
  clearContext: () => set({ context: [] }),
};

export function useAssistant(): AssistantState {
  const [, force] = useState(0);
  useEffect(() => {
    const l = () => force((x) => x + 1);
    listeners.add(l);
    return () => {
      listeners.delete(l);
    };
  }, []);
  return state;
}
