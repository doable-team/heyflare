import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Kbd } from "@/components/ui/kbd";

const GROUPS: { title: string; keys: [string, string][] }[] = [
  {
    title: "Go to",
    keys: [["1", "Imbox"], ["2", "The Feed"], ["3", "Paper Trail"], ["4", "Screener"], ["5", "Focus & Reply"], ["6", "Set Aside"], ["7", "Bubble Up"], ["8", "Previously Seen"], ["9", "Contacts"], ["⌘K", "Search & commands"], ["⌘B", "Toggle sidebar"]],
  },
  {
    title: "Lists",
    keys: [["j / k", "Move down / up"], ["↵ or o", "Open thread"], ["x", "Select thread"], ["l", "Reply later"], ["a", "Set aside"], ["z", "Bubble up"], ["u", "Mark unread"], ["#", "Trash"], ["b", "Labels (with selection)"], ["g", "Merge selected"]],
  },
  {
    title: "Everywhere",
    keys: [["c", "Compose"], ["⌘↵", "Send message"], ["q", "Undo send"], ["i", "Back to Imbox"], ["esc", "Close / clear"], ["?", "This overlay"]],
  },
];

export function ShortcutsOverlay({ open, onClose }: { open: boolean; onClose: () => void }) {
  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Keyboard shortcuts</DialogTitle>
          <DialogDescription>The whole app works without a mouse.</DialogDescription>
        </DialogHeader>
        <div className="grid sm:grid-cols-3 gap-6 pt-1">
          {GROUPS.map((g) => (
            <div key={g.title}>
              <div className="text-xs font-medium text-muted-foreground mb-2">{g.title}</div>
              <div className="space-y-1.5">
                {g.keys.map(([k, v]) => (
                  <div key={k} className="flex items-center justify-between gap-3 text-[13px]">
                    <span>{v}</span>
                    <Kbd>{k}</Kbd>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      </DialogContent>
    </Dialog>
  );
}
