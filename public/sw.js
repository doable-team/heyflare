// This worker caches nothing on purpose. installBuildWatcher in src/web/lib/update.ts polls
// /api/version and calls location.reload() when the server reports a new build. If this worker
// cached index.html or the JS bundle, that reload would serve the stale cached shell, the version
// would still look new, and the app would reload in a loop forever. The worker exists only to
// satisfy Chrome's installability requirement of a registered fetch handler; the empty fetch
// listener below never calls respondWith, so every request falls through to the network exactly as
// if no worker were installed.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});