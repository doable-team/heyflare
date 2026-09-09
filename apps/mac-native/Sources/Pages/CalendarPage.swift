import SwiftUI
import AppKit

/// `Calendar.tsx` + `CalendarContext.tsx`: the toolbar, then the week stack, the day ribbon or
/// the year, over one shared `CalendarStore`. The context's state — cursor, view, the loaded
/// window, `reveal`, the visible month — lives here, exactly as the provider keeps it.
struct CalendarPage: View {
    /// `?d=YYYY-MM-DD`: the day to open on. Nil lands on today and asks to be shown it.
    var initialDate: String? = nil

    @Environment(UIState.self) private var ui
    @Environment(SheetState.self) private var sheet
    @Environment(DialogState.self) private var dialogs
    @Environment(PopLayerState.self) private var pops
    @Environment(Router.self) private var router
    @State private var store = CalendarStore()
    @State private var view = "week"
    @State private var viewChosen = false
    @State private var cursor: String
    @State private var win: CalWindow
    @State private var revealAt: RevealAt
    @State private var visibleMonth: String

    init(initialDate: String? = nil) {
        self.initialDate = initialDate
        let valid = initialDate.flatMap { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? $0 : nil }
        let start = valid ?? CalDate.todayKey
        _cursor = State(initialValue: start)
        _win = State(initialValue: CalendarPage.windowFor("week", start, CalDate.cal))
        _revealAt = State(initialValue: RevealAt(date: start, nonce: 0))
        _visibleMonth = State(initialValue: String(start.prefix(7)))
    }

    private var cal: Calendar { store.calendar }
    private var today: String { CalDate.todayKey }
    private var overlayOpen: Bool { sheet.isOpen || dialogs.isOpen }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            switch view {
            case "year":
                YearView(store: store, cursor: cursor, revealAt: revealAt, onPick: { setCursor($0); setView("days") }, onEvent: edit)
            case "days":
                DayRibbonView(store: store, cursor: cursor, revealAt: revealAt, onEvent: edit, onCreate: createSpan,
                              onVisibleMonth: { m in DispatchQueue.main.async { if visibleMonth != m { visibleMonth = m } } })
            default:
                // The scroll callbacks can fire from inside AppKit's layout; the state they set
                // waits for the next turn of the loop, as a browser's scroll event would.
                WeekStack(store: store, cursor: cursor, win: win, revealAt: revealAt, onEvent: edit, onCreate: createSpan, onSetCursor: setCursor,
                          onExtend: { side, days in DispatchQueue.main.async { extend(side, days) } },
                          onVisibleMonth: { m in DispatchQueue.main.async { if visibleMonth != m { visibleMonth = m } } }, onRefresh: refresh)
            }
        }
        .task {
            await store.loadPrefs()
            // `CalendarContext.tsx`: the saved default view applies until a view is picked.
            if !viewChosen, ["days", "week", "year"].contains(store.prefs.defaultView) { view = store.prefs.defaultView }
            win = Self.windowFor(view, cursor, cal)
            // Opening the calendar lands on today — asked to be *shown* it, since the cursor is
            // already there. A URL that names a date is left alone.
            if initialDate == nil { reveal(today) }
            await store.ensureRange(fromKey: win.from, toKey: win.to)
            // "Create event" on an email lands here with a prefill; consumed once.
            if let draft = ui.pendingEvent { ui.pendingEvent = nil; create(day: draft.dayKey, start: draft.startMinutes, end: draft.endMinutes, draft: draft) }
        }
        .onChange(of: view) { _, _ in win = Self.windowFor(view, cursor, cal) }
        .onChange(of: store.prefs.weekStart) { _, _ in win = Self.windowFor(view, cursor, cal) }
        .onChange(of: String(cursor.prefix(4))) { _, _ in if view == "year" { win = Self.windowFor(view, cursor, cal) } }
        .onChange(of: win) { _, w in Task { await store.ensureRange(fromKey: w.from, toKey: w.to) } }
        .onChange(of: CalendarBus.shared.revision) { _, _ in Task { await refresh() } }
        // ↑ ↓ and Page Up/Down are the only keys the sidebar also wants, so they alone check
        // where focus is; the rest work from any region.
        .onKeys([
            "ArrowUp": { setCursor(step(-1)) }, "ArrowDown": { setCursor(step(1)) },
            "PageUp": { setCursor(CalDate.addingDays(-7, toKey: cursor, in: cal)) }, "PageDown": { setCursor(CalDate.addingDays(7, toKey: cursor, in: cal)) },
        ], enabled: !overlayOpen && ui.region == .content)
        .onKeys([
            "t": { reveal(today) }, "d": { setView("days") }, "w": { setView("week") }, "y": { setView("year") },
            "n": { create(day: cursor, start: 9 * 60, end: 10 * 60) },
            "j": { router.go(.journal(cursor)) }, "b": { router.go(.habits) },
        ], enabled: !overlayOpen)
    }

    // MARK: Context

    /// `windowFor`: the window a view needs loaded around a date. Day and week grow as you
    /// scroll; the year snaps.
    static func windowFor(_ view: String, _ date: String, _ cal: Calendar) -> CalWindow {
        switch view {
        case "year":
            let y = String(date.prefix(4))
            return CalWindow(from: "\(y)-01-01", to: "\(y)-12-31")
        case "week":
            let ws = CalUI.weekStart(date, cal)
            return CalWindow(from: CalDate.addingDays(-35, toKey: ws, in: cal), to: CalDate.addingDays(70, toKey: ws, in: cal))
        default:
            return CalWindow(from: CalDate.addingDays(-3, toKey: date, in: cal), to: CalDate.addingDays(4, toKey: date, in: cal))
        }
    }

    private func setCursor(_ d: String) {
        cursor = d
        visibleMonth = String(d.prefix(7))
        var w = win
        if CalUI.daysBetween(w.from, d, cal) < 7 { w.from = CalDate.addingDays(-21, toKey: d, in: cal) }
        if CalUI.daysBetween(d, w.to, cal) < 7 { w.to = CalDate.addingDays(45, toKey: d, in: cal) }
        win = w
    }

    /// `reveal`: distinct from `setCursor` because "Today" has to work when the cursor is
    /// already on today and you have simply scrolled away from it.
    private func reveal(_ d: String) {
        setCursor(d)
        revealAt = RevealAt(date: d, nonce: revealAt.nonce + 1)
    }

    private func setView(_ v: String) { view = v; viewChosen = true }

    private func extend(_ side: String, _ days: Int) {
        if side == "start" { win.from = CalDate.addingDays(-days, toKey: win.from, in: cal) }
        else { win.to = CalDate.addingDays(days, toKey: win.to, in: cal) }
    }

    private func refresh() async { await store.refreshRange(fromKey: win.from, toKey: win.to) }

    /// `step` in CalendarToolbar.tsx: what ‹ › and ↑ ↓ move by in each view.
    private func step(_ delta: Int) -> String {
        switch view {
        case "week": return CalDate.addingDays(delta * 7, toKey: CalUI.weekStart(cursor, cal), in: cal)
        case "year":
            let y = (Int(cursor.prefix(4)) ?? 2000) + delta
            return String(format: "%04d", y) + String(cursor.dropFirst(4))
        default: return CalDate.addingDays(delta, toKey: cursor, in: cal)
        }
    }

    // MARK: Toolbar (`CalendarToolbar.tsx`)

    /// The title follows what you are actually looking at: scrolling the week stack past a
    /// month boundary renames the header, even though the cursor has not moved.
    private var title: String {
        view == "year" ? String(cursor.prefix(4)) : CalUI.monthLabel("\(visibleMonth)-01", cal)
    }

    private var toolbar: some View {
        let syncing = store.calendars.contains { $0.syncStatus == "syncing" }
        return HStack(spacing: 6) {
            HStack(spacing: 0) {
                WButton(icon: "chevronLeft", variant: .ghost, size: .iconSm, help: "Previous") { reveal(step(-1)) }
                WButton(icon: "chevronRight", variant: .ghost, size: .iconSm, help: "Next") { reveal(step(1)) }
            }
            // `h-7 px-2 text-sm`
            Button { reveal(today) } label: { Text("Today").font(W.font(14, 500)).padding(.horizontal, -2) }
                .buttonStyle(.web(.ghost, .sm))
            Text(title).font(W.font(14, 500)).monospacedDigit().foregroundStyle(W.foreground).padding(.leading, 4)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach([("days", "Day", "d"), ("week", "Week", "w"), ("year", "Year", "y")], id: \.0) { v in
                    ViewTab(label: v.1, key: v.2, active: view == v.0) { setView(v.0) }
                }
            }
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1))
            WButton(icon: "calendarDays", variant: .ghost, size: .iconSm, expanded: pops.isOpen("cal-visible"), help: "Calendars") {
                pops.toggle("cal-visible", side: .bottom, align: .end) { CalendarsMenu(store: store) }
            }
            .popAnchor("cal-visible")
            // `size sm h-7 gap-1.5 px-2.5 text-xs` with the `n` kbd in the button's own ink.
            Button {
                let m = CalUI.nextHalfHour(cal)
                create(day: cursor, start: m, end: m + 60)
            } label: {
                HStack(spacing: 6) {
                    Icon("plus", size: 14)
                    Text("New").font(W.font(12, 500))
                    Kbd("n", onDark: true).padding(.leading, 2)
                }
            }
            .buttonStyle(.web(.default, .sm))
            .help("New")
            if store.loading || syncing { RingSpinner().help("Syncing") }
        }
        .padding(.bottom, 8)
    }

    // MARK: Editor

    private func edit(_ e: CalEventFull) {
        sheet.present(title: "Event", width: 480) { EventSheet(store: store, target: .edit(e)) }
    }

    /// A sketch drawn on a column or the ribbon: the editor opens on those instants.
    private func createSpan(_ startsAt: Double, _ endsAt: Double) {
        let day = CalDate.key(Date(timeIntervalSince1970: startsAt / 1000), in: cal)
        let base = CalDate.ms(day, minutes: 0, in: cal)
        create(day: day, start: Int((startsAt - base) / 60_000), end: Int((endsAt - base) / 60_000))
    }

    private func create(day: String, start: Int, end: Int, draft: EventDraft? = nil) {
        sheet.present(title: "New event", width: 480) { EventSheet(store: store, target: .create(day: day, startMinutes: start, endMinutes: end, allDay: false), draft: draft) }
    }
}

