import type { Env } from "./env";
import { now, chunk, runBatch } from "./db";

/** Consumer mailbox providers never have a brand logo for the sender domain. */
const CONSUMER_DOMAINS = /^(gmail\.com|googlemail\.com|yahoo\.[a-z.]+|ymail\.com|outlook\.com|outlook\.[a-z.]+|hotmail\.[a-z.]+|live\.com|live\.[a-z.]+|msn\.com|icloud\.com|me\.com|mac\.com|proton\.me|protonmail\.com|pm\.me|aol\.com)$/i;
const RECHECK_MS = 7 * 24 * 3600_000;
const MAX_LOOKUPS = 10;

interface DohAnswer {
  Answer?: { type: number; data: string }[];
}

/** BIMI lookup: TXT at default._bimi.<domain> → "v=BIMI1; l=https://.../logo.svg". Returns '' when there is none. */
export async function lookupBimi(domain: string): Promise<string> {
  try {
    const res = await fetch(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(`default._bimi.${domain}`)}&type=TXT`, {
      headers: { accept: "application/dns-json" },
    });
    if (!res.ok) return "";
    const j = (await res.json()) as DohAnswer;
    for (const a of j.Answer ?? []) {
      if (a.type !== 16) continue;
      const txt = a.data.replace(/^"|"$/g, "").replace(/"\s*"/g, "");
      if (!/v\s*=\s*BIMI1/i.test(txt)) continue;
      const m = /(?:^|;)\s*l\s*=\s*([^;\s]+)/i.exec(txt);
      const url = m?.[1]?.trim() ?? "";
      if (!/^https:\/\//i.test(url)) continue;
      const path = url.split("?")[0].split("#")[0];
      const hasExt = /\.[a-z0-9]{2,5}$/i.test(path);
      if (!hasExt || /\.svg$/i.test(path)) return url;
    }
  } catch {
    // DNS hiccup: treat as none for now; the cache entry will be re-checked later.
  }
  return "";
}

function domainOf(email: string): string {
  const at = email.lastIndexOf("@");
  return at < 0 ? "" : email.slice(at + 1).toLowerCase();
}

/**
 * Attach BIMI brand logos to contacts (those without a photo yet) for the given sender emails.
 * Uses the brand_logos cache; at most MAX_LOOKUPS DNS queries per call.
 */
export async function resolveBrandLogos(env: Env, accountId: string, emails: string[]): Promise<{ resolved: number }> {
  const db = env.DB;
  const domains = [...new Set(emails.map(domainOf).filter((d) => d && !CONSUMER_DOMAINS.test(d)))];
  if (!domains.length) return { resolved: 0 };
  const cached = new Map<string, { logo_url: string; checked_at: number }>();
  for (const part of chunk(domains, 90)) {
    const rows = await db
      .prepare(`SELECT domain, logo_url, checked_at FROM brand_logos WHERE domain IN (${part.map(() => "?").join(",")})`)
      .bind(...part)
      .all<{ domain: string; logo_url: string; checked_at: number }>();
    for (const r of rows.results) cached.set(r.domain, r);
  }
  const t = now();
  const logos = new Map<string, string>();
  let lookups = 0;
  const upserts: D1PreparedStatement[] = [];
  for (const d of domains) {
    const c = cached.get(d);
    if (c && t - c.checked_at < RECHECK_MS) {
      if (c.logo_url) logos.set(d, c.logo_url);
      continue;
    }
    if (lookups >= MAX_LOOKUPS) {
      if (c?.logo_url) logos.set(d, c.logo_url);
      continue;
    }
    lookups++;
    const url = await lookupBimi(d);
    upserts.push(db.prepare(`INSERT INTO brand_logos (domain, logo_url, checked_at) VALUES (?, ?, ?) ON CONFLICT(domain) DO UPDATE SET logo_url = excluded.logo_url, checked_at = excluded.checked_at`).bind(d, url, t));
    if (url) logos.set(d, url);
  }
  const updates: D1PreparedStatement[] = [];
  for (const [d, url] of logos) {
    updates.push(db.prepare(`UPDATE contacts SET avatar_url = ? WHERE account_id = ? AND avatar_url = '' AND email LIKE ?`).bind(url, accountId, `%@${d}`));
  }
  await runBatch(db, [...upserts, ...updates], 40);
  return { resolved: logos.size };
}
