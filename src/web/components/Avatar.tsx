import { useState } from "react";
import { Check } from "lucide-react";
import { cn } from "@/lib/utils";
import { initials } from "../lib/format";
import {
  Tooltip as UiTooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";

/** Compat: v2 exported a hue hash. Monochrome now — kept so old imports compile. */
export function avatarHue(_email: string): number {
  return 0;
}
export function avatarBg(_email: string): string {
  return "var(--muted)";
}

// ---- Photo lookup: only what Gmail would show — Google People photo or BIMI brand logo (server-provided `src`); else initials. ----
const failedUrls = new Set<string>();

/** Notion-style avatar: 4px-rounded square. Shows the person's photo when available, otherwise initials. */
export function Avatar({
  email,
  name,
  size = 24,
  selected,
  onClick,
  className = "",
  strong,
  src,
}: {
  email: string;
  name?: string;
  size?: number;
  selected?: boolean;
  onClick?: (e: React.MouseEvent) => void;
  className?: string;
  /** Inverted (foreground bg) for emphasis. */
  strong?: boolean;
  ring?: boolean;
  /** Photo url (Google contact photo, profile picture, or BIMI brand logo). Falls back to initials. */
  src?: string;
}) {
  const style = { width: size, height: size, fontSize: Math.max(9, Math.round(size * 0.42)) };
  const inverted = selected || strong;
  const [broken, setBroken] = useState<string>("");
  const photo = src && !failedUrls.has(src) && src !== broken ? src : "";
  const isLogo = /\.svg(\?|#|$)/i.test(photo);
  const showPhoto = !selected && !!photo;
  const content = selected ? (
    <Check size={Math.round(size * 0.55)} strokeWidth={2.5} />
  ) : showPhoto ? (
    <img
      src={photo}
      alt=""
      width={size}
      height={size}
      loading="lazy"
      referrerPolicy="no-referrer"
      draggable={false}
      className={cn("block w-full h-full rounded-[4px]", isLogo ? "object-contain p-[12%] bg-muted" : "object-cover")}
      onError={() => {
        failedUrls.add(photo);
        setBroken(photo);
      }}
    />
  ) : (
    initials(name ?? "", email)
  );
  const cls = cn(
    "shrink-0 rounded-[4px] font-medium flex items-center justify-center select-none leading-none overflow-hidden",
    inverted ? "bg-foreground text-background" : "bg-muted text-foreground/80",
    className,
  );
  if (onClick) {
    return (
      <button type="button" onClick={onClick} style={style} aria-pressed={selected} aria-label={selected ? "Deselect" : "Select"} className={cn(cls, "hover:bg-accent")}>
        {content}
      </button>
    );
  }
  return (
    <div style={style} className={cls} aria-hidden>
      {content}
    </div>
  );
}

export function AvatarStack({ people, size = 20, max = 3, className, plus = true }: { people: { email: string; name?: string; avatar_url?: string }[]; size?: number; max?: number; className?: string; plus?: boolean }) {
  const shown = people.slice(0, max);
  const rest = people.length - shown.length;
  return (
    <div className={cn("flex items-center", className)}>
      {shown.map((p, i) => (
        <span
          key={p.email + i}
          className={cn("relative shrink-0 rounded-[6px] bg-background p-[2px]", i > 0 && "-ml-1.5")}
          style={{ zIndex: i + 1 }}
        >
          <Avatar email={p.email} name={p.name} src={p.avatar_url} size={size} />
        </span>
      ))}
      {plus && rest > 0 && (
        <span className="relative -ml-1.5 rounded-[6px] bg-background p-[2px]" style={{ zIndex: shown.length + 1 }}>
          <span className="rounded-[4px] bg-muted text-muted-foreground flex items-center justify-center tnum" style={{ width: size, height: size, fontSize: Math.max(9, Math.round(size * 0.4)) }}>
            +{rest}
          </span>
        </span>
      )}
    </div>
  );
}

/** Tiny monochrome mark identifying an account in the unified inbox. */
export function AccountGlyph({ glyph, label, className }: { glyph: string; label?: string; className?: string }) {
  if (!glyph) return null;
  const el = (
    <span aria-label={label} className={cn("inline-flex items-center justify-center text-[9px] leading-none text-muted-foreground shrink-0", className)}>
      {glyph}
    </span>
  );
  if (!label) return el;
  return (
    <UiTooltip>
      <TooltipTrigger asChild>{el}</TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </UiTooltip>
  );
}

/** Two people in one square (mobile rows): the latest sender bottom-right, another participant top-left. */
export function AvatarCluster({ people, size = 36, strong }: { people: { email: string; name?: string; avatar_url?: string }[]; size?: number; strong?: boolean }) {
  const a = people[0];
  const b = people[1];
  if (!b) return <Avatar email={a?.email ?? ""} name={a?.name} src={a?.avatar_url} size={size} strong={strong} />;
  const small = Math.round(size * 0.68);
  return (
    <span className="relative block shrink-0" style={{ width: size, height: size }}>
      <span className="absolute left-0 top-0"><Avatar email={b.email} name={b.name} src={b.avatar_url} size={small} /></span>
      <span className="absolute -right-[2px] -bottom-[2px] rounded-[6px] bg-background p-[2px]"><Avatar email={a.email} name={a.name} src={a.avatar_url} size={small} strong={strong} /></span>
    </span>
  );
}

/** A bundle at a glance (HEY-style): the sender's tile on top of a couple of blank cards offset up-left. */
export function BundleAvatar({ email, name, src, size = 20, strong }: { email: string; name?: string; src?: string; size?: number; strong?: boolean }) {
  const off = Math.max(2, Math.round(size * 0.12));
  return (
    <span className="relative block shrink-0" style={{ width: size + off * 2, height: size + off * 2 }} aria-hidden>
      <span className="absolute rounded-[4px] bg-muted border border-border" style={{ width: size, height: size, left: 0, top: 0 }} />
      <span className="absolute rounded-[4px] bg-muted border border-border" style={{ width: size, height: size, left: off, top: off }} />
      <span className="absolute" style={{ left: off * 2, top: off * 2 }}>
        <Avatar email={email} name={name} src={src} size={size} strong={strong} />
      </span>
    </span>
  );
}
