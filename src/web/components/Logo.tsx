import { cn } from "@/lib/utils";

/**
 * heyflare mark: an "h" whose flare is a spark at the top right.
 * Monochrome — tile uses the foreground color, glyph the background color, so it inverts in dark mode.
 */
export function Mark({ size = 20, className }: { size?: number; className?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" className={cn("shrink-0", className)} aria-hidden>
      <rect width="64" height="64" rx="16" className="fill-foreground" />
      <path d="M21 15v34M21 37c0-9 18-9 18 0v12" fill="none" className="stroke-background" strokeWidth="7" strokeLinecap="round" strokeLinejoin="round" />
      <circle cx="47" cy="17" r="4.5" className="fill-background" />
    </svg>
  );
}

export function Wordmark({ className, size = 20 }: { className?: string; size?: number }) {
  return (
    <span className={cn("inline-flex items-center gap-2 font-semibold tracking-[-0.01em]", className)}>
      <Mark size={size} />
      heyflare
    </span>
  );
}
