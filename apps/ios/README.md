# heyflare for iPhone and iPad

A native iOS app: a real Swift/WKWebView shell built with [Tauri 2](https://v2.tauri.app), not a
progressive web app. It stores which heyflare server to open, keeps the session in the app's own
cookie jar, posts system notifications, and hands every link that leaves your server to Safari.

The web app already ships a hand-built mobile UI, so the shell stays small on purpose. The whole
Rust side is one file: [`src-tauri/src/lib.rs`](src-tauri/src/lib.rs).

## What you need

| | |
|---|---|
| macOS | 13 or newer |
| Xcode | 15 or newer, the full app from the App Store — command-line tools alone cannot build for iOS |
| Rust | with the iOS targets: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios` |
| CocoaPods | `brew install cocoapods` |
| Apple ID | a free one is enough, see below |

After installing Xcode, point the toolchain at it once:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
```

## Build and run

```sh
cd apps/ios
npm install
npm run ios:init      # generates src-tauri/gen/apple (the Xcode project) — run once
npm run dev           # build and launch on a simulator or a connected iPhone
```

`npm run dev` lists the available devices. A simulator needs no Apple ID at all; a physical iPhone
needs signing, which is the next section.

To build a release app and open the project in Xcode:

```sh
npm run build
npm run open
```

The generated Xcode project lives in `src-tauri/gen/apple` and is not committed. Delete it and
re-run `npm run ios:init` whenever you change the icons or the bundle identifier.

## Installing on your own iPhone with a free Apple ID

You do not need the paid Apple Developer Program to run this on your own device. A free Apple ID
issues a personal development certificate, with three limits:

- **The app expires after 7 days** and has to be reinstalled or refreshed.
- **Three apps at a time** may be signed with one free Apple ID.
- **Ten devices per week** may be registered.

Push notifications and app groups need a paid account. heyflare uses local notifications only, so
nothing here depends on that.

### One-time setup

1. Open Xcode, go to **Settings → Accounts**, and add your Apple ID.
2. Run `npm run ios:init`, then `npm run open`.
3. In Xcode select the **heyflare_iOS** target → **Signing & Capabilities** → tick *Automatically
   manage signing* and pick your Personal Team. Xcode creates the provisioning profile.
4. Change the bundle identifier if `team.doable.heyflare` is taken on your account. Set the same
   value in `src-tauri/tauri.conf.json` under `identifier` so the two stay in step.
5. Plug in your iPhone, select it as the run destination, and press ▶.
6. On the phone: **Settings → General → VPN & Device Management** → trust your developer
   certificate. The app will not launch until you do.

### Keeping it installed past 7 days

Re-running `npm run dev` with the phone connected re-signs and reinstalls it, which resets the
clock. If you would rather not keep a Mac around, either of these refreshes the signature over
Wi-Fi from the phone itself:

- **[SideStore](https://sidestore.io)** — installs from your phone and refreshes in the background
  over a local WireGuard tunnel, so it does not need the Mac after setup. Install the `.ipa` that
  `npm run build` produces (`src-tauri/gen/apple/build/*/heyflare.ipa`).
- **[AltStore](https://altstore.io)** — the original; refreshes whenever the phone is on the same
  network as a Mac or PC running AltServer.

Both use your own free Apple ID and the same personal certificate Xcode would use. Neither removes
the 7-day limit; they automate the renewal so you never see it. Note that they consume one of your
three free app slots for the store itself.

Signing up for the paid Apple Developer Program ($99/year) raises the expiry to a year and lifts the
three-app limit, but nothing about the app requires it.

## Notes

- The server address is stored in the app's data directory. **Settings → Sign out** in the web app
  logs you out; to point the app at a different server, reinstall or clear the app's data.
- Notifications ask for permission on first launch. Denying it costs you nothing else.
- There is no in-app updater. Rebuild from source, or refresh with SideStore or AltStore.
- The Mac app lives in [`../mac`](../mac) and shares this web app.