/// `revealAt` in the context: a date and a nonce, so asking twice for the same day still asks.
struct RevealAt: Equatable {
    var date: String
    var nonce: Int
}

/// `[from, to]`, the loaded window.
struct CalWindow: Equatable {
    var from: String
    var to: String
}

enum MacEventTarget: Hashable {
    case create(day: String, startMinutes: Int, endMinutes: Int, allDay: Bool)
    case edit(CalEventFull)
}

/// One of the Day / Week / Year tabs: `h-6 rounded-[4px] px-2 text-xs`, the active one
/// reversed out (`bg-foreground text-background`).
private struct ViewTab: View {
    let label: String
    let key: String
    let active: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(W.font(12))
                .foregroundStyle(active ? W.background : (hovering ? W.foreground : W.mutedForeground))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(active ? W.foreground : Color.clear)
                .rounded(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(label)  \(key)")
    }
}

/// `size-3 animate-spin rounded-full border-2 border-muted-foreground/30 border-t-foreground`.
private struct RingSpinner: View {
    @State private var spinning = false
    var body: some View {
        ZStack {
            Circle().strokeBorder(W.mutedForeground.opacity(0.3), lineWidth: 2)
            Circle().trim(from: 0, to: 0.25).stroke(W.foreground, lineWidth: 2).rotationEffect(.degrees(-90)).padding(1)
        }
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(spinning ? 360 : 0))
        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true } }
    }
}

/// `CalendarToolbar.tsx:74-101`: the calendars popover — a dot, the name, an eye, and along
/// the bottom Refresh all and Manage.
private struct CalendarsMenu: View {
    let store: CalendarStore
    @Environment(PopLayerState.self) private var pops
    @Environment(Router.self) private var router
    @State private var syncing = false

    var body: some View {
        let broken = store.calendars.filter { $0.syncStatus == "error" }
        PopCard(width: 288, padding: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Calendars").font(W.xs).foregroundStyle(W.mutedForeground).padding(.horizontal, 6).padding(.bottom, 4)
                if store.calendars.isEmpty {
                    Text("Nothing connected yet.").font(W.xs).foregroundStyle(W.mutedForeground).padding(.horizontal, 6).padding(.vertical, 8)
                }
                ForEach(store.calendars) { c in
                    CalendarRow(calendar: c) {
                        Task {
                            do { _ = try await CalendarAPI.updateSource(id: c.id, visible: !c.visible); await store.loadCalendars(); CalendarBus.shared.changed() }
                            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
                        }
                    }
                }
                HStack(spacing: 4) {
                    Button {
                        guard !syncing else { return }
                        syncing = true
                        Task { defer { syncing = false }; try? await CalendarAPI.syncSources(); CalendarBus.shared.changed() }
                    } label: {
                        HStack(spacing: 4) {
                            if syncing { Spinner(size: 14) } else { Icon("refreshCw", size: 14) }
                            Text("Refresh all").font(W.font(12, 500))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.web(.ghost, .sm))
                    .disabled(syncing)
                    Button { pops.closeAll(); router.go(.settings("calendar")) } label: {
                        HStack(spacing: 4) { Icon("settings2", size: 14); Text("Manage").font(W.font(12, 500)) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.web(.ghost, .sm))
                }
                .padding(.top, 4)
                .edgeLine(.top)
                .padding(.top, 4)
                if let first = broken.first, let err = first.syncError, !err.isEmpty {
                    Text(err).font(W.font(11)).foregroundStyle(W.mutedForeground).padding(.horizontal, 6).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct CalendarRow: View {
    let calendar: CalSource
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: calendar.color)).frame(width: 8, height: 8)
                Text(calendar.name).font(W.sm).foregroundStyle(calendar.visible ? W.foreground : W.mutedForeground).truncate()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if calendar.syncStatus == "error" { Text("error").font(W.font(10)).foregroundStyle(W.mutedForeground) }
                Icon(calendar.visible ? "eye" : "eyeOff", size: 13).foregroundStyle(W.tertiary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? W.accent : Color.clear)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Shared helpers (`caldate.ts`, `scale.ts`)

enum CalUI {
    static let weekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    static let monthsLong = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]
    static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    static let dayMs: Double = 86_400_000
    /// Tailwind's `red-500`.
    static let red = Color(hex: "#ef4444")

    /// `weekStartOf`: the first day of the week containing `key`, by the owner's first weekday.
    static func weekStart(_ key: String, _ cal: Calendar) -> String {
        guard let d = CalDate.date(fromKey: key, in: cal) else { return key }
        let weekday = cal.component(.weekday, from: d) - 1
        let ws = cal.firstWeekday - 1
        let back = (weekday - ws + 7) % 7
        return CalDate.addingDays(-back, toKey: key, in: cal)
    }

    /// `daysBetween`: calendar days from `a` to `b`, positive when `b` is later.
    static func daysBetween(_ a: String, _ b: String, _ cal: Calendar) -> Int {
        guard let x = CalDate.date(fromKey: a, in: cal), let y = CalDate.date(fromKey: b, in: cal) else { return 0 }
        return cal.dateComponents([.day], from: cal.startOfDay(for: x), to: cal.startOfDay(for: y)).day ?? 0
    }

    /// `getDay()`: 0 = Sunday.
    static func dow(_ key: String, _ cal: Calendar) -> Int {
        guard let d = CalDate.date(fromKey: key, in: cal) else { return 0 }
        return cal.component(.weekday, from: d) - 1
    }

    static func dayNumber(_ key: String) -> Int { Int(key.suffix(2)) ?? 0 }
    static func monthIndex(_ key: String) -> Int { (Int(key.dropFirst(5).prefix(2)) ?? 1) - 1 }

    /// `monthLabel`: "January 2026".
    static func monthLabel(_ key: String, _ cal: Calendar) -> String {
        guard let d = CalDate.date(fromKey: key, in: cal) else { return key }
        let f = DateFormatter(); f.calendar = cal; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMMM yyyy"
        return f.string(from: d)
    }

    /// `nextHalfHour`: minutes past midnight of the next half hour from now.
    static func nextHalfHour(_ cal: Calendar) -> Int {
        let now = Date()
        let h = cal.component(.hour, from: now), m = cal.component(.minute, from: now)
        return (h * 60 + (m < 30 ? 30 : 60)) % 1440
    }

    /// `heyTime` in scale.ts: "11:34AM", "11AM", or "23:34" — never a space.
    static func heyTime(_ ms: Double, _ format: String, _ cal: Calendar = CalDate.cal) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        if format == "24" { return String(format: "%02d:%02d", h, m) }
        let hh = h % 12 == 0 ? 12 : h % 12
        let ap = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(hh)\(ap)" : "\(hh):\(String(format: "%02d", m))\(ap)"
    }

    /// `heyRange`: "9AM- 10AM".
    static func heyRange(_ a: Double, _ b: Double, _ format: String, _ cal: Calendar = CalDate.cal) -> String {
        "\(heyTime(a, format, cal))- \(heyTime(b, format, cal))"
    }

    /// `object-position: "50% 30%"` → unit point.
    static func objectPosition(_ s: String) -> CGPoint {
        let parts = s.split(separator: " ").map { Double($0.replacingOccurrences(of: "%", with: "")) ?? 50 }
        let x = parts.count > 0 ? parts[0] : 50, y = parts.count > 1 ? parts[1] : 50
        return CGPoint(x: min(max(x, 0), 100) / 100, y: min(max(y, 0), 100) / 100)
    }
}

/// The hand-drawn face a "maybe" is lettered in: `"Bradley Hand", "Brush Script MT",
/// "Segoe Script", "Comic Sans MS", cursive`.
enum Hand {
    static func font(_ size: CGFloat) -> Font {
        for name in ["BradleyHandITCTT-Bold", "BrushScriptMT", "SegoeScript", "ComicSansMS"] {
            if let f = NSFont(name: name, size: size) { return Font(f).italic() }
        }
        return Font.system(size: size, design: .default).italic()
    }
}

// MARK: - Scroll control

/// The scroll view behind a SwiftUI `ScrollView`, so a view can read and set the offset the
/// way the web reads `scrollTop` and calls `scrollTo` — landing centred, holding the head
/// still while rows are prepended, animating a nudge and jumping a leap.
@MainActor
@Observable
final class ScrollController {
    weak var scrollView: NSScrollView?
    private(set) var offset: CGPoint = .zero
    private(set) var viewport: CGSize = .zero
    private(set) var content: CGSize = .zero
    @ObservationIgnored var onScroll: (() -> Void)?
    @ObservationIgnored var onContentResize: ((CGSize, CGSize) -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// No scroller at all, ever — for the week's hour scroll, which the gutter already reads.
    var hidesScrollers = false

    func attach(_ sv: NSScrollView) {
        guard scrollView !== sv else { return }
        detach()
        scrollView = sv
        if hidesScrollers {
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
            sv.verticalScroller?.alphaValue = 0
        }
        sv.contentView.postsBoundsChangedNotifications = true
        sv.contentView.postsFrameChangedNotifications = true
        sv.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync(scrolled: true) }
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: sv.contentView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync(scrolled: false) }
        })
        if let doc = sv.documentView {
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync(scrolled: false) }
            })
        }
        sync(scrolled: false)
    }

    func detach() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        scrollView = nil
    }

    private func sync(scrolled: Bool) {
        guard let sv = scrollView else { return }
        let old = content
        offset = sv.contentView.bounds.origin
        viewport = sv.contentView.bounds.size
        content = sv.documentView?.frame.size ?? .zero
        if content != old { onContentResize?(old, content) }
        if scrolled { onScroll?() }
    }

    /// `el.scrollTo({ top, behavior })`. Clamped to the document, like the browser.
    func scrollTo(x: CGFloat? = nil, y: CGFloat? = nil, animated: Bool) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        var o = clip.bounds.origin
        if let x { o.x = min(max(x, 0), max(0, doc.frame.width - clip.bounds.width)) }
        if let y { o.y = min(max(y, 0), max(0, doc.frame.height - clip.bounds.height)) }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(o)
            }
        } else {
            clip.setBoundsOrigin(o)
        }
        sv.reflectScrolledClipView(clip)
        sync(scrolled: true)
    }
}

