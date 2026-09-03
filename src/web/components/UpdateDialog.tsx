import { useState } from "react";
import { ArrowUpCircle, Check, Copy, ExternalLink } from "lucide-react";
import { native } from "../lib/native";
import { plainNotes, type UpdateInfo } from "../lib/update";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";

const UPDATING_DOC = "https://github.com/doable-team/heyflare/blob/main/docs/UPDATING.md";

function CopyLine({ cmd }: { cmd: string }) {
  const [done, setDone] = useState(false);
  return (
    <div className="flex items-center gap-2 rounded-md bg-muted px-2.5 py-1.5">
      <code className="flex-1 font-mono text-[12px] text-foreground truncate">{cmd}</code>
      <button
        type="button"
        aria-label={`Copy: ${cmd}`}
        className="text-muted-foreground hover:text-foreground shrink-0"
        onClick={() => {
          void navigator.clipboard?.writeText(cmd);
          setDone(true);
          window.setTimeout(() => setDone(false), 1500);
        }}
      >
        {done ? <Check size={14} /> : <Copy size={14} />}
      </button>
    </div>
  );
}

/**
 * What's new, and how to get it: one click in the Mac app, one command on a self-hosted server.
 * Either way the data stays put — only the code is replaced.
 */
export function UpdateDialog({ open, onClose, info }: { open: boolean; onClose: () => void; info: UpdateInfo & { dismiss: () => void } }) {
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const notes = plainNotes(info.notes);

  const install = async () => {
    setBusy(true);
    setError(null);
    setProgress(0);
    const err = await native.updateApp((f) => setProgress(f));
    if (err) {
      setError(err);
      setBusy(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-[460px]">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <ArrowUpCircle size={16} className="text-muted-foreground" />
            heyflare v{info.latest} is available
          </DialogTitle>
          <DialogDescription>{info.current ? `You're on v${info.current}.` : "A newer version has been released."}</DialogDescription>
        </DialogHeader>

        {notes && <div className="max-h-44 overflow-y-auto whitespace-pre-wrap font-sans text-[13px] leading-5 text-muted-foreground">{notes}</div>}

        <p className="text-[13px] text-muted-foreground">
          <span className="text-foreground font-medium">Your mail is safe.</span> Updating replaces the app code only. Mail, contacts, screener decisions,
          settings and AI memory live in your database and are untouched. Any new database changes apply themselves the first time the updated app runs.{" "}
          <a href={UPDATING_DOC} target="_blank" rel="noreferrer" className="underline underline-offset-2 hover:text-foreground">
            How updating works
          </a>
          .
        </p>

        {info.native ? (
          <>
            {busy && (
              <p className="text-[13px] text-muted-foreground tnum">
                {progress != null && progress >= 0 ? `Downloading… ${Math.round(progress * 100)}%` : "Downloading…"}
              </p>
            )}
            {error && (
              <p className="text-[13px] text-foreground">
                Download failed. {error}{" "}
                <button type="button" className="underline underline-offset-2" onClick={() => native.openExternal(info.url)}>
                  Open the release page
                </button>
                .
              </p>
            )}
          </>
        ) : (
          <div className="space-y-2">
            <p className="text-[13px] text-muted-foreground">Update your server by redeploying:</p>
            <CopyLine cmd="npx create-heyflare deploy" />
            <CopyLine cmd="git pull && npm run deploy" />
            <p className="text-[12px] text-muted-foreground">
              The first command is for projects created with <code className="font-mono">npm create heyflare</code>, the second for a cloned repo. A fork
              connected to Workers Builds redeploys on its own when you push.
            </p>
          </div>
        )}

        <DialogFooter className="gap-2 sm:gap-2">
          <Button
            variant="ghost"
            onClick={() => {
              info.dismiss();
              onClose();
            }}
            disabled={busy}
          >
            Later
          </Button>
          <Button variant="outline" asChild>
            <a href={info.url} target="_blank" rel="noreferrer">
              Release notes <ExternalLink />
            </a>
          </Button>
          {info.native && (
            <Button onClick={install} disabled={busy}>
              {busy ? "Updating…" : "Update and restart"}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
