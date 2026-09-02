import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Check, ExternalLink, Loader2, Pencil, Plus, RefreshCw, Sparkles, Trash2, X } from "lucide-react";
import { toast } from "sonner";
import type { AiMemoryKind, AiPreset } from "@shared/types";
import { useAiMemory, useAiMutations, useAiSettings } from "../api";
import { Section, Row, Danger } from "../pages/Settings";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field";
import { fmtRelative } from "../lib/format";
import { cn } from "@/lib/utils";

const KIND_LABEL: Record<AiMemoryKind, string> = { profile: "About you", tone: "How you write", fact: "Facts", preference: "Preferences", contact: "People" };
const KINDS: AiMemoryKind[] = ["profile", "tone", "fact", "preference", "contact"];

export function AiSection({ compact }: { compact?: boolean }) {
  const settings = useAiSettings();
  const m = useAiMutations();
  const s = settings.data;
  const [preset, setPreset] = useState<AiPreset["id"]>("anthropic");
  const [baseUrl, setBaseUrl] = useState("");
  const [key, setKey] = useState("");
  const [model, setModel] = useState("");
  const [dirty, setDirty] = useState(false);
  const [clearOpen, setClearOpen] = useState(false);
  useEffect(() => {
    if (!s || dirty) return;
    setPreset(s.preset);
    setBaseUrl(s.preset === "custom" ? s.base_url : "");
    setModel(s.model);
  }, [s, dirty]);
  const inputCls = compact ? "h-11 text-[16px]" : undefined;
  const p = s?.presets.find((x) => x.id === preset) ?? s?.presets[0];
  const choosePreset = (id: AiPreset["id"]) => {
    const np = s?.presets.find((x) => x.id === id);
    setPreset(id);
    setModel(np?.default_model ?? "");
    if (id !== "custom") setBaseUrl("");
    setDirty(true);
  };
  const save = () =>
    m.saveSettings.mutate(
      { preset, base_url: preset === "custom" ? baseUrl : undefined, api_key: key.trim() ? key.trim() : undefined, model },
      { onSuccess: () => { toast("AI settings saved"); setKey(""); setDirty(false); }, onError: (e) => toast.error((e as Error).message) }
    );
  const test = () => m.test.mutate(undefined, { onSuccess: (r) => (r.ok ? toast(`Connected · ${r.model} said “${r.reply}”`) : toast.error(r.error ?? "Failed")), onError: (e) => toast.error((e as Error).message) });

  return (
    <>
      <Section title="AI assistant" description="Bring your own key. Mail is only sent to the provider when you use an AI feature.">
        {s && !s.server_ready && <div className="mx-2 mb-3 rounded-md bg-muted/60 px-3 py-2 text-[13px]">SESSION_SECRET isn't set on the server, so keys can't be stored yet.</div>}
        <div className={cn("px-2", !compact && "max-w-lg")}>
          <FieldGroup className="gap-4">
            <Field>
              <FieldLabel>Provider</FieldLabel>
              <Select value={preset} onValueChange={(v) => choosePreset(v as AiPreset["id"])}>
                <SelectTrigger className={cn("w-full", inputCls)}><SelectValue /></SelectTrigger>
                <SelectContent>
                  {(s?.presets ?? []).map((x) => <SelectItem key={x.id} value={x.id}>{x.label}</SelectItem>)}
                </SelectContent>
              </Select>
              {p && p.id !== "custom" && <FieldDescription className="tnum">Endpoint: {p.base_url}</FieldDescription>}
            </Field>
            {preset === "custom" && (
              <Field>
                <FieldLabel htmlFor="ai-base">Base URL</FieldLabel>
                <Input id="ai-base" value={baseUrl} onChange={(e) => { setBaseUrl(e.target.value); setDirty(true); }} placeholder="http://localhost:11434/v1" className={inputCls} />
                <FieldDescription>Any OpenAI-compatible server: Ollama, LM Studio, Groq, Mistral, Together…</FieldDescription>
              </Field>
            )}
            <Field>
              <FieldLabel htmlFor="ai-key">API key</FieldLabel>
              <Input id="ai-key" type="password" value={key} onChange={(e) => { setKey(e.target.value); setDirty(true); }} placeholder={s?.key_hint ? `Stored · ${s.key_hint}` : p?.key_placeholder ?? "API key"} autoComplete="off" className={inputCls} />
              <FieldDescription className="flex items-center gap-2 flex-wrap">
                <span>Stored encrypted on your server and never shown again.</span>
                {p?.key_url && <a className="inline-flex items-center gap-1 underline underline-offset-2" href={p.key_url} target="_blank" rel="noreferrer">Get a key <ExternalLink className="size-3" /></a>}
                {s?.key_hint && <button type="button" className="underline underline-offset-2" onClick={() => m.saveSettings.mutate({ api_key: null }, { onSuccess: () => toast("Key removed") })}>Remove key</button>}
              </FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="ai-model">Model</FieldLabel>
              <Input id="ai-model" list="ai-models" value={model} onChange={(e) => { setModel(e.target.value); setDirty(true); }} placeholder={p?.default_model} className={inputCls} />
              <datalist id="ai-models">{(p?.models ?? []).map((x) => <option key={x} value={x} />)}</datalist>
              <FieldDescription>Type any model id the provider supports.</FieldDescription>
            </Field>
          </FieldGroup>
          <div className={cn("flex items-center gap-2 mt-4", compact && "flex-col items-stretch")}>
            <Button size={compact ? "lg" : "sm"} onClick={save} disabled={m.saveSettings.isPending || (!dirty && !key)}>{m.saveSettings.isPending ? <Loader2 className="animate-spin" /> : <Check />} Save</Button>
            <Button size={compact ? "lg" : "sm"} variant="outline" onClick={test} disabled={m.test.isPending || !s?.configured || dirty}>{m.test.isPending ? <Loader2 className="animate-spin" /> : <Sparkles />} Test connection</Button>
            {s?.configured && !dirty && <span className="text-[12px] text-muted-foreground">Ready · <Link to="/assistant" className="underline underline-offset-2">open the assistant</Link></span>}
          </div>
        </div>
      </Section>

      <Section title="Behaviour">
        <Row label="Learn from my mail" hint="Reads what you send to learn your tone, sign-offs and recurring facts. Runs in the background, at most twice a day.">
          <Switch checked={!!s?.learn} onCheckedChange={(v) => m.saveSettings.mutate({ learn: v })} />
        </Row>
        <Row label="Send mail without asking" hint="Off: the assistant only prepares drafts and you press Send. On: it may send when you clearly ask it to.">
          <Switch checked={!!s?.auto_send} onCheckedChange={(v) => m.saveSettings.mutate({ auto_send: v })} />
        </Row>
      </Section>

      <MemorySection compact={compact} onClear={() => setClearOpen(true)} lastLearned={s?.last_learned_at ?? null} />
      <Danger open={clearOpen} onOpenChange={setClearOpen} title="Forget everything?" body="Deletes every memory entry and the learning history. The assistant starts from scratch." action="Forget everything" onConfirm={() => m.clearMemory.mutate(undefined, { onSuccess: () => toast("Memory cleared") })} />
    </>
  );
}