/// Finds the `NSScrollView` the content sits in and hands it to the controller.
struct ScrollHook: NSViewRepresentable {
    let controller: ScrollController
    func makeNSView(context: Context) -> HookView { let v = HookView(); v.controller = controller; return v }
    func updateNSView(_ view: HookView, context: Context) { view.controller = controller }
    final class HookView: NSView {
        var controller: ScrollController?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let sv = enclosingScrollView { controller?.attach(sv) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Week (`WeekView.tsx`)

/// The week's geometry, in points: `HABITS_PX + HEADER_PX + BODY_PX + TASKS_PX`.
enum WeekGeom {
    static let habits: CGFloat = 22
    static let header: CGFloat = 34
    /// All 24 hours at one scale — 24 to the hour (raised from HEY's 19.2, at which a half-hour
    /// meeting had no room for its own name).
    static let body: CGFloat = 576
    /// The body shows twelve hours at a time; the full day is drawn twice as tall inside it and
    /// scrolls within the row, landing on the current hour, so the row keeps its height.
    static let hoursOnScreen: CGFloat = 12
    static let inner: CGFloat = body / hoursOnScreen * 24
    static let maxHourScroll: CGFloat = inner - body
    static let tasks: CGFloat = 28
    /// The shortest a block is drawn — 25 minutes at this scale.
    static let floor: CGFloat = 8
    static let row: CGFloat = habits + header + body + tasks
    static let gap: CGFloat = 12
    static let stride: CGFloat = row + gap
    static let pxPerHour: CGFloat = inner / 24
    static let allDayMax = 3
    static let bodyTop: CGFloat = habits + header
}

/// The week's night fold — the one place the Mac departs from the web, by the user's own
/// decision: with `collapse_night` on, each week folds the night (night_start → night_end)
/// into a thin 16pt band, unless something in that week is actually scheduled in the night,
/// in which case the whole week is drawn at the full 24-hour scale. Every position in a
/// column — rules, marks, events, the now line, a drag, a sketch — reads through the day's
/// ribbon, so the fold is consistent for drawing and dragging.
@MainActor
enum WeekFold {
    static let nightPx: CGFloat = 16

    static func ribbon(day: String, collapse: Bool, store: CalendarStore) -> CalRibbon {
        let cal = store.calendar
        let from = CalDate.ms(day, minutes: 0, in: cal)
        let to = CalDate.ms(CalDate.addingDays(1, toKey: day, in: cal), minutes: 0, in: cal)
        return CalRibbon(from: from, to: to, pxPerHour: WeekGeom.pxPerHour, nightStart: store.prefs.nightStart, nightEnd: store.prefs.nightEnd, nightPx: nightPx, collapseNight: collapse, in: cal)
    }

    /// Retired: the body now shows twelve hours with the current hour in the middle and the
    /// rest a scroll away, so the night is never folded.
    static func collapses(week: String, store: CalendarStore) -> Bool {
        return false
        // swiftlint:disable:next unreachable_code
        guard store.prefs.collapseNight else { return false }
        let cal = store.calendar
        for i in 0..<7 {
            let day = CalDate.addingDays(i, toKey: week, in: cal)
            let r = ribbon(day: day, collapse: true, store: store)
            let timed = store.events(onKey: day).timed
            for run in r.runs where run.night {
                if timed.contains(where: { $0.startsAt < run.to && $0.endsAt > run.from }) { return false }
            }
        }
        return true
    }

    /// The body's height this week: the ribbon's length (460 unfolded, shorter folded).
    static func bodyHeight(week: String, store: CalendarStore) -> CGFloat {
        ribbon(day: week, collapse: collapses(week: week, store: store), store: store).length
    }

    static func rowHeight(week: String, store: CalendarStore) -> CGFloat { WeekGeom.row }
}

/// The hour a week's body is scrolled to, shared by its gutter and its seven columns.
@MainActor
@Observable
final class HourScroll {
    var y: CGFloat

    init(week: String, cal: Calendar) { y = Self.initial(week: week, cal: cal) }

    /// Where a body opens: the current hour in the middle for the week holding today, noon
    /// otherwise.
    static func initial(week: String, cal: Calendar) -> CGFloat {
        let today = CalDate.todayKey
        let inWeek = today >= week && today < CalDate.addingDays(7, toKey: week, in: cal)
        let ms = inWeek ? Date().timeIntervalSince1970 * 1000 : CalDate.ms(week, minutes: 12 * 60, in: cal)
        let dayStart = CalDate.ms(CalDate.key(Date(timeIntervalSince1970: ms / 1000), in: cal), minutes: 0, in: cal)
        let y = CGFloat((ms - dayStart) / 3_600_000) * WeekGeom.pxPerHour
        return max(0, min(WeekGeom.maxHourScroll, y - WeekGeom.body / 2))
    }
}

/// The stack's scroll bookkeeping, a class so the scroll callbacks always see current values.
@MainActor
final class WeekStackModel {
    let scroll = ScrollController()
    var weeks: [String] = []
    var win = CalWindow(from: "", to: "")
    var cursorWeek = ""
    var cal = CalDate.cal
    var landed = false
    var asked = (start: "", end: "")
    var pendingShift: CGFloat = 0
    /// Each week's own row height — the night fold makes them differ.
    var heights: [CGFloat] = []
    var onExtend: (String, Int) -> Void = { _, _ in }
    var onVisibleMonth: (String) -> Void = { _ in }

    private func height(_ i: Int) -> CGFloat { heights.indices.contains(i) ? heights[i] : WeekGeom.row }
    private func rowTop(_ i: Int) -> CGFloat { 8 + (0..<min(i, heights.count)).reduce(0) { $0 + heights[$1] + WeekGeom.gap } }
    private func target(_ i: Int) -> CGFloat { max(0, rowTop(i) - (scroll.viewport.height - height(i)) / 2) }
    private var expectedHeight: CGFloat { 16 + heights.reduce(0) { $0 + $1 + WeekGeom.gap } }

    /// Put the cursor's week in the middle of the viewport, now, without animating.
    func tryLand() {
        guard !landed, scroll.viewport.height > 0, let i = weeks.firstIndex(of: cursorWeek) else { return }
        let t = target(i)
        guard scroll.content.height >= expectedHeight - 1 || scroll.content.height >= t + scroll.viewport.height else { return }
        landed = true
        scroll.scrollTo(y: t, animated: false)
    }

    /// Follow the cursor when it leaves the screen; `force` (reveal) brings it in regardless.
    func show(week: String, force: Bool) {
        guard landed, let i = weeks.firstIndex(of: week) else { return }
        let vh = scroll.viewport.height
        let t = target(i)
        if !force {
            let top = rowTop(i) - scroll.offset.y
            if top >= 0 && top + height(i) <= vh { return }
        }
        // A jump of more than a screen and a half is a different place, not a nudge.
        let far = abs(t - scroll.offset.y) > vh * 1.5
        scroll.scrollTo(y: t, animated: !far)
    }

    func scrolled() {
        guard landed else { return }
        let vh = scroll.viewport.height
        guard !weeks.isEmpty else { return }
        if scroll.offset.y < height(0) + WeekGeom.gap && asked.start != win.from { asked.start = win.from; onExtend("start", 28) }
        if scroll.content.height - scroll.offset.y - vh < height(weeks.count - 1) + WeekGeom.gap && asked.end != win.to { asked.end = win.to; onExtend("end", 28) }
        // The row nearest the top of the viewport wins, and its middle day names the month.
        var best = 0, bestD = CGFloat.infinity
        var top: CGFloat = 8
        for i in weeks.indices {
            let d = abs(top - scroll.offset.y)
            if d < bestD { best = i; bestD = d }
            top += height(i) + WeekGeom.gap
        }
        onVisibleMonth(String(CalDate.addingDays(3, toKey: weeks[best], in: cal).prefix(7)))
    }

    func contentResized(_ old: CGSize, _ new: CGSize) {
        if pendingShift != 0 && new.height != old.height {
            scroll.scrollTo(y: scroll.offset.y + pendingShift, animated: false)
            pendingShift = 0
        }
        tryLand()
    }
}

/// A vertical stack of week rows that runs on forever in both directions; the week the
/// cursor is in wears a thin rounded frame.
struct WeekStack: View {
    let store: CalendarStore
    let cursor: String
    let win: CalWindow
    let revealAt: RevealAt
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void
    var onSetCursor: (String) -> Void
    var onExtend: (String, Int) -> Void
    var onVisibleMonth: (String) -> Void
    var onRefresh: () async -> Void

    @State private var model = WeekStackModel()

    private var cal: Calendar { store.calendar }
    private var cursorWeek: String { CalUI.weekStart(cursor, cal) }
    /// Every week the loaded window touches, oldest first.
    private var weeks: [String] {
        let first = CalUI.weekStart(win.from, cal), last = CalUI.weekStart(win.to, cal)
        let n = min(max(CalUI.daysBetween(first, last, cal) / 7 + 1, 1), 520)
        return (0..<n).map { CalDate.addingDays($0 * 7, toKey: first, in: cal) }
    }

    var body: some View {
        let weeks = weeks
        let cursorWeek = cursorWeek
        model.weeks = weeks; model.win = win; model.cursorWeek = cursorWeek; model.cal = cal
        model.heights = weeks.map { WeekFold.rowHeight(week: $0, store: store) }
        model.onExtend = onExtend; model.onVisibleMonth = onVisibleMonth
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(weeks, id: \.self) { w in
                    WeekRow(store: store, weekStart: w, current: w == cursorWeek, cursor: cursor, revealAt: revealAt, onEvent: onEvent, onCreate: onCreate, onSetCursor: onSetCursor, onRefresh: onRefresh)
                        .padding(.bottom, WeekGeom.gap)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 8)
            .background(ScrollHook(controller: model.scroll))
        }
        // Overlay scrollers, like the browser's: the grid keeps the full width.
        .scrollIndicators(.never)
        .onAppear {
            model.scroll.onScroll = { model.scrolled() }
            model.scroll.onContentResize = { old, new in model.contentResized(old, new) }
            model.tryLand()
        }
        .onChange(of: model.scroll.viewport.height) { _, _ in model.tryLand() }
        .onChange(of: weeks.first) { old, new in
            // Grown at the head: hold what you were reading still. Replaced: land again.
            if let old, let new, weeks.contains(old) {
                let k = max(0, CalUI.daysBetween(new, old, cal) / 7)
                model.pendingShift = (0..<min(k, model.heights.count)).reduce(0) { $0 + model.heights[$1] + WeekGeom.gap }
            } else {
                model.landed = false
                model.tryLand()
            }
        }
        .onChange(of: cursorWeek) { _, w in model.show(week: w, force: false) }
        .onChange(of: revealAt.nonce) { _, _ in model.show(week: CalUI.weekStart(revealAt.date, cal), force: true) }
    }
}

/// One week: the month standing on its side at the left edge, the hour gutter, seven columns,
/// and the week's loose tasks along the floor. Dragging lives on the row, because a block
/// that moves to Thursday leaves Wednesday's column halfway through the gesture.
struct WeekRow: View {
    let store: CalendarStore
    let weekStart: String
    let current: Bool
    let cursor: String
    let revealAt: RevealAt
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void
    var onSetCursor: (String) -> Void
    var onRefresh: () async -> Void

