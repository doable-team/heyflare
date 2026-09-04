// Bridge to the native macOS shell (Tauri). Every function is a no-op in the browser.
type Tauri = {
  core: { invoke: (cmd: string, args?: Record<string, unknown>) => Promise<unknown> };
  event: { listen: (name: string, cb: (e: { payload: unknown }) => void) => Promise<() => void> };
};
type Internals = {
  invoke: (cmd: string, payload?: Record<string, unknown>, options?: unknown) => Promise<unknown>;
  transformCallback?: (cb: (v: unknown) => void, once?: boolean) => number;
};
function internals(): Internals | undefined {
  return typeof window !== "undefined" ? ((window as unknown as { __TAURI_INTERNALS__?: Internals }).__TAURI_INTERNALS__ ?? undefined) : undefined;
}
/**
 * The bundled JS API (`window.__TAURI__`) is not always injected into a *remote* page, while the
 * low-level bridge (`__TAURI_INTERNALS__`) always is. Prefer the API, fall back to the bridge —
 * without this, every native call silently did nothing in the app.
 */
function tauri(): Tauri | undefined {
  const api = typeof window !== "undefined" ? (window as unknown as { __TAURI__?: Tauri }).__TAURI__ : undefined;
  if (api?.core?.invoke) return api;
  const i = internals();
  if (!i?.invoke) return undefined;
  return {
    core: { invoke: (cmd, args) => i.invoke(cmd, args ?? {}) },
    event: {
      listen: async (name, cb) => {
        if (!i.transformCallback) return () => {};
        const handler = i.transformCallback((payload) => cb({ payload }));
        const id = (await i.invoke("plugin:event|listen", { event: name, target: { kind: "Any" }, handler })) as number;
        return () => void i.invoke("plugin:event|unlisten", { event: name, eventId: id });
      },
    },
  };
}
export const isNative: boolean = typeof window !== "undefined" && !!(window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__;

/**
 * Which native shell is running, if any. The two builds share this web app but not their chrome:
 * only the Mac app has traffic lights to clear, a menu bar, a dock badge and a self-updater.
 * WKWebView reports the real device in its user agent, and an iPad in desktop mode claims to be a
 * Mac — the touch-point count is what separates them.
 */
function detectPlatform(): "macos" | "ios" | null {
  if (!isNative) return null;
  const ua = typeof navigator !== "undefined" ? navigator.userAgent : "";
  if (/iPhone|iPad|iPod/.test(ua)) return "ios";
  if (/Macintosh/.test(ua) && typeof navigator !== "undefined" && navigator.maxTouchPoints > 1) return "ios";
  return "macos";
}
export const nativePlatform: "macos" | "ios" | null = detectPlatform();
/** The Mac app specifically: window chrome, menu bar, dock badge, one-click updates. */
export const isMac: boolean = nativePlatform === "macos";

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

/**
 * Send a URL to the default browser.
 *
 * In the native apps we deliberately *navigate* rather than call the `open_external` command: the JS
 * bridge is not reliably injected into the remote page, and a silent no-op is worse than useless.
 * Both shells carry a navigation guard that catches anything leaving the server, opens it in the
 * system browser and blocks the navigation, so the window never actually moves.
 */
export function openExternalUrl(url: string) {
  if (isNative) {
    try {
      window.location.assign(url);
      return;
    } catch {
      /* fall through */
    }
  }
  window.open(url, "_blank", "noopener,noreferrer");
}

export const native = {
  /** Dock badge (0 clears it). Mac only — the iPhone build has no such command. */
  setBadge: (count: number) => {
    if (isMac) void invoke("set_badge", { count: Math.max(0, Math.floor(count)) });
  },
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
    openExternalUrl(url.toString());
  };
  document.addEventListener("click", onClick, true);
  return () => document.removeEventListener("click", onClick, true);
}