function MemorySection({ compact, onClear, lastLearned }: { compact?: boolean; onClear: () => void; lastLearned: number | null }) {
  const mem = useAiMemory();
  const m = useAiMutations();
  const [adding, setAdding] = useState("");
  const [addKind, setAddKind] = useState<AiMemoryKind>("preference");
  const [editing, setEditing] = useState<{ id: string; content: string } | null>(null);
  const rows = mem.data ?? [];
  return (
    <Section
      title="Memory"
      description={`What the assistant knows about you. ${rows.length} ${rows.length === 1 ? "entry" : "entries"}${lastLearned ? ` · learned ${fmtRelative(lastLearned)}` : ""}.`}
      actions={compact ? undefined : <div className={cn("flex items-center gap-1", compact && "mb-3 -ml-2")}>
          <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={() => m.learn.mutate(undefined, { onSuccess: (r) => toast(r.skipped === "nothing_new" ? "Nothing new to learn from" : r.skipped === "no_key" ? "Add an API key first" : `Learned · ${r.changed} update${r.changed === 1 ? "" : "s"}`), onError: (e) => toast.error((e as Error).message) })} disabled={m.learn.isPending}>
            <RefreshCw className={cn(m.learn.isPending && "animate-spin")} /> Learn now
          </Button>
          {rows.length > 0 && <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={onClear}><Trash2 /> Forget everything</Button>}
        </div>}
    >
      <div className="px-2">
        {compact && <div className={cn("flex items-center gap-1", compact && "mb-3 -ml-2")}>
          <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={() => m.learn.mutate(undefined, { onSuccess: (r) => toast(r.skipped === "nothing_new" ? "Nothing new to learn from" : r.skipped === "no_key" ? "Add an API key first" : `Learned · ${r.changed} update${r.changed === 1 ? "" : "s"}`), onError: (e) => toast.error((e as Error).message) })} disabled={m.learn.isPending}>
            <RefreshCw className={cn(m.learn.isPending && "animate-spin")} /> Learn now
          </Button>
          {rows.length > 0 && <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={onClear}><Trash2 /> Forget everything</Button>}
        </div>}
        {KINDS.filter((k) => rows.some((r) => r.kind === k)).map((k) => (
          <div key={k} className="mb-4">
            <div className="text-[12px] font-medium text-muted-foreground mb-1">{KIND_LABEL[k]}</div>
            <ul className="divide-y divide-border">
              {rows.filter((r) => r.kind === k).map((r) => (
                <li key={r.id} className="group flex items-start gap-2 py-2 text-[13px]">
                  {editing?.id === r.id ? (
                    <>
                      <Input autoFocus value={editing.content} onChange={(e) => setEditing({ id: r.id, content: e.target.value })} onKeyDown={(e) => { if (e.key === "Enter") { m.updateMemory.mutate({ id: r.id, content: editing.content }); setEditing(null); } if (e.key === "Escape") setEditing(null); }} className="h-8" />
                      <Button size="icon-xs" variant="ghost" aria-label="Save" onClick={() => { m.updateMemory.mutate({ id: r.id, content: editing.content }); setEditing(null); }}><Check /></Button>
                      <Button size="icon-xs" variant="ghost" aria-label="Cancel" onClick={() => setEditing(null)}><X /></Button>
                    </>
                  ) : (
                    <>
                      <span className="flex-1 min-w-0 leading-5">{r.content}</span>
                      <span className="text-[11px] text-muted-foreground shrink-0 pt-0.5">{r.source === "learned" ? "learned" : r.source === "assistant" ? "assistant" : "you"}</span>
                      <span className={cn("flex items-center shrink-0", !compact && "opacity-0 group-hover:opacity-100")}>
                        <Button size="icon-xs" variant="ghost" className="text-muted-foreground" aria-label="Edit" onClick={() => setEditing({ id: r.id, content: r.content })}><Pencil /></Button>
                        <Button size="icon-xs" variant="ghost" className="text-muted-foreground" aria-label="Delete" onClick={() => m.deleteMemory.mutate(r.id)}><Trash2 /></Button>
                      </span>
                    </>
                  )}
                </li>
              ))}
            </ul>
          </div>
        ))}
        {rows.length === 0 && <div className="text-[13px] text-muted-foreground mb-3">Nothing yet. Chat with the assistant, send some mail, or add a note below.</div>}
        <form
          className={cn("flex gap-2", compact ? "flex-col" : "items-center")}
          onSubmit={(e) => {
            e.preventDefault();
            if (!adding.trim()) return;
            m.addMemory.mutate({ kind: addKind, content: adding.trim() }, { onSuccess: () => setAdding("") });
          }}
        >
          <Select value={addKind} onValueChange={(v) => setAddKind(v as AiMemoryKind)}>
            <SelectTrigger className={cn(compact ? "h-11 w-full" : "w-36")}><SelectValue /></SelectTrigger>
            <SelectContent>{KINDS.map((k) => <SelectItem key={k} value={k}>{KIND_LABEL[k]}</SelectItem>)}</SelectContent>
          </Select>
          <Input value={adding} onChange={(e) => setAdding(e.target.value)} placeholder="Add a note, e.g. “Sign replies with just Farhan”" className={compact ? "h-11 text-[16px]" : "h-8"} />
          <Button type="submit" size={compact ? "lg" : "sm"} variant="outline" disabled={!adding.trim() || m.addMemory.isPending}><Plus /> Add</Button>
        </form>
      </div>
    </Section>
  );
}
