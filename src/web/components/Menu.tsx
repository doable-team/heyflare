import { useState, type ReactNode } from "react";
import { Check } from "lucide-react";
import { cn } from "@/lib/utils";
import { Popover as UiPopover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Kbd } from "@/components/ui/kbd";

/**
 * Compat Popover: render-prop trigger + children(close). Backed by shadcn/Radix Popover.
 */
export function Popover({
  trigger,
  children,
  align = "left",
  side = "bottom",
  open: controlledOpen,
  onOpenChange,
  className,
  panelClassName,
}: {
  trigger: (props: { open: boolean; toggle: () => void }) => ReactNode;
  children: ReactNode | ((close: () => void) => ReactNode);
  align?: "left" | "right" | "center";
  side?: "bottom" | "top";
  open?: boolean;
  onOpenChange?: (o: boolean) => void;
  className?: string;
  panelClassName?: string;
}) {
  const [inner, setInner] = useState(false);
  const open = controlledOpen ?? inner;
  const setOpen = (o: boolean) => {
    if (controlledOpen === undefined) setInner(o);
    onOpenChange?.(o);
  };
  const close = () => setOpen(false);
  return (
    <UiPopover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <span className={cn("inline-flex", className)}>{trigger({ open, toggle: () => setOpen(!open) })}</span>
      </PopoverTrigger>
      <PopoverContent side={side} align={align === "left" ? "start" : align === "right" ? "end" : "center"} className={cn("w-auto p-0", panelClassName)}>
        {typeof children === "function" ? children(close) : children}
      </PopoverContent>
    </UiPopover>
  );
}

export function Menu({ children, className, width, onClick }: { children: ReactNode; className?: string; width?: number | string; onClick?: () => void }) {
  return (
    <div role="menu" className={cn("p-1 min-w-40", className)} style={width ? { width } : undefined} onClick={onClick}>
      {children}
    </div>
  );
}

export function MenuItem({
  icon,
  children,
  onClick,
  danger: _danger,
  disabled,
  active,
  checked,
  kbd,
  trailing,
  className,
}: {
  icon?: ReactNode;
  children: ReactNode;
  onClick?: () => void;
  danger?: boolean;
  disabled?: boolean;
  active?: boolean;
  checked?: boolean;
  kbd?: string;
  trailing?: ReactNode;
  className?: string;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      disabled={disabled}
      onClick={onClick}
      className={cn(
        "w-full flex items-center gap-2 h-7 px-2 rounded-md text-sm text-left outline-none transition-colors duration-100",
        "hover:bg-accent focus-visible:bg-accent disabled:opacity-50 disabled:pointer-events-none [&>svg]:size-4 [&>svg]:text-muted-foreground",
        active && "bg-accent",
        className,
      )}
    >
      {icon}
      <span className="flex-1 min-w-0 truncate">{children}</span>
      {checked && <Check className="!text-foreground" />}
      {kbd && <Kbd>{kbd}</Kbd>}
      {trailing}
    </button>
  );
}

export function MenuSeparator() {
  return <div className="my-1 h-px bg-border" role="separator" />;
}
export function MenuLabel({ children }: { children: ReactNode }) {
  return <div className="px-2 py-1.5 text-xs text-muted-foreground">{children}</div>;
}
