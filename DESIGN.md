# heyflare — Design System v3 ("Monochrome, shadcn")

Supersedes v2. The user wants: **shadcn/ui components, strict black & white, and a unified inbox across all
connected Gmail accounts.** Quality bar stays world-class: precise, quiet, fast, keyboard-first.

## 1. Foundations
- **Components**: shadcn/ui (radix base, "nova" preset) installed in `src/web/components/ui/*` with `cn()` in `src/web/lib/utils.ts`.
  Use them everywhere: Button, Input, Textarea, Label, Field, InputGroup, ButtonGroup, Badge, Avatar, Card, Dialog, AlertDialog,
  DropdownMenu, Popover, Tooltip, Sheet, Separator, ScrollArea, Skeleton, Switch, Select, Tabs, ToggleGroup, Toggle, Command,
  Sidebar (+ SidebarProvider/Inset/Menu…), Sonner (toasts), Checkbox, Calendar, Kbd, Empty, Spinner, Item, Table, Collapsible,
  HoverCard, Progress. Add more with `npx shadcn@latest add -y <name>` if needed. No hand-rolled primitives; the old `src/web/ui/`
  folder must be deleted when nothing imports it.
- **Color**: strictly grayscale. shadcn neutral variables only (`background`, `foreground`, `card`, `muted`, `muted-foreground`,
  `accent`, `border`, `input`, `ring`, `primary` = near-black on white / near-white on black, `secondary`, `sidebar-*`).
  Override `--destructive` to grayscale too (`oklch(0.205 0 0)` light / `oklch(0.922 0 0)` dark) — destructive actions are
  communicated with the word (Delete, Trash) and an AlertDialog, not red. Remove every colored token (accent teal, amber, indigo,
  rose, sky, note, cover gradient, avatar hue hash). Avatars: initials in `bg-foreground text-background` (unread/active) or
  `bg-muted text-foreground` (default). Account glyphs (unified inbox): each connected account gets a tiny monochrome mark —
  index 0 ● , 1 ■ , 2 ▲ , 3 ◆ , 4 ✦ — shown on rows when more than one account is connected.
- **Type**: Geist (self-hosted via `@fontsource-variable/geist`, already imported in index.css) for everything; Geist Mono for
  kbd/codes (add `@fontsource-variable/geist-mono` if available, else fall back to `ui-monospace`). Remove Fraunces and the
  Google Fonts link from `index.html`. Scale: 11 (caps labels, tracking .06em), 12, 13, 14 (default), 16, 20/600 (section),
  24/600 tracking -0.02em (page title), 30/600 tracking -0.025em (thread subject). Tabular nums on times/counts.
- **Shape**: shadcn defaults (`--radius: .625rem`), 1px borders, no colored shadows. Motion via `tw-animate-css` (already imported).
- **Dark mode**: shadcn's `.dark` class on `<html>` (update `AccountContext` to toggle the class from the theme setting; keep
  `prefers-color-scheme` when "system"). Both modes are pure grayscale.

## 2. Layout — shadcn Sidebar
- `SidebarProvider` + `Sidebar collapsible="icon"` + `SidebarInset`. Rail toggle with `⌘B` (SidebarTrigger) and the mobile sheet
  behavior comes for free.
- Sidebar header: wordmark **heyflare** (16px/600, tracking -0.02em) + an **account scope switcher** (DropdownMenu):
  "All accounts" (unified, default) and each connected account with its glyph, plus "Connect Gmail…". Selected scope shows under
  the wordmark as muted text. Scope id `all` is stored in `localStorage['hey.accountId']` and sent as `X-Account-Id: all`.
- Compose button (`Button` default variant, full width, with `Kbd` c).
- Groups (`SidebarGroup`/`SidebarGroupLabel`): (none) Imbox · The Feed · Paper Trail · Screener — with `SidebarMenuBadge` counts;
  "Trays": Reply Later · Set Aside · Bubble Up; "Library": Previously Seen · Contacts · Clips · Collections · Files · Labels · Drafts.
  Footer: Search (⌘K) · Settings · theme toggle · user (avatar + name, DropdownMenu with Keyboard shortcuts, Settings, Log out).
- Main (`SidebarInset`): a 48px sticky header bar with `SidebarTrigger`, breadcrumb-ish page title (14px/600), right side page
  actions; content column `max-w-3xl` (lists) / `max-w-2xl` (reading), padding 24px.
