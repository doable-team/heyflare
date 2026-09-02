// Full-screen "Taking you to Google…" overlay shown while the browser navigates to the OAuth flow.
const MARK = `<svg width="40" height="40" viewBox="0 0 64 64" aria-hidden><rect width="64" height="64" rx="16" fill="currentColor"/><path d="M21 15v34M21 37c0-9 18-9 18 0v12" fill="none" stroke="var(--background)" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/><circle cx="47" cy="17" r="4.5" fill="var(--background)"/></svg>`;

export function showConnectOverlay(text = "Taking you to Google…") {
  if (document.getElementById("hey-connect-overlay")) return;
  const el = document.createElement("div");
  el.id = "hey-connect-overlay";
  el.setAttribute("role", "status");
  el.className = "fixed inset-0 z-[1000] flex flex-col items-center justify-center gap-4 bg-background text-foreground";
  el.innerHTML = `${MARK}<div class="flex items-center gap-2 text-sm text-muted-foreground"><span class="inline-block size-3.5 rounded-full border-2 border-muted-foreground/40 border-t-foreground animate-spin"></span>${text}</div>`;
  document.body.appendChild(el);
}

export function startGoogleConnect(hint?: string) {
  showConnectOverlay();
  const url = hint ? `/auth/google/start?login_hint=${encodeURIComponent(hint)}` : "/auth/google/start";
  // Let the overlay paint before the navigation starts.
  requestAnimationFrame(() => setTimeout(() => (location.href = url), 30));
}

/** Intercepts every <a href="/auth/google/start…"> so all Connect/Reconnect links get the overlay. */
export function installConnectInterceptor() {
  document.addEventListener("click", (e) => {
    const a = (e.target as HTMLElement | null)?.closest?.('a[href^="/auth/google/start"]') as HTMLAnchorElement | null;
    if (!a || e.defaultPrevented || e.metaKey || e.ctrlKey || e.button !== 0) return;
    e.preventDefault();
    showConnectOverlay();
    const href = a.getAttribute("href")!;
    requestAnimationFrame(() => setTimeout(() => (location.href = href), 30));
  });
  // Remove the overlay if the page is restored from bfcache (user pressed Back on Google's page).
  window.addEventListener("pageshow", (e) => {
    if ((e as PageTransitionEvent).persisted) document.getElementById("hey-connect-overlay")?.remove();
  });
}
