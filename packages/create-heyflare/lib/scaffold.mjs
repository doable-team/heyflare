import { cpSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const TEMPLATE_DIR = resolve(here, "..", "template");

const RENAMES = { _gitignore: ".gitignore", "_package-lock.json": "package-lock.json" };

export function templateAvailable() {
  return existsSync(join(TEMPLATE_DIR, "package.json"));
}

export function dirIsEmpty(dir) {
  if (!existsSync(dir)) return true;
  return readdirSync(dir).filter((f) => f !== ".DS_Store").length === 0;
}

/** Copy the template into `target`, applying the dotfile renames. */
export function scaffold(target) {
  mkdirSync(target, { recursive: true });
  cpSync(TEMPLATE_DIR, target, { recursive: true });
  for (const [from, to] of Object.entries(RENAMES)) {
    const f = join(target, from);
    if (existsSync(f)) {
      rmSync(join(target, to), { force: true });
      renameSync(f, join(target, to));
    }
  }
  rmSync(join(target, ".heyflare-template.json"), { force: true });
}
