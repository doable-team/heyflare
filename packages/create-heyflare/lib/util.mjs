import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** Strip line and block comments from JSONC without touching strings (handles "https://…"). */
export function stripJsonc(text) {
  let out = "";
  let i = 0;
  let inStr = false;
  while (i < text.length) {
    const ch = text[i];
    const next = text[i + 1];
    if (inStr) {
      out += ch;
      if (ch === "\\") {
        out += next ?? "";
        i += 2;
        continue;
      }
      if (ch === '"') inStr = false;
      i++;
      continue;
    }
    if (ch === '"') {
      inStr = true;
      out += ch;
      i++;
      continue;
    }
    if (ch === "/" && next === "/") {
      while (i < text.length && text[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && next === "*") {
      i += 2;
      while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    out += ch;
    i++;
  }
  // tolerate trailing commas
  return out.replace(/,(\s*[}\]])/g, "$1");
}

export function readJsonc(path) {
  return JSON.parse(stripJsonc(readFileSync(path, "utf8")));
}

/** Command used to run wrangler; tests override it with a shim. */
export function wranglerCmd() {
  const override = process.env.HEYFLARE_WRANGLER;
  if (override) return override.split(" ");
  return ["npx", "--no-install", "wrangler"];
}

/**
 * Run a command. `capture: true` returns stdout/stderr (still echoing when `echo`), otherwise inherits the TTY.
 * `input` is piped to stdin (used for `wrangler secret put`).
 */
export function run(cmd, args, { cwd, capture = false, echo = false, input, env } = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: [input != null ? "pipe" : "inherit", capture ? "pipe" : "inherit", capture ? "pipe" : "inherit"],
      shell: process.platform === "win32",
    });
    let out = "";
    let err = "";
    if (capture) {
      child.stdout.on("data", (d) => {
        out += d;
        if (echo) process.stdout.write(d);
      });
      child.stderr.on("data", (d) => {
        err += d;
        if (echo) process.stderr.write(d);
      });
    }
    if (input != null) {
      child.stdin.write(input);
      child.stdin.end();
    }
    child.on("error", (e) => resolve({ code: 1, out, err: err + String(e) }));
    child.on("close", (code) => resolve({ code: code ?? 1, out, err }));
  });
}

export function hasLocalConfig(cwd) {
  return existsSync(join(cwd, "wrangler.local.jsonc"));
}

export function isHeyflareProject(cwd) {
  return existsSync(join(cwd, "wrangler.jsonc")) && existsSync(join(cwd, "src", "worker", "index.ts"));
}

export function slug(s) {
  return String(s)
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 54) || "heyflare";
}
