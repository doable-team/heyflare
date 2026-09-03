// Offline checks: scaffold into a temp dir and run the deploy flow against a fake wrangler shim.
import { execSync, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pkg = resolve(here, "..");
const tmp = mkdtempSync(join(tmpdir(), "hf-test-"));
const proj = join(tmp, "my-mail");
const shimDir = join(tmp, "shim");
let failed = false;
const assert = (cond, msg) => {
  if (!cond) {
    failed = true;
    console.error("✗ " + msg);
  } else console.log("✓ " + msg);
};
try {
  // 1. scaffold without install/deploy
  const r1 = spawnSync(process.execPath, [join(pkg, "bin.mjs"), proj, "--yes", "--no-install", "--no-deploy"], { encoding: "utf8" });
  assert(r1.status === 0, "scaffold exits 0" + (r1.status ? "\n" + r1.stdout + r1.stderr : ""));
  assert(existsSync(join(proj, ".gitignore")), "_gitignore renamed to .gitignore");
  assert(existsSync(join(proj, "package-lock.json")), "_package-lock.json renamed to package-lock.json");
  assert(existsSync(join(proj, "src/worker/index.ts")) && existsSync(join(proj, "migrations/0001_init.sql")), "app files copied");
  const pj = JSON.parse(readFileSync(join(proj, "package.json"), "utf8"));
  assert(pj.name === "heyflare-app" && /wrangler\.local\.jsonc/.test(pj.scripts.deploy), "package.json rewritten for the scaffolded project");
  assert(!existsSync(join(proj, "docs")) && !existsSync(join(proj, "packages")) && !existsSync(join(proj, "wrangler.local.jsonc")), "excluded files not copied");

  // 2. deploy flow against a fake wrangler
  const shim = join(shimDir, "wrangler");
  execSync(`mkdir -p ${shimDir}`);
  writeFileSync(
    shim,
    `#!/bin/sh
cmd="$1"; shift
log="${tmp}/shim.log"
echo "wrangler $cmd $*" >> "$log"
case "$cmd" in
  whoami) echo "You are logged in with an OAuth Token, associated with the email test@example.com."; ;;
  d1) echo '{ "d1_databases": [ { "binding": "DB", "database_name": "my-mail-db", "database_id": "11111111-2222-4333-8444-555555555555" } ] }'; ;;
  deploy) echo "Uploaded my-mail (1.00 sec)"; echo "https://my-mail.test-user.workers.dev"; ;;
  secret) cat > "${tmp}/secret_$2.txt"; echo "Success! Uploaded secret $2"; ;;
  *) echo "unknown $cmd" >&2; exit 1; ;;
esac
`
  );
  chmodSync(shim, 0o755);
  // fake build so the test doesn't need node_modules in the scaffolded project
  writeFileSync(join(proj, "package.json"), JSON.stringify({ ...pj, scripts: { ...pj.scripts, build: "node -e \"require('fs').mkdirSync('dist',{recursive:true})\"" } }, null, 2));
  const r2 = spawnSync(process.execPath, [join(pkg, "bin.mjs"), "deploy", "--yes"], {
    cwd: proj,
    encoding: "utf8",
    env: { ...process.env, HEYFLARE_WRANGLER: shim, HEYFLARE_HOST: "mail.example.com", GOOGLE_CLIENT_ID: "id-123", GOOGLE_CLIENT_SECRET: "sec-456", CI: "1" },
  });
  assert(r2.status === 0, "deploy flow exits 0" + (r2.status ? "\n" + r2.stdout + r2.stderr : ""));
  const cfg = JSON.parse(readFileSync(join(proj, "wrangler.local.jsonc"), "utf8").replace(/^\/\/.*$/m, ""));
  assert(cfg.name === "my-mail" && cfg.d1_databases[0].database_id === "11111111-2222-4333-8444-555555555555", "wrangler.local.jsonc has name + D1 id");
  assert(cfg.routes?.[0]?.pattern === "mail.example.com" && cfg.vars.APP_URL === "https://mail.example.com", "custom domain written as route + APP_URL");
  assert(cfg.rules?.[0]?.type === "Text" && cfg.assets?.directory === "./dist", "template settings carried over");
  const log = readFileSync(join(tmp, "shim.log"), "utf8");
  assert(/wrangler d1 create my-mail-db/.test(log) && /wrangler deploy -c wrangler.local.jsonc/.test(log), "d1 create then deploy called");
  assert(log.indexOf("wrangler deploy") < log.indexOf("wrangler secret put"), "secrets are set after the first deploy");
  assert(readFileSync(join(tmp, "secret_GOOGLE_CLIENT_ID.txt"), "utf8").trim() === "id-123" && readFileSync(join(tmp, "secret_GOOGLE_CLIENT_SECRET.txt"), "utf8").trim() === "sec-456", "secrets piped via stdin");
  assert(/https:\/\/mail\.example\.com/.test(r2.stdout), "final note shows the URL");
  // 3. idempotent re-run reuses config (no second d1 create)
  const r3 = spawnSync(process.execPath, [join(pkg, "bin.mjs"), "deploy", "--yes"], { cwd: proj, encoding: "utf8", env: { ...process.env, HEYFLARE_WRANGLER: shim, CI: "1" } });
  const log2 = readFileSync(join(tmp, "shim.log"), "utf8");
  assert(r3.status === 0 && (log2.match(/d1 create/g) || []).length === 1, "re-run reuses wrangler.local.jsonc (no new database)");
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
if (failed) process.exit(1);
console.log("all checks passed");
