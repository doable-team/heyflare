// RFC 6238 TOTP (SHA-1, 30s, 6 digits) + recovery codes, on WebCrypto only.

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function base32Encode(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(s: string): Uint8Array {
  const clean = s.toUpperCase().replace(/[^A-Z2-7]/g, "");
  const out: number[] = [];
  let bits = 0;
  let value = 0;
  for (const ch of clean) {
    value = (value << 5) | B32.indexOf(ch);
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

export function generateSecret(): string {
  return base32Encode(crypto.getRandomValues(new Uint8Array(20)));
}

export function otpauthUrl(label: string, secret: string, issuer = "heyflare"): string {
  return `otpauth://totp/${encodeURIComponent(issuer)}:${encodeURIComponent(label)}?secret=${secret}&issuer=${encodeURIComponent(issuer)}&algorithm=SHA1&digits=6&period=30`;
}

async function hotp(secret: Uint8Array, counter: number): Promise<string> {
  const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const msg = new Uint8Array(8);
  let c = counter;
  for (let i = 7; i >= 0; i--) {
    msg[i] = c & 0xff;
    c = Math.floor(c / 256);
  }
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, msg));
  const off = sig[sig.length - 1] & 0x0f;
  const code = ((sig[off] & 0x7f) << 24) | ((sig[off + 1] & 0xff) << 16) | ((sig[off + 2] & 0xff) << 8) | (sig[off + 3] & 0xff);
  return String(code % 1_000_000).padStart(6, "0");
}

export async function totpCode(secretB32: string, at = Date.now(), step = 30): Promise<string> {
  return hotp(base32Decode(secretB32), Math.floor(at / 1000 / step));
}

/** Accepts the current step and ±1 neighbour (clock drift). */
export async function verifyTotp(secretB32: string, code: string, at = Date.now()): Promise<boolean> {
  const digits = code.replace(/\s+/g, "");
  if (!/^\d{6}$/.test(digits)) return false;
  const secret = base32Decode(secretB32);
  const counter = Math.floor(at / 1000 / 30);
  for (const d of [0, -1, 1]) {
    if ((await hotp(secret, counter + d)) === digits) return true;
  }
  return false;
}

// ---- recovery codes: 10 × "xxxx-xxxx", stored as salted SHA-256 (fast enough to check 10 at login) ----

const ALNUM = "abcdefghijkmnpqrstuvwxyz23456789"; // no ambiguous 0/o/1/l

export function generateRecoveryCodes(n = 10): string[] {
  const out: string[] = [];
  for (let i = 0; i < n; i++) {
    const r = crypto.getRandomValues(new Uint8Array(8));
    const s = Array.from(r, (b) => ALNUM[b % ALNUM.length]).join("");
    out.push(`${s.slice(0, 4)}-${s.slice(4)}`);
  }
  return out;
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function normalizeRecovery(code: string): string {
  return code.toLowerCase().replace(/[^a-z0-9]/g, "");
}

export async function hashRecoveryCode(code: string, saltHex?: string): Promise<string> {
  const salt = saltHex ?? hex(crypto.getRandomValues(new Uint8Array(8)));
  const data = new TextEncoder().encode(`${salt}:${normalizeRecovery(code)}`);
  const digest = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", data)));
  return `${salt}$${digest}`;
}

/** Returns the index of the matching (unused) stored hash, or -1. */
export async function matchRecoveryCode(code: string, stored: string[]): Promise<number> {
  const norm = normalizeRecovery(code);
  if (norm.length !== 8) return -1;
  for (let i = 0; i < stored.length; i++) {
    const [salt] = stored[i].split("$");
    if (!salt) continue;
    if ((await hashRecoveryCode(norm, salt)) === stored[i]) return i;
  }
  return -1;
}
