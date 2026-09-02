import type { ReactNode } from "react";
import { cn } from "@/lib/utils";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Sheet as UiSheet, SheetContent, SheetFooter, SheetHeader, SheetTitle, SheetDescription } from "@/components/ui/sheet";

const SIZES = { sm: "sm:max-w-sm", md: "sm:max-w-lg", lg: "sm:max-w-2xl", xl: "sm:max-w-4xl" } as const;

export function Modal({ open, onClose, title, subtitle, children, wide, footer, size, bare }: { open: boolean; onClose: () => void; title?: ReactNode; subtitle?: ReactNode; children: ReactNode; wide?: boolean; size?: "sm" | "md" | "lg" | "xl"; footer?: ReactNode; bare?: boolean }) {
  const sz = SIZES[size ?? (wide ? "lg" : "md")];
  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className={cn(sz, bare && "p-0 gap-0")} showCloseButton={!bare}>
        {(title || subtitle) && (
          <DialogHeader>
            {title && <DialogTitle>{title}</DialogTitle>}
            {subtitle ? <DialogDescription>{subtitle}</DialogDescription> : <DialogDescription className="sr-only">Dialog</DialogDescription>}
          </DialogHeader>
        )}
        {!title && <DialogTitle className="sr-only">Dialog</DialogTitle>}
        {children}
        {footer && <DialogFooter>{footer}</DialogFooter>}
      </DialogContent>
    </Dialog>
  );
}

export function Confirm({ open, onClose, onConfirm, title, body, confirmLabel = "Confirm", danger: _danger }: { open: boolean; onClose: () => void; onConfirm: () => void; title: string; body?: ReactNode; confirmLabel?: string; danger?: boolean }) {
  return (
    <AlertDialog open={open} onOpenChange={(o) => !o && onClose()}>
      <AlertDialogContent size="sm">
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          {body ? <AlertDialogDescription>{body}</AlertDialogDescription> : <AlertDialogDescription className="sr-only">Confirm</AlertDialogDescription>}
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction onClick={() => { onConfirm(); onClose(); }}>{confirmLabel}</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}

export function Sheet({ open, onClose, title, children, side = "right", width = 560, footer }: { open: boolean; onClose: () => void; title?: ReactNode; children: ReactNode; side?: "right" | "bottom"; width?: number; footer?: ReactNode }) {
  return (
    <UiSheet open={open} onOpenChange={(o) => !o && onClose()}>
      <SheetContent side={side} className={cn("flex flex-col gap-0 p-0", side === "right" && "w-full sm:max-w-none")} style={side === "right" ? { width: "100%", maxWidth: width } : undefined}>
        <SheetHeader className={cn(!title && "sr-only")}>
          <SheetTitle>{title ?? "Panel"}</SheetTitle>
          <SheetDescription className="sr-only">Panel</SheetDescription>
        </SheetHeader>
        <div className="flex-1 min-h-0 overflow-y-auto">{children}</div>
        {footer && <SheetFooter>{footer}</SheetFooter>}
      </SheetContent>
    </UiSheet>
  );
}
