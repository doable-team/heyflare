import type { ReactNode } from "react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty";
import { Skeleton as UiSkeleton } from "@/components/ui/skeleton";

export function SkeletonRows({ rows = 6, compact }: { rows?: number; compact?: boolean }) {
  return (
    <div aria-busy>
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className={cn("flex items-center gap-3 px-2", compact ? "h-10" : "h-11")}>
          {!compact && <UiSkeleton className="size-5 rounded-[4px] shrink-0" />}
          <UiSkeleton className="h-3 w-[22%]" />
          <UiSkeleton className="h-3 w-[38%]" />
          <span className="flex-1" />
          <UiSkeleton className="h-3 w-10" />
        </div>
      ))}
    </div>
  );
}
/** Legacy alias. */
export function Skeleton({ rows = 6, compact }: { rows?: number; compact?: boolean }) {
  return <SkeletonRows rows={rows} compact={compact} />;
}

/** Minimal empty state: icon in secondary color + one line + optional ghost action. No illustrations. */
export function EmptyState({ illustration, icon, title, body, action, compact, className }: { illustration?: ReactNode; icon?: ReactNode; title: ReactNode; body?: ReactNode; action?: ReactNode; compact?: boolean; className?: string }) {
  const media = icon ?? illustration;
  if (compact) {
    return (
      <div className={cn("px-2 py-3 text-[13px] text-muted-foreground", className)}>
        <span className="text-foreground/80">{title}</span>
        {body && <span> {body}</span>}
        {action && <span className="ml-2 inline-flex">{action}</span>}
      </div>
    );
  }
  return (
    <Empty className={cn("border-0 py-16", className)}>
      <EmptyHeader>
        {media && <EmptyMedia variant="icon" className="bg-transparent text-muted-foreground [&>svg]:size-5">{media}</EmptyMedia>}
        <EmptyTitle className="text-sm font-medium">{title}</EmptyTitle>
        {body && <EmptyDescription className="text-[13px]">{body}</EmptyDescription>}
      </EmptyHeader>
      {action && <EmptyContent>{action}</EmptyContent>}
    </Empty>
  );
}

export function ErrorState({ error, onRetry, title = "Something went sideways." }: { error: unknown; onRetry?: () => void; title?: string }) {
  const msg = error instanceof Error ? error.message : String(error);
  return (
    <Empty className="border-0 py-12">
      <EmptyHeader>
        <EmptyTitle className="text-sm font-medium">{title}</EmptyTitle>
        <EmptyDescription className="font-mono text-xs">{msg}</EmptyDescription>
      </EmptyHeader>
      {onRetry && (
        <EmptyContent>
          <Button variant="outline" size="sm" onClick={onRetry}>Try again</Button>
        </EmptyContent>
      )}
    </Empty>
  );
}

export function PageHeader({ title, subtitle, actions, eyebrow, className }: { title: ReactNode; subtitle?: ReactNode; actions?: ReactNode; eyebrow?: ReactNode; className?: string }) {
  return (
    <header data-slot="page-header" className={cn("flex items-end justify-between gap-4 mb-6 flex-wrap", className)}>
      <div className="min-w-0">
        {eyebrow && <div className="text-xs text-muted-foreground mb-1">{eyebrow}</div>}
        <h1 className="text-[28px] leading-[34px] font-bold tracking-[-0.02em] text-foreground">{title}</h1>
        {subtitle && <p className="text-sm text-muted-foreground mt-1">{subtitle}</p>}
      </div>
      {actions && <div className="flex items-center gap-1 shrink-0">{actions}</div>}
    </header>
  );
}

export function SectionTitle({ children, count, className, actions }: { children: ReactNode; count?: number; className?: string; actions?: ReactNode }) {
  return (
    <div className={cn("flex items-center gap-2 h-8 px-2 mb-0.5", className)}>
      <h2 className="text-xs font-medium text-muted-foreground">{children}</h2>
      {typeof count === "number" && count > 0 && <span className="text-xs text-tertiary tnum">{count}</span>}
      <span className="flex-1" />
      {actions}
    </div>
  );
}
