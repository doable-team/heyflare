import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Kbd } from "@/components/ui/kbd";

const GROUPS: { title: string; keys: [string, string][] }[] = [
  {
    title: "Moving around",
    keys: [["↑ / ↓", "Move through mail"], ["←", "Jump to the sidebar"], ["→", "Open the Assistant"], ["↵", "Open (sidebar: go there)"], ["esc", "Back to the list"]],
  },
  {
    title: "Go to",
    keys: [["⌘K", "Search & commands"], ["⌘B", "Toggle sidebar"], ["⌘J", "Assistant (open / close)"]],
  },
  {
    title: "Lists",
    keys: [["j / k", "Move down / up"], ["↵ or o", "Open thread"], ["x", "Select thread"], ["l", "Reply later"], ["a", "Set aside"], ["z", "Bubble up"], ["u", "Mark unread"], ["#", "Trash"], ["b", "Labels (with selection)"], ["g", "Merge selected"]],
  },
  {
    title: "Power through new",
    keys: [["o", "Start (from the Imbox)"], ["j / k", "Next / previous"], ["r", "Reply inline"], ["l", "Reply later"], ["a", "Set aside"], ["e", "Mark seen"], ["#", "Trash"], ["↵", "Open the full thread"], ["esc", "Back to the Imbox"]],
  },
  {
    title: "Calendar",
    keys: [["0", "Mail ⇄ Calendar"], ["↑ / ↓", "Previous / next"], ["←", "Jump to the sidebar"], ["→", "Open the Assistant"], ["t", "Today"], ["d / w / y", "Day, week, year"], ["n", "New event"], ["j", "Journal"], ["b", "Habits"]],
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
        <div className="grid sm:grid-cols-2 gap-x-8 gap-y-6 pt-1">
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
