/**
 * A calendar's colour is the one place colour enters this otherwise monochrome UI. It belongs to
 * the user's data, not to the chrome — and a week of forty grey events is unreadable. Events are
 * solid saturated fills with the text flipped to whichever of near-white or near-black actually
 * contrasts, the way HEY draws them.
 */
const DEFAULT_FILL = "#1f1f1f";

export function normalizeHex(hex: string | null | undefined): string | null {
  if (!hex) return null;
  const v = hex.trim();
  if (/^#[0-9a-fA-F]{6}$/.test(v)) return v.toLowerCase();
  if (/^#[0-9a-fA-F]{3}$/.test(v)) return `#${v[1]}${v[1]}${v[2]}${v[2]}${v[3]}${v[3]}`.toLowerCase();
  return null;
}

export function eventColors(hex: string | null | undefined): { background: string; color: string } {
  const background = normalizeHex(hex) ?? DEFAULT_FILL;
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(background.slice(i, i + 2), 16) / 255);
  const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  const L = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  // Contrast ratio against white is 1.05/(L+0.05); against black it is (L+0.05)/0.05.
  return { background, color: 1.05 / (L + 0.05) >= (L + 0.05) / 0.05 ? "#fbfbfa" : "#131313" };
}

/** The same fill at low opacity, for a tentative or declined event. */
export function softFill(hex: string | null | undefined): string {
  const c = normalizeHex(hex) ?? DEFAULT_FILL;
  return `${c}22`;
}