- Mobile: shadcn's sidebar sheet; bottom tab bar NOT needed (trigger in header is enough) — but keep everything usable at 375px.

## 3. Key components (in `src/web/components/`)
- `ThreadRow`: 56px, `grid-cols-[auto_1fr_auto]`; left: `Checkbox` (visible on hover/selected, otherwise the Avatar) ; middle:
  line 1 = sender (14/600 when unread, 14/500 otherwise) + account glyph (if >1 accounts) + "· 3" count; line 2 = subject
  (14) — snippet (13 muted) ; right: paperclip / shield icons (muted), time (12 tabular muted), and on hover a quick-action
  cluster (`Button variant="ghost" size="icon-sm"` with `Tooltip` + `Kbd`): Reply later, Set aside, Bubble up, Trash.
  Unread: a 6px `bg-foreground` dot before the sender. Selected: `bg-accent`. Keyboard cursor: `ring-1 ring-ring` inset.
  Labels: `Badge variant="outline"` (max 2). Note: sticky-note icon. Rows animate out with `animate-out fade-out slide-out-to-left-2`.
- `ThreadList`: same props as today (sections, selection, j/k/x/o/l/a/z/u/#, month headers as sticky caps labels).
- `BulkBar`: sticky `bg-background/80 backdrop-blur border-b` toolbar: "3 selected", then `ButtonGroup` of actions.
- `Piles` (Imbox bottom-right): two compact `Card`s side by side (Reply Later / Set Aside): count + 3 stacked mini rows; click →
  `Popover` list with a footer link. Hidden when empty.
- `CommandPalette`: shadcn `Command` in a `CommandDialog` (⌘K, ctrl+K, `/`): groups Jump to / Actions / Mail (search results).
- `ScreenerCard`: `Card` with avatar 48, name/email/domain `Badge`, message previews, why-`Badge`, `ToggleGroup` destination
  (Imbox / The Feed / Paper Trail), `Button` "Let them in" + `Button variant="outline"` "Screen out"; keys y/n/1/2/3.
- `MessageCard` (thread): `Card` per message, collapsible (Collapsible), header (avatar 32, name, email, to-line, time, ••• DropdownMenu),
  sanitized HTML in the auto-sizing sandboxed iframe (grayscale-safe: force `color-scheme` and body color), attachments as `Item`s,
  tracker `Badge variant="secondary"` ("Blocked 2 trackers · mailchimp.com"), quoted-text Collapsible.
- `ReplyBox` docked under the messages; `ComposeSheet` = `Sheet side="right"` 600px (full width mobile) with From `Select`
  (accounts — required for the unified inbox), To/Cc/Bcc chip inputs (`Badge` chips + `Command`-style autocomplete in a Popover),
  Subject, body (contenteditable), toolbar (`ToggleGroup`/`Button ghost`), attachments `Item`s, Send `ButtonGroup` (Send ▾ Send later
  with `Calendar` + time `Select` in a Popover), autosave text, Undo via Sonner toast with action.
- `DateTimePicker`: Popover with preset `Button variant="ghost"` list (Later today, Tomorrow morning, This weekend, Next week, In a
  month with resolved dates) + `Calendar` + time `Select`.
- `EmptyState`: shadcn `Empty` (+ `EmptyMedia` icon in a muted circle, `EmptyTitle`, `EmptyDescription`, action).
- Loading: `Skeleton` rows; errors: `Empty` with retry.

## 4. Unified inbox behavior (frontend)
- Default scope = **All accounts**. `AccountContext` exposes `scope: 'all' | accountId`, `accounts`, `account` (null in unified),
  `glyphFor(accountId)`, `accountFor(id)`. `api.ts` sends `X-Account-Id: all` in unified scope.
- Rows/cards show the account glyph + tooltip with the account email when more than one account is connected.
- Compose: From `Select` defaults to the first account (or the thread's account for replies); sends `account_id`.
- Screener: entries carry `account_id`; show the glyph. Contacts: rows show the glyph (same email may appear per account).
- Settings → Accounts lists each account; the sidebar switcher narrows scope.
- Onboarding with zero accounts: `Empty` card "Connect your Gmail" with the steps.

## 5. Page treatments (monochrome)
- Imbox: header "Imbox" 24/600 + scope label; screener notice as an `Item` with `Badge` count and arrow; sections "New for you" /
  "Previously seen" as 11px caps labels with counts; Piles bottom-right.
- The Feed: `Card`s, expanded body capped at 480px with a fade + "Read more"; footer buttons ghost.
- Paper Trail: compact 44px rows, sticky month labels.
- Screener: card grid (2 cols ≥ 1100px). Reply Later: one-at-a-time Focus & Reply with `Progress`. Set Aside: card grid.
- Thread: Back (`Button ghost` + Kbd esc), subject 30/600 with inline rename, participants `Avatar` group, `Badge`s (labels,
  collections), sticky note as a `Card` in `bg-muted` with a pin icon, messages, docked action bar (`ButtonGroup`s) centered in the
  main column, ReplyBox.
- Contacts (Table), Contact detail, Clips (Cards), Collections (Cards), Files (tiles), Labels (Table), Drafts, Settings (Tabs:
  Profile / Preferences / Accounts / Security), Login/Setup (centered `Card` on `bg-muted/40`, wordmark above; no split panel).
- Copy voice unchanged (casual, first person, short).

## 6. Checklist
No color anywhere (audit with a grep for `rose|amber|indigo|sky|accent-soft|teal|#[0-9a-f]{6}` in src/web); zero console errors;
375/768/1280/1920 clean; light + dark; keyboard complete; ⌘K works; unified + single scope both render.

## 7. Minimalism addendum — "like Notion" (overrides anything above that conflicts)
The user wants the app to feel like notion.so: quiet, text-first, almost no chrome.
- **Palette (light)**: page `#ffffff`; sidebar `#f7f7f5`; text `#37352f`; secondary text `rgba(55,53,47,.65)`; tertiary `rgba(55,53,47,.45)`;
  hover `rgba(55,53,47,.06)`; selected `rgba(55,53,47,.08)`; divider `rgba(55,53,47,.09)`; primary button = `#37352f` on white text (rarely used).
  **Dark**: page `#191919`; sidebar `#202020`; text `#d4d4d4`; secondary `rgba(255,255,255,.55)`; hover `rgba(255,255,255,.055)`; divider `rgba(255,255,255,.094)`.
  Map these onto the shadcn variables (`--background`, `--sidebar`, `--foreground`, `--muted-foreground`, `--accent`, `--border`, `--primary`…). Still strictly grayscale.
- **Radius**: `--radius: 0.375rem` (6px) everywhere; avatars 4px rounded squares (Notion-style), not circles.
- **Borders**: avoid them. Lists are rows separated by nothing (or a hairline divider only between sections); cards only where grouping is essential, and then as `bg-muted/40` panels without borders. Inputs are borderless with a `bg-muted` fill until focus. No shadows except on popovers/menus (`shadow-md`, hairline border).
- **Sidebar**: Notion-style: 14px items, 28px tall, 6px radius, icon 16px in secondary color, hover `accent`, active `accent` with text in `foreground`; group labels 12px/500 secondary; counts as plain secondary text (no badge pills); wordmark small 14px/600 with a 20px monochrome mark; collapsible via ⌘B with the double-chevron on hover.
- **Typography**: Geist 14px/1.5 default; headings are just bigger text (page title 28px/700, tracking -0.02em; section labels 12px/500 secondary; thread subject 24px/600). No caps-tracking labels except tiny secondary ones.
- **Buttons**: default is `variant="ghost"` size sm (text + icon); `variant="outline"` hairline for secondary; the filled primary only for Send / Let them in / Log in.
- **Rows**: 40–44px, no avatar by default in dense lists (Notion-like) — Imbox keeps a small 20px square avatar; hover shows the row background and the quick actions; unread = 600 weight + a 6px dot.
- **Empty states**: an icon in secondary color + one line of text + a ghost button. No illustrations.
- **Motion**: near none — 100ms hover, menus fade only.
- Auth pages: plain page, wordmark top-left, a 360px-wide form centered, no card.

## 8. Mobile — a tailor-made app UI (not a responsive desktop)
Below 768px the app renders a separate mobile UI (`src/web/mobile/`). It should feel like a native iOS/Android mail app in the
Notion visual language: same grayscale tokens, Geist, 6px radius, but layouts designed for thumbs.
- **MobileShell**: fixed top bar (44px + safe-area) with large title on list screens (28px/700, collapses to 17px/600 centered on
  scroll), left/right slots; fixed **bottom tab bar** (56px + `env(safe-area-inset-bottom)`): Imbox · Feed · Paper Trail · Screener
  (with count dot) · More. A **compose FAB** (48px, `bg-foreground text-background`, bottom-right above the tab bar) on list screens.
  Screens push/pop with a 200ms slide (thread from a list, contact from a thread); Back is a chevron in the top-left; also
  edge-swipe-right to go back. Account scope switcher lives in the top bar (tap the title → bottom sheet).
- **Sheets**: shadcn `Drawer` (vaul) for every menu/picker/date picker; grabber handle; large 48px rows; destructive rows at the end.
- **Rows** (`MobileThreadRow`, 64px): 36px square avatar (photo), sender 15px/600 (unread) or 15px/500, time 13px muted right; subject
  15px; snippet 14px muted, 1 line; unread dot; account glyph. **Swipe**: right → Reply later (reveal a muted panel with icon+label,
  commit at 96px with a short haptic-like scale), left → Set aside; long-press → selection mode with a bottom action bar
  (Reply later, Set aside, Bubble up, Move, Trash). Tap → thread. Pull-to-refresh on lists (native overscroll ok; add a spinner
  indicator that triggers `refetch`).
- **Imbox**: large title, scope subtitle, Screener banner card (avatars + count + chevron), "New for you" / "Previously seen"
  sections; **trays** as a horizontal row of two pile chips (stack visual + count) docked above the tab bar; tapping opens a sheet list.
- **Screener**: full-width cards, one per sender, big avatar 48, previews, destination `ToggleGroup` full-width, two 48px buttons
  (Screen out / Let them in); swipe the card right = let in (to the selected destination), left = screen out.
- **Feed**: cards full-bleed with the message body; sticky per-card footer actions. **Paper Trail**: dense 56px rows.
- **Thread**: full screen; title 22px/700; participants line; messages as stacked blocks (collapsed = 56px rows); bottom action bar
  (Reply · Reply later · Set aside · Bubble up · More) 56px above safe-area; reply opens the full-screen composer.
- **Composer**: full-screen modal (Sheet from bottom, 100dvh): top bar Cancel · "New message" · Send (bold); From row (tap → sheet),
  To/Cc/Bcc rows with chips, Subject, body; attachment + formatting bar above the keyboard (sticky bottom).
- **Reply Later / Set Aside / Bubble Up / Previously seen / Contacts / Clips / Collections / Files / Labels / Drafts / Settings**:
  reachable from **More** (a list screen with 48px rows + icons + counts), each with a mobile top bar; reuse desktop content where it
  already works on a narrow screen, but wrapped in the mobile shell (no desktop sidebar, no desktop header).
- Touch targets ≥ 44px; no hover-only affordances; `overscroll-behavior` and `touch-action` set so swipes don't fight scrolling;
  `100dvh` heights; `env(safe-area-inset-*)` padding; no horizontal overflow at 360px.

## 9. Calendar — time as a filmstrip

The calendar keeps the same monochrome rules as the mail side, with one deliberate exception: a
calendar's colour. It appears only as a 2px left border on an event, never as a fill, so a screen
full of meetings still reads as black on white.

**The day column** is the unit. Days run left to right and time runs down inside each of them, in a
single scroll container: the hour gutter is `sticky left`, the day headers are `sticky top`. Both
axes then behave correctly without synchronising two scrollers. Stacking runs corner `z-40`, day
headers `z-30`, gutter `z-[25]`, the now line `z-20`, event blocks `z-10`.

**The timeline is not a linear scale.** Night collapses to a 26px band you can click open, so the
hours you actually live in fill the screen. That makes the minute-to-pixel mapping piecewise across
three segments; `src/web/calendar/scale.ts` owns it, and every event, hour rule and now line reads
its `y()`. Nothing should compute a y offset any other way.

**Overlaps sit side by side, never stacked.** `layoutColumns` in `src/web/lib/caldate.ts` cuts
overlapping events into clusters and assigns each a column, so a double-booked hour shows both
halves rather than hiding one.

**Density.** 56px per hour, 11–12px type inside a block, 208px day columns in the filmstrip and
flexible columns in week view. An event under 34px tall drops to a single line with the time on the
right. Today's date sits in a filled circle; past days dim to about 82%; weekends take `bg-muted/30`.

**A day is more than its meetings.** The column header carries a cover image, an editable label,
the day's habits as tick-able pills, and the all-day banners, in that order — the personal part of
the day above the scheduled part.

Views: `days` (the filmstrip), `week`, `month`, `year` (all-day and multi-day items only, so a year
stays legible), `agenda`. Mobile gets its own month-plus-agenda screen and a full-screen day, not a
shrunken filmstrip — a strip of thumb-width columns does not work.
