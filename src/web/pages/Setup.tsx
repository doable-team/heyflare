import { useState } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { api } from "../api";
import { useAccount } from "../context/AccountContext";
import { AuthLayout } from "./AuthLayout";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

// First-run only: creates the single owner of this heyflare instance.
export default function Setup() {
  const { setupRequired, loading, user } = useAccount();
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();
  const qc = useQueryClient();

  if (user) return <Navigate to="/" replace />;
  if (!loading && !setupRequired) return <Navigate to="/login" replace />;

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setErr("");
    try {
      await api.post("/auth/setup", { email, name, password });
      await qc.invalidateQueries({ queryKey: ["me"] });
      nav("/", { replace: true });
    } catch (ex) {
      setErr((ex as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <AuthLayout title="Set up your login" subtitle="This is a private, single-owner heyflare. You only do this once.">
      <form onSubmit={submit} className="space-y-4">
        <div className="grid gap-1.5">
          <Label htmlFor="name">Your name</Label>
          <Input id="name" placeholder="Farhan" value={name} onChange={(e) => setName(e.target.value)} autoFocus autoComplete="name" />
        </div>
        <div className="grid gap-1.5">
          <Label htmlFor="email">Email</Label>
          <Input id="email" type="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} required autoComplete="email" />
          <div className="text-xs text-muted-foreground">Used to log in. It doesn't have to be a Gmail address.</div>
        </div>
        <div className="grid gap-1.5">
          <Label htmlFor="password">Password</Label>
          <Input id="password" type="password" placeholder="At least 8 characters" value={password} onChange={(e) => setPassword(e.target.value)} required minLength={8} autoComplete="new-password" aria-invalid={!!err} />
          {err && <div className="text-xs text-foreground">{err}</div>}
        </div>
        <Button type="submit" className="w-full" disabled={busy}>
          {busy && <Loader2 className="animate-spin" />}
          Create my login
        </Button>
        <p className="text-xs text-muted-foreground">Next, you'll connect one or more Gmail accounts from the Imbox.</p>
      </form>
    </AuthLayout>
  );
}
