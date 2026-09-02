import type { ReactNode } from "react";
import { Screen } from "./Screen";

/** Hosts a desktop page inside the mobile frame: compact bar with Back, the page keeps its own header. */
export function MobilePageWrap({ title, children, back = true, tabs = true }: { title?: string; children: ReactNode; back?: boolean; tabs?: boolean }) {
  return (
    <Screen title={title ?? ""} back={back} tabs={tabs}>
      <div className="px-4 pt-2 min-w-0 overflow-x-hidden [&_h1]:text-[24px] [&_h1]:leading-7">{children}</div>
    </Screen>
  );
}
