import { useInfiniteQuery, useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";
import type * as T from "@shared/types";
import { markDraftSent } from "./lib/sentDrafts";

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function getAccountId(): string | null {
  try {
    return localStorage.getItem("hey.accountId");
  } catch {
    return null;
  }
}
/** Current scope: a specific account id, or "all" for the unified inbox (default). */
export function getScope(): string {
  return getAccountId() ?? "all";
}
export function storeAccountId(id: string | null) {
  try {
    if (id) localStorage.setItem("hey.accountId", id);
    else localStorage.removeItem("hey.accountId");
  } catch {
    /* ignore */
  }
}

async function request<R>(method: string, path: string, body?: unknown): Promise<R> {
  const headers: Record<string, string> = {};
  if (body !== undefined) headers["Content-Type"] = "application/json";
  headers["X-Account-Id"] = getScope();
  const res = await fetch(path, {
    method,
    headers,
    credentials: "include",
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 401) {
    const p = location.pathname;
    if (!p.startsWith("/login") && !p.startsWith("/register")) {
      location.href = "/login?next=" + encodeURIComponent(p + location.search);
    }
    throw new ApiError(401, "Please log in");
  }
  const text = await res.text();
  let data: unknown = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { error: text };
  }
  if (!res.ok) {
    const msg = (data as T.ApiError | null)?.error || res.statusText || "Request failed";
    throw new ApiError(res.status, humanize(msg));
  }
  return data as R;
}

function humanize(code: string): string {
  const map: Record<string, string> = {
    no_account: "Connect a Gmail account first.",
    account_disabled: "This account has been disabled.",
    invalid_credentials: "Wrong email or password.",
    setup_done: "Setup has already been completed. Just log in.",
    unauthorized: "Please log in.",
    forbidden: "You don't have permission to do that.",
    not_found: "Not found.",
  };
  return map[code] || code.replace(/_/g, " ");
}

export const api = {
  get: <R>(path: string) => request<R>("GET", path),
  post: <R>(path: string, body?: unknown) => request<R>("POST", path, body ?? {}),
  patch: <R>(path: string, body?: unknown) => request<R>("PATCH", path, body ?? {}),
  del: <R>(path: string) => request<R>("DELETE", path),
};

export function qs(params: Record<string, string | number | undefined | null>): string {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== "") p.set(k, String(v));
  const s = p.toString();
  return s ? `?${s}` : "";
}

// ---------- Query keys ----------
export const keys = {
  me: ["me"] as const,
  counts: ["counts"] as const,
  imbox: ["imbox"] as const,
  threads: (bucket: string, q?: string, label?: string) => ["threads", bucket, q ?? "", label ?? ""] as const,
  feed: ["feed"] as const,
  thread: (id: string) => ["thread", id] as const,
  screener: ["screener"] as const,
  screenedOut: ["screened-out"] as const,
  contacts: (q: string) => ["contacts", q] as const,
  contact: (id: string) => ["contact", id] as const,
  labels: ["labels"] as const,
  collections: ["collections"] as const,
  collection: (id: string) => ["collection", id] as const,
  clips: ["clips"] as const,
  files: ["files"] as const,
  drafts: ["drafts"] as const,
  search: (q: string) => ["search", q] as const,
  // Calendar. Every calendar key starts with "cal" so invalidateCalendar can sweep them in one call.
  calRange: (from: string, to: string) => ["cal", "range", from, to] as const,
  calSources: ["cal", "sources"] as const,
  habits: ["cal", "habits"] as const,
  journal: ["cal", "journal"] as const,
  journalDay: (d: string) => ["cal", "journal", d] as const,
  calDay: (d: string) => ["cal", "day", d] as const,
  dayCovers: ["cal", "covers"] as const,
  flexTasks: (w: string) => ["cal", "flex", w] as const,
  timeEntries: ["cal", "time"] as const,
  calSettings: ["cal", "settings"] as const,
};

export function invalidateMail(qc: QueryClient) {
  for (const k of [["imbox"], ["threads"], ["feed"], ["thread"], ["counts"], ["screener"], ["screened-out"], ["search"], ["collection"], ["contact"], ["clips"]]) {
    qc.invalidateQueries({ queryKey: k });
  }
}

/** Invalidate every calendar cache: ranges, sources, habits, days, journal, flex tasks, time, settings. */
export function invalidateCalendar(qc: QueryClient) {
  qc.invalidateQueries({ queryKey: ["cal"] });
}

/** Optimistically drop threads from list caches (imbox + paged lists). */
export function removeThreadsFromLists(qc: QueryClient, ids: string[]) {
  const set = new Set(ids);
  qc.setQueriesData<T.ImboxResponse>({ queryKey: keys.imbox }, (old) => {
    if (!old) return old;
    const f = (arr: T.ThreadSummary[]) => arr.filter((t) => !set.has(t.id));
    return { ...old, new_threads: f(old.new_threads), seen_threads: f(old.seen_threads), reply_later: f(old.reply_later), set_aside: f(old.set_aside) };
  });
  type Paged = { pages: { threads: T.ThreadSummary[]; next_page: number | null }[]; pageParams: unknown[] };
  for (const key of [["threads"], ["feed"], ["search"]]) {
    qc.setQueriesData<Paged>({ queryKey: key }, (old) => {
      if (!old) return old;
      return { ...old, pages: old.pages.map((p) => ({ ...p, threads: p.threads.filter((t) => !set.has(t.id)) })) };
    });
  }
}

// ---------- Auth / me ----------
export interface MeResponse {
  user: T.User | null;
  google_configured?: boolean;
  microsoft_configured?: boolean;
  accounts: T.Account[];
  setup_required: boolean;
}
export function useMe(enabled = true) {
  return useQuery({ queryKey: keys.me, queryFn: () => api.get<MeResponse>("/api/me"), retry: false, enabled, staleTime: 30_000 });
}

// ---------- Mail ----------
export function useCounts(enabled = true) {
  return useQuery({ queryKey: keys.counts, queryFn: () => api.get<T.Counts>("/api/counts"), refetchInterval: 30_000, enabled });
}
export function useImbox(enabled = true) {
  return useQuery({ queryKey: keys.imbox, queryFn: () => api.get<T.ImboxResponse>("/api/imbox"), refetchInterval: 60_000, enabled });
}

