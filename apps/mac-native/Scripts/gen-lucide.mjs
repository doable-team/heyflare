// Generates Sources/Design/LucideData.swift from the lucide icons the web imports.
// Run from the repo root: node apps/mac-native/Scripts/gen-lucide.mjs
import fs from "node:fs";
import path from "node:path";
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../..");
process.chdir(root);
function walk(dir, out = []) { for (const e of fs.readdirSync(dir, { withFileTypes: true })) { const p = path.join(dir, e.name); if (e.isDirectory()) walk(p, out); else if (/\.tsx?$/.test(e.name)) out.push(p); } return out; }
const names = [];
for (const f of walk("src/web")) {
  for (const m of fs.readFileSync(f, "utf8").matchAll(/import \{([^}]+)\} from "lucide-react"/g)) {
    for (const raw of m[1].split(",")) { const n = raw.trim().replace(/ as .*$/, ""); if (n) names.push(n); }
  }
}
// extra icons the Mac shell uses
names.push("PanelLeft", "ArrowUp", "Square", "Loader2", "Check", "ChevronsUpDown", "CircleCheck", "Info", "OctagonX", "TriangleAlert", "Mail", "MailOpen", "Copy", "ChevronUp", "SkipForward", "Receipt", "UserRound", "ArrowUpRight", "GitMerge", "Ungroup", "Layers", "SquarePen", "MessageSquare", "MessagesSquare", "Presentation", "FileSpreadsheet", "Film", "Music", "FileImage", "FileArchive", "File", "Pin", "Pencil", "ScrollText", "CalendarPlus", "CalendarClock", "Sparkles", "Bold", "Italic", "Underline", "Link2", "List", "ListOrdered", "Quote", "RemoveFormatting", "Paperclip", "Send", "X", "Trash2", "Download", "Search", "Settings", "Settings2", "Keyboard", "LogOut", "Monitor", "Moon", "Sun", "Plus", "Minus", "Eye", "EyeOff", "RefreshCw", "Globe", "KeyRound", "ShieldCheck", "SlidersHorizontal", "User", "Unplug", "Zap", "NotebookPen", "Repeat", "BookOpen", "Coffee", "Sunrise", "Circle", "Dot");
const dir = "node_modules/lucide-react/dist/esm/icons";
const ALIAS = { AlertTriangle: "TriangleAlert", ArrowUpCircle: "CircleArrowUp", CheckCircle2: "CircleCheck", Loader2: "LoaderCircle", MoreHorizontal: "Ellipsis", PenSquare: "SquarePen", CalendarX2: "CalendarX2", Link2: "Link2", Trash2: "Trash2", Settings2: "Settings2", Heading2: "Heading2" };
const kebab = (raw) => { let s = ALIAS[raw] ?? raw.replace(/Icon$/, ""); s = ALIAS[s] ?? s; return s.replace(/([a-z])([A-Z0-9])/g, "$1-$2").replace(/([A-Z])([A-Z][a-z])/g, "$1-$2").replace(/([0-9])([A-Z])/g, "$1-$2").toLowerCase(); };
const num = (v) => String(Number(v));
function toPath(tag, a) {
  switch (tag) {
    case "path": return a.d;
    case "circle": { const cx = +a.cx, cy = +a.cy, r = +a.r; return `M${cx - r} ${cy}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0`; }
    case "ellipse": { const cx = +a.cx, cy = +a.cy, rx = +a.rx, ry = +a.ry; return `M${cx - rx} ${cy}a${rx} ${ry} 0 1 0 ${2 * rx} 0a${rx} ${ry} 0 1 0 ${-2 * rx} 0`; }
    case "rect": { const x = +a.x, y = +a.y, w = +a.width, h = +a.height, rx = +(a.rx ?? 0), ry = +(a.ry ?? a.rx ?? 0);
      if (!rx) return `M${x} ${y}h${w}v${h}h${-w}z`;
      return `M${x + rx} ${y}h${w - 2 * rx}a${rx} ${ry} 0 0 1 ${rx} ${ry}v${h - 2 * ry}a${rx} ${ry} 0 0 1 ${-rx} ${ry}h${-(w - 2 * rx)}a${rx} ${ry} 0 0 1 ${-rx} ${-ry}v${-(h - 2 * ry)}a${rx} ${ry} 0 0 1 ${rx} ${-ry}z`; }
    case "line": return `M${num(a.x1)} ${num(a.y1)}L${num(a.x2)} ${num(a.y2)}`;
    case "polyline": { const p = a.points.trim().split(/[\s,]+/).map(Number); let s = `M${p[0]} ${p[1]}`; for (let i = 2; i < p.length; i += 2) s += `L${p[i]} ${p[i + 1]}`; return s; }
    case "polygon": { const p = a.points.trim().split(/[\s,]+/).map(Number); let s = `M${p[0]} ${p[1]}`; for (let i = 2; i < p.length; i += 2) s += `L${p[i]} ${p[i + 1]}`; return s + "z"; }
    default: throw new Error("unknown tag " + tag);
  }
}
const out = [];
const missing = [];
for (const n of [...new Set(names)]) {
  const file = path.join(dir, kebab(n) + ".js");
  if (!fs.existsSync(file)) { missing.push(n); continue; }
  const src = fs.readFileSync(file, "utf8");
  const m = src.match(/createLucideIcon\("[^"]+",\s*(\[[\s\S]*?\])\s*\);/);
  if (!m) { missing.push(n); continue; }
  // The array literal is valid JS: unquoted keys, strings. Evaluate it.
  const arr = new Function("return " + m[1])();
  // A leading relative moveto is absolute by the SVG spec, but the implicit pairs after it
  // stay relative linetos — so spell that out before the element paths are joined.
  const absStart = (d) => d.replace(/^\s*m\s*(-?[\d.]+(?:e-?\d+)?)[\s,]*(-?[\d.]+(?:e-?\d+)?)\s*/, (m, x, y, off, str) => `M${x} ${y}` + (/^[-\d.]/.test(str.slice(off + m.length)) ? " l" : " "));
  const paths = arr.map(([tag, attrs]) => absStart(toPath(tag, attrs)));
  const camel = n[0].toLowerCase() + n.slice(1);
  out.push(`    "${camel}": ${JSON.stringify(paths.join(" "))},`);
}
const swift = `// Generated from lucide-react ${JSON.parse(fs.readFileSync("node_modules/lucide-react/package.json")).version} — do not edit.
// Each icon is one SVG path string in a 24×24 box, drawn with a 2pt round stroke.

enum LucideData {
    static let paths: [String: String] = [
${out.join("\n")}
    ]
}
`;
fs.writeFileSync("apps/mac-native/Sources/Design/LucideData.swift", swift);
console.log("icons:", out.length, "missing:", missing.join(","));
