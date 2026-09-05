import { createContext, lazy, Suspense, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { invalidateMail, sendMail, type SendPayload } from "../api";
import type { ComposerHandle, ComposerInitial } from "../components/Composer";
import { whenIdle } from "../lib/lazy";
import { useKeys } from "../lib/keys";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { useIsMobile } from "@/hooks/use-mobile";

// The composer is the heaviest thing that is not a page — editor, recipients, attachments, the
// scheduling picker — and most sessions never open it. Each form factor gets its own chunk,
// fetched in idle time so the first ⌘N still opens instantly.
const loadComposer = () => import("../components/Composer");
const loadMobileComposer = () => import("../mobile/MobileComposer");
const Composer = lazy(() => loadComposer().then((m) => ({ default: m.Composer })));
const MobileComposer = lazy(() => loadMobileComposer().then((m) => ({ default: m.MobileComposer })));

interface Ctx {
  openCompose: (initial?: ComposerInitial) => void;
  closeCompose: () => void;
  queueSend: (payload: SendPayload, undoSeconds: number) => void;
}
const C = createContext<Ctx>({ openCompose: () => {}, closeCompose: () => {}, queueSend: () => {} });

interface Pending {
  id: number;
  payload: SendPayload;
  until: number;
  toastId: string | number;
}

export function ComposeProvider({ children }: { children: ReactNode }) {
  const [open, setOpen] = useState<{ key: number; initial: ComposerInitial } | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const timer = useRef<number | null>(null);
  const composer = useRef<ComposerHandle>(null);
  const qc = useQueryClient();

  const fire = useCallback(
    async (p: Pending) => {
      setPending(null);
      toast.dismiss(p.toastId);
      try {
        await sendMail(p.payload);
        toast.success("Sent");
        invalidateMail(qc);
        qc.invalidateQueries({ queryKey: ["drafts"] });
      } catch (e) {
        toast.error("Couldn't send", {
          description: (e as Error).message,
          duration: 10000,
          action: { label: "Edit", onClick: () => setOpen({ key: Date.now(), initial: { ...p.payload, title: "Unsent message" } }) },
        });
      }
    },
    [qc],
  );

  const pendingRef = useRef<Pending | null>(null);
  pendingRef.current = pending;

  const undo = useCallback(() => {
    const p = pendingRef.current;
    if (!p) return;
    if (timer.current) window.clearTimeout(timer.current);
    setPending(null);
    toast.dismiss(p.toastId);
    setOpen({ key: Date.now(), initial: { ...p.payload, title: "Unsent message" } });
  }, []);

  const queueSend = useCallback<Ctx["queueSend"]>(
    (payload, undoSeconds) => {
      if (timer.current) window.clearTimeout(timer.current);
      const secs = Math.max(0, undoSeconds);
      if (secs <= 0) {
        fire({ id: Date.now(), payload, until: Date.now(), toastId: -1 });
        return;
      }
      const toastId = toast("Sending…", {
        description: `Press q to undo within ${secs}s.`,
        duration: secs * 1000,
        action: { label: "Undo", onClick: () => undo() },
      });
      const p: Pending = { id: Date.now(), payload, until: Date.now() + secs * 1000, toastId };
      setPending(p);
      timer.current = window.setTimeout(() => fire(p), secs * 1000);
    },
    [fire, undo],
  );

  // Send pending immediately if the tab is closing.
  useEffect(() => {
    const h = () => {
      const p = pendingRef.current;
      if (p) {
        if (timer.current) window.clearTimeout(timer.current);
        navigator.sendBeacon?.("/api/send", new Blob([JSON.stringify(p.payload)], { type: "application/json" }));
      }
    };
    window.addEventListener("beforeunload", h);
    return () => window.removeEventListener("beforeunload", h);
  }, []);

  useKeys({ q: () => undo() }, !!pending);

  const openCompose = useCallback((initial: ComposerInitial = {}) => setOpen({ key: Date.now(), initial }), []);
  const closeCompose = useCallback(() => setOpen(null), []);
  const requestClose = useCallback(() => {
    if (composer.current) composer.current.saveAndClose();
    else setOpen(null);
  }, []);

  const title = open?.initial.title || (open?.initial.thread_id ? "Reply" : "New message");
  const mobile = useIsMobile();
  useEffect(() => {
    whenIdle(() => void (mobile ? loadMobileComposer() : loadComposer()).catch(() => {}));
  }, [mobile]);

  if (mobile) {
    return (
      <C.Provider value={{ openCompose, closeCompose, queueSend }}>
        {children}
        <Suspense fallback={null}>
          <MobileComposer open={open} composerRef={composer} title={title} onRequestClose={requestClose} onClose={closeCompose} />
        </Suspense>
      </C.Provider>
    );
  }

  return (
    <C.Provider value={{ openCompose, closeCompose, queueSend }}>
      {children}
      <Sheet open={!!open} onOpenChange={(o) => !o && requestClose()}>
        <SheetContent side="right" className="w-full data-[side=right]:w-full data-[side=right]:sm:max-w-[600px] gap-0 p-0 bg-background" showCloseButton>
          <SheetHeader className="h-11 justify-center border-b border-border py-0 pr-12">
            <SheetTitle className="text-[13px] font-medium">{title}</SheetTitle>
            <SheetDescription className="sr-only">Compose a message</SheetDescription>
          </SheetHeader>
          <div className="flex-1 min-h-0 overflow-y-auto">
            {open && (
              <Suspense fallback={null}>
                <Composer key={open.key} ref={composer} initial={open.initial} onDone={closeCompose} onCancel={closeCompose} />
              </Suspense>
            )}
          </div>
        </SheetContent>
      </Sheet>
    </C.Provider>
  );
}

export function useCompose() {
  return useContext(C);
}