export interface ThreadsPage {
  threads: T.ThreadSummary[];
  bundles?: T.Bundle[];
  next_page: number | null;
}
export function useThreads(bucket: string, opts: { q?: string; label?: string; enabled?: boolean } = {}) {
  return useInfiniteQuery({
    queryKey: keys.threads(bucket, opts.q, opts.label),
    queryFn: ({ pageParam }) => api.get<ThreadsPage>(`/api/threads${qs({ bucket, q: opts.q, label: opts.label, page: pageParam })}`),
    initialPageParam: 0,
    getNextPageParam: (last) => last.next_page ?? undefined,
    refetchInterval: 60_000,
    enabled: opts.enabled ?? true,
  });
}
export type FeedThread = T.ThreadSummary & { latest_message: T.Message };
export interface FeedPage {
  threads: FeedThread[];
  next_page: number | null;
}
export function useFeed(enabled = true, show: "new" | "all" = "new") {
  return useInfiniteQuery({
    queryKey: [...keys.feed, show],
    queryFn: ({ pageParam }) => api.get<FeedPage>(`/api/feed${qs({ page: pageParam, show })}`),
    initialPageParam: 0,
    getNextPageParam: (last) => last.next_page ?? undefined,
    refetchInterval: 60_000,
    enabled,
  });
}
export function useSearch(q: string) {
  return useInfiniteQuery({
    queryKey: keys.search(q),
    queryFn: ({ pageParam }) => api.get<ThreadsPage>(`/api/search${qs({ q, page: pageParam })}`),
    initialPageParam: 0,
    getNextPageParam: (last) => last.next_page ?? undefined,
    enabled: q.trim().length > 0,
  });
}
export function useThread(id: string | undefined, peek = false) {
  return useQuery({
    queryKey: keys.thread(id ?? ""),
    queryFn: () => api.get<T.ThreadDetail>(`/api/threads/${id}${peek ? "?peek=1" : ""}`),
    enabled: !!id,
  });
}

export type ThreadAction =
  | { action: "mark_unread" | "mark_read" | "seen" | "delete" }
  | { action: "reply_later"; on: boolean }
  | { action: "set_aside"; on: boolean }
  | { action: "bubble_up"; at: number | null }
  | { action: "move"; bucket: T.Bucket }
  | { action: "rename"; subject: string | null }
  | { action: "note"; note: string }
  | { action: "merge"; thread_ids: string[] }
  | { action: "labels"; add?: string[]; remove?: string[] }
  | { action: "collections"; add?: string[]; remove?: string[] }
  | { action: "bundle"; on: boolean };

export function useThreadAction(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (a: ThreadAction) => api.post<T.ThreadDetail>(`/api/threads/${id}/actions`, a),
    onSuccess: (data) => {
      qc.setQueryData(keys.thread(id), data);
      invalidateMail(qc);
    },
  });
}

export function useBulkAction() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ thread_ids, ...a }: ThreadAction & { thread_ids: string[] }) => api.post<{ ok: boolean }>("/api/threads/bulk", { thread_ids, ...a }),
    onMutate: ({ thread_ids, ...a }) => {
      // Optimistic: actions that remove the thread from the current list
      const removing = ["reply_later", "set_aside", "bubble_up", "move", "delete"].includes(a.action) && !("on" in a && a.on === false) && !("at" in a && a.at === null);
      if (removing) removeThreadsFromLists(qc, thread_ids);
    },
    onSettled: () => invalidateMail(qc),
  });
}

// ---------- Screener ----------
export interface ScreenerSender {
  account_id: string;
  contact: T.Contact;
  threads: T.ThreadSummary[];
  suggestion: "imbox" | "feed" | "paper_trail";
}
export function useScreener(enabled = true) {
  return useQuery({ queryKey: keys.screener, queryFn: () => api.get<{ senders: ScreenerSender[] }>("/api/screener"), refetchInterval: 60_000, enabled });
}
export function useScreenerDecide() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (p: { contact_id: string; decision: T.ScreenStatus; scope?: T.DecisionScope }) => api.post<{ ok: boolean }>("/api/screener/decide", p),
    onMutate: ({ contact_id }) => {
      qc.setQueryData<{ senders: ScreenerSender[] }>(keys.screener, (old) => (old ? { senders: old.senders.filter((s) => s.contact.id !== contact_id) } : old));
    },
    onSettled: () => {
      invalidateMail(qc);
      qc.invalidateQueries({ queryKey: ["contacts"] });
    },
  });
}
export function useScreenedOut() {
  return useQuery({ queryKey: keys.screenedOut, queryFn: () => api.get<{ contacts: T.Contact[] }>("/api/screener/screened-out") });
}

// ---------- Contacts ----------
export function useContacts(q: string, enabled = true) {
  return useQuery({ queryKey: keys.contacts(q), queryFn: () => api.get<T.MergedContact[]>(`/api/contacts${qs({ q })}`), enabled, staleTime: 30_000 });
}
export interface Suggestion { email: string; name: string; avatar_url: string }
export function useSuggest(q: string, enabled = true) {
  return useQuery({ queryKey: ["suggest", q], queryFn: () => api.get<Suggestion[]>(`/api/contacts/suggest${qs({ q })}`), enabled, staleTime: 60_000 });
}
export function useContact(id: string | undefined, bucket?: string) {
  return useQuery({
    queryKey: [...keys.contact(id ?? ""), bucket ?? ""],
    queryFn: () => api.get<{ contact: T.MergedContact; threads: T.ThreadSummary[] }>(`/api/contacts/${id}${qs({ bucket })}`),
    enabled: !!id,
  });
}
export function useUpdateContact() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: { id: string; name?: string; notes?: string; screen_status?: T.ScreenStatus; bundled?: boolean; scope?: T.DecisionScope }) => api.patch<T.MergedContact>(`/api/contacts/${id}`, body),
    onSuccess: (_d, v) => {
      qc.invalidateQueries({ queryKey: ["contacts"] });
      qc.invalidateQueries({ queryKey: keys.contact(v.id) });
      invalidateMail(qc);
    },
  });
}

