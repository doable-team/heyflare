# heyflare for Mac

A native macOS shell for your heyflare server, built with Tauri 2 (Rust + WebKit — no Electron). ~10 MB, launches instantly,
and always shows the current web version because the app loads your server rather than bundling a copy.

What the shell adds on top of the web app: a real title bar with the traffic lights over the sidebar, a native menu bar with
Mac shortcuts (⌘1–9 to navigate, ⌘N compose, ⌘K search, ⌘J assistant, ⌘B sidebar, ⌘R reload, zoom), a dock badge for new
mail + Screener, system notifications for new mail while the window is in the background, external links opening in your
browser, remembered window size/position, persistent login, and auto-updates from GitHub Releases.

## Run / build

```sh
# once
curl -sSf https://sh.rustup.rs | sh        # Rust toolchain
xcode-select --install                     # Command Line Tools

cd apps/mac
npm install
npm run dev            # runs the app with a debug build
npm run build          # .app + .dmg under src-tauri/target/release/bundle/
npm run build:universal   # arm64 + x86_64 in one binary (needs `rustup target add x86_64-apple-darwin`)
```

Unsigned builds are ad-hoc signed; macOS will ask you to allow the app on first open (right-click → Open).

## Signing & notarizing (needs an Apple Developer account)

Set these before `npm run build`:

```sh
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_PASSWORD="app-specific-password"     # https://appleid.apple.com → App-Specific Passwords
export APPLE_TEAM_ID="TEAMID"
```

Tauri signs the bundle, submits it for notarization and staples the ticket.

## Auto-updates

The app checks `https://github.com/doable-team/heyflare/releases/latest/download/latest.json` (heyflare menu → Check for
Updates…). Release builds must be signed with the updater key:

```sh
export TAURI_SIGNING_PRIVATE_KEY="$(cat ~/.tauri/heyflare.key)"   # keep this file private; never commit it
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD=""                        # if you set one
npm run build
```

The public half of that key is in `src-tauri/tauri.conf.json` (`plugins.updater.pubkey`). The GitHub Actions workflow
`.github/workflows/mac.yml` builds the DMG and `latest.json` on every release when the `TAURI_SIGNING_PRIVATE_KEY`
(and optional Apple) secrets are configured.

## First launch

You'll be asked for your server address (e.g. `https://hey.far.hn`). heyflare menu → Switch Server… changes it later.
