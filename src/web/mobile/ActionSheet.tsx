import type { ReactNode } from "react";
import { cn } from "@/lib/utils";
import { Drawer, DrawerContent, DrawerDescription, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";

export interface SheetAction {
  icon?: ReactNode;
  label: ReactNode;
  hint?: ReactNode;
  onSelect: () => void;
  destructive?: boolean;
  checked?: boolean;
  disabled?: boolean;
}

/** Bottom sheet with large, thumb-sized rows. */
export function ActionSheet({ open, onOpenChange, title, description, actions, children }: { open: boolean; onOpenChange: (o: boolean) => void; title?: ReactNode; description?: ReactNode; actions?: SheetAction[]; children?: ReactNode }) {
  return (
    <Drawer open={open} onOpenChange={onOpenChange}>
      <DrawerContent className="pb-safe">
        {(title || description) && (
          <DrawerHeader className="pb-1">
            {title && <DrawerTitle className="text-[15px]">{title}</DrawerTitle>}
            {description ? <DrawerDescription>{description}</DrawerDescription> : <DrawerDescription className="sr-only">Actions</DrawerDescription>}
          </DrawerHeader>
        )}
        {!title && !description && <DrawerTitle className="sr-only">Actions</DrawerTitle>}
        {actions && (
          <div className="px-2 pb-2">
            {actions.map((a, i) => (
              <button
                key={i}
                type="button"
                disabled={a.disabled}
                onClick={() => {
                  onOpenChange(false);
                  window.setTimeout(a.onSelect, 60);
                }}
                className={cn(
                  "w-full h-12 flex items-center gap-3 px-3 rounded-md text-[15px] text-left active:bg-accent disabled:opacity-40",
                  a.destructive ? "text-foreground" : "text-foreground",
                  a.checked && "bg-muted",
                )}
              >
                {a.icon && <span className="text-muted-foreground [&>svg]:size-5 shrink-0">{a.icon}</span>}
                <span className="flex-1 min-w-0 truncate">{a.label}</span>
                {a.hint && <span className="text-[13px] text-muted-foreground shrink-0">{a.hint}</span>}
              </button>
            ))}
          </div>
        )}
        {children}
      </DrawerContent>
    </Drawer>
  );
}
