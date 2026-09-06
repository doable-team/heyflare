# heyflare for iPhone — native

A native SwiftUI client for your heyflare server. Not a web view: every screen is drawn
by UIKit/SwiftUI, talks to the worker's JSON API directly, and holds no embedded browser
except the sandbox that renders a message body.

This lives beside [`apps/ios`](../ios), which is the Tauri/WKWebView wrapper. That one ships
the same web UI inside a shell. This one is a separate client against the same API.

## Why a second iOS app

The wrapper is the cheapest way to get heyflare onto a phone and it stays useful. But it
inherits the web build's costs: a JavaScript bundle to parse on every cold start, layout
driven by the DOM, scrolling that is never quite a `UIScrollView`, and gestures that fight
the page. This client exists where those costs are felt:

- **Cold start** draws the Imbox from the first frame, with no bundle to evaluate.
- **Scrolling** is a `LazyVStack` in a real scroll view, so rows are recycled by the system.
- **Swipes** are `DragGesture`s with a commit threshold and haptics, not touch handlers
  racing the page's own scrolling.
- **Avatars** are downsampled while decoding and cached in memory and on disk, so a long
  list never holds full-size bitmaps.
- **Images inside mail** stay inside a `WKWebView` with JavaScript off and a content
  security policy, because message HTML is untrusted and should stay boxed.

## Requirements

- macOS with Xcode 16 or newer (built and tested against Xcode 26).
- iOS 17.0 or newer on the device.
- A heyflare server you can reach over HTTPS.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to produce the project file:
  `brew install xcodegen`.

## Build

```sh
cd apps/ios-native
xcodegen generate          # writes Heyflare.xcodeproj from project.yml
open Heyflare.xcodeproj
```

Then pick a simulator or your iPhone and press Run.

From the command line:

```sh
# Simulator
xcodebuild -project Heyflare.xcodeproj -scheme Heyflare \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Device, signed with your own team
xcodebuild -project Heyflare.xcodeproj -scheme Heyflare \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM=YOURTEAMID build
```

`Heyflare.xcodeproj` is generated and git-ignored. Edit `project.yml` and regenerate rather
than changing build settings in Xcode, or your change will be lost on the next generate.

### Install on a connected iPhone

```sh
./install-device.sh
```

It checks for a signing identity, finds the connected device, builds and installs.
It needs an Apple ID signed into Xcode first — see below.

### Signing with a free Apple ID

Like the Tauri app, this builds with a free Apple ID and no paid developer account.

One-time setup, which nothing can do on your behalf because it needs your Apple ID and its
second factor:

1. **Xcode → Settings → Accounts**, press **+**, sign in with your Apple ID.
2. Select the account, **Manage Certificates**, **+**, **Apple Development**.

After that `./install-device.sh` works, or in Xcode select the **Heyflare** target,
**Signing & Capabilities**, tick *Automatically manage signing* and pick your personal
team. The bundle identifier has to be unique across Apple's systems, so if
`com.doable.heyflare` is refused, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to
something like `com.yourname.heyflare` and regenerate.

Free-provisioned builds expire after 7 days. Re-run from Xcode, or refresh over Wi-Fi with
SideStore or AltStore, exactly as described in [`apps/ios/README.md`](../ios/README.md).

## First run

The app asks for your server address, then signs you in with the same email and password
as the web app, including two-factor when it is switched on. The session is the worker's
own `hey_session` cookie, held by `URLSession` and never read by app code.

## What is here

| Area | Screens |
|---|---|
| Mail | Imbox with trays and bundles, thread reader, Feed, Paper Trail and every saved list, search, power through, create a calendar event from a thread |
| Triage | Screener cards, swipe right to select and left to mark read, bulk bar for Reply Later, Set Aside, bubble up, move and trash, labels |
| Compose | Full-screen composer, recipient chips with contact autocomplete, reply and forward, send later, undo send |
| Assistant | Conversation list (rename, delete) and streaming chat, with tool activity and drafts that open in the composer; provider, key, model and behaviour settings; memory you can read, correct and clear |
| Calendar | Month grid, day agenda with the day's name and cover photo, habits, journal, this week's loose tasks and a stopwatch |
| Library | Contacts, clips, collections, labels, drafts, scheduled |
| Settings | Mailbox scope and sync, connect a Gmail account, per-mailbox sync log, contact photos, start fresh and disconnect, custom domains and new mailboxes, password and two-factor, theme, remote-image blocking, sign out |

