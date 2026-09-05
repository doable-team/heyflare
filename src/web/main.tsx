import { installConnectInterceptor } from "./lib/connect";
import { installBuildWatcher } from "./lib/update";
import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import App from "./App";
import "./index.css";

const queryClient = new QueryClient({
  defaultOptions: {
    // No refetch-on-focus: `useSyncOnFocus` already syncs each account on focus and then invalidates
    // everything, so the automatic refetch only ever produced a second copy of every request.
    queries: { retry: 1, staleTime: 10_000, refetchOnWindowFocus: false },
  },
});

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      {/* Navigations become transitions: a route whose chunk is still downloading keeps the current
          page on screen instead of dropping to a Suspense fallback. */}
      <BrowserRouter future={{ v7_startTransition: true }}>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </React.StrictMode>,
);
installConnectInterceptor();
installBuildWatcher();
