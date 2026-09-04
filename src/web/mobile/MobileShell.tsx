import { Navigate, Outlet, useLocation } from "react-router-dom";
import { Layers, Plus, Settings } from "lucide-react";
import { Mark } from "../components/Logo";
import { ALL, useAccount } from "../context/AccountContext";
import { startGoogleConnect, startMicrosoftConnect } from "../lib/connect";
import { ActionSheet } from "./ActionSheet";
import { useNavigate } from "react-router-dom";

/** Mobile layout: only the auth guard; each screen draws its own bars. */
export function MobileShell() {
  const { user, loading, error } = useAccount();
  const loc = useLocation();
  if (loading) {
    return (
      <div className="min-h-dvh flex items-center justify-center gap-2 text-sm text-muted-foreground">
        <Mark /> heyflare
      </div>
    );
  }
  if (error || !user) return <Navigate to={`/login?next=${encodeURIComponent(loc.pathname + loc.search)}`} replace />;
  return <Outlet />;
}

/** Account scope picker as a bottom sheet (tap the Imbox title). */
export function ScopeSheet({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const { accounts, scope, setScope, glyphFor, googleConfigured, microsoftConfigured } = useAccount();
  const nav = useNavigate();
  return (
    <ActionSheet
      open={open}
      onOpenChange={onOpenChange}
      title="Inbox scope"
      actions={[
        { icon: <Layers />, label: "All accounts", hint: accounts.length > 1 ? accounts.length : undefined, checked: scope === ALL, onSelect: () => { setScope(ALL); nav("/"); } },
        ...accounts.map((a) => ({ icon: <span className="text-[13px] w-5 text-center">{glyphFor(a.id)}</span>, label: a.email, checked: scope === a.id, onSelect: () => { setScope(a.id); nav("/"); } })),
...(googleConfigured ? [{ icon: <Plus />, label: "Connect Gmail", onSelect: () => startGoogleConnect() }] : []),
        ...(microsoftConfigured ? [{ icon: <Plus />, label: "Connect Outlook", onSelect: () => startMicrosoftConnect() }] : []),
        { icon: <Settings />, label: "Manage accounts", onSelect: () => nav("/settings#accounts") },
      ]}
    />
  );
}

export function useScopeLabel(): string {
  const { accounts, scope, account } = useAccount();
  if (accounts.length === 0) return "";
  if (scope === ALL) return accounts.length > 1 ? "All accounts" : accounts[0].email;
  return account?.email ?? "All accounts";
}
