// Copies the heyflare app from the repo root into ./template so the published package always ships the current app.
import { execSync } from "node:child_process";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pkgDir = resolve(here, "..");
const root = resolve(pkgDir, "../..");
const out = join(pkgDir, "template");

const EXCLUDE_PREFIX = ["docs/", "packages/", "scripts/", ".github/"];
const EXCLUDE_EXACT = new Set(["DESIGN.md", "API.md", "wrangler.local.jsonc", ".dev.vars"]);

if (!existsSync(join(root, "wrangler.jsonc")) || !existsSync(join(root, "src/worker/index.ts"))) {
  console.error("sync-template: repo root not found at " + root);
  process.exit(1);
}
const tracked = execSync("git ls-files -z", { cwd: root }).toString().split("\0").filter(Boolean);
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
let n = 0;
for (const rel of tracked) {
  if (EXCLUDE_PREFIX.some((p) => rel.startsWith(p)) || EXCLUDE_EXACT.has(rel)) continue;
  if (rel.startsWith("dist/") || rel.startsWith(".wrangler/") || rel.startsWith("node_modules/")) continue;
  // npm strips .gitignore and package-lock.json from published packages; ship them under safe names.
  let dest = rel;
  if (rel === ".gitignore") dest = "_gitignore";
  if (rel === "package-lock.json") dest = "_package-lock.json";
  mkdirSync(dirname(join(out, dest)), { recursive: true });
  cpSync(join(root, rel), join(out, dest));
  n++;
}
// Rewrite package.json for a scaffolded project.
const pkg = JSON.parse(readFileSync(join(out, "package.json"), "utf8"));
pkg.name = "heyflare-app";
pkg.private = true;
delete pkg.scripts["deploy:mine"];
delete pkg.scripts["db:migrate:mine"];
delete pkg.scripts["db:migrate:mine:local"];
pkg.scripts.deploy = "npm run build && wrangler deploy -c wrangler.local.jsonc";
pkg.scripts["db:migrate"] = "wrangler d1 migrations apply DB --remote -c wrangler.local.jsonc";
pkg.scripts["db:migrate:local"] = "wrangler d1 migrations apply DB --local -c wrangler.local.jsonc";
pkg.scripts["dev:worker"] = "wrangler dev -c wrangler.local.jsonc";
writeFileSync(join(out, "package.json"), JSON.stringify(pkg, null, 2) + "\n");
// Version stamp so `create-heyflare` can tell users which app version they got.
const meta = { app_version: pkg.version, synced_at: new Date().toISOString(), commit: execSync("git rev-parse --short HEAD", { cwd: root }).toString().trim() };
writeFileSync(join(out, ".heyflare-template.json"), JSON.stringify(meta, null, 2) + "\n");
console.log(`sync-template: ${n} files → ${out} (app ${pkg.version} @ ${meta.commit})`);