// ---------- Labels ----------
export function useLabels(enabled = true) {
  return useQuery({ queryKey: keys.labels, queryFn: () => api.get<T.Label[]>("/api/labels"), enabled, staleTime: 60_000 });
}
export function useLabelMutations() {
  const qc = useQueryClient();
  const inv = () => {
    qc.invalidateQueries({ queryKey: keys.labels });
    invalidateMail(qc);
  };
  return {
    create: useMutation({ mutationFn: (b: { name: string; color: string; account_id?: string }) => api.post<T.Label>("/api/labels", b), onSuccess: inv }),
    update: useMutation({ mutationFn: ({ id, ...b }: { id: string; name?: string; color?: string }) => api.patch<T.Label>(`/api/labels/${id}`, b), onSuccess: inv }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/labels/${id}`), onSuccess: inv }),
  };
}
export function useLabelThreads(id: string | undefined) {
  return useQuery({ queryKey: ["threads", "label", id], queryFn: () => api.get<{ threads: T.ThreadSummary[] }>(`/api/labels/${id}/threads`), enabled: !!id, refetchInterval: 60_000 });
}

// ---------- Collections ----------
export function useCollections(enabled = true) {
  return useQuery({ queryKey: keys.collections, queryFn: () => api.get<T.Collection[]>("/api/collections"), enabled });
}
export function useCollection(id: string | undefined) {
  return useQuery({
    queryKey: keys.collection(id ?? ""),
    queryFn: () => api.get<{ collection: T.Collection; threads: T.ThreadSummary[]; files: T.Attachment[] }>(`/api/collections/${id}`),
    enabled: !!id,
  });
}
export function useCollectionMutations() {
  const qc = useQueryClient();
  const inv = () => {
    qc.invalidateQueries({ queryKey: keys.collections });
    qc.invalidateQueries({ queryKey: ["collection"] });
    qc.invalidateQueries({ queryKey: ["thread"] });
  };
  return {
    create: useMutation({ mutationFn: (b: { name: string; description?: string; account_id?: string }) => api.post<T.Collection>("/api/collections", b), onSuccess: inv }),
    update: useMutation({ mutationFn: ({ id, ...b }: { id: string; name?: string; description?: string }) => api.patch<T.Collection>(`/api/collections/${id}`, b), onSuccess: inv }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/collections/${id}`), onSuccess: inv }),
  };
}

// ---------- Clips ----------
export function useClips() {
  return useQuery({ queryKey: keys.clips, queryFn: () => api.get<T.Clip[]>("/api/clips") });
}
export function useClipMutations() {
  const qc = useQueryClient();
  const inv = () => {
    qc.invalidateQueries({ queryKey: keys.clips });
    qc.invalidateQueries({ queryKey: ["thread"] });
  };
  return {
    create: useMutation({ mutationFn: (b: { thread_id: string; message_id?: string; text: string; account_id?: string }) => api.post<T.Clip>("/api/clips", b), onSuccess: inv }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/clips/${id}`), onSuccess: inv }),
  };
}

// ---------- Files ----------
export interface FilesPage {
  files: T.Attachment[];
  next_page: number | null;
}
export function useFiles() {
  return useInfiniteQuery({
    queryKey: keys.files,
    queryFn: ({ pageParam }) => api.get<FilesPage>(`/api/files${qs({ page: pageParam })}`),
    initialPageParam: 0,
    getNextPageParam: (last) => last.next_page ?? undefined,
  });
}
export function attachmentUrl(messageId: string, attId: string, download = false) {
  const acc = getAccountId();
  return `/api/messages/${messageId}/attachments/${attId}${qs({ download: download ? 1 : undefined, account: acc && acc !== "all" ? acc : undefined })}`;
}

// ---------- Drafts / send ----------
export function useDrafts() {
  return useQuery({ queryKey: keys.drafts, queryFn: () => api.get<T.Draft[]>("/api/drafts") });
}
export interface DraftBody {
  /** From account (unified inbox). Defaults server-side to the thread's account, else the first account. */
  account_id?: string;
  thread_id?: string | null;
  reply_to_message_id?: string | null;
  to: T.Address[];
  cc: T.Address[];
  bcc: T.Address[];
  subject: string;
  body_html: string;
  send_at?: number | null;
}
export function useDraftMutations() {
  const qc = useQueryClient();
  const inv = () => qc.invalidateQueries({ queryKey: keys.drafts });
  return {
    create: useMutation({ mutationFn: (b: DraftBody) => api.post<T.Draft>("/api/drafts", b), onSuccess: inv }),
    update: useMutation({ mutationFn: ({ id, ...b }: Partial<DraftBody> & { id: string }) => api.patch<T.Draft>(`/api/drafts/${id}`, b), onSuccess: inv }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/drafts/${id}`), onSuccess: inv }),
    cancelScheduled: useMutation({ mutationFn: (draft_id: string) => api.post<{ ok: boolean }>("/api/send/cancel", { draft_id }), onSuccess: inv }),
  };
}
export interface SendPayload extends DraftBody {
  draft_id?: string;
  attachments?: { filename: string; mime_type: string; data_base64: string }[];
}
export interface SendResult {
  ok: boolean;
  account_id?: string;
  thread_id?: string;
  message_id?: string;
  scheduled?: boolean;
  draft_id?: string;
}
export async function sendMail(payload: SendPayload): Promise<SendResult> {
  const res = await api.post<SendResult>("/api/send", payload);
  markDraftSent(payload.draft_id, res.thread_id);
  return res;
}

