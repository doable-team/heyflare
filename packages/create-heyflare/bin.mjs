#!/usr/bin/env node
import * as p from "@clack/prompts";
import pc from "picocolors";
import { basename, resolve } from "node:path";
import { dirIsEmpty, scaffold, templateAvailable } from "./lib/scaffold.mjs";
import { deploy } from "./lib/deploy.mjs";
import { run, slug } from "./lib/util.mjs";

const argv = process.argv.slice(2);
const flags = new Set(argv.filter((a) => a.startsWith("--")));
const positional = argv.filter((a) => !a.startsWith("--"));
const yes = flags.has("--yes") || flags.has("-y");

if (flags.has("--help") || flags.has("-h")) {
  console.log(`create-heyflare

  npm create heyflare@latest [dir]     scaffold a new heyflare project (then optionally deploy)
  npx create-heyflare deploy           guided Cloudflare deploy for the project in the current folder

  --yes         accept defaults, no prompts
  --no-install  skip npm install
  --no-deploy   skip the deploy step
`);
  process.exit(0);
}

function guard(v) {
  if (p.isCancel(v)) {
    p.cancel("Cancelled.");
    process.exit(1);
  }
  return v;
}

if (positional[0] === "deploy") {
  await deploy({ cwd: process.cwd(), yes });
  process.exit(0);
}

p.intro(pc.bgWhite(pc.black(" create-heyflare ")));
if (!templateAvailable()) {
  p.cancel("Template missing from this package build. Please reinstall create-heyflare.");
  process.exit(1);
}
let dir = positional[0];
if (!dir) dir = yes ? "heyflare" : String(guard(await p.text({ message: "Where should we create your heyflare?", initialValue: "heyflare", placeholder: "heyflare" }))).trim();
const target = resolve(process.cwd(), dir);
if (!dirIsEmpty(target)) {
  if (yes) {
    p.cancel(`${dir} is not empty.`);
    process.exit(1);
  }
  const ok = guard(await p.confirm({ message: `${dir} is not empty. Continue and overwrite files?`, initialValue: false }));
  if (!ok) process.exit(1);
}
scaffold(target);
p.log.success(`Created ${pc.bold(basename(target))} (worker name ${pc.dim(slug(basename(target)))})`);

if (!flags.has("--no-install")) {
  const s = p.spinner();
  s.start("Installing dependencies (this takes a minute)");
  const r = await run(process.platform === "win32" ? "npm.cmd" : "npm", ["install", "--no-audit", "--no-fund", "--loglevel=error"], { cwd: target, capture: true });
  if (r.code !== 0) {
    s.stop("npm install failed");
    console.error((r.out + r.err).slice(-1500));
    process.exit(1);
  }
  s.stop("Dependencies installed");
}

let doDeploy = false;
if (!flags.has("--no-deploy")) {
  doDeploy = yes ? true : guard(await p.confirm({ message: "Deploy to Cloudflare now?", initialValue: true }));
}
if (doDeploy) {
  await deploy({ cwd: target, yes });
} else {
  p.note([`cd ${dir}`, "npx create-heyflare deploy     # guided Cloudflare deploy", "", "or for local dev:", "cp .dev.vars.example .dev.vars", "npm run dev:worker & npm run dev"].join("\n"), "Next steps");
  p.outro("Done.");
}
