import { Toaster as Sonner } from "sonner";

/** Sonner styled with shadcn variables (theme follows the .dark class on <html>). */
export function Toaster() {
  return (
    <Sonner
      position="bottom-center"
      closeButton={false}
      toastOptions={{
        classNames: {
          toast: "!bg-popover !text-popover-foreground !border !border-border !shadow-md !rounded-md !text-sm",
          description: "!text-muted-foreground",
          actionButton: "!bg-foreground !text-background !rounded-[4px]",
        },
      }}
    />
  );
}