// ---------- Accounts / settings ----------
export function useAccountMutations() {
  const qc = useQueryClient();
  const inv = () => qc.invalidateQueries({ queryKey: keys.me });
  return {
    update: useMutation({ mutationFn: ({ id, ...b }: { id: string; signature?: string; cover_art?: string; display_name?: string }) => api.patch<T.Account>(`/api/accounts/${id}`, b), onSuccess: inv }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/accounts/${id}`), onSuccess: () => { inv(); invalidateMail(qc); } }),
    sync: useMutation({ mutationFn: (id: string) => api.post<{ ok: boolean; added?: number }>(`/api/accounts/${id}/sync`), onSuccess: () => { inv(); invalidateMail(qc); } }),
    reset: useMutation({ mutationFn: (id: string) => api.post<{ ok: boolean; account: T.Account; sync_error: string | null }>(`/api/accounts/${id}/reset`), onSuccess: () => { inv(); invalidateMail(qc); } }),
    syncPhotos: useMutation({ mutationFn: (id: string) => api.post<{ ok: boolean; updated: number }>(`/api/accounts/${id}/sync-photos`), onSuccess: () => { inv(); invalidateMail(qc); } }),
  };
}
export function useMeMutations() {
  const qc = useQueryClient();
  const inv = () => qc.invalidateQueries({ queryKey: keys.me });
  return {
    update: useMutation({ mutationFn: (b: { name?: string; settings?: T.UserSettings }) => api.patch<{ user: T.User }>("/api/me", b), onSuccess: inv }),
    password: useMutation({ mutationFn: (b: { current: string; next: string }) => api.post<{ ok: boolean }>("/api/me/password", b) }),
  };
}

// ---------- Sync log (owner) ----------
export interface SyncLogRow {
  id: number;
  account_id: string | null;
  level: string;
  message: string;
  created_at: number;
}
export function useAccountLogs(accountId?: string) {
  return useQuery({ queryKey: ["logs", accountId ?? ""], queryFn: () => api.get<SyncLogRow[]>(`/api/accounts/${accountId}/logs`), enabled: !!accountId });
}

// ---------- Domains (custom domain mailboxes) ----------
export const DOMAIN_ERRORS: Record<string, string> = {
  invalid_domain: "That doesn't look like a domain name.",
  domain_exists: "That domain is already added.",
  mailbox_exists: "That mailbox already exists.",
  invalid_local_part: "Use letters, numbers, dots, dashes, plus or underscores.",
  invalid_mailbox: "Pick one of this domain's mailboxes.",
  sending_not_configured: "Outbound mail isn't configured for this domain yet.",
};
/** Thrown by createDomain when the domain's MX records point somewhere else (409 mx_in_use). */
export class DomainMxError extends ApiError {
  mx: string[];
  constructor(mx: string[]) {
    super(409, "This domain's mail currently goes somewhere else.");
    this.mx = mx;
  }
}
export function domainErrorMessage(e: unknown): string {
  const m = e instanceof Error ? e.message : String(e);
  const key = m.replace(/ /g, "_");
  return DOMAIN_ERRORS[key] ?? DOMAIN_ERRORS[m] ?? m;
}
/** POST /api/domains with a 409 `mx_in_use` body surfaced as DomainMxError (the generic client drops the mx list). */
export async function createDomain(body: { name: string; confirm?: boolean }): Promise<T.Domain> {
  const res = await fetch("/api/domains", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Account-Id": getScope() },
    credentials: "include",
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let data: any = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { error: text };
  }
  if (res.status === 409 && data?.error === "mx_in_use") throw new DomainMxError(Array.isArray(data.mx) ? data.mx : []);
  if (!res.ok) throw new ApiError(res.status, DOMAIN_ERRORS[data?.error] ?? String(data?.error ?? res.statusText).replace(/_/g, " "));
  return data as T.Domain;
}
export interface OAuthCredentialStatus {
  provider: "google" | "microsoft";
  configured: boolean;
  /** "env" means a Worker secret is set, so the stored value is ignored and the form is read-only. */
  source: "env" | "db" | "none";
  client_id: string;
  secret_hint: string;
}

export function useOAuthCredentials() {
  return useQuery({ queryKey: ["oauth"], queryFn: () => api.get<OAuthCredentialStatus[]>("/api/oauth"), staleTime: 30_000 });
}

export function useOAuthMutations() {
  const qc = useQueryClient();
  const inv = () => {
    qc.invalidateQueries({ queryKey: ["oauth"] });
    qc.invalidateQueries({ queryKey: keys.me });
  };
  return {
    save: useMutation({
      mutationFn: (b: { provider: string; client_id?: string; client_secret?: string | null }) =>
        request<OAuthCredentialStatus>("PUT", `/api/oauth/${b.provider}`, { client_id: b.client_id, client_secret: b.client_secret }),
      onSuccess: inv,
    }),
  };
}

export interface ImapDraft {
  email: string;
  display_name?: string;
  imap_host: string;
  imap_port: number;
  imap_security: "tls" | "starttls";
  smtp_host: string;
  smtp_port: number;
  smtp_security: "tls" | "starttls";
  username?: string;
  password: string;
  folder?: string;
}

export function useImapMutations() {
  const qc = useQueryClient();
  const inv = () => {
    qc.invalidateQueries({ queryKey: ["domains"] });
    qc.invalidateQueries({ queryKey: keys.me });
  };
  return {
    create: useMutation({
      mutationFn: (b: ImapDraft) => api.post<{ ok: boolean; account: T.Account }>("/api/accounts/imap", b),
      onSuccess: inv,
    }),
    test: useMutation({
      mutationFn: (id: string) => api.post<{ ok: boolean; error?: string }>(`/api/accounts/${id}/imap/test`),
    }),
  };
}

export function useDomains(enabled = true) {
  return useQuery({ queryKey: ["domains"], queryFn: () => api.get<T.Domain[]>("/api/domains"), enabled, staleTime: 15_000 });
}
export function useDomainMutations() {
  const qc = useQueryClient();
  const inv = () => {
    qc.invalidateQueries({ queryKey: ["domains"] });
    qc.invalidateQueries({ queryKey: keys.me });
  };
  return {
    create: useMutation({ mutationFn: createDomain, onSuccess: inv }),
    verify: useMutation({ mutationFn: (id: string) => api.post<T.Domain>(`/api/domains/${id}/verify`), onSuccess: inv }),
    patch: useMutation({ mutationFn: ({ id, ...b }: { id: string; catch_all_account_id?: string | null }) => api.patch<T.Domain>(`/api/domains/${id}`, b), onSuccess: inv }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/domains/${id}`), onSuccess: () => { inv(); invalidateMail(qc); } }),
    createMailbox: useMutation({
      mutationFn: ({ domain_id, ...b }: { domain_id: string; local_part: string; display_name?: string; catch_all?: boolean }) => api.post<T.Account>(`/api/domains/${domain_id}/mailboxes`, b),
      onSuccess: inv,
    }),
  };
}

