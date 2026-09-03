# create-heyflare

Scaffold and deploy [heyflare](https://github.com/doable-team/heyflare) — a self-hosted, HEY-style email client with a
built-in AI agent, running on Cloudflare Workers + D1.

```sh
npm create heyflare@latest my-mail
```

The wizard copies the app into `my-mail`, installs dependencies, and offers a guided deploy: Wrangler login, a D1 database,
your Worker name and hostname (`*.workers.dev` or a custom domain), optional Google OAuth secrets, build and deploy.
Migrations are applied by the app itself on first request.

Later:

```sh
cd my-mail
npx create-heyflare deploy   # or: npm run deploy
```

Flags: `--yes` (defaults, no prompts), `--no-install`, `--no-deploy`. Env for non-interactive runs: `HEYFLARE_NAME`,
`HEYFLARE_HOST`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`.

Requires Node 20+ and a Cloudflare account. MIT.
