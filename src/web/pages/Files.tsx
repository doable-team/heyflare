import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Download, File, FileArchive, FileImage, FileSpreadsheet, FileText, Film, MessageSquare, Music, Presentation } from "lucide-react";
import type { Attachment } from "@shared/types";
import { cn } from "@/lib/utils";
import { attachmentUrl, useFiles } from "../api";
import { EmptyState, ErrorState, PageHeader } from "../components/EmptyState";
import { LoadMore } from "../components/ThreadList";
import { fmtSize, fmtDate } from "../lib/format";
import { Skeleton } from "@/components/ui/skeleton";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useCardScroll } from "../lib/cardKeys";

export type FileKind = "image" | "pdf" | "document" | "slides" | "spreadsheet" | "archive" | "video" | "audio" | "other";
type Filter = "all" | "image" | "pdf" | "document" | "spreadsheet" | "archive" | "media" | "other";

export function kindOf(mime: string, name: string): FileKind {
  const n = name.toLowerCase();
  const m = mime.toLowerCase();
  if (m.startsWith("image/")) return "image";
  if (m === "application/pdf" || n.endsWith(".pdf")) return "pdf";
  if (m.includes("presentation") || m.includes("powerpoint") || /\.(pptx?|key)$/.test(n)) return "slides";
  if (m.includes("spreadsheet") || m.includes("excel") || m === "text/csv" || /\.(xlsx?|csv|numbers)$/.test(n)) return "spreadsheet";
  if (m.includes("word") || m.includes("document") || m.startsWith("text/") || m.includes("rtf") || /\.(docx?|txt|md|rtf|pages)$/.test(n)) return "document";
  if (m.includes("zip") || m.includes("compressed") || m.includes("tar") || /\.(zip|rar|7z|tar|gz|tgz)$/.test(n)) return "archive";
  if (m.startsWith("video/")) return "video";
  if (m.startsWith("audio/")) return "audio";
  return "other";
}

const KIND_ICON: Record<FileKind, React.ReactNode> = {
  image: <FileImage />,
  pdf: <FileText />,
  document: <FileText />,
  slides: <Presentation />,
  spreadsheet: <FileSpreadsheet />,
  archive: <FileArchive />,
  video: <Film />,
  audio: <Music />,
  other: <File />,
};

function matches(k: FileKind, f: Filter) {
  if (f === "all") return true;
  if (f === "media") return k === "video" || k === "audio";
  if (f === "document") return k === "document" || k === "slides";
  return k === f;
}

function ext(name: string) {
  const m = /\.([a-z0-9]{1,5})$/i.exec(name);
  return m ? m[1].toUpperCase() : "";
}

export function FileTile({ f }: { f: Attachment; delay?: number }) {
  const k = kindOf(f.mime_type, f.filename);
  const url = attachmentUrl(f.message_id, f.id);
  const [broken, setBroken] = useState(false);
  return (
    <article className="group relative flex flex-col min-w-0">
      <a href={url} target="_blank" rel="noopener" className="relative block aspect-[4/3] rounded-md bg-muted overflow-hidden">
        {k === "image" && !broken ? (
          <img src={url} alt={f.filename} loading="lazy" onError={() => setBroken(true)} className="absolute inset-0 w-full h-full object-cover" />
        ) : (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-1.5 text-muted-foreground [&>svg]:size-6">
            {KIND_ICON[k]}
            {ext(f.filename) && <span className="text-[11px] tracking-wide">{ext(f.filename)}</span>}
          </div>
        )}
        <Tooltip>
          <TooltipTrigger asChild>
            <a
              href={attachmentUrl(f.message_id, f.id, true)}
              className="absolute top-1.5 right-1.5 size-7 rounded-md bg-background/90 text-muted-foreground hover:text-foreground flex items-center justify-center opacity-0 group-hover:opacity-100 focus-visible:opacity-100 transition-opacity"
              onClick={(e) => e.stopPropagation()}
              aria-label="Download"
            >
              <Download size={14} />
            </a>
          </TooltipTrigger>
          <TooltipContent>Download</TooltipContent>
        </Tooltip>
      </a>
      <div className="px-0.5 pt-2">
        <div className="text-[13px] font-medium truncate" title={f.filename}>{f.filename || "attachment"}</div>
        <div className="text-xs text-muted-foreground truncate tnum mt-0.5">
          {fmtSize(f.size)} · {fmtDate(f.created_at)}
        </div>
        {(f.from || f.thread_subject) && (
          <Link to={`/t/${f.thread_id}`} className="mt-1 flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground min-w-0">
            <MessageSquare size={11} className="shrink-0" />
            <span className="truncate">{f.from?.name || f.from?.email || ""}{f.from && f.thread_subject ? " · " : ""}{f.thread_subject || ""}</span>
          </Link>
        )}
      </div>
    </article>
  );
}