// ---------- Two-factor authentication ----------
export function useTwoFactor() {
  return useQuery({ queryKey: ["2fa"], queryFn: () => api.get<T.TwoFactorStatus>("/api/me/2fa"), staleTime: 10_000 });
}
export function useTwoFactorMutations() {
  const qc = useQueryClient();
  const inv = () => { qc.invalidateQueries({ queryKey: ["2fa"] }); qc.invalidateQueries({ queryKey: keys.me }); };
  return {
    setup: useMutation({ mutationFn: () => api.post<{ secret: string; otpauth_url: string }>("/api/me/2fa/setup") }),
    enable: useMutation({ mutationFn: (b: { code: string }) => api.post<{ ok: boolean; recovery_codes: string[] }>("/api/me/2fa/enable", b), onSuccess: inv }),
    regenerate: useMutation({ mutationFn: (b: { code: string }) => api.post<{ ok: boolean; recovery_codes: string[] }>("/api/me/2fa/recovery-codes", b), onSuccess: inv }),
    disable: useMutation({ mutationFn: (b: { password: string; code?: string }) => api.post<{ ok: boolean }>("/api/me/2fa/disable", b), onSuccess: inv }),
  };
}

// ---------- Bundles (batches) ----------
export function useBundle(id: string | undefined) {
  return useQuery({ queryKey: ["bundle", id ?? ""], queryFn: () => api.get<T.BundleDetail>(`/api/bundles/${id}`), enabled: !!id });
}
export function useBundleMutations() {
  const qc = useQueryClient();
  const inv = (id: string) => {
    qc.invalidateQueries({ queryKey: ["bundle", id] });
    invalidateMail(qc);
  };
  return {
    seen: useMutation({ mutationFn: (id: string) => api.post<{ ok: boolean }>(`/api/bundles/${id}/seen`), onSuccess: (_r, id) => inv(id) }),
    unseen: useMutation({ mutationFn: (id: string) => api.post<{ ok: boolean }>(`/api/bundles/${id}/unseen`), onSuccess: (_r, id) => inv(id) }),
    dissolve: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/bundles/${id}`), onSuccess: (_r, id) => inv(id) }),
  };
}

// ---------- AI assistant ----------
export function useAiSettings() {
  return useQuery({ queryKey: ["ai", "settings"], queryFn: () => api.get<T.AiSettings>("/api/ai/settings"), staleTime: 30_000 });
}
export function useAiMemory() {
  return useQuery({ queryKey: ["ai", "memory"], queryFn: () => api.get<T.AiMemoryEntry[]>("/api/ai/memory"), staleTime: 15_000 });
}
export function useAiConversations() {
  return useQuery({ queryKey: ["ai", "conversations"], queryFn: () => api.get<T.AiConversation[]>("/api/ai/conversations"), staleTime: 10_000 });
}
export interface AiStoredMessage {
  id: string;
  role: "user" | "assistant";
  content: unknown[];
  created_at: number;
}
export function useAiConversation(id: string | undefined) {
  return useQuery({ queryKey: ["ai", "conversation", id ?? ""], queryFn: () => api.get<{ conversation: T.AiConversation; messages: AiStoredMessage[] }>(`/api/ai/conversations/${id}`), enabled: !!id });
}
export function useAiMutations() {
  const qc = useQueryClient();
  const invSettings = () => qc.invalidateQueries({ queryKey: ["ai", "settings"] });
  const invMemory = () => qc.invalidateQueries({ queryKey: ["ai", "memory"] });
  const invConvs = () => qc.invalidateQueries({ queryKey: ["ai", "conversations"] });
  return {
    saveSettings: useMutation({ mutationFn: (b: { preset?: string; base_url?: string; api_key?: string | null; model?: string; learn?: boolean; auto_send?: boolean }) => request<{ ok: boolean }>("PUT", "/api/ai/settings", b), onSuccess: invSettings }),
    test: useMutation({ mutationFn: () => api.post<{ ok: boolean; model?: string; reply?: string; error?: string }>("/api/ai/settings/test") }),
    learn: useMutation({ mutationFn: () => api.post<{ changed: number; skipped?: string }>("/api/ai/learn"), onSuccess: () => { invMemory(); invSettings(); } }),
    addMemory: useMutation({ mutationFn: (b: { kind: T.AiMemoryKind; content: string }) => api.post<T.AiMemoryEntry>("/api/ai/memory", b), onSuccess: invMemory }),
    updateMemory: useMutation({ mutationFn: ({ id, ...b }: { id: string; kind?: T.AiMemoryKind; content?: string }) => api.patch<T.AiMemoryEntry>(`/api/ai/memory/${id}`, b), onSuccess: invMemory }),
    deleteMemory: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/ai/memory/${id}`), onSuccess: invMemory }),
    clearMemory: useMutation({ mutationFn: () => api.del<{ ok: boolean }>("/api/ai/memory"), onSuccess: () => { invMemory(); invSettings(); } }),
    newConversation: useMutation({ mutationFn: () => api.post<T.AiConversation>("/api/ai/conversations"), onSuccess: invConvs }),
    renameConversation: useMutation({ mutationFn: ({ id, title }: { id: string; title: string }) => api.patch<{ ok: boolean }>(`/api/ai/conversations/${id}`, { title }), onSuccess: invConvs }),
    deleteConversation: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/ai/conversations/${id}`), onSuccess: invConvs }),
    reply: useMutation({ mutationFn: (b: { thread_id: string; brief: string; tone?: "match" | "formal" | "friendly" | "brief" }) => api.post<{ subject: string | null; body_text: string; body_html: string; reply_to_message_id: string | null }>("/api/ai/reply", b) }),
    summarize: useMutation({ mutationFn: (thread_id: string) => api.post<{ summary: string }>("/api/ai/summarize", { thread_id }) }),
  };
}

export type AiSseEvent =
  | { type: "start"; conversation_id: string }
  | { type: "text"; text: string }
  | { type: "tool"; id: string; name: string; status: "running" | "done" | "error"; summary: string }
  | { type: "draft"; draft: T.AiDraftCard }
  | { type: "sent"; draft_id: string; thread_id: string }
  | { type: "done"; conversation_id: string }
  | { type: "error"; message: string };

/** Streams one assistant turn. Resolves when the server sends `done` (or the stream ends). */
export async function aiChatStream(body: { conversation_id?: string; message: string; context_thread_ids?: string[] }, onEvent: (e: AiSseEvent) => void, signal?: AbortSignal): Promise<void> {
  const res = await fetch("/api/ai/chat", { method: "POST", headers: { "Content-Type": "application/json", "X-Account-Id": getScope() }, credentials: "include", body: JSON.stringify(body), signal });
  if (!res.ok || !res.body) {
    let msg = res.statusText;
    try {
      const j = (await res.json()) as { error?: string };
      msg = j.error || msg;
    } catch {}
    throw new ApiError(res.status, msg);
  }
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let idx: number;
    while ((idx = buf.indexOf("\n\n")) >= 0) {
      const chunk = buf.slice(0, idx);
      buf = buf.slice(idx + 2);
      const line = chunk.split("\n").find((l) => l.startsWith("data: "));
      if (!line) continue;
      try {
        onEvent(JSON.parse(line.slice(6)) as AiSseEvent);
      } catch {}
    }
  }
}

// ---------- Power through new ----------
export interface PowerThroughResponse {
  items: (T.ThreadSummary & { latest_message: T.Message | null })[];
}
export function usePowerThrough(enabled = true) {
  return useQuery({
    queryKey: ["power-through"],
    queryFn: () => api.get<PowerThroughResponse>("/api/power-through"),
    enabled,
    // The queue is a snapshot you work through; refetching under the cursor would be jarring.
    staleTime: 5 * 60_000,
    refetchOnWindowFocus: false,
  });
}
export function usePowerThroughMutations() {
  const qc = useQueryClient();
  return {
    markAllSeen: useMutation({
      mutationFn: (thread_ids: string[]) => api.post<{ ok: boolean; count: number }>("/api/power-through/seen", { thread_ids }),
      onSuccess: () => {
        qc.invalidateQueries({ queryKey: ["power-through"] });
        invalidateMail(qc);
      },
    }),
  };
}

// ---------- Calendar ----------
/** How a write applies to a recurring event: just this occurrence, this and later, or the series. */
export type EventScope = "this" | "following" | "all";

/** The writable half of a CalEvent. Everything is optional on PATCH; POST needs at least a title. */
export interface EventInput {
  calendar_id?: string;
  kind?: T.EventKind;
  title?: string;
  description?: string;
  location?: string;
  emoji?: string;
  all_day?: boolean;
  starts_at?: number;
  ends_at?: number;
  start_date?: string | null;
  end_date?: string | null;
  timezone?: string;
  rrule?: string | null;
  status?: T.CalEvent["status"];
  busy?: boolean;
  countdown?: boolean;
  circled?: boolean;
  attendees?: T.EventAttendee[];
  conference_url?: string;
  url?: string;
  reminders?: T.Reminder[];
  thread_id?: string | null;
  done?: boolean;
}

/** POST /api/calendar/events/from-thread — a half-filled event to open the composer with. */
export interface EventPrefill extends EventInput {
  thread_id: string | null;
  /** Suggested times parsed out of the message, if any. */
  suggestions?: { starts_at: number; ends_at: number }[];
}

/** `:id` may be `<row>@<YYYY-MM-DD>`, addressing one occurrence of a recurring master. */
function eventPath(id: string): string {
  return `/api/calendar/events/${encodeURIComponent(id)}`;
}

/** Download URL for a single event as `.ics`. */
export function eventIcsUrl(id: string): string {
  return `${eventPath(id)}.ics`;
}

// --- Range ---
/**
 * Everything needed to draw `from`..`to` (inclusive dates): events, habits, day labels and
 * cover art, the week's flex tasks and time entries.
 *
 * `placeholderData` keeps the previous window on screen while the next one loads, so scrolling
 * the day strip never blanks the columns.
 */
export function useCalendarRange(from: string, to: string, enabled = true) {
  return useQuery({
    queryKey: keys.calRange(from, to),
    queryFn: () => api.get<T.CalendarRange>(`/api/calendar/events${qs({ from, to })}`),
    enabled: enabled && !!from && !!to,
    placeholderData: (prev) => prev,
    staleTime: 30_000,
  });
}

// --- Sources ---
export function useCalendarSources(enabled = true) {
  return useQuery({
    queryKey: keys.calSources,
    queryFn: () => api.get<T.CalendarSourcesResponse>("/api/calendar/sources"),
    enabled,
    staleTime: 30_000,
  });
}

export function useCalendarSourceMutations() {
  const qc = useQueryClient();
  const inv = () => invalidateCalendar(qc);
  return {
    create: useMutation({ mutationFn: (b: { name: string; color?: string }) => api.post<T.Calendar>("/api/calendar/sources", b), onSuccess: inv }),
    subscribe: useMutation({ mutationFn: (b: { url: string; name?: string; color?: string }) => api.post<T.Calendar>("/api/calendar/sources/subscribe", b), onSuccess: inv }),
    update: useMutation({
      mutationFn: ({ id, ...b }: { id: string; name?: string; color?: string; visible?: boolean; is_default?: boolean }) => api.patch<T.Calendar>(`/api/calendar/sources/${id}`, b),
      onSuccess: inv,
    }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/calendar/sources/${id}`), onSuccess: inv }),
    sync: useMutation({ mutationFn: (id: string) => api.post<{ ok: boolean; error?: string | null }>(`/api/calendar/sources/${id}/sync`), onSuccess: inv }),
    syncAll: useMutation({ mutationFn: () => api.post<{ ok: boolean; synced?: number }>("/api/calendar/sources/sync"), onSuccess: inv }),
    /** Upload an `.ics` body; its events land in a local calendar and become editable. */
    importIcs: useMutation({
      mutationFn: (b: { ics: string; calendar_id?: string; name?: string; color?: string }) => api.post<{ ok: boolean; imported: number; calendar?: T.Calendar }>("/api/calendar/sources/import", b),
      onSuccess: inv,
    }),
  };
}

