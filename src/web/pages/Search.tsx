import { useEffect, useRef, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { Search, X } from "lucide-react";
import { useSearch } from "../api";
import { LoadMore, ThreadList } from "../components/ThreadList";
import { PageHeader } from "../components/EmptyState";
import { Button } from "@/components/ui/button";
import { Kbd } from "@/components/ui/kbd";

/** Highlights query matches inside `root` using the CSS Custom Highlight API (no DOM edits). */
function useTextHighlight(root: React.RefObject<HTMLElement | null>, q: string, dep: unknown) {
  useEffect(() => {
    const H = (window as unknown as { Highlight?: new (...r: Range[]) => unknown }).Highlight;
    const reg = (CSS as unknown as { highlights?: Map<string, unknown> }).highlights;
    if (!H || !reg || !root.current) return;
    const words = q
      .toLowerCase()
      .split(/\s+/)
      .filter((w) => w.length > 1);
    if (!words.length) return;
    const ranges: Range[] = [];
    const walker = document.createTreeWalker(root.current, NodeFilter.SHOW_TEXT);
    let node: Node | null;
    while ((node = walker.nextNode())) {
      const text = node.textContent?.toLowerCase() ?? "";
      for (const w of words) {
        let i = text.indexOf(w);
        while (i >= 0) {
          const r = new Range();
          r.setStart(node, i);
          r.setEnd(node, i + w.length);
          ranges.push(r);
          i = text.indexOf(w, i + w.length);
        }
      }
    }
    reg.set("hey-search", new H(...ranges));
    return () => {
      reg.delete("hey-search");
    };
  }, [root, q, dep]);
}

export default function SearchPage() {
  const [sp, setSp] = useSearchParams();
  const q = sp.get("q") ?? "";
  const [text, setText] = useState(q);
  useEffect(() => setText(q), [q]);
  const res = useSearch(q);
  const threads = res.data?.pages.flatMap((p) => p.threads) ?? [];
  const listRef = useRef<HTMLDivElement>(null);
  useTextHighlight(listRef, q, threads);
  const inputRef = useRef<HTMLInputElement>(null);
  const count = q && !res.isLoading ? `${threads.length}${res.hasNextPage ? "+" : ""} ${threads.length === 1 ? "result" : "results"} for “${q}”` : undefined;

  return (
    <div className="max-w-3xl mx-auto">
      <style>{`::highlight(hey-search){background:var(--accent);color:var(--foreground);text-decoration:underline;text-underline-offset:2px}`}</style>
      <PageHeader className="px-2" title="Search" subtitle={count ?? "Subjects, names, and what they said."} />
      <form
        role="search"
        className="relative mb-6 px-2"
        onSubmit={(e) => {
          e.preventDefault();
          setSp(text.trim() ? { q: text.trim() } : {});
        }}
      >
        <Search className="absolute left-5 top-1/2 -translate-y-1/2 size-4 text-muted-foreground pointer-events-none" />
        <input
          ref={inputRef}
          autoFocus
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Search subjects, people, and message text…"
          className="w-full h-11 pl-10 pr-20 rounded-md bg-muted text-base placeholder:text-muted-foreground outline-none focus:ring-1 focus:ring-border"
        />
        <div className="absolute right-4 top-1/2 -translate-y-1/2 flex items-center gap-1">
          {text && (
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              aria-label="Clear"
              className="text-muted-foreground"
              onClick={() => {
                setText("");
                setSp({});
                inputRef.current?.focus();
              }}
            >
              <X />
            </Button>
          )}
          <Kbd className="hidden sm:inline-flex">↵</Kbd>
        </div>
      </form>
      {q ? (
        <div ref={listRef}>
          <ThreadList
            showBucket
            loading={res.isLoading}
            error={res.error}
            onRetry={() => res.refetch()}
            emptyIcon={<Search />}
            sections={[{ threads, emptyTitle: "No matches.", emptyBody: "Try fewer words, or just a name." }]}
            footer={<LoadMore hasMore={!!res.hasNextPage} loading={res.isFetchingNextPage} onMore={() => res.fetchNextPage()} />}
          />
        </div>
      ) : (
        <div className="text-center text-[13px] text-muted-foreground pt-4 flex items-center justify-center gap-1.5">
          Tip: <Kbd>⌘K</Kbd> searches from anywhere.
        </div>
      )}
    </div>
  );
}