    @State private var live: EventPreview?
    @State private var pending: EventPreview?
    @State private var gridWidth: CGFloat = 0
    @State private var hour: HourScroll?

    private var cal: Calendar { store.calendar }
    private var days: [String] { (0..<7).map { CalDate.addingDays($0, toKey: weekStart, in: cal) } }
    private var space: String { "week-\(weekStart)" }
    private var preview: EventPreview? { live ?? pending }

    var body: some View {
        let days = days
        let habits = store.habitList(near: weekStart)
        let dayMeta = store.dayByKey
        let order = store.serverOrder
        let collapse = WeekFold.collapses(week: weekStart, store: store)
        let first = WeekFold.ribbon(day: days[0], collapse: collapse, store: store)
        let bodyH = WeekGeom.body
        let hour = hour ?? HourScroll(week: weekStart, cal: cal)
        // A month that turns inside the row is announced on the divider it turns at, with its year.
        let turns: [Int: String] = Dictionary(uniqueKeysWithValues: (1..<7).compactMap { i in
            CalUI.monthIndex(days[i]) != CalUI.monthIndex(days[i - 1]) ? (i, "\(CalUI.monthsLong[CalUI.monthIndex(days[i])]) \(days[i].prefix(4))") : nil
        })
        VStack(spacing: -2) {
            HStack(alignment: .top, spacing: 0) {
                // The month, once, on its side — taking no width from the days.
                Text(CalUI.monthsLong[CalUI.monthIndex(weekStart)])
                    .font(W.font(15)).tracking(0.9).foregroundStyle(W.foreground.opacity(0.25))
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                    .clipped()
                // The hour gutter: `right-1 text-[9.5px] tnum leading-none text-tertiary`, every
                // third hour — the ones inside the fold have no room and are not drawn.
                ZStack(alignment: .topTrailing) {
                    Color.clear
                    // The marks scroll with the columns, clipped to the twelve hours on show.
                    ZStack(alignment: .topTrailing) {
                        Color.clear
                        ForEach(first.hours.filter { $0.hour % 3 == 0 }, id: \.ms) { h in
                            Text(hourLabel(h.hour)).font(W.font(9.5)).monospacedDigit().foregroundStyle(W.tertiary).fixedSize()
                                .offset(y: h.pos - hour.y - Geist.naturalLine(size: 9.5) / 2)
                        }
                    }
                    .frame(height: WeekGeom.body)
                    .clipped()
                    .offset(y: WeekGeom.bodyTop)
                }
                .frame(width: 36)
                .padding(.trailing, 4)
                HStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element) { col, day in
                        DayColumn(store: store, date: day, col: col, first: col == 0, day: dayMeta[day], habits: habits, cursor: cursor,
                                  preview: preview, space: space, turn: turns[col], nextTurn: turns[col + 1], order: order,
                                  ribbon: WeekFold.ribbon(day: day, collapse: collapse, store: store), hour: hour,
                                  onEvent: onEvent, onCreate: onCreate, onSetCursor: onSetCursor,
                                  onDrag: { e, mode, p0, p1, ended in drag(e, date: day, col: col, collapse: collapse, mode: mode, p0: p0, p1: p1, ended: ended) })
                    }
                }
                .coordinateSpace(name: space)
                .background(GeometryReader { g in Color.clear.onAppear { gridWidth = g.size.width }.onChange(of: g.size.width) { _, w in gridWidth = w } })
            }
            .frame(height: WeekGeom.habits + WeekGeom.header + bodyH)
            WeekTasksView(weekStart: weekStart).frame(height: WeekGeom.tasks)
        }
        .padding(.top, 1)
        .frame(height: WeekGeom.habits + WeekGeom.header + bodyH + WeekGeom.tasks, alignment: .top)
        .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(current ? W.border : Color.clear, lineWidth: 1))
        .onAppear { if self.hour == nil { self.hour = hour } }
        // "Today" and the arrows ask for the hour as much as for the week.
        .onChange(of: revealAt.nonce) { _, _ in
            if CalUI.weekStart(revealAt.date, cal) == weekStart { self.hour?.y = HourScroll.initial(week: weekStart, cal: cal) }
        }
    }

    /// "6a", "12p", "9p" — short enough for a 36px gutter.
    private func hourLabel(_ h: Int) -> String {
        if h == 0 { return "12a" }
        if h == 12 { return "12p" }
        return h < 12 ? "\(h)a" : "\(h - 12)p"
    }

    /// The pointer's travel as a column shift and a delta in time read off the day's ribbon —
    /// so the folded night counts for what it is rather than what it measures.
    private func drag(_ e: CalEventFull, date: String, col: Int, collapse: Bool, mode: EventDrag.Mode, p0: CGPoint, p1: CGPoint, ended: Bool) {
        let colW = gridWidth / 7
        let dx = p1.x - p0.x
        let days = mode == .move && colW > 0 ? max(-col, min(6 - col, Int((dx / colW).rounded()))) : 0
        let span: EventDrag.Span
        if e.allDay {
            span = EventDrag.allDaySpan(e, days: days, in: cal)
        } else {
            let ribbon = WeekFold.ribbon(day: date, collapse: collapse, store: store)
            let delta = ribbon.at(p1.y - WeekGeom.bodyTop) - ribbon.at(p0.y - WeekGeom.bodyTop)
            let dayStart = ribbon.from
            span = EventDrag.span(e, mode: mode, deltaMs: delta, days: days, bounds: (EventDrag.shiftDays(dayStart, days, in: cal), EventDrag.shiftDays(dayStart, days + 1, in: cal)), in: cal)
        }
        if !ended { live = EventPreview(event: e, span: span); return }
        live = nil
        guard EventDrag.moved(e, span) else { return }
        let p = EventPreview(event: e, span: span)
        pending = p
        DragCommit.commit(p, refresh: onRefresh) { if pending == p { pending = nil } }
    }
}

