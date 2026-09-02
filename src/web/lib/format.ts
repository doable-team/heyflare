// Timestamps from the API are treated as ms; values that look like seconds are upscaled.
export function toMs(n: number): number {
  return n < 1e12 ? n * 1000 : n;
}

const DAY = 86_400_000;

export function fmtTime(n: number): string {
  const d = new Date(toMs(n));
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  if (sameDay) return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const diff = now.getTime() - d.getTime();
  if (diff > 0 && diff < 6 * DAY) return d.toLocaleDateString([], { weekday: "short" });
  if (d.getFullYear() === now.getFullYear()) return d.toLocaleDateString([], { month: "short", day: "numeric" });
  return d.toLocaleDateString([], { month: "short", day: "numeric", year: "numeric" });
}

export function fmtFull(n: number): string {
  const d = new Date(toMs(n));
  return d.toLocaleString([], { month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit" });
}

export function fmtDate(n: number): string {
  return new Date(toMs(n)).toLocaleDateString([], { month: "short", day: "numeric", year: "numeric" });
}

export function fmtRelative(n: number): string {
  const diff = toMs(n) - Date.now();
  const abs = Math.abs(diff);
  const future = diff > 0;
  const units: [number, string][] = [
    [60_000, "minute"],
    [3_600_000, "hour"],
    [DAY, "day"],
    [7 * DAY, "week"],
    [30 * DAY, "month"],
  ];
  if (abs < 60_000) return future ? "in a moment" : "just now";
  let value = 0;
  let unit = "minute";
  for (let i = units.length - 1; i >= 0; i--) {
    if (abs >= units[i][0]) {
      value = Math.round(abs / units[i][0]);
      unit = units[i][1];
      break;
    }
  }
  const label = `${value} ${unit}${value === 1 ? "" : "s"}`;
  return future ? `in ${label}` : `${label} ago`;
}

export function monthKey(n: number): string {
  return new Date(toMs(n)).toLocaleDateString([], { month: "long", year: "numeric" });
}

export function fmtSize(bytes: number): string {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let i = 0;
  let v = bytes;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v < 10 && i > 0 ? v.toFixed(1) : Math.round(v)} ${units[i]}`;
}

export function initials(name: string, email: string): string {
  const src = (name || "").trim() || email.split("@")[0] || "?";
  const parts = src.replace(/[^a-zA-Z0-9 ._-]/g, "").split(/[\s._-]+/).filter(Boolean);
  if (parts.length === 0) return src.slice(0, 2).toUpperCase();
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

const PALETTE = ["#0f766e", "#7c3aed", "#db2777", "#ea580c", "#2563eb", "#059669", "#b45309", "#4f46e5", "#be123c", "#0891b2"];

export function avatarColor(email: string): string {
  let h = 0;
  for (let i = 0; i < email.length; i++) h = (h * 31 + email.charCodeAt(i)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

export function displayName(a: { name: string; email: string }): string {
  return a.name?.trim() || a.email;
}

export function toDatetimeLocal(ms: number): string {
  const d = new Date(ms);
  const pad = (x: number) => String(x).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

export function textToHtml(s: string): string {
  return escapeHtml(s).replace(/\r?\n/g, "<br>");
}

export function unsubscribeTarget(header: string): { url?: string; mailto?: string } {
  const out: { url?: string; mailto?: string } = {};
  const m = header.match(/<?(https?:\/\/[^>,\s]+)>?/i);
  if (m) out.url = m[1];
  const mm = header.match(/<?mailto:([^>,\s?]+)/i);
  if (mm) out.mailto = mm[1];
  return out;
}
