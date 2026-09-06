# heyflare for Mac

A native macOS client that draws the web app's design — the shadcn/Notion shell, Geist,
lucide icons, the same pages and shortcuts — with SwiftUI and AppKit. Nothing here loads
the web app; it is not the WebKit wrapper in `apps/mac`.

## How it is built

- **Shared core.** `project.yml` compiles `../ios-native/Sources/{Core,Stores,Design}`
  straight from the iOS tree: API client, models, the offline cache, `MailBus` freshness,
  every store, the undo-send queue. A fix to a store lands on both apps.
- **Web tokens, natively.** `Sources/Design/WebTheme.swift` carries `src/web/index.css`
  verbatim (light and dark palettes, radii); `Primitives.swift` is shadcn's Button, Badge,
  Kbd, Input, Switch, Checkbox, ToggleGroup, Avatar at the same sizes; `Overlays.swift`
  draws popovers, dropdown menus, dialogs, the right-hand sheet and sonner-style toasts
  inside the window so they look like radix's, not AppKit's.
- **Geist.** `Resources/Fonts` bundles the variable TTFs; `Geist.font(size:weight:)` sets
  the weight axis. The message web view embeds the woff2 files so mail reads in Geist too.
- **lucide.** `Sources/Design/LucideData.swift` is generated from `node_modules/lucide-react`
  (every icon the web imports) and drawn by a small SVG path parser (`SVGPath.swift`).
  Regenerate after adding icons to the web: `node apps/mac-native/Scripts/gen-lucide.mjs` from the repo root.
- **Pages.** One content column, like the web: `Sources/Pages/*` mirror `src/web/pages/*`
  one-to-one (Imbox with piles, Feed cards, Screener cards, Focus & Reply, Set Aside board,
  Bubble Up, Power Through, thread page with the docked action bar, contacts, clips,
  collections, files, labels, drafts, settings with all seven tabs, calendar).
- **Keys.** `Sources/App/Keys.swift` is `useKeys`: single keys unless typing; `⌘` goes to the
  menu bar. `Router.swift` is the browser history (Back/esc).

## Build and run

```sh
brew install xcodegen          # once
cd apps/mac-native
xcodegen generate              # rerun after adding or removing Swift files
xcodebuild -project HeyflareMac.xcodeproj -scheme HeyflareMac -configuration Release build
```

The app lands under DerivedData (`xcodebuild -showBuildSettings | grep BUILT_PRODUCTS_DIR`).
It is sandboxed with outgoing network only. `DEVELOPMENT_TEAM` is empty in `project.yml`;
set it to run on another Mac.

Local worker: `npx wrangler dev --port 8787 --local` in the repo root, then type
`localhost:8787` on the first screen.

## The tour

Debug builds can walk every page and write a PNG per stop, without screen-recording
permission:

```sh
S=~/Library/Containers/com.doable.heyflare.mac/Data/tmp/tour   # must be inside the sandbox
HEY_TOUR_DIR=$S HEY_TOUR_SERVER=http://localhost:8787 HEY_TOUR_EMAIL=owner@example.com HEY_TOUR_PASSWORD=… \
  …/Debug/heyflare.app/Contents/MacOS/heyflare
```

Web views draw out of process and come out blank in these shots; everything else is what a
person sees.

## Known gaps against the web

Journal and Habits pages; the calendar's horizontal day ribbon and year heat-map (the Mac
draws a week stack, a single day column and a plain year grid); calendar subscriptions in
Settings; thread merge/labels/collections menus are present but simpler; drag-and-drop of
events. All exist on the web and can be ported the same way.

## A note on windows

AppKit's state restoration keys SwiftUI windows by the root view's *type*. When that type
changes between builds, restoration fails and SwiftUI opens no window at all, on this
machine permanently. So the window is hosted by `AppDelegate` in an `NSWindow` with an
`NSHostingView`, marked non-restorable, and the SwiftUI scene only supplies the menu bar.
