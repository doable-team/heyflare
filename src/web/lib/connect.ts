import { isNative, native, openExternalUrl } from "./native";

// Full-screen overlay shown while the browser takes over the OAuth flow.
const MARK = `<svg width="40" height="40" viewBox="0 0 64 64" aria-hidden><rect width="64" height="64" rx="16" fill="currentColor"/><path d="M21 15v34M21 37c0-9 18-9 18 0v12" fill="none" stroke="var(--background)" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/><circle cx="47" cy="17" r="4.5" fill="var(--background)"/></svg>`;
const ID = "hey-connect-overlay";

function removeOverlay() {
  document.getElementById(ID)?.remove();
}

export function showConnectOverlay(text = "Taking you to Google…") {
  if (document.getElementById(ID)) return;
  const el = document.createElement("div");
  el.id = ID;
  el.setAttribute("role", "status");
  el.className = "fixed inset-0 z-[1000] flex flex-col items-center justify-center gap-4 bg-background text-foreground";
  el.innerHTML = `${MARK}<div class="flex items-center gap-2 text-sm text-muted-foreground"><span class="inline-block size-3.5 rounded-full border-2 border-muted-foreground/40 border-t-foreground animate-spin"></span>${text}</div>`;
  document.body.appendChild(el);
}

/**
 * In the Mac app, Google's consent screen has to run in the real browser: Google blocks sign-in from
 * embedded web views, and the browser already holds the user's Google session. The app asks the
 * server for a one-time handoff link (it holds the heyflare session), opens it outside the webview,
 * and waits for the window to come back.
 */
function showWaitingOverlay(onDone: () => void) {
  removeOverlay();
  const el = document.createElement("div");
  el.id = ID;
  el.setAttribute("role", "status");
  el.className = "fixed inset-0 z-[1000] flex flex-col items-center justify-center gap-5 bg-background text-foreground px-6 text-center";
  el.innerHTML = `${MARK}
    <div class="max-w-xs space-y-1">
      <div class="text-sm font-medium">Waiting for your browser…</div>
      <div class="text-[13px] text-muted-foreground">Finish signing in there, then come back. Your account shows up on its own.</div>
    </div>
    <div class="flex items-center gap-2">
      <button type="button" data-done class="h-8 px-3 rounded-md bg-foreground text-background text-[13px] font-medium">Done</button>
      <button type="button" data-cancel class="h-8 px-3 rounded-md text-[13px] text-muted-foreground hover:text-foreground">Cancel</button>
    </div>`;
  el.querySelector<HTMLButtonElement>("[data-done]")?.addEventListener("click", () => {
    removeOverlay();
    onDone();
  });
  el.querySelector<HTMLButtonElement>("[data-cancel]")?.addEventListener("click", removeOverlay);
  document.body.appendChild(el);
}

/** Called when the connect flow may have added an account: refresh whatever is on screen. */
let refresh: () => void = () => location.reload();
export function setConnectRefresh(fn: () => void) {
  refresh = fn;
}

async function startNative(hint?: string, provider: "google" | "microsoft" = "google") {
  let url: string | undefined;
  try {
    const res = await fetch("/api/accounts/connect-link", {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ provider, ...(hint ? { login_hint: hint } : {}) }),
    });
    const data = (await res.json().catch(() => null)) as { url?: string; message?: string; error?: string } | null;
    if (!res.ok || !data?.url) throw new Error(data?.message || data?.error || "Couldn't start the Google flow.");
    url = data.url;
  } catch (e) {
    removeOverlay();
    alert(e instanceof Error ? e.message : "Couldn't start the Google flow.");
    return;
  }
  openExternalUrl(url);
  showWaitingOverlay(refresh);
  // The window regaining focus is the usual signal that Google is done.
  const onFocus = () => {
    refresh();
    window.removeEventListener("focus", onFocus);
  };
  window.addEventListener("focus", onFocus);
}

export function startGoogleConnect(hint?: string) {
  if (isNative) {
    showConnectOverlay("Opening your browser…");
    void startNative(hint);
    return;
  }
  showConnectOverlay();
  const url = hint ? `/auth/google/start?login_hint=${encodeURIComponent(hint)}` : "/auth/google/start";
  // Let the overlay paint before the navigation starts.
  requestAnimationFrame(() => setTimeout(() => (location.href = url), 30));
}

/**
 * Microsoft goes through the same system-browser handoff as Google in the native apps. It is less
 * strict about embedded web views than Google, but Conditional Access can still refuse one — and a
 * connect that fails only for some tenants is worse than always using the path that works.
 */
export function startMicrosoftConnect(hint?: string) {
  if (isNative) {
    showConnectOverlay("Opening your browser…");
    void startNative(hint, "microsoft");
    return;
  }
  showConnectOverlay("Taking you to Microsoft…");
  const url = hint ? `/auth/microsoft/start?login_hint=${encodeURIComponent(hint)}` : "/auth/microsoft/start";
  requestAnimationFrame(() => setTimeout(() => (location.href = url), 30));
}

/** Intercepts every <a href="/auth/google/start…"> so Connect/Reconnect links take the right path. */
export function installConnectInterceptor() {
  document.addEventListener("click", (e) => {
    const a = (e.target as HTMLElement | null)?.closest?.('a[href^="/auth/google/start"]') as HTMLAnchorElement | null;
    if (!a || e.defaultPrevented || e.metaKey || e.ctrlKey || e.button !== 0) return;
    e.preventDefault();
    const href = a.getAttribute("href") ?? "";
    const hint = new URLSearchParams(href.split("?")[1] ?? "").get("login_hint") ?? undefined;
    startGoogleConnect(hint);
  });
  // Remove the overlay if the page is restored from bfcache (user pressed Back on Google's page).
  window.addEventListener("pageshow", (e) => {
    if ((e as PageTransitionEvent).persisted) removeOverlay();
  });
}