/// One day: habits on their rail, the header, then the track, and the photo picker that
/// appears over the day's top-left corner on hover.
private struct DayColumn: View {
    let store: CalendarStore
    let date: String
    let col: Int
    let first: Bool
    let day: CalDay?
    let habits: [CalHabit]
    let cursor: String
    let preview: EventPreview?
    let space: String
    let turn: String?
    let nextTurn: String?
    let order: [String: Int]
    /// This day's ruler — folded or not, the week decided.
    let ribbon: CalRibbon
    let hour: HourScroll
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void
    var onSetCursor: (String) -> Void
    var onDrag: (CalEventFull, EventDrag.Mode, CGPoint, CGPoint, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        let photo = !(day?.coverURL.isEmpty ?? true)
        VStack(spacing: 0) {
            HabitRail(store: store, date: date, habits: habits)
            DayHeader(date: date, photo: photo, cal: store.calendar)
            Track(store: store, date: date, col: col, first: first, day: day, cursor: cursor, preview: preview, space: space, turn: turn, nextTurn: nextTurn, order: order, ribbon: ribbon, hour: hour,
                  onEvent: onEvent, onCreate: onCreate, onSetCursor: onSetCursor, onDrag: onDrag)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            // HEY's entry point: hover the day's top-left corner and a photo icon appears over it.
            DayPhotoButton(store: store, date: date, day: day)
                .opacity(hovering ? 1 : (photo ? 0.8 : 0))
                .animation(.easeOut(duration: 0.15), value: hovering)
                .padding(.leading, 6)
                .padding(.top, WeekGeom.bodyTop + 6)
                .zIndex(30)
        }
        .onHover { hovering = $0 }
    }
}

/// The habits, as small circles straddling a hairline the width of the column. Outlined when
/// undone, filled in the habit's own colour when done.
private struct HabitRail: View {
    let store: CalendarStore
    let date: String
    let habits: [CalHabit]

    var body: some View {
        let dow = CalUI.dow(date, store.calendar)
        let mine = habits.filter { $0.days.isEmpty || $0.days.contains(dow) }
        ZStack {
            Rectangle().fill(W.border).frame(height: 1).padding(.horizontal, 6).allowsHitTesting(false)
            HStack(spacing: 4) {
                ForEach(mine) { h in
                    HabitDot(habit: h, done: h.completions.contains(date)) { Task { do { try await store.toggleHabit(h, date: date) } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) } } }
                }
            }
        }
        .frame(height: WeekGeom.habits)
    }
}

private struct HabitDot: View {
    let habit: CalHabit
    let done: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let s = EventSurface(hex: habit.color)
        Button(action: action) {
            Text(habit.icon.isEmpty ? String(habit.name.prefix(1)).uppercased() : habit.icon)
                .font(W.font(9.5))
                .foregroundStyle(done ? s.ink : (hovering ? W.foreground : W.tertiary))
                .frame(width: 19, height: 19)
                .background(done ? s.fill : W.background)
                .overlay(Circle().strokeBorder(done ? Color.clear : (hovering ? W.foreground.opacity(0.4) : W.border), lineWidth: 1))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(habit.name)\(done ? " · done" : "")")
        .zIndex(10)
    }
}

/// `SUN 30`, right-aligned and deliberately small; today reversed out of a solid blob.
private struct DayHeader: View {
    let date: String
    let photo: Bool
    let cal: Calendar

    var body: some View {
        let today = date == CalDate.todayKey
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(CalUI.weekdays[CalUI.dow(date, cal)])
                .font(W.font(11)).tracking(1.1).webLine(11, 11)
                .foregroundStyle(today ? W.background : (photo ? Color.white : W.tertiary))
            Text("\(CalUI.dayNumber(date))")
                .font(W.font(16, 700)).monospacedDigit().webLine(16, 16, weight: 700)
                .foregroundStyle(today ? W.background : (photo ? Color.white : W.foreground))
        }
        .padding(.horizontal, today ? 8 : 0)
        .padding(.vertical, today ? 3 : 0)
        .background(today ? W.foreground : Color.clear)
        .clipShape(Capsule())
        // Over a photo the number goes white with a shadow, as HEY does.
        .shadow(color: !today && photo ? Color.black.opacity(0.9) : .clear, radius: 1.5)
        .shadow(color: !today && photo ? Color.black.opacity(0.8) : .clear, radius: 1, y: 1)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 6)
        .frame(height: WeekGeom.header)
        .zIndex(20)
    }
}

/// The body of a column: the day's photo, its events, its all-day pills on the floor, and —
/// on today only — a dotted line where the hour hand is. Midnight at the top, midnight at the
/// bottom, 24 hours in between at one rate.
private struct Track: View {
    let store: CalendarStore
    let date: String
    let col: Int
    let first: Bool
    let day: CalDay?
    let cursor: String
    let preview: EventPreview?
    let space: String
    let turn: String?
    let nextTurn: String?
    let order: [String: Int]
    let ribbon: CalRibbon
    let hour: HourScroll
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void
    var onSetCursor: (String) -> Void
    var onDrag: (CalEventFull, EventDrag.Mode, CGPoint, CGPoint, Bool) -> Void

    @State private var sketch: (from: Double, to: Double)?
    @State private var now = Date()
    /// The column's own scroll box; it follows the row's shared hour and reports its own.
    @State private var ctl: ScrollController = { let c = ScrollController(); c.hidesScrollers = true; return c }()

    private var cal: Calendar { store.calendar }
    private var dayStart: Double { ribbon.from }
    private var dayEnd: Double { ribbon.to }
    /// Every position reads off the ribbon, so the folded night measures 16pt and no more.
    private func posOf(_ ms: Double) -> CGFloat { ribbon.pos(ms) }
    private func msAtY(_ y: CGFloat) -> Double { EventDrag.snap(ribbon.at(y)) }

