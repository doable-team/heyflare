import { lazy, Suspense, type ComponentProps, type ComponentType } from "react";

type Module = { default: ComponentType<any> };

/** Run `fn` once the browser has a spare moment. Safari still has no requestIdleCallback. */
export function whenIdle(fn: () => void, timeout = 2000): void {
  if (typeof window.requestIdleCallback === "function") window.requestIdleCallback(fn, { timeout });
  else window.setTimeout(fn, 300);
}

/**
 * A route's page as its own chunk, with the Suspense boundary *inside* the page rather than around
 * the router — so while a chunk downloads the shell, sidebar and cursor stay exactly where they were
 * and only the content area waits. The loader is kept on the component so it can be fetched ahead
 * of time (see `warm`). Props are taken from the module's default export, so a page that takes
 * props keeps them typed at the call site.
 */
export function page<M extends Module>(load: () => Promise<M>): ComponentType<ComponentProps<M["default"]>> & { preload: () => Promise<M> } {
  const Lazy = lazy(load);
  function Page(props: ComponentProps<M["default"]>) {
    return (
      <Suspense fallback={<PageFallback />}>
        <Lazy {...props} />
      </Suspense>
    );
  }
  return Object.assign(Page, { preload: load });
}

/** Fetch these pages' chunks in idle time, so the first click on them is instant. */
export function warm(pages: { preload: () => Promise<unknown> }[]): void {
  whenIdle(() => {
    for (const p of pages) void p.preload().catch(() => {});
  });
}

/** Blank, but tall enough that the page doesn't collapse and re-expand around the chunk load. */
function PageFallback() {
  return <div className="min-h-[60vh]" aria-busy="true" />;
}