/**
 * Kicks off Google consent for the Calendar scope; open the returned URL. `account_id` pre-fills
 * which account to sign in as; `calendar_only` asks for calendar access and no mail access at all.
 */
export function useCalendarConnectLink() {
  return useMutation({
    mutationFn: (b: { account_id?: string; calendar_only?: boolean } = {}) => api.post<{ url: string }>("/api/calendar/google/connect-link", b),
  });
}

/** Drops one Google account's calendars and their events, and forgets its Calendar scope. Mail is untouched. */
export function useCalendarDisconnect() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (accountId: string) => api.post<{ ok: boolean; removed: number } & T.CalendarSourcesResponse>(`/api/calendar/google/${accountId}/disconnect`),
    onSuccess: () => invalidateCalendar(qc),
  });
}

// --- Settings ---
export function useCalendarSettings(enabled = true) {
  return useQuery({
    queryKey: keys.calSettings,
    queryFn: () => api.get<T.CalendarSettings>("/api/calendar/settings"),
    enabled,
    staleTime: 60_000,
  });
}
export function useCalendarSettingsMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (b: Partial<T.CalendarSettings>) => request<T.CalendarSettings>("PUT", "/api/calendar/settings", b),
    onSuccess: (data) => {
      qc.setQueryData(keys.calSettings, data);
      invalidateCalendar(qc);
    },
  });
}