    var body: some View {
        let events = store.events(onKey: date)
        let today = date == CalDate.todayKey
        let photo = !(day?.coverURL.isEmpty ?? true)
        let dayStart = dayStart, dayEnd = dayEnd
        // A dragged event is drawn where it is going, which may be another column: every column
        // drops it from its own list, and the one its span lands in draws it on top, full width.
        let rest = events.timed.filter { $0.id != preview?.id }
        let ghost: CalEventFull? = preview.flatMap { p in (!p.event.allDay && p.span.endsAt > dayStart && p.span.startsAt < dayEnd) ? p.shown : nil }
        // The web keeps the range's own order for the pills; the shared index alphabetises.
        let allDay = events.allDay.sorted { (order[$0.id] ?? .max, $0.id) < (order[$1.id] ?? .max, $1.id) }
        let pills: [CalEventFull] = {
            guard let p = preview else { return allDay }
            let kept = allDay.filter { $0.id != p.id }
            guard p.event.allDay, let a = p.span.startDate else { return kept }
            let b = p.span.endDate ?? a
            return date >= a && date <= b ? kept + [p.shown] : kept
        }()
        // The floor in time is the week's 8pt at the *daytime* rate: a block in the fold is
        // drawn no shorter than that either, so the columns still match what is on screen.
        // Columns split only on true overlap; the drawn minimum is handled by pushing, not widening.
        let layout = CalDate.layoutColumns(rest, floorMs: 0)
        let placed = CalDate.placeBlocks(rest.map { (top: posOf(max($0.startsAt, dayStart)), bottom: posOf(min($0.endsAt, dayEnd))) }, slots: layout, minPx: 16, gapPx: 2)
        let extra = pills.count - WeekGeom.allDayMax
        let nowMs = now.timeIntervalSince1970 * 1000
        ZStack(alignment: .topLeading) {
            (cursor == date ? W.muted.opacity(0.25) : Color.clear)
            if !first { Rectangle().fill(W.border).frame(width: 1).frame(maxHeight: .infinity, alignment: .leading) }
            // Not a thumbnail, and not dimmed: the photo fills the column at full strength.
            DayPhotoBackdrop(day: day)
            // The scroll box's content is given the column's exact width: left to itself it
            // would keep a scroller's worth of room on the right that nothing ever fills.
            GeometryReader { box in
            ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
            // Hour rules behind the events: every hour faint, every sixth a shade stronger. Hours
            // inside the fold have no room and get none.
            ForEach(ribbon.hours.filter { $0.hour > 0 }, id: \.ms) { h in
                Rectangle().fill(h.hour % 6 == 0 ? W.border : W.border.opacity(0.4)).frame(height: 1).offset(y: h.pos).allowsHitTesting(false)
            }
            // The folded night: a darker band, so the fold reads as one.
            ForEach(ribbon.runs.filter(\.night), id: \.from) { r in
                Rectangle().fill(W.muted60).frame(height: r.size).offset(y: r.pos).allowsHitTesting(false)
            }
            // The month-turn watermark: this column's half on its leading edge, the next
            // column's on the trailing one, each on a page-coloured chip behind the events.
            if let turn { MonthTurn(label: turn).alignmentGuide(.leading) { d in d.width / 2 }.padding(.top, 8) }
            if let nextTurn {
                Color.clear.overlay(alignment: .topTrailing) { MonthTurn(label: nextTurn).alignmentGuide(.trailing) { d in d.width / 2 }.padding(.top, 8) }
            }
            ForEach(Array(rest.enumerated()), id: \.element.id) { i, e in
                let top = placed[i].top
                let height = placed[i].height
                EventBlock(event: e, height: height, floor: WeekGeom.floor, column: layout[i].column, columns: layout[i].columns, timeFormat: store.prefs.timeFormat, space: space, onPhoto: photo,
                           onTap: { onSetCursor(date); onEvent(e) },
                           onToggleDone: { toggleDone(e) },
                           onDrag: { mode, p0, p1, ended in onDrag(e, mode, p0, p1, ended) })
                    .offset(y: top)
                    // Later events sit on top, so a short one keeps its title line.
                    .zIndex(Double(20 + min(i, 40)))
            }
            if let g = ghost {
                let top = posOf(max(g.startsAt, dayStart))
                EventBlock(event: g, height: posOf(min(g.endsAt, dayEnd)) - top, floor: WeekGeom.floor, timeFormat: store.prefs.timeFormat, space: space, dragging: true, onPhoto: photo, onTap: { onEvent(g) })
                    .offset(y: top)
                    .zIndex(90)
            }
            if let sketch {
                let a = posOf(min(sketch.from, sketch.to)), b = posOf(max(sketch.from, sketch.to))
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(W.foreground.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .frame(height: max(b - a, 8)).padding(.horizontal, 2).offset(y: a).allowsHitTesting(false).zIndex(95)
            }
            if today && nowMs >= dayStart && nowMs < dayEnd {
                ZStack(alignment: .topLeading) {
                    Rectangle().stroke(CalUI.red, style: StrokeStyle(lineWidth: 1, dash: [1, 1])).frame(height: 1).frame(maxWidth: .infinity)
                    Text(CalUI.heyTime(nowMs, store.prefs.timeFormat, cal)).font(W.font(9)).monospacedDigit().foregroundStyle(CalUI.red)
                        .webLine(9, 9).padding(.trailing, 4).background(W.background.opacity(0.8)).offset(y: -7)
                }
                .offset(y: posOf(nowMs))
                .allowsHitTesting(false)
                .zIndex(100)
            }
            }
            .frame(width: box.size.width, height: ribbon.length, alignment: .top)
            .contentShape(Rectangle())
            // Press to set the cursor; drag down the column to draw out a new event; a plain
            // click makes a half hour.
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if sketch == nil {
                    onSetCursor(date)
                    let from = msAtY(v.startLocation.y)
                    sketch = (from, from + 30 * 60_000)
                }
                if v.translation != .zero { sketch = (sketch!.from, msAtY(v.location.y)) }
            }.onEnded { _ in
                guard let s = sketch else { return }
                sketch = nil
                let a = min(s.from, s.to), b = max(s.from, s.to)
                onCreate(a, b == a ? a + 30 * 60_000 : b)
            })
            .background(ScrollHook(controller: ctl))
            }
            .scrollIndicators(.hidden)
            }
            // All-day things sit on the floor of the day — the ground it stands on, not a banner.
            if !pills.isEmpty {
                VStack(spacing: 2) {
                    ForEach(pills.prefix(WeekGeom.allDayMax)) { e in
                        AllDayPill(event: e, dragging: preview?.id == e.id, onTap: { onSetCursor(date); onEvent(e) },
                                   onDrag: { p0, p1, ended in onDrag(e, .move, p0, p1, ended) }, space: space)
                    }
                    if extra > 0 {
                        Text("+\(extra) more").font(W.font(10)).foregroundStyle(W.tertiary).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(80)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: WeekGeom.body, alignment: .top)
        .clipped()
        // The seven columns and the gutter scroll as one: this box follows the row's hour and
        // reports its own scrolling back.
        .onAppear {
            ctl.onScroll = { if abs(ctl.offset.y - hour.y) > 0.5 { hour.y = ctl.offset.y } }
        }
        .onChange(of: ctl.viewport.height) { _, h in if h > 0, abs(ctl.offset.y - hour.y) > 0.5 { ctl.scrollTo(y: hour.y, animated: false) } }
        .onChange(of: hour.y) { _, y in if abs(ctl.offset.y - y) > 0.5 { ctl.scrollTo(y: y, animated: false) } }
        .task(id: today) {
            guard today else { return }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)); now = Date() }
        }
    }

    private func toggleDone(_ e: CalEventFull) {
        Task {
            do { _ = try await CalendarAPI.setDone(id: e.id, done: !e.done, date: date); CalendarBus.shared.changed() }
            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
}

/// "MARCH 2026" standing on its side on a page-coloured chip: `text-[12px] uppercase
/// tracking-[0.08em] text-foreground/25 bg-background px-[3px] py-1`, at most 190 tall.
private struct MonthTurn: View {
    let label: String
    var body: some View {
        let font = Geist.nsFont(size: 12, weight: 400)
        let w = ceil((label as NSString).size(withAttributes: [.font: font, .kern: 0.96]).width)
        let box = w + 8
        Text(label).font(W.font(12)).tracking(0.96).foregroundStyle(W.foreground.opacity(0.25)).lineLimit(1).fixedSize()
            .frame(width: w, height: 16)
            .padding(.horizontal, 4).padding(.vertical, 3)
            .background(W.background)
            .rotationEffect(.degrees(90))
            .frame(width: 22, height: box)
            .frame(height: min(box, 190), alignment: .top)
            .clipped()
            .allowsHitTesting(false)
    }
}

// MARK: - Event surfaces (`colors.ts`, `EventBlock.tsx`)

/// `eventColors`: the calendar's colour as a solid fill, the text flipped to whichever of
/// near-white or near-black actually contrasts.
struct EventSurface {
    let fill: Color
    let ink: Color
    static let defaultFill = "#1f1f1f"

    init(hex: String) {
        let hex = Self.normalize(hex) ?? Self.defaultFill
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x1f1f1f
        let r = Double((v >> 16) & 0xff) / 255, g = Double((v >> 8) & 0xff) / 255, b = Double(v & 0xff) / 255
        let lin: (Double) -> Double = { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let L = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        fill = Color(hex: hex)
        ink = Color(hex: 1.05 / (L + 0.05) >= (L + 0.05) / 0.05 ? "#fbfbfa" : "#131313")
    }

    private init(fill: Color, ink: Color) { self.fill = fill; self.ink = ink }

    /// `surface(e)`: a maybe is drawn without colour — white, hatched, in ink.
    init(_ e: CalEventFull) {
        if EventSurface.isMaybe(e) { self.init(fill: Color(hex: "#ffffff"), ink: Color(hex: "#131313")) }
        else { self.init(hex: e.calendarColor) }
    }

    static func isMaybe(_ e: CalEventFull) -> Bool { e.isTentative || e.rsvp == .tentative }

    static func normalize(_ hex: String) -> String? {
        let v = hex.trimmingCharacters(in: .whitespaces)
        if v.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil { return v.lowercased() }
        if v.range(of: "^#[0-9a-fA-F]{3}$", options: .regularExpression) != nil {
            let c = Array(v.dropFirst())
            return "#\(c[0])\(c[0])\(c[1])\(c[1])\(c[2])\(c[2])".lowercased()
        }
        return nil
    }
}

/// `HATCH`: `repeating-linear-gradient(45deg, rgba(0,0,0,0.09) 0 3px, transparent 3px 7px)`.
struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let period: CGFloat = 7 * 2.0.squareRoot()
        let h = rect.height, w = rect.width
        var k = -Int(ceil(h / period)) - 1
        while CGFloat(k) * period < w + h {
            let x = CGFloat(k) * period
            p.move(to: CGPoint(x: rect.minX + x, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + x + h, y: rect.minY + h))
            k += 1
        }
        return p
    }
}

