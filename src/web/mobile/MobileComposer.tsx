import { useEffect, type RefObject } from "react";
import { Composer, type ComposerHandle, type ComposerInitial } from "../components/Composer";

/** Full-screen composer for phones: Cancel · title · Send in the top bar, the editor underneath. */
export function MobileComposer({ open, initial, composerRef, title, onRequestClose, onClose }: { open: { key: number; initial: ComposerInitial } | null; initial?: ComposerInitial; composerRef: RefObject<ComposerHandle | null>; title: string; /** Top-bar Cancel: saves a draft first. */ onRequestClose: () => void; /** The editor finished (sent, discarded, or draft saved). */ onClose: () => void }) {
  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, [open]);
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-[60] bg-background flex flex-col animate-in slide-in-from-bottom-4 fade-in duration-200" role="dialog" aria-label={title} style={{ height: "100dvh" }}>
      <div className="shrink-0 pt-safe bg-background border-b border-border">
        <div className="h-11 flex items-center px-1">
          <button type="button" onClick={onRequestClose} className="h-11 px-3 text-[15px] text-foreground">Cancel</button>
          <div className="flex-1 text-center text-[15px] font-semibold truncate">{title}</div>
          <button type="button" onClick={() => composerRef.current?.send()} className="h-11 px-3 text-[15px] font-semibold text-foreground">Send</button>
        </div>
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto overscroll-contain">
        <Composer key={open.key} ref={composerRef} initial={initial ?? open.initial} onDone={onClose} onCancel={onClose} />
      </div>
    </div>
  );
}