// --- Events ---
export function useEventMutations() {
  const qc = useQueryClient();
  const inv = () => invalidateCalendar(qc);
  return {
    create: useMutation({ mutationFn: (b: EventInput) => api.post<T.CalEvent>("/api/calendar/events", b), onSuccess: inv }),
    /** Copy an event onto the same calendar, at the same time, so it can be moved. */
    duplicate: useMutation({ mutationFn: (id: string) => api.post<T.CalEvent>(`${eventPath(id)}/duplicate`), onSuccess: inv }),
    /** `scope` rides as a query param, per the recurring-event contract. */
    update: useMutation({
      mutationFn: ({ id, scope, ...b }: EventInput & { id: string; scope?: EventScope }) => api.patch<T.CalEvent>(`${eventPath(id)}${qs({ scope })}`, b),
      onSuccess: inv,
    }),
    remove: useMutation({
      mutationFn: ({ id, scope }: { id: string; scope?: EventScope }) => api.del<{ ok: boolean }>(`${eventPath(id)}${qs({ scope })}`),
      onSuccess: inv,
    }),
    rsvp: useMutation({ mutationFn: ({ id, rsvp }: { id: string; rsvp: T.Rsvp }) => api.post<T.CalEvent>(`${eventPath(id)}/rsvp`, { rsvp }), onSuccess: inv }),
    /** Todos: `date` marks one occurrence of a repeating todo done. */
    setDone: useMutation({ mutationFn: ({ id, done, date }: { id: string; done: boolean; date?: string }) => api.post<T.CalEvent>(`${eventPath(id)}/done`, { done, date }), onSuccess: inv }),
  };
}

/** Turn an email into a half-filled event. Returns the prefill; it does not create anything. */
export function useEventFromThread() {
  return useMutation({ mutationFn: (thread_id: string) => api.post<EventPrefill>("/api/calendar/events/from-thread", { thread_id }) });
}

// --- Habits ---
export function useHabits(from?: string, to?: string, enabled = true) {
  return useQuery({
    queryKey: [...keys.habits, from ?? "", to ?? ""],
    queryFn: () => api.get<T.Habit[]>(`/api/calendar/habits${qs({ from, to })}`),
    enabled,
    staleTime: 30_000,
  });
}

export interface HabitInput {
  name?: string;
  icon?: string;
  color?: string;
  /** Weekdays the habit is expected on, 0 = Sunday. Empty means every day. */
  days?: number[];
  position?: number;
  archived?: boolean;
}

