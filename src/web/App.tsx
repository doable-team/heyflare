import { lazy, Suspense, useEffect } from "react";
import { Route, Routes } from "react-router-dom";
import { AccountProvider } from "./context/AccountContext";
import { ComposeProvider } from "./context/ComposeContext";
import { Toaster } from "@/components/ui/toaster-shim";
import { TooltipProvider } from "@/components/ui/tooltip";
import { useIsMobile } from "@/hooks/use-mobile";
import { whenIdle } from "./lib/lazy";
import Login from "./pages/Login";
import Setup from "./pages/Setup";

/**
 * The two apps are two chunks. A phone never downloads the desktop shell, sidebar, command palette
 * or a single desktop page, and a laptop never downloads the mobile ones. What is left in the entry
 * chunk is React, the router, the query client, the providers and the two sign-in pages — which is
 * everything a visitor who is not signed in will ever need.
 */
const loadDesktop = () => import("./DesktopApp");
const loadMobile = () => import("./MobileApp");
const DesktopApp = lazy(loadDesktop);
const MobileApp = lazy(loadMobile);

export default function App() {
  const mobile = useIsMobile();
  // Fetch the app chunk while the sign-in page is on screen, so signing in lands on a warm cache.
  useEffect(() => {
    whenIdle(() => void (mobile ? loadMobile() : loadDesktop()).catch(() => {}));
  }, [mobile]);
  const Tree = mobile ? MobileApp : DesktopApp;
  return (
    <TooltipProvider delayDuration={300}>
      <Toaster />
      <AccountProvider>
        <ComposeProvider>
          <Routes>
            <Route path="/login" element={<Login />} />
            <Route path="/setup" element={<Setup />} />
            {/* Painted in the theme's own background, so dark mode never flashes white while the chunk arrives. */}
            <Route path="/*" element={<Suspense fallback={<div className="min-h-dvh bg-background" />}><Tree /></Suspense>} />
          </Routes>
        </ComposeProvider>
      </AccountProvider>
    </TooltipProvider>
  );
}
