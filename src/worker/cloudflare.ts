// Thin Cloudflare API client for Email Routing setup (needs CF_API_TOKEN) + a DoH MX lookup.
import type { Env } from "./env";
import type { DnsRecord } from "@shared/types";

const API = "https://api.cloudflare.com/client/v4";

export class CfError extends Error {
  constructor(public status: number, public body: string) {
    super(`Cloudflare API ${status}: ${body.slice(0, 300)}`);
  }
}

export function cfConfigured(env: Env): boolean {
  return !!env.CF_API_TOKEN;
}

async function cf<T>(env: Env, path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`${API}${path}`, {
    ...init,
    headers: { authorization: `Bearer ${env.CF_API_TOKEN}`, "content-type": "application/json", ...(init.headers ?? {}) },
  });
  const text = await res.text();
  let json: any = null;
  try {
    json = JSON.parse(text);
  } catch {
    // ignore
  }
  if (!res.ok || !json?.success) {
    const msg = json?.errors?.map((e: any) => e.message).join("; ") || text;
    throw new CfError(res.status, msg);
  }
  return json.result as T;
}

export interface CfZone {
  id: string;
  name: string;
  status: string;
  type?: string;
}

export async function findZone(env: Env, name: string): Promise<CfZone | null> {
  const zones = await cf<CfZone[]>(env, `/zones?name=${encodeURIComponent(name)}&per_page=5`);
  return zones.find((z) => z.name.toLowerCase() === name.toLowerCase()) ?? null;
}

export interface CfRoutingSettings {
  enabled: boolean;
  status: string; // ready | unconfigured | misconfigured | ...
  name: string;
}

export const getRoutingSettings = (env: Env, zoneId: string) => cf<CfRoutingSettings>(env, `/zones/${zoneId}/email/routing`);
export const enableRouting = (env: Env, zoneId: string) => cf<CfRoutingSettings>(env, `/zones/${zoneId}/email/routing/enable`, { method: "POST", body: "{}" });

export async function routingDns(env: Env, zoneId: string): Promise<DnsRecord[]> {
  const rows = await cf<any>(env, `/zones/${zoneId}/email/routing/dns`);
  const list: any[] = Array.isArray(rows) ? rows : rows?.record ?? [];
  return list.map((r) => ({ type: r.type, name: r.name, content: r.content, priority: r.priority })).filter((r) => r.type && r.content);
}

export interface CfCatchAll {
  enabled: boolean;
  matchers: { type: string }[];
  actions: { type: string; value?: string[] }[];
}

export const getCatchAll = (env: Env, zoneId: string) => cf<CfCatchAll>(env, `/zones/${zoneId}/email/routing/rules/catch_all`);

export function setCatchAllToWorker(env: Env, zoneId: string, workerName: string) {
  return cf<CfCatchAll>(env, `/zones/${zoneId}/email/routing/rules/catch_all`, {
    method: "PUT",
    body: JSON.stringify({ name: "heyflare catch-all", enabled: true, matchers: [{ type: "all" }], actions: [{ type: "worker", value: [workerName] }] }),
  });
}

export function catchAllTargetsWorker(rule: CfCatchAll | null, workerName: string): boolean {
  if (!rule?.enabled) return false;
  return rule.actions.some((a) => a.type === "worker" && (a.value ?? []).includes(workerName));
}

/** Current MX targets for a domain via DNS-over-HTTPS (used to warn before taking over a domain's mail). */
export async function lookupMx(domain: string): Promise<string[]> {
  try {
    const res = await fetch(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(domain)}&type=MX`, { headers: { accept: "application/dns-json" } });
    if (!res.ok) return [];
    const j = (await res.json()) as { Answer?: { type: number; data: string }[] };
    return (j.Answer ?? [])
      .filter((a) => a.type === 15)
      .map((a) => a.data.replace(/^\d+\s+/, "").replace(/\.$/, "").toLowerCase())
      .filter(Boolean);
  } catch {
    return [];
  }
}

export const isCloudflareMx = (mx: string[]) => mx.length > 0 && mx.every((m) => /\.mx\.cloudflare\.net$/i.test(m));

/** The standard records Cloudflare Email Routing uses (shown when we can't read them from the API). */
export function defaultRoutingDns(domain: string): DnsRecord[] {
  return [
    { type: "MX", name: domain, content: "route1.mx.cloudflare.net", priority: 8 },
    { type: "MX", name: domain, content: "route2.mx.cloudflare.net", priority: 11 },
    { type: "MX", name: domain, content: "route3.mx.cloudflare.net", priority: 14 },
    { type: "TXT", name: domain, content: "v=spf1 include:_spf.mx.cloudflare.net ~all" },
  ];
}
