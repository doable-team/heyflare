import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { Account, User } from "@shared/types";
import { getAccountId, storeAccountId, useMe } from "../api";
import { api } from "../api";
import { setConnectRefresh } from "../lib/connect";

export const ALL = "all" as const;
export type Scope = typeof ALL | string;

/** Monochrome marks used to tell accounts apart in the unified inbox. */
export const GLYPHS = ["●", "■", "▲", "◆", "✦", "◐", "▼", "○"] as const;

interface Ctx {
  user: User | null;
  accounts: Account[];
  /** Selected scope: "all" (unified, default) or an account id. */
  scope: Scope;
  /** The scoped account, or null in unified scope. */
  account: Account | null;
  /** True when more than one account is connected (show glyphs). */
  multi: boolean;
  setupRequired: boolean;
  loading: boolean;
  error: Error | null;
  setScope: (scope: Scope) => void;
  /** @deprecated use setScope */
  setAccountId: (id: string) => void;
  glyphFor: (accountId: string | undefined | null) => string;
  accountFor: (accountId: string | undefined | null) => Account | undefined;
  /** Default account for creating things (compose From, new labels…). */
  defaultAccount: Account | null;
  refetch: () => void;
}

const AccountCtx = createContext<Ctx>({
  user: null,
  accounts: [],
  scope: ALL,
  account: null,
  multi: false,
  setupRequired: false,
  loading: true,
  error: null,
  setScope: () => {},
  setAccountId: () => {},
  glyphFor: () => "",
  accountFor: () => undefined,
  defaultAccount: null,
  refetch: () => {},
});

function applyTheme(theme: "light" | "dark" | "system") {
  const root = document.documentElement;
  const dark = theme === "dark" || (theme === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  root.classList.toggle("dark", dark);
  root.setAttribute("data-theme", theme);
}


/** Kick a sync when the app is opened or regains focus (throttled), so mail feels live without any push setup. */
function useSyncOnFocus(accounts: Account[], qc: ReturnType<typeof useQueryClient>) {
  const last = useRef(0);
  useEffect(() => {
    const gmail = accounts.filter((a) => (a.provider === "gmail" || a.provider === "outlook") && a.sync_status !== "disconnected");
    if (gmail.length === 0) return;
    const run = () => {
      if (document.visibilityState !== "visible") return;
      const t = Date.now();
      if (t - last.current < 45_000) return;
      last.current = t;
      Promise.allSettled(gmail.map((a) => api.post(`/api/accounts/${a.id}/sync`))).then(() => {
        qc.invalidateQueries({ predicate: (q) => q.queryKey[0] !== "me" });
      });
    };
    run();
    window.addEventListener("focus", run);
    document.addEventListener("visibilitychange", run);
    return () => {
      window.removeEventListener("focus", run);
      document.removeEventListener("visibilitychange", run);
    };
  }, [accounts.map((a) => a.id + a.sync_status).join(","), qc]);
}

export function AccountProvider({ children }: { children: ReactNode }) {
  const me = useMe();
  const qc = useQueryClient();
  const [scope, setScopeState] = useState<Scope>(() => getAccountId() ?? ALL);

  const accounts = useMemo(() => me.data?.accounts ?? [], [me.data?.accounts]);
  useSyncOnFocus(accounts, qc);
  // The Google connect flow (which runs in the system browser on the Mac app) refreshes through this
  // rather than reloading the whole page.
  useEffect(() => {
    setConnectRefresh(() => {
      void me.refetch();
      qc.invalidateQueries({ predicate: (q) => q.queryKey[0] !== "me" });
    });
  }, [me, qc]);
  const account = useMemo(() => (scope === ALL ? null : accounts.find((a) => a.id === scope) ?? null), [accounts, scope]);

  // A stored account id that no longer exists → fall back to unified.
  useEffect(() => {
    if (scope !== ALL && me.data && !accounts.some((a) => a.id === scope)) {
      setScopeState(ALL);
      storeAccountId(null);
    }
  }, [scope, accounts, me.data]);

  // Theme → .dark class (system follows the OS and reacts to changes).
  const theme = me.data?.user?.settings?.theme ?? "system";
  useEffect(() => {
    applyTheme(theme);
    if (theme !== "system") return;
    const mql = window.matchMedia("(prefers-color-scheme: dark)");
    const fn = () => applyTheme("system");
    mql.addEventListener("change", fn);
    return () => mql.removeEventListener("change", fn);
  }, [theme]);

  const setScope = useCallback(
    (s: Scope) => {
      storeAccountId(s === ALL ? null : s);
      setScopeState(s);
      // scope-dependent data must be reloaded
      qc.removeQueries({ predicate: (q) => q.queryKey[0] !== "me" });
    },
    [qc],
  );

  const glyphFor = useCallback(
    (id: string | undefined | null) => {
      if (!id) return "";
      const i = accounts.findIndex((a) => a.id === id);
      return i < 0 ? "" : GLYPHS[i % GLYPHS.length];
    },
    [accounts],
  );
  const accountFor = useCallback((id: string | undefined | null) => (id ? accounts.find((a) => a.id === id) : undefined), [accounts]);

  const value: Ctx = {
    user: me.data?.user ?? null,
    accounts,
    scope,
    account,
    multi: accounts.length > 1,
    setupRequired: me.data?.setup_required ?? false,
    loading: me.isLoading,
    error: (me.error as Error) ?? null,
    setScope,
    setAccountId: setScope,
    glyphFor,
    accountFor,
    defaultAccount: account ?? accounts[0] ?? null,
    refetch: () => me.refetch(),
  };
  return <AccountCtx.Provider value={value}>{children}</AccountCtx.Provider>;
}

export function useAccount() {
  return useContext(AccountCtx);
}
