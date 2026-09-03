// Bridge to the native macOS shell (Tauri). Every function is a no-op in the browser.
type Tauri = {
  core: { invoke: (cmd: string, args?: Record<string, unknown>) => Promise<unknown> };
  event: { listen: (name: string, cb: (e: { payload: unknown }) => void) => Promise<() => void> };
};
function tauri(): Tauri | undefined {
  return typeof window !== "undefined" ? ((window as unknown as { __TAURI__?: Tauri }).__TAURI__ ?? undefined) : undefined;
}
export const isNative: boolean = typeof window !== "undefined" && !!(window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;

async function invoke<T = unknown>(cmd: string, args?: Record<string, unknown>): Promise<T | undefined> {
  const t = tauri();
  if (!t) return undefined;
  try {
    return (await t.core.invoke(cmd, args)) as T;
  } catch (e) {
    console.warn(`[native] ${cmd} failed`, e);
    return undefined;
  }
}

export const native = {
  /** Dock badge (0 clears it). */
  setBadge: (count: number) => void invoke("set_badge", { count: Math.max(0, Math.floor(count)) }),
  /** System notification; `url` is an in-app path opened when the user comes back to the window. */
  notify: (title: string, body: string, url?: string) => void invoke("notify", { title, body, url: url ?? null }),
  /** Path queued by a notification, consumed once. */
  takePendingUrl: () => invoke<string | null>("take_pending_url"),
  /** Open a link in the default browser. */
  openExternal: (url: string) => void invoke("open_external", { url }),
  /** Is a newer build of the Mac app published? */
  checkUpdate: () => invoke<{ available: boolean; version?: string; notes?: string }>("check_update"),
  /**
   * Download, install and relaunch. `onProgress` gets 0..1 while downloading (or -1 when the
   * server sends no length). Resolves only if the install failed — on success the app restarts.
   */
  updateApp: async (onProgress?: (fraction: number) => void): Promise<string | null> => {
    const t = tauri();
    if (!t) return "This build can't update itself.";
    let off: (() => void) | undefined;
    if (onProgress) {
      off = await t.event
        .listen("update://progress", (e) => onProgress(Number((e.payload as { fraction?: number })?.fraction ?? -1)))
        .catch(() => undefined);
    }
    try {
      await t.core.invoke("install_update");
      return null; // the app restarts; nothing after this runs
    } catch (e) {
      return e instanceof Error ? e.message : String(e);
    } finally {
      off?.();
    }
  },
};

/** Subscribe to native menu actions (ids like `nav:/feed`, `compose`, `palette`, `toggle-sidebar`, `assistant`, `back`, `forward`). */
export function onMenu(handler: (id: string) => void): () => void {
  const t = tauri();
  if (!t) return () => {};
  let un: (() => void) | undefined;
  let cancelled = false;
  t.event.listen("menu", (e) => handler(String(e.payload))).then((u) => {
    if (cancelled) u();
    else un = u;
  });
  return () => {
    cancelled = true;
    un?.();
  };
}

/** Send external links to the system browser instead of navigating the app's webview. */
export function installExternalLinkHandler(): () => void {
  if (!isNative) return () => {};
  const onClick = (e: MouseEvent) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey) return;
    const a = (e.target as HTMLElement | null)?.closest?.("a[href]") as HTMLAnchorElement | null;
    if (!a) return;
    const href = a.getAttribute("href") ?? "";
    if (href.startsWith("mailto:")) return; // handled by the app
    let url: URL;
    try {
      url = new URL(href, location.href);
    } catch {
      return;
    }
    if (url.origin === location.origin && a.target !== "_blank") return;
    e.preventDefault();
    native.openExternal(url.toString());
  };
  document.addEventListener("click", onClick, true);
  return () => document.removeEventListener("click", onClick, true);
}
