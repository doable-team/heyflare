// Is a newer heyflare out? Compares what this server is running against the latest GitHub release.
// Both halves fail silently: an offline app or a rate-limited API simply means "no update to show".
import { useEffect, useState } from "react";
import { isMac } from "./native";

const RELEASES = "https://api.github.com/repos/doable-team/heyflare/releases/latest";
export const RELEASES_PAGE = "https://github.com/doable-team/heyflare/releases/latest";
const CACHE_KEY = "hey.update";
const DISMISS_KEY = "hey.update.dismissed";
const TTL = 6 * 60 * 60 * 1000; // 6h

export interface BuildInfo {
  version: string;
  commit: string;
  built_at: string;
}
interface Cached {
  at: number;
  tag: string;
  notes: string;
  url: string;
}
export interface UpdateInfo {
  current: string | null;
  latest: string | null;
  notes: string;
  url: string;
  updateAvailable: boolean;
  native: boolean;
}

/** `1.2.10` > `1.2.9`; anything unparsable sorts low so we never nag on garbage. */
function parse(v: string): number[] {
  return v
    .replace(/^v/i, "")
    .split("-")[0]
    .split(".")
    .map((p) => parseInt(p, 10) || 0);
}
export function isNewer(latest: string, current: string): boolean {
  const a = parse(latest);
  const b = parse(current);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x > y;
  }
  return false;
}

function readCache(): Cached | null {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (!raw) return null;
    const c = JSON.parse(raw) as Cached;
    return typeof c?.tag === "string" ? c : null;
  } catch {
    return null;
  }
}

/** Release notes as plain text: markdown headers, list bullets and links flattened. */
export function plainNotes(body: string, maxLines = 15): string {
  return body
    .replace(/\r/g, "")
    .split("\n")
    .map((l) =>
      l
        .replace(/^#{1,6}\s*/, "")
        .replace(/^\s*[-*]\s+/, "· ")
        .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
        .replace(/[*_`]/g, "")
        .trimEnd(),
    )
    .filter((l, i, arr) => l.trim() !== "" || (i > 0 && arr[i - 1].trim() !== ""))
    .slice(0, maxLines)
    .join("\n")
    .trim();
}

// Dismissal is shared: hiding the banner from the dialog must also hide the sidebar row.
const dismissListeners = new Set<() => void>();
function dismissed(): string | null {
  try {
    return localStorage.getItem(DISMISS_KEY);
  } catch {
    return null;
  }
}
export function dismissVersion(tag: string) {
  try {
    localStorage.setItem(DISMISS_KEY, tag);
  } catch {
    /* private mode */
  }
  dismissListeners.forEach((l) => l());
}

// One request each per page load, however many components ask.
let versionPromise: Promise<BuildInfo | null> | null = null;
let releasePromise: Promise<Cached | null> | null = null;

function fetchVersion(): Promise<BuildInfo | null> {
  versionPromise ??= fetch("/api/version", { credentials: "include" })
    .then((r) => (r.ok ? (r.json() as Promise<BuildInfo>) : null))
    .catch(() => null);
  return versionPromise;
}

function fetchRelease(): Promise<Cached | null> {
  const fresh = readCache();
  if (fresh && Date.now() - fresh.at < TTL) return Promise.resolve(fresh);
  releasePromise ??= fetch(RELEASES, { headers: { accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? (r.json() as Promise<{ tag_name?: string; body?: string; html_url?: string }>) : null))
    .then((rel) => {
      if (!rel?.tag_name) return null;
      const c: Cached = { at: Date.now(), tag: rel.tag_name.replace(/^v/i, ""), notes: rel.body ?? "", url: rel.html_url ?? RELEASES_PAGE };
      try {
        localStorage.setItem(CACHE_KEY, JSON.stringify(c));
      } catch {
        /* private mode */
      }
      return c;
    })
    .catch(() => null);
  return releasePromise;
}

export function useUpdateCheck(): UpdateInfo & { dismiss: () => void } {
  const [current, setCurrent] = useState<string | null>(null);
  const [cache, setCache] = useState<Cached | null>(() => readCache());
  const [hidden, setHidden] = useState<string | null>(() => dismissed());

  useEffect(() => {
    const l = () => setHidden(dismissed());
    dismissListeners.add(l);
    return () => void dismissListeners.delete(l);
  }, []);

  useEffect(() => {
    let alive = true;
    void fetchVersion().then((v) => {
      if (alive && v?.version) setCurrent(v.version);
    });
    void fetchRelease().then((c) => {
      if (alive && c) setCache(c);
    });
    return () => void (alive = false);
  }, []);

  const latest = cache?.tag ?? null;
  const updateAvailable = !!(current && latest && isNewer(latest, current) && hidden !== latest);
  return {
    current,
    latest,
    notes: cache?.notes ?? "",
    url: cache?.url ?? RELEASES_PAGE,
    updateAvailable,
    native: isMac,
    dismiss: () => {
      if (latest) dismissVersion(latest);
    },
  };
}

// ---------- Reload when the server ships a new build ----------

/** Is anything in flight that a reload would throw away? */
function busy(): boolean {
  const el = document.activeElement as HTMLElement | null;
  if (el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable)) return true;
  return !!document.querySelector('[role="dialog"],[role="alertdialog"],[data-slot="sheet-content"],[data-assistant-streaming="1"]');
}

/**
 * The app is served from the same Worker that reports its build. When a deploy lands, the running page is
 * stale: reload it the next time the window is focused and nothing would be lost. The Mac app benefits most,
 * since it stays open for days.
 */
export function installBuildWatcher() {
  let boot: string | null = null;
  let checking = false;
  let last = 0;

  const read = async (): Promise<string | null> => {
    try {
      const r = await fetch("/api/version", { credentials: "include", cache: "no-store" });
      if (!r.ok) return null;
      const j = (await r.json()) as BuildInfo;
      return `${j.version}@${j.commit}`;
    } catch {
      return null;
    }
  };

  const check = async () => {
    if (checking || document.visibilityState !== "visible") return;
    if (Date.now() - last < 60_000) return;
    last = Date.now();
    checking = true;
    try {
      const now = await read();
      if (!now) return;
      if (boot == null) {
        boot = now;
        return;
      }
      if (now !== boot && !busy()) location.reload();
    } finally {
      checking = false;
    }
  };

  void check();
  window.addEventListener("focus", check);
  document.addEventListener("visibilitychange", check);
  window.setInterval(check, 10 * 60_000);
}
