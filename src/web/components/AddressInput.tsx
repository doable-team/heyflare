import { useEffect, useRef, useState } from "react";
import { X } from "lucide-react";
import type { Address } from "@shared/types";
import { cn } from "@/lib/utils";
import { useSuggest } from "../api";
import { Avatar } from "./Avatar";

export function parseAddresses(s: string): Address[] {
  const out: Address[] = [];
  for (const part of s.split(/[,;\n]+/)) {
    const p = part.trim();
    if (!p) continue;
    const m = p.match(/^"?([^"<]*)"?\s*<([^>]+)>$/);
    if (m) out.push({ name: m[1].trim(), email: m[2].trim().toLowerCase() });
    else if (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(p)) out.push({ name: "", email: p.toLowerCase() });
  }
  return out;
}

/** Recipient chip input with contact autocomplete. One borderless row of the compose header. */
export function AddressInput({
  label,
  value,
  onChange,
  autoFocus,
  placeholder = "Add people…",
  trailing,
}: {
  label: string;
  value: Address[];
  onChange: (v: Address[]) => void;
  autoFocus?: boolean;
  placeholder?: string;
  trailing?: React.ReactNode;
}) {
  const [text, setText] = useState("");
  const [open, setOpen] = useState(false);
  const [hi, setHi] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const contacts = useSuggest(text, text.trim().length > 0);
  const suggestions = (contacts.data ?? []).filter((c) => !value.some((v) => v.email === c.email)).slice(0, 8);

  useEffect(() => setHi(0), [text]);

  const commit = (a: Address) => {
    if (!value.some((v) => v.email === a.email)) onChange([...value, a]);
    setText("");
    setOpen(false);
  };
  const commitText = () => {
    const parsed = parseAddresses(text);
    if (parsed.length) {
      onChange([...value, ...parsed.filter((p) => !value.some((v) => v.email === p.email))]);
      setText("");
    }
  };
  const showMenu = open && text.trim().length > 0 && suggestions.length > 0;

  return (
    <div className="relative flex items-start gap-3 py-1.5 border-b border-border" onClick={() => inputRef.current?.focus()}>
      <span className="w-14 shrink-0 pt-1 text-[13px] text-muted-foreground select-none">{label}</span>
      <div className="flex-1 min-w-0 flex flex-wrap gap-1 items-center">
        {value.map((a) => (
          <span key={a.email} className="inline-flex items-center gap-1.5 h-6 rounded-md bg-muted pl-1 pr-1 text-[13px] text-foreground max-w-full" title={a.email}>
            <Avatar email={a.email} name={a.name} src={a.avatar_url} size={16} />
            <span className="truncate max-w-56">{a.name || a.email}</span>
            <button
              type="button"
              className="size-4 rounded-sm flex items-center justify-center text-muted-foreground hover:text-foreground hover:bg-accent"
              onClick={(e) => {
                e.stopPropagation();
                onChange(value.filter((v) => v.email !== a.email));
              }}
              aria-label={`Remove ${a.email}`}
            >
              <X size={11} />
            </button>
          </span>
        ))}
        <input
          ref={inputRef}
          autoFocus={autoFocus}
          className="flex-1 min-w-36 bg-transparent outline-none text-[14px] text-foreground placeholder:text-tertiary h-6"
          value={text}
          placeholder={value.length ? "" : placeholder}
          onChange={(e) => {
            setText(e.target.value);
            setOpen(true);
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => {
            setTimeout(() => {
              commitText();
              setOpen(false);
            }, 150);
          }}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") { e.preventDefault(); setHi((h) => Math.min(h + 1, suggestions.length - 1)); }
            else if (e.key === "ArrowUp") { e.preventDefault(); setHi((h) => Math.max(h - 1, 0)); }
            else if (e.key === "Enter" || e.key === "Tab" || e.key === ",") {
              if (e.key === "Enter" || e.key === ",") e.preventDefault();
              if (suggestions[hi] && showMenu) { if (e.key === "Tab") e.preventDefault(); commit({ email: suggestions[hi].email, name: suggestions[hi].name }); }
              else if (text.trim()) { if (e.key === "Tab") e.preventDefault(); commitText(); }
            } else if (e.key === "Backspace" && !text && value.length) onChange(value.slice(0, -1));
            else if (e.key === "Escape") { e.stopPropagation(); setOpen(false); }
          }}
        />
      </div>
      {trailing && <div className="shrink-0 pt-0.5 flex items-center gap-2">{trailing}</div>}
      {showMenu && (
        <div className="absolute left-[68px] top-full mt-1 z-50 w-72 max-w-[85vw] rounded-lg bg-popover p-1 text-popover-foreground shadow-md ring-1 ring-foreground/10" role="listbox">
          {suggestions.map((c, i) => (
            <button
              key={c.email}
              type="button"
              role="option"
              aria-selected={i === hi}
              className={cn("w-full flex items-center gap-2 px-1.5 h-8 rounded-md text-left", i === hi && "bg-accent")}
              onMouseDown={(e) => e.preventDefault()}
              onMouseEnter={() => setHi(i)}
              onClick={() => commit({ email: c.email, name: c.name })}
            >
              <Avatar email={c.email} name={c.name} src={c.avatar_url} size={20} />
              <span className="flex-1 min-w-0 flex items-baseline gap-1.5">
                <span className="text-[13px] truncate">{c.name || c.email}</span>
                {c.name && <span className="text-xs text-muted-foreground truncate">{c.email}</span>}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