/// `InkCircle.tsx`: the ring you draw round something on a paper calendar — an imperfect
/// ellipse that overshoots itself, drawn beyond the event's edges. Ink, not the calendar's colour.
struct InkCircle: View {
    static let overshoot: CGFloat = 7
    var body: some View {
        InkLoop().stroke(W.foreground.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .padding(-Self.overshoot)
            .allowsHitTesting(false)
    }
}

private struct InkLoop: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100, sy = rect.height / 100
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var p = Path()
        p.move(to: pt(52, 7))
        p.addCurve(to: pt(6, 51), control1: pt(22, 7), control2: pt(6, 27))
        p.addCurve(to: pt(52, 95), control1: pt(6, 75), control2: pt(24, 96))
        p.addCurve(to: pt(95, 49), control1: pt(79, 94), control2: pt(96, 73))
        p.addCurve(to: pt(46, 7), control1: pt(94, 27), control2: pt(75, 6))
        p.addCurve(to: pt(8, 39), control1: pt(28, 7.5), control2: pt(12, 19))
        return p
    }
}

/// `AllDayPill`: a fully rounded stadium pill, solid in the calendar's colour, on the floor
/// of the column. All-day things move by whole days only.
struct AllDayPill: View {
    let event: CalEventFull
    var dragging = false
    var onTap: () -> Void
    var onDrag: ((CGPoint, CGPoint, Bool) -> Void)? = nil
    var space = "week"
    @State private var hovering = false

    var body: some View {
        let s = EventSurface(event)
        let maybe = EventSurface.isMaybe(event)
        let declined = event.rsvp == .declined
        let title = event.title.isEmpty ? "(no title)" : event.title
        HStack(spacing: 4) {
            if !event.emoji.isEmpty { Text(event.emoji).font(W.font(11, 500)).fixedSize() }
            Text(title).font(maybe ? Hand.font(11) : W.font(11, 500)).strikethrough(event.done || declined).truncate()
            if event.recurring { Spacer(minLength: 0); Icon("repeat", size: 9).opacity(0.6) }
        }
        .foregroundStyle(s.ink)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 18)
        .background(s.fill)
        .overlay { if maybe { Capsule().strokeBorder(W.foreground.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3])) } }
        .clipShape(Capsule())
        .overlay { if dragging { Capsule().strokeBorder(W.foreground.opacity(0.4), lineWidth: 1) } }
        .opacity(dragging ? 1 : (declined ? 0.45 : (hovering ? 0.85 : 1)))
        .shadow(color: .black.opacity(dragging ? 0.2 : 0), radius: 8, y: 4)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .gesture(DragGesture(minimumDistance: EventDrag.slop, coordinateSpace: .named(space)).onChanged { v in
            guard let onDrag, event.writable else { return }
            onDrag(v.startLocation, v.location, false)
        }.onEnded { v in
            guard let onDrag, event.writable else { return }
            onDrag(v.startLocation, v.location, true)
        })
        .help(title)
    }
}

/// `EventBlock` (timed): a proportional box in its calendar's colour, the title flipped to
/// contrast. Under 13pt it is a bare bar of colour; under 34pt the time and the title share
/// one line; taller blocks carry the range over the title, and from 64pt the small icons
/// along the floor. Overlapping neighbours split the column between them.
struct EventBlock: View {
    let event: CalEventFull
    var height: CGFloat
    /// The shortest this view ever draws a block.
    var floor: CGFloat = 22
    var column = 0
    var columns = 1
    var timeFormat = "12"
    /// The coordinate space the drag reports in: the week's grid, so a move can cross columns.
    var space = "week"
    var dragging = false
    /// Sitting over a day's photo: keep the fill opaque and ring it in white, the way HEY does.
    var onPhoto = false
    var onTap: () -> Void
    var onToggleDone: (() -> Void)? = nil
    /// (mode, point at press, point now, ended) — nil for a block that cannot be dragged.
    var onDrag: ((EventDrag.Mode, CGPoint, CGPoint, Bool) -> Void)? = nil
    @State private var mode: EventDrag.Mode?
    @State private var blockTop: CGFloat = 0
    @State private var hovering = false

    /// Never shorter than one line of type (16), and 2pt of air is left under every block.
    private var h: CGFloat { max(height, floor, 16) }
    private var drawn: CGFloat { max(h - 2, 14) }
    private var bare: Bool { false }
    private var oneLine: Bool { h < 34 }
    private var roomy: Bool { h >= 64 }
    private var titleLines: Int { max(1, min(3, Int((h - 6 - 12) / 14))) }
    private var declined: Bool { event.rsvp == .declined }
    private var maybe: Bool { EventSurface.isMaybe(event) }

