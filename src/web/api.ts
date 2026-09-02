import { useInfiniteQuery, useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query";
import type * as T from "@shared/types";

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
};

export function invalidateMail(qc: QueryClient) {
  for (const k of [["imbox"], ["threads"], ["feed"], ["thread"], ["counts"], ["screener"], ["screened-out"], ["search"], ["collection"], ["contact"], ["clips"]]) {
    qc.invalidateQueries({ queryKey: k });
  }
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
    mutationFn: (p: { contact_id: string; decision: T.ScreenStatus }) => api.post<{ ok: boolean }>("/api/screener/decide", p),
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
  return useQuery({ queryKey: keys.contacts(q), queryFn: () => api.get<T.Contact[]>(`/api/contacts${qs({ q })}`), enabled, staleTime: 30_000 });
}
export interface Suggestion { email: string; name: string; avatar_url: string }
export function useSuggest(q: string, enabled = true) {
  return useQuery({ queryKey: ["suggest", q], queryFn: () => api.get<Suggestion[]>(`/api/contacts/suggest${qs({ q })}`), enabled, staleTime: 60_000 });
}
export function useContact(id: string | undefined, bucket?: string) {
  return useQuery({
    queryKey: [...keys.contact(id ?? ""), bucket ?? ""],
    queryFn: () => api.get<{ contact: T.Contact; threads: T.ThreadSummary[] }>(`/api/contacts/${id}${qs({ bucket })}`),
    enabled: !!id,
  });
}
export function useUpdateContact() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: { id: string; name?: string; notes?: string; screen_status?: T.ScreenStatus; bundled?: boolean }) => api.patch<T.Contact>(`/api/contacts/${id}`, body),
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
  return api.post<SendResult>("/api/send", payload);
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
