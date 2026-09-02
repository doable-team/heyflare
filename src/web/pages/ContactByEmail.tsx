import { useEffect, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import { api } from "../api";
import { ErrorState } from "../components/EmptyState";

/** /contacts/email/:email → resolves the contact row and forwards to its page. */
export default function ContactByEmail() {
  const { email = "" } = useParams();
  const [sp] = useSearchParams();
  const nav = useNavigate();
  const [err, setErr] = useState<unknown>(null);
  useEffect(() => {
    let alive = true;
    api
      .get<{ id: string }>(`/api/contacts/by-email?email=${encodeURIComponent(email)}${sp.get("account") ? `&account_id=${encodeURIComponent(sp.get("account")!)}` : ""}${sp.get("name") ? `&name=${encodeURIComponent(sp.get("name")!)}` : ""}`)
      .then((r) => alive && nav(`/contacts/${r.id}`, { replace: true }))
      .catch((e) => alive && setErr(e));
    return () => {
      alive = false;
    };
  }, [email]);
  if (err) return <ErrorState error={err} onRetry={() => location.reload()} />;
  return <div className="p-6 text-sm text-muted-foreground">Opening contact…</div>;
}