export function useHabitMutations() {
  const qc = useQueryClient();
  const inv = () => invalidateCalendar(qc);
  return {
    create: useMutation({ mutationFn: (b: HabitInput & { name: string }) => api.post<T.Habit>("/api/calendar/habits", b), onSuccess: inv }),
    update: useMutation({ mutationFn: ({ id, ...b }: HabitInput & { id: string }) => api.patch<T.Habit>(`/api/calendar/habits/${id}`, b), onSuccess: inv }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/calendar/habits/${id}`), onSuccess: inv }),
    /**
     * Ticking a habit has to feel instant, so this one is optimistic: every cached range
     * gets the completion added (or removed) before the request goes out, and the snapshots
     * are rolled back if the server disagrees.
     */
    toggle: useMutation({
      mutationFn: ({ id, date }: { id: string; date: string }) => api.post<{ ok: boolean; done: boolean }>(`/api/calendar/habits/${id}/toggle`, { date }),
      onMutate: async ({ id, date }) => {
        // Stop in-flight range fetches from landing on top of the optimistic patch.
        await qc.cancelQueries({ queryKey: ["cal", "range"] });
        const snapshots = qc.getQueriesData<T.CalendarRange>({ queryKey: ["cal", "range"] });
        qc.setQueriesData<T.CalendarRange>({ queryKey: ["cal", "range"] }, (old) => {
          if (!old) return old;
          let hit = false;
          const habits = old.habits.map((h) => {
            if (h.id !== id) return h;
            hit = true;
            const done = h.completions?.includes(date) ?? false;
            const completions = done ? (h.completions ?? []).filter((d) => d !== date) : [...(h.completions ?? []), date].sort();
            // streak is server-computed; nudge it so the badge doesn't lag the tick.
            const streak = h.streak === undefined ? undefined : Math.max(0, h.streak + (done ? -1 : 1));
            return { ...h, completions, streak };
          });
          return hit ? { ...old, habits } : old;
        });
        return { snapshots };
      },
      onError: (_e, _v, ctx) => {
        for (const [key, data] of ctx?.snapshots ?? []) qc.setQueryData(key, data);
      },
      onSettled: inv,
    }),
  };
}

// --- Days (label + cover art) ---
export function useCalendarDay(date: string | undefined) {
  return useQuery({
    queryKey: keys.calDay(date ?? ""),
    queryFn: () => api.get<T.CalendarDay>(`/api/calendar/days/${date}`),
    enabled: !!date,
  });
}
/** The photo library — every picture stuck on a day, newest first, so one can be reused. */
export function useDayCovers(enabled = true) {
  return useQuery({ queryKey: keys.dayCovers, queryFn: () => api.get<T.DayCover[]>("/api/calendar/covers"), enabled, staleTime: 60_000 });
}

export function useDayCoverMutations() {
  const qc = useQueryClient();
  const inv = () => {
    qc.invalidateQueries({ queryKey: keys.dayCovers });
    invalidateCalendar(qc);
  };
  return {
    /** Downscales in the browser, then posts the raw bytes — no multipart, no base64. */
    upload: useMutation({
      mutationFn: async (file: File) => {
        const { prepareCover } = await import("./lib/image");
        const img = await prepareCover(file);
        const res = await fetch("/api/calendar/covers", {
          method: "POST",
          credentials: "include",
          headers: {
            "content-type": img.type,
            "x-image-width": String(img.width),
            "x-image-height": String(img.height),
            "x-image-name": encodeURIComponent(file.name).slice(0, 120),
          },
          body: img.blob,
        });
        const text = await res.text();
        const data = text ? JSON.parse(text) : null;
        if (!res.ok) throw new ApiError(res.status, humanize((data as T.ApiError | null)?.error || "upload failed"));
        return data as T.DayCover;
      },
      onSuccess: inv,
    }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/calendar/covers/${id}`), onSuccess: inv }),
  };
}

export function useCalendarDayMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ date, ...b }: { date: string; label?: string; cover_url?: string; cover_id?: string | null; cover_position?: string }) =>
      request<T.CalendarDay>("PUT", `/api/calendar/days/${date}`, b),
    onSuccess: (data, v) => {
      qc.setQueryData(keys.calDay(v.date), data);
      invalidateCalendar(qc);
    },
  });
}

// --- Journal ---
export function useJournal(date: string | undefined) {
  return useQuery({
    queryKey: keys.journalDay(date ?? ""),
    queryFn: () => api.get<T.JournalEntry>(`/api/calendar/journal/${date}`),
    enabled: !!date,
  });
}
/** Every day that has a journal entry, for the journal index. */
export function useJournalIndex(enabled = true) {
  return useQuery({ queryKey: keys.journal, queryFn: () => api.get<T.JournalIndexEntry[]>("/api/calendar/journal"), enabled, staleTime: 30_000 });
}
export function useJournalMutation() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ date, ...b }: { date: string; journal_html: string }) => request<T.JournalEntry>("PUT", `/api/calendar/journal/${date}`, b),
    onSuccess: (data, v) => {
      qc.setQueryData(keys.journalDay(v.date), data);
      invalidateCalendar(qc);
    },
  });
}

// --- Flex tasks ("sometime this week") ---
export function useFlexTasks(weekStart: string, enabled = true) {
  return useQuery({
    queryKey: keys.flexTasks(weekStart),
    queryFn: () => api.get<T.FlexTask[]>(`/api/calendar/flex-tasks${qs({ week: weekStart })}`),
    enabled: enabled && !!weekStart,
    staleTime: 30_000,
  });
}
export function useFlexTaskMutations() {
  const qc = useQueryClient();
  const inv = () => invalidateCalendar(qc);
  return {
    create: useMutation({ mutationFn: (b: { week_start: string; title: string }) => api.post<T.FlexTask>("/api/calendar/flex-tasks", b), onSuccess: inv }),
    update: useMutation({ mutationFn: ({ id, ...b }: { id: string; title?: string; done?: boolean; position?: number; week_start?: string }) => api.patch<T.FlexTask>(`/api/calendar/flex-tasks/${id}`, b), onSuccess: inv }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/calendar/flex-tasks/${id}`), onSuccess: inv }),
    /** Carry unfinished tasks forward into `week` (the target week's start date). */
    roll: useMutation({ mutationFn: (b: { week: string }) => api.post<{ ok: boolean; rolled: number }>(`/api/calendar/flex-tasks/roll`, b), onSuccess: inv }),
  };
}

// --- Time tracking ---
export function useTimeEntries(from: string, to: string, enabled = true) {
  return useQuery({
    queryKey: [...keys.timeEntries, from, to],
    queryFn: () => api.get<T.TimeEntry[]>(`/api/calendar/time${qs({ from, to })}`),
    enabled: enabled && !!from && !!to,
    staleTime: 30_000,
  });
}
export function useTimeMutations() {
  const qc = useQueryClient();
  const inv = () => invalidateCalendar(qc);
  return {
    start: useMutation({ mutationFn: (b: { title: string; event_id?: string | null; started_at?: number }) => api.post<T.TimeEntry>("/api/calendar/time", b), onSuccess: inv }),
    stop: useMutation({ mutationFn: ({ id, ended_at }: { id: string; ended_at?: number }) => api.post<T.TimeEntry>(`/api/calendar/time/${id}/stop`, { ended_at }), onSuccess: inv }),
    update: useMutation({ mutationFn: ({ id, ...b }: { id: string; title?: string; event_id?: string | null; started_at?: number; ended_at?: number | null }) => api.patch<T.TimeEntry>(`/api/calendar/time/${id}`, b), onSuccess: inv }),
    remove: useMutation({ mutationFn: (id: string) => api.del<{ ok: boolean }>(`/api/calendar/time/${id}`), onSuccess: inv }),
  };
}
