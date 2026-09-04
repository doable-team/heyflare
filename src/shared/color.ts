/**
 * Calendar colours, toned down.
 *
 * Google hands back its own palette, which is built for a white grid with dark text on pale chips —
 * `#9fe1e7`, `#cd74e6`, `#9a9cff`. heyflare fills the whole block and puts light text on it, and in
 * a monochrome UI those pastels shout. Muting pins every imported colour into one band: enough hue
 * to tell calendars apart, dark enough to carry white text, quiet enough to sit in a grey app.
 */
const SAT = 0.34;
const LIGHT = 0.4;

export function normalizeHex(hex: string | null | undefined): string | null {
  if (!hex) return null;
  const v = hex.trim();
  if (/^#[0-9a-fA-F]{6}$/.test(v)) return v.toLowerCase();
  if (/^#[0-9a-fA-F]{3}$/.test(v)) return `#${v[1]}${v[1]}${v[2]}${v[2]}${v[3]}${v[3]}`.toLowerCase();
  return null;
}

function toHsl(hex: string): [number, number, number] {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  if (d === 0) return [0, 0, l];
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h: number;
  if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
  else if (max === g) h = ((b - r) / d + 2) / 6;
  else h = ((r - g) / d + 4) / 6;
  return [h, s, l];
}

function toHex(h: number, s: number, l: number): string {
  const f = (n: number) => {
    const k = (n + h * 12) % 12;
    const a = s * Math.min(l, 1 - l);
    const v = l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    return Math.round(255 * v)
      .toString(16)
      .padStart(2, "0");
  };
  return `#${f(0)}${f(8)}${f(4)}`;
}

/** Same hue, pinned to a muted saturation and a mid-dark lightness. Greys stay grey. */
export function muteHex(hex: string | null | undefined): string | null {
  const v = normalizeHex(hex);
  if (!v) return null;
  const [h, s, l] = toHsl(v);
  // A colour with almost no hue is a deliberate grey; keep it, just settle its lightness.
  if (s < 0.08) return toHex(h, 0, Math.min(Math.max(l, 0.1), 0.72));
  return toHex(h, SAT, LIGHT);
}
