import type { Env } from "./env";
import type { AccountRow } from "./db";
import { now, chunk, logSync, runBatch } from "./db";
import { googleFetch, GmailError } from "./google";

interface Person {
  names?: { displayName?: string; metadata?: { primary?: boolean } }[];
  emailAddresses?: { value?: string }[];
  photos?: { url?: string; default?: boolean; metadata?: { primary?: boolean } }[];
}
interface PeoplePage {
  otherContacts?: Person[];
  connections?: Person[];
  people?: Person[];
  nextPageToken?: string;
}

function bestPhoto(p: Person): string {
  const photos = (p.photos ?? []).filter((ph) => ph.url && !ph.default);
  if (!photos.length) return "";
  const primary = photos.find((ph) => ph.metadata?.primary) ?? photos[0];
  return primary.url ?? "";
}

export interface AddressEntry { name: string; photo: string }

async function collect(env: Env, account: AccountRow, base: string, key: "otherContacts" | "connections" | "people", out: Map<string, AddressEntry>) {
  let pageToken: string | undefined;
  let pages = 0;
  do {
    const url = base + (pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : "");
    const res = await googleFetch(env, account, url);
    const text = await res.text();
    if (!res.ok) throw new GmailError(res.status, text, `People API ${res.status}`);
    const j = (text ? JSON.parse(text) : {}) as PeoplePage;
    for (const p of j[key] ?? []) {
      const photo = bestPhoto(p);
      const name = ((p.names ?? []).find((n) => n.metadata?.primary) ?? (p.names ?? [])[0])?.displayName?.trim() ?? "";
      for (const e of p.emailAddresses ?? []) {
        const email = (e.value ?? "").trim().toLowerCase();
        if (!email || !email.includes("@")) continue;
        const prev = out.get(email);
        if (!prev) out.set(email, { name, photo });
        else out.set(email, { name: prev.name || name, photo: prev.photo || photo });
      }
    }
    pageToken = j.nextPageToken;
    pages++;
  } while (pageToken && pages < 10);
}

/**
 * Pull contact photos from Google People (other contacts + saved contacts) and store them on matching contacts rows.
 * 403 (scope not granted on an older connection) is logged and ignored.
 */
export async function syncContactPhotos(env: Env, account: AccountRow): Promise<{ updated: number }> {
  const db = env.DB;
  if (account.provider !== "gmail") return { updated: 0 };
  const people = new Map<string, AddressEntry>();
  try {
    await collect(env, account, "https://people.googleapis.com/v1/otherContacts?readMask=names,emailAddresses,photos&pageSize=1000&sources=READ_SOURCE_TYPE_PROFILE&sources=READ_SOURCE_TYPE_CONTACT", "otherContacts", people);
    await collect(env, account, "https://people.googleapis.com/v1/people/me/connections?personFields=names,emailAddresses,photos&pageSize=1000&sources=READ_SOURCE_TYPE_PROFILE&sources=READ_SOURCE_TYPE_CONTACT&sources=READ_SOURCE_TYPE_DOMAIN_CONTACT", "connections", people);
    // Workspace directory (coworkers' domain profile photos — what Gmail shows for colleagues). Consumer Gmail accounts have
    // no directory and older connections may lack the scope: both are logged and skipped without failing the sync.
    try {
      await collect(env, account, "https://people.googleapis.com/v1/people:listDirectoryPeople?readMask=names,emailAddresses,photos&sources=DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE&sources=DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT&pageSize=1000", "people", people);
    } catch (e) {
      if (e instanceof GmailError && (e.status === 403 || e.status === 400 || e.status === 401)) {
        await logSync(db, account.id, "info", `Directory photos skipped: ${/insufficient/i.test(e.body ?? "") ? "reconnect Gmail to grant the directory scope" : "no Workspace directory for this account"}`);
      } else throw e;
    }
  } catch (e) {
    if (e instanceof GmailError && (e.status === 403 || e.status === 401)) {
      const disabled = /has not been used|is disabled/i.test(e.message ?? "") || /has not been used|is disabled/i.test(String((e as { body?: string }).body ?? ""));
      await logSync(db, account.id, "warn", disabled
        ? `Contact photos skipped: People API is not enabled in the Google Cloud project — enable it under APIs & Services → Library → People API`
        : `Contact photos skipped: People API ${e.status} (reconnect Gmail to grant the contacts scopes)`);
      // Retry in ~10 minutes when the API is merely disabled (the user can enable it any time); otherwise back off a day.
      const stamp = disabled ? now() - 24 * 3600_000 + 10 * 60_000 : now();
      await db.prepare(`UPDATE accounts SET photos_synced_at = ? WHERE id = ?`).bind(stamp, account.id).run();
      return { updated: 0 };
    }
    throw e;
  }
  // Address book: every person Google knows about, for compose autocomplete.
  // The upsert only writes when a name or photo actually differs. Without that guard a repeat pass
  // rewrites `updated_at` on all ~1,000 rows for nothing, and D1 bills every one of them.
  const t0 = now();
  const bookStmts: D1PreparedStatement[] = [];
  for (const [email, entry] of people) {
    bookStmts.push(
      db
        .prepare(
          `INSERT INTO address_book (account_id, email, name, avatar_url, updated_at) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(account_id, email) DO UPDATE SET name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE address_book.name END,
             avatar_url = CASE WHEN excluded.avatar_url <> '' THEN excluded.avatar_url ELSE address_book.avatar_url END, updated_at = excluded.updated_at
           WHERE (excluded.name <> '' AND address_book.name <> excluded.name)
              OR (excluded.avatar_url <> '' AND address_book.avatar_url <> excluded.avatar_url)`
        )
        .bind(account.id, email, entry.name, entry.photo, t0)
    );
  }
  await runBatch(db, bookStmts, 40);

  const photos = new Map<string, string>();
  for (const [email, entry] of people) if (entry.photo) photos.set(email, entry.photo);
  let updated = 0;
  const emails = [...photos.keys()];
  const stmts: D1PreparedStatement[] = [];
  for (const part of chunk(emails, 90)) {
    const rows = await db
      .prepare(
        `SELECT id, email, avatar_url FROM contacts WHERE account_id IN (SELECT id FROM accounts WHERE user_id = ?) AND email IN (${part.map(() => "?").join(",")})`
      )
      .bind(account.user_id, ...part)
      .all<{ id: string; email: string; avatar_url: string }>();
    for (const r of rows.results) {
      const url = photos.get(r.email);
      if (url && url !== r.avatar_url) {
        stmts.push(db.prepare(`UPDATE contacts SET avatar_url = ? WHERE id = ?`).bind(url, r.id));
        updated++;
      }
    }
  }
  await runBatch(db, stmts, 40);
  await db.prepare(`UPDATE accounts SET photos_synced_at = ? WHERE id = ?`).bind(now(), account.id).run();
  account.photos_synced_at = now();
  await logSync(db, account.id, "info", `Address book: ${people.size} people, ${photos.size} with photos, ${updated} contact photos updated`);
  return { updated };
}