The five tabs are **Imbox · Assistant · Calendar · Screener · More**. The Feed gave up its
tab slot to the Assistant and the Paper Trail gave up its slot to the calendar, on the same
reasoning in reverse: the Feed is somewhere you go when you have time to read, while the
assistant is something you reach for in the middle of another task. Both are one tap away
under More. The web build's mobile tab bar was changed to match.

## Staying current

Every list refreshes itself when mail changes anywhere in the app. `MailBus` is one
revision counter — the phone's `invalidateMail` — bumped by every thread action, every
Screener decision, every send, and by reading a thread (which the worker marks seen).
Each list screen watches it with `syncsWithMail` and refetches when the counter moves
while it is showing, or on its way back on screen if it moved while covered. That is
what makes a thread read on its own page come back un-bold in the Imbox behind it
without a pull. A refresh is skipped while a selection is open and caught up when it
ends. The app also syncs every mailbox and bumps the bus when it returns to the
foreground, throttled to once every 30 seconds.

## Swipes and scrolling

Row swipes, the Screener's card throw and the calendar's month and day swipes all run on
`HorizontalPan`, a UIKit pan recogniser that only begins on sideways movement. A SwiftUI
`DragGesture` on a row inside a `ScrollView` steals vertical scrolling wherever a finger
lands on that row — with `.gesture`, `.simultaneousGesture` and `.highPriorityGesture`
alike — and under a button never engages at all, so the lists could not be scrolled by
dragging on a row and swipes landed as taps. The recogniser attaches to the enclosing
scroll view, filters to the row's own frame, and cancels the touches under it when it
begins, which is what stops the release from also being a tap.

## UI tour

`UITests/HeyflareUITests.swift` walks the app in the simulator — taps, real drags, typing —
and attaches a screenshot at every stop. It is how the swipe and scroll behaviour above was
found and verified; synthetic mouse events from outside the simulator arrive as taps. See
`UITests/README.md` to run it.

## Content cache

Every screen the app has drawn is kept, so it opens with last time's rows on the first
frame and corrects them when the request lands. A spinner appears only where there is
genuinely nothing to show. The cache is scoped per mailbox, capped at 32 MB with the
oldest entries pruned first, cleared on sign-out or a change of server, and clearable by
hand in Settings.

The session is treated the same way: a login that worked last time is assumed to still
work, so the app opens straight into the Imbox and validates behind the already-drawn
screen. Only a real 401 signs you out. The practical effect is that heyflare opens and is
readable with no network at all, with a banner saying the refresh failed.

## Layout

```
Sources/
  App/        entry point, root phase switch, tab shell, toasts
  Core/       models mirroring src/shared/types.ts, API client, app state, HTML handling, image cache
  Design/     grayscale tokens, type scale, row and bar primitives, swipe container
  Features/   one folder per surface
Resources/    Info.plist, asset catalog
```

`Core/Models.swift` mirrors `src/shared/types.ts` field for field. When the worker's
contract changes, that file and `Core/APIClient.swift` are the two places to update.

## Design

Follows [`DESIGN.md`](../../DESIGN.md): strictly grayscale, no colour carries meaning
anywhere, destructive actions are named rather than tinted, touch targets are at least
44pt, and the five tabs are Imbox, Assistant, Calendar, Screener, More.

The web build self-hosts Geist. This client uses SF Pro instead — it is the system face,
ships at every optical size, and costs nothing to load — with Geist's scale and weights, so
the two read the same.

## Notes and limits

- Push notifications are not wired up. The worker has no push endpoint, and APNs needs a
  paid developer account, so mail arrives when the app is opened or refreshed. The app
  syncs on foreground, throttled to once every 30 seconds.
- Attachments download through the session and hand off to the share sheet.
