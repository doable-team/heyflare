import { Mark } from "../components/Logo";
import type { ReactNode } from "react";
import { Navigate, useSearchParams } from "react-router-dom";
import { useMe } from "../api";
import { isMac } from "../lib/native";
import { cn } from "@/lib/utils";

/** Plain auth page: wordmark top-left, a 360px form centered, no card. */
export function AuthLayout({ title, subtitle, children }: { title: string; subtitle?: ReactNode; children: ReactNode }) {
  const me = useMe();
  const [sp] = useSearchParams();
  if (me.data?.user) return <Navigate to={sp.get("next") || "/"} replace />;
  return (
    <div className="min-h-screen bg-background flex flex-col">
      {/* In the Mac app the window has no title bar: this strip clears the traffic lights and drags the window.
          On iPhone the same strip just clears the status bar. */}
      <div data-tauri-drag-region={isMac || undefined} className={cn("shrink-0 pt-safe", isMac ? "min-h-12" : "min-h-6")} />
      <div className="flex-1 flex items-start sm:items-center justify-center px-5 pb-16">
        <div className="w-full max-w-[360px] pt-6 sm:pt-0">
          <div className="flex items-center gap-2 mb-6 text-sm font-semibold">
            <Mark size={22} />
            heyflare
          </div>
          <h1 className="text-[22px] leading-7 font-semibold tracking-[-0.01em]">{title}</h1>
          {subtitle && <p className="text-sm text-muted-foreground mt-1.5">{subtitle}</p>}
          <div className="mt-7">{children}</div>
        </div>
      </div>
    </div>
  );
}
