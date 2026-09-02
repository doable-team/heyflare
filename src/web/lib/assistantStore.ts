import { useEffect, useState } from "react";

export interface ContextChip {
  id: string;
  subject: string;
  from: string;
}

export type AssistantMode = "float" | "dock";

interface AssistantState {
  open: boolean;
  /** float = compact window bottom-right; dock = full-height side panel that pushes the app content left. */
  mode: AssistantMode;
  width: number;
  conversationId: string | null;
  context: ContextChip[];
}

const KEY = "hey.assistant";
function load(): AssistantState {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) {
      const j = JSON.parse(raw) as Partial<AssistantState>;
      return { open: !!j.open, mode: "dock", width: clampWidth(j.width), conversationId: j.conversationId ?? null, context: [] };
    }
  } catch {}
  return { open: false, mode: "dock", width: 400, conversationId: null, context: [] };
}

let state: AssistantState = load();
const listeners = new Set<() => void>();
function emit() {
  try {
    localStorage.setItem(KEY, JSON.stringify({ open: state.open, mode: state.mode, width: state.width, conversationId: state.conversationId }));
  } catch {}
  listeners.forEach((l) => l());
}
export const MIN_W = 320;
export const MAX_W = 720;
export function clampWidth(w: unknown): number {
  const n = typeof w === "number" && Number.isFinite(w) ? w : 400;
  return Math.min(MAX_W, Math.max(MIN_W, Math.round(n)));
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
  setMode: (mode: AssistantMode) => set({ mode }),
  toggleMode: () => set({ mode: "dock" }),
  setWidth: (w: number) => set({ width: clampWidth(w) }),
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
