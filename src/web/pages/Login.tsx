import { useState } from "react";
import { Navigate, useNavigate, useSearchParams } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { api } from "../api";
import { useAccount } from "../context/AccountContext";
import { AuthLayout } from "./AuthLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export default function Login() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  // Second factor step
  const [ticket, setTicket] = useState<string | null>(null);
  const [code, setCode] = useState("");
  const [recoveryMode, setRecoveryMode] = useState(false);
  const nav = useNavigate();
  const qc = useQueryClient();
  const [sp] = useSearchParams();
  const { setupRequired, loading } = useAccount();
  if (!loading && setupRequired) return <Navigate to="/setup" replace />;

  const finish = async () => {
    await qc.invalidateQueries({ queryKey: ["me"] });
    nav(sp.get("next") || "/", { replace: true });
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setErr("");
    try {
      const r = await api.post<{ mfa_required?: boolean; ticket?: string }>("/auth/login", { email, password });
      if (r.mfa_required && r.ticket) {
        setTicket(r.ticket);
        setCode("");
        return;
      }
      await finish();
    } catch (ex) {
      setErr((ex as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const submitCode = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setErr("");
    try {
      await api.post("/auth/login/2fa", { ticket, code });
      await finish();
    } catch (ex) {
      const msg = (ex as Error).message;
      setErr(/ticket expired/i.test(msg) ? "That took too long. Log in again." : /too many/i.test(msg) ? "Too many attempts. Log in again." : "That code isn't right.");
      if (/expired|too many/i.test(msg)) {
        setTicket(null);
        setCode("");
      }
    } finally {
      setBusy(false);
    }
  };

  if (ticket) {
    return (
      <AuthLayout title="Two-factor code" subtitle={recoveryMode ? "Enter one of your recovery codes." : "Enter the 6-digit code from your authenticator app."}>
        <form onSubmit={submitCode} className="space-y-4">
          <div className="grid gap-1.5">
            <Label htmlFor="code">{recoveryMode ? "Recovery code" : "Code"}</Label>
            <Input
              id="code"
              inputMode={recoveryMode ? "text" : "numeric"}
              autoComplete="one-time-code"
              placeholder={recoveryMode ? "xxxx-xxxx" : "123456"}
              value={code}
              onChange={(e) => setCode(e.target.value)}
              required
              autoFocus
              aria-invalid={!!err}
              className={recoveryMode ? "font-mono" : "text-[18px] tracking-[0.3em] font-mono"}
            />
            {err && <div className="text-xs text-foreground">{err}</div>}
          </div>
          <Button type="submit" className="w-full" disabled={busy || !code.trim()}>
            {busy && <Loader2 className="animate-spin" />}
            Continue
          </Button>
          <div className="flex items-center justify-between text-xs text-muted-foreground">
            <button type="button" className="hover:text-foreground underline underline-offset-2" onClick={() => { setRecoveryMode((v) => !v); setCode(""); setErr(""); }}>
              {recoveryMode ? "Use authenticator code" : "Use a recovery code"}
            </button>
            <button type="button" className="hover:text-foreground" onClick={() => { setTicket(null); setCode(""); setErr(""); }}>
              ← Back
            </button>
          </div>
        </form>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout title="Log in" subtitle="Welcome back to your Imbox.">
      <form onSubmit={submit} className="space-y-4">
        <div className="grid gap-1.5">
          <Label htmlFor="email">Email</Label>
          <Input id="email" type="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} required autoFocus autoComplete="email" />
        </div>
        <div className="grid gap-1.5">
          <Label htmlFor="password">Password</Label>
          <Input id="password" type="password" placeholder="••••••••" value={password} onChange={(e) => setPassword(e.target.value)} required autoComplete="current-password" aria-invalid={!!err} />
          {err && <div className="text-xs text-foreground">{err}</div>}
        </div>
        <Button type="submit" className="w-full" disabled={busy}>
          {busy && <Loader2 className="animate-spin" />}
          Continue
        </Button>
      </form>
    </AuthLayout>
  );
}
