import { Mark } from "../components/Logo";
import type { ReactNode } from "react";
import { Navigate, useSearchParams } from "react-router-dom";
import { useMe } from "../api";
import { isNative } from "../lib/native";
import { cn } from "@/lib/utils";

/** Plain auth page: wordmark top-left, a 360px form centered, no card. */
export function AuthLayout({ title, subtitle, children }: { title: string; subtitle?: ReactNode; children: ReactNode }) {
  const me = useMe();
  const [sp] = useSearchParams();
  if (me.data?.user) return <Navigate to={sp.get("next") || "/"} replace />;
  return (
    <div className="min-h-screen bg-background flex flex-col">
      {/* In the Mac app the window has no title bar, so leave room for the traffic lights and let this strip drag the window. */}
      <div
        data-tauri-drag-region={isNative || undefined}
        className={cn("flex items-center px-5 gap-2 text-sm font-semibold", isNative ? "h-14 pt-6 pl-[86px]" : "h-12")}
      >
        <Mark />
        heyflare
      </div>
      <div className="flex-1 flex items-start sm:items-center justify-center px-5 pb-16">
        <div className="w-full max-w-[360px] pt-10 sm:pt-0">
          <h1 className="text-[22px] leading-7 font-semibold tracking-[-0.01em]">{title}</h1>
          {subtitle && <p className="text-sm text-muted-foreground mt-1.5">{subtitle}</p>}
          <div className="mt-7">{children}</div>
        </div>
      </div>
    </div>
  );
}