const FILTERS: { value: Filter; label: string }[] = [
  { value: "all", label: "All" },
  { value: "image", label: "Images" },
  { value: "pdf", label: "PDFs" },
  { value: "document", label: "Docs" },
  { value: "spreadsheet", label: "Sheets" },
  { value: "archive", label: "Archives" },
  { value: "media", label: "Media" },
  { value: "other", label: "Other" },
];

export default function FilesPage() {
  useCardScroll();
  const q = useFiles();
  const [filter, setFilter] = useState<Filter>("all");
  const all = q.data?.pages.flatMap((p) => p.files) ?? [];
  const list = all.filter((f) => matches(kindOf(f.mime_type, f.filename), filter));
  const sentinel = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const el = sentinel.current;
    if (!el || !q.hasNextPage) return;
    const io = new IntersectionObserver((entries) => {
      if (entries[0].isIntersecting && !q.isFetchingNextPage) q.fetchNextPage();
    }, { rootMargin: "400px" });
    io.observe(el);
    return () => io.disconnect();
  }, [q.hasNextPage, q.isFetchingNextPage, q.fetchNextPage, list.length]);
  const total = all.reduce((s, f) => s + f.size, 0);
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader
        title="Files"
        subtitle="Every attachment anyone has ever sent you, in one place."
        actions={all.length > 0 ? <span className="text-xs text-muted-foreground tnum">{all.length} files · {fmtSize(total)}</span> : undefined}
      />
      <div className="mb-4 px-2 overflow-x-auto [scrollbar-width:none]">
        <ToggleGroup type="single" size="sm" value={filter} onValueChange={(v) => v && setFilter(v as Filter)} className="w-max">
          {FILTERS.map((f) => (
            <ToggleGroupItem key={f.value} value={f.value} className={cn("text-muted-foreground data-[state=on]:bg-accent data-[state=on]:text-foreground")}>{f.label}</ToggleGroupItem>
          ))}
        </ToggleGroup>
      </div>
      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && (
        <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3 px-2">
          {[0, 1, 2, 3, 4, 5, 6, 7].map((i) => (
            <Skeleton key={i} className="aspect-[4/5] rounded-md" />
          ))}
        </div>
      )}
      {!q.isLoading && list.length === 0 && !q.error && (
        <EmptyState
          icon={<File />}
          title={filter === "all" ? "No files yet." : `No ${FILTERS.find((f) => f.value === filter)?.label.toLowerCase()} here.`}
          body={filter === "all" ? "Attachments show up here as your mail syncs." : "Try another type, or clear the filter."}
        />
      )}
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-x-3 gap-y-5 px-2">
        {list.map((f) => (
          <FileTile key={f.id} f={f} />
        ))}
      </div>
      <div ref={sentinel} />
      <LoadMore hasMore={!!q.hasNextPage} loading={q.isFetchingNextPage} onMore={() => q.fetchNextPage()} />
    </div>
  );
}
