import { useNavigate, useSearchParams } from "react-router-dom";
import { Composer } from "../components/Composer";
import { parseAddresses } from "../components/AddressInput";
import { useCardScroll } from "../lib/cardKeys";

export default function ComposePage() {
  useCardScroll();
  const nav = useNavigate();
  const [sp] = useSearchParams();
  return (
    <div className="max-w-2xl mx-auto">
      <header className="mb-4 px-2">
        <h1 className="text-[28px] leading-[34px] font-bold tracking-[-0.02em]">New message</h1>
      </header>
      <div className="rounded-lg ring-1 ring-border overflow-hidden">
        <Composer inline autoFocusBody={!!sp.get("to")} initial={{ to: parseAddresses(sp.get("to") ?? ""), subject: sp.get("subject") ?? "" }} onDone={() => nav(-1)} onCancel={() => nav(-1)} />
      </div>
    </div>
  );
}