    var body: some View {
        let s = EventSurface(event)
        let icons = roomy && (!event.conferenceURL.isEmpty || !event.attendees.isEmpty || event.recurring || !event.writable)
        GeometryReader { g in
            let n = CGFloat(max(columns, 1))
            let width = (g.size.width - 4) / n - (n > 1 ? 1 : 0)
            let left = (g.size.width - 4) / n * CGFloat(column) + 2
            let grab = EventDrag.handle(h)
            Group {
                VStack(alignment: .leading, spacing: 0) {
                    if bare {
                        EmptyView()
                    } else if oneLine {
                        // One line: the time and the title share a baseline — "5:30PM- 6PM  Weekly Call…"
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if event.isTodo { DoneBox(done: event.done, action: onToggleDone) }
                            Text(dragging ? CalUI.heyRange(event.startsAt, event.endsAt, timeFormat) : CalUI.heyTime(event.startsAt, timeFormat))
                                .font(W.font(9.5)).monospacedDigit().opacity(0.7).fixedSize()
                            Text(titleText).font(maybe ? Hand.font(11) : W.font(11, 600)).strikethrough(event.done || declined).lineLimit(1)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    } else {
                        Text(CalUI.heyRange(event.startsAt, event.endsAt, timeFormat)).font(W.font(9.5)).monospacedDigit().opacity(0.7).lineLimit(1).frame(height: 12)
                        HStack(alignment: .top, spacing: 4) {
                            if event.isTodo { DoneBox(done: event.done, action: onToggleDone) }
                            Text(titleText).font(maybe ? Hand.font(12) : W.font(12, 600)).strikethrough(event.done || declined).lineLimit(titleLines).webLine(12, 14, weight: 600)
                        }
                    }
                    if icons {
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            if !event.conferenceURL.isEmpty { Icon("video", size: 10) }
                            if !event.attendees.isEmpty { Icon("users", size: 10) }
                            if event.recurring { Icon("repeat", size: 10) }
                            if !event.writable { Icon("lock", size: 10) }
                        }
                        .opacity(0.65).padding(.top, 2)
                    }
                }
                .foregroundStyle(s.ink)
                .padding(.horizontal, 6).padding(.vertical, oneLine ? 0 : 3)
                .frame(width: width, height: drawn, alignment: .topLeading)
                .background { ZStack { s.fill; if maybe { Hatch().stroke(Color.black.opacity(0.09), lineWidth: 3) } } }
                .clipped()
                .overlay { if maybe { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3])) } }
                .rounded(3)
                .opacity(dragging ? 1 : (declined ? 0.45 : (hovering ? 0.9 : 1)))
                .overlay { if onPhoto { RoundedRectangle(cornerRadius: 3, style: .continuous).inset(by: -1).stroke(Color.white, lineWidth: 2) } }
                .overlay { if dragging { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.4), lineWidth: 1) } }
                .shadow(color: .black.opacity(dragging ? 0.2 : 0), radius: 8, y: 4)
                .overlay { if event.circled { InkCircle().zIndex(30) } }
                .contentShape(Rectangle())
            }
            .onHover { hovering = $0 }
            .onTapGesture(perform: onTap)
            // Press the block to move it, or either end to take that edge with you.
            .gesture(DragGesture(minimumDistance: EventDrag.slop, coordinateSpace: .named(space)).onChanged { v in
                guard let onDrag, event.writable else { return }
                if mode == nil {
                    let atTop = (v.startLocation.y - blockTop) < grab
                    let atBottom = (blockTop + h - v.startLocation.y) < grab
                    mode = atTop ? .start : (atBottom ? .end : .move)
                }
                onDrag(mode!, v.startLocation, v.location, false)
            }.onEnded { v in
                guard let onDrag, let m = mode else { return }
                mode = nil
                onDrag(m, v.startLocation, v.location, true)
            })
            .offset(x: left)
            .background(GeometryReader { bg in Color.clear.onAppear { blockTop = bg.frame(in: .named(space)).minY }.onChange(of: bg.frame(in: .named(space)).minY) { _, y in blockTop = y } })
        }
        .frame(height: h)
        .help("\(titleText)\(event.location.isEmpty ? "" : " · \(event.location)") · \(CalUI.heyRange(event.startsAt, event.endsAt, timeFormat))")
    }

    private var titleText: String { (event.emoji.isEmpty ? "" : "\(event.emoji) ") + (event.title.isEmpty ? "(no title)" : event.title) }
}

/// A repeating todo carries its own tick, and ticking it must not open the editor.
private struct DoneBox: View {
    let done: Bool
    var action: (() -> Void)?
    @State private var hovering = false
    var body: some View {
        Button { action?() } label: {
            Icon(done ? "checkCircle2" : "circle", size: 11).padding(.top, 1).opacity(hovering ? 1 : 0.8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Day photos (`DayPhoto.tsx`)

/// The day's photo at full strength — no scrim, no dim, no blur. Legibility comes from what
/// sits on top of it.
struct DayPhotoBackdrop: View {
    let day: CalDay?
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { g in
            if let image, let day {
                let pos = CalUI.objectPosition(day.coverPosition.isEmpty ? "50% 50%" : day.coverPosition)
                let iw = max(image.size.width, 1), ih = max(image.size.height, 1)
                let scale = max(g.size.width / iw, g.size.height / ih)
                let sw = iw * scale, sh = ih * scale
                Image(nsImage: image).resizable()
                    .frame(width: sw, height: sh)
                    .offset(x: (g.size.width - sw) * pos.x, y: (g.size.height - sh) * pos.y)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .task(id: day?.coverURL ?? "") {
            guard let url = day?.coverImageURL else { image = nil; return }
            image = await ImageCache.shared.image(for: url, maxPixel: 1800)
        }
    }
}

/// The picker: exactly two affordances — upload, and remove once there is one — reached from
/// a photo icon in the day's corner.
struct DayPhotoButton: View {
    let store: CalendarStore
    let date: String
    let day: CalDay?
    @Environment(PopLayerState.self) private var pops
    @State private var hovering = false

    private var id: String { "day-photo-\(date)" }

    var body: some View {
        let has = !(day?.coverURL.isEmpty ?? true)
        Button {
            pops.toggle(id, side: .bottom, align: .start) { DayPhotoPicker(store: store, date: date, day: day) }
        } label: {
            Icon("images", size: 13)
                .foregroundStyle(hovering ? W.foreground : W.foreground.opacity(0.7))
                .padding(4)
                .background(hovering ? W.background : W.background.opacity(0.85))
                .rounded(5)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(has ? "Change this day's photo" : "Give this day a background")
        .popAnchor(id)
    }
}

/// `PopoverContent align="start" className="w-64 p-4"`.
private struct DayPhotoPicker: View {
    let store: CalendarStore
    let date: String
    let day: CalDay?
    @Environment(PopLayerState.self) private var pops
    @State private var busy = false
    @State private var error: String?
    @State private var hoverUpload = false
    @State private var hoverRemove = false

    private var has: Bool { !(day?.coverURL.isEmpty ?? true) }

    var body: some View {
        PopCard(width: 256, padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("GIVE THIS DAY A BACKGROUND").font(W.font(11, 600)).tracking(0.77).foregroundStyle(W.mutedForeground)
                Button(action: pick) {
                    HStack(spacing: 6) {
                        if busy { Spinner(size: 13) }
                        Text(busy ? "Uploading…" : has ? "Upload a different image" : "Upload an image").font(W.font(13, 600))
                    }
                    .foregroundStyle(hoverUpload && !busy ? W.background : W.foreground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(hoverUpload && !busy ? W.foreground : Color.clear)
                    .overlay(Capsule().strokeBorder(W.foreground, lineWidth: 2))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    .opacity(busy ? 0.6 : 1)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .onHover { hoverUpload = $0 }
                .padding(.top, 12)
                if has {
                    Button {
                        Task {
                            do { store.adoptOrInsert(day: try await CalendarAPI.updateDay(date, coverID: .some(nil), coverURL: "")) }
                            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
                        }
                        pops.close("day-photo-\(date)")
                    } label: {
                        Text("Remove background").font(W.font(12)).underline().foregroundStyle(hoverRemove ? W.foreground : W.mutedForeground).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverRemove = $0 }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                }
                if let error {
                    Text(error).font(W.font(11.5)).foregroundStyle(W.mutedForeground).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                }
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let prepared = try CoverImage.prepare(url)
                let cover = try await CalendarAPI.uploadCover(prepared.data, mime: prepared.mime, width: prepared.width, height: prepared.height, name: prepared.name)
                store.adoptOrInsert(day: try await CalendarAPI.updateDay(date, coverID: .some(cover.id)))
                pops.close("day-photo-\(date)")
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? (error.localizedDescription.isEmpty ? "That didn't upload." : error.localizedDescription)
            }
        }
    }
}

/// `prepareCover` in lib/image.ts: downscale to 1800 on the long side and re-encode, stepping
/// the quality down until it fits 1.4 MB. Small GIFs pass through untouched.
enum CoverImage {
    static let maxEdge: CGFloat = 1800
    static let maxBytes = 1_400_000
    struct Prepared { let data: Data; let mime: String; let width: Int; let height: Int; let name: String }
    struct NotAnImage: LocalizedError { var errorDescription: String? { "That file isn't an image." } }
    struct CannotCompress: LocalizedError { var errorDescription: String? { "Couldn't compress that image." } }

    static func prepare(_ url: URL) throws -> Prepared {
        let raw = try Data(contentsOf: url)
        let name = String(url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.prefix(120) ?? "image")
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil), let type = CGImageSourceGetType(source) as String? else { throw NotAnImage() }
        if type == "com.compuserve.gif", raw.count <= maxBytes, let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return Prepared(data: raw, mime: "image/gif", width: cg.width, height: cg.height, name: name)
        }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw NotAnImage() }
        let scale = min(1, maxEdge / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int((CGFloat(cg.width) * scale).rounded())), height = max(1, Int((CGFloat(cg.height) * scale).rounded()))
        let hasAlpha = [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(cg.alphaInfo) && ["public.png", "org.webmproject.webp", "public.avif"].contains(type)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue) else { throw CannotCompress() }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = ctx.makeImage() else { throw CannotCompress() }
        let rep = NSBitmapImageRep(cgImage: scaled)
        if hasAlpha, let png = rep.representation(using: .png, properties: [:]) {
            return Prepared(data: png, mime: "image/png", width: width, height: height, name: name)
        }
        for q in [0.82, 0.72, 0.62, 0.5] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: q]), jpeg.count <= maxBytes || q == 0.5 {
                return Prepared(data: jpeg, mime: "image/jpeg", width: width, height: height, name: name)
            }
        }
        throw CannotCompress()
    }
}
