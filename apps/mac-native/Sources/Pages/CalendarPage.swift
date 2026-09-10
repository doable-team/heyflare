import SwiftUI
import AppKit

/// The calendar, in the style of Apple's Calendar app: a toolbar, then one of four views —
/// day, week, month, year — over one shared `CalendarStore`. The page owns the cursor, the
/// view, the loaded window and the keyboard; the views only draw and report.
struct CalendarPage: View {
    /// `?d=YYYY-MM-DD`: the day to open on. Nil lands on today.
    var initialDate: String? = nil

    @Environment(UIState.self) private var ui
    @Environment(SheetState.self) private var sheet
    @Environment(DialogState.self) private var dialogs
    @Environment(PopLayerState.self) private var pops
    @Environment(Router.self) private var router
    @State private var store = CalendarStore()
    @State private var view: CalView = .week
    @State private var viewChosen = false
    @State private var cursor: String
    @State private var win: CalWindow
    @State private var revealAt: RevealAt
    /// The week/day grid's scroll box, held here so PageUp/PageDown can move it by a viewport.
    @State private var gridScroll: ScrollController = { let c = ScrollController(); c.hidesScrollers = true; return c }()

    init(initialDate: String? = nil) {
        self.initialDate = initialDate
        let valid = initialDate.flatMap { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? $0 : nil }
        let start = valid ?? CalDate.todayKey
        _cursor = State(initialValue: start)
        _win = State(initialValue: CalendarPage.windowFor(.week, start, CalDate.cal))
        _revealAt = State(initialValue: RevealAt(date: start, nonce: 0))
    }

    private var cal: Calendar { store.calendar }
    private var today: String { CalDate.todayKey }
    private var overlayOpen: Bool { sheet.isOpen || dialogs.isOpen }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Group {
                switch view {
                case .day:
                    DayView(store: store, cursor: cursor, revealAt: revealAt, scroll: gridScroll, onEvent: edit, onCreate: createSpan, onSetCursor: setCursor, onRefresh: refresh)
                case .week:
                    WeekView(store: store, cursor: cursor, revealAt: revealAt, scroll: gridScroll, onEvent: edit, onCreate: createSpan, onSetCursor: setCursor, onRefresh: refresh)
                case .month:
                    MonthView(store: store, cursor: cursor, onEvent: edit, onSetCursor: setCursor, onOpenDay: { setCursor($0); setView(.day) })
                case .year:
                    YearView(store: store, cursor: cursor, onPick: { setCursor($0); setView(.day) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // `border border-border rounded-lg bg-background overflow-hidden`.
            .padding(1)
            .background(W.background)
            .clipShape(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.border, lineWidth: 1))
            .padding(.top, 8)
        }
        .task {
            await store.loadPrefs()
            // The saved default view applies until a view is picked.
            if !viewChosen, let v = CalView(pref: store.prefs.defaultView) { view = v }
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
        .onChange(of: win) { _, w in Task { await store.ensureRange(fromKey: w.from, toKey: w.to) } }
        .onChange(of: CalendarBus.shared.revision) { _, _ in Task { await refresh() } }
        // The arrows, Page Up/Down and Enter are the keys the sidebar also wants, so they alone
        // check where focus is; the letters work from any region.
        .onKeys([
            "ArrowUp": { move(-7) }, "ArrowDown": { move(7) },
            "ArrowLeft": { move(-1) }, "ArrowRight": { move(1) },
            "PageUp": { page(-1) }, "PageDown": { page(1) },
            "Enter": { if view == .month || view == .year { setView(.day) } },
        ], enabled: !overlayOpen && ui.region == .content)
        .onKeys([
            "t": { reveal(today) }, "d": { setView(.day) }, "w": { setView(.week) }, "m": { setView(.month) }, "y": { setView(.year) },
            "n": { create(day: cursor, start: 9 * 60, end: 10 * 60) },
            "j": { router.go(.journal(cursor)) }, "b": { router.go(.habits) },
        ], enabled: !overlayOpen)
    }

    // MARK: State

    /// The window a view needs loaded around a date: the month and its neighbours for the
    /// day, week and month; the whole year for the year.
    static func windowFor(_ view: CalView, _ date: String, _ cal: Calendar) -> CalWindow {
        if view == .year {
            let y = String(date.prefix(4))
            return CalWindow(from: "\(y)-01-01", to: "\(y)-12-31")
        }
        guard let d = CalDate.date(fromKey: date, in: cal) else { return CalWindow(from: date, to: date) }
        let first = CalDate.addingMonths(-1, to: CalDate.startOfMonth(d, in: cal), in: cal)
        let after = CalDate.addingMonths(2, to: CalDate.startOfMonth(d, in: cal), in: cal)
        return CalWindow(from: CalDate.key(first, in: cal), to: CalDate.key(CalDate.addingDays(-1, to: after, in: cal), in: cal))
    }

    private func setCursor(_ d: String) {
        cursor = d
        win = Self.windowFor(view, d, cal)
    }

    /// Distinct from `setCursor` because "Today" has to work when the cursor is already on
    /// today and you have simply scrolled away from it.
    private func reveal(_ d: String) {
        setCursor(d)
        revealAt = RevealAt(date: d, nonce: revealAt.nonce + 1)
    }

    private func setView(_ v: CalView) { view = v; viewChosen = true }

    private func move(_ days: Int) { setCursor(CalDate.addingDays(days, toKey: cursor, in: cal)) }

    /// Page Up/Down: the grid scrolls by a viewport; the month and year step by one of themselves.
    private func page(_ delta: Int) {
        switch view {
        case .day, .week:
            gridScroll.scrollTo(y: gridScroll.offset.y + CGFloat(delta) * gridScroll.viewport.height, animated: true)
        case .month: setCursor(stepMonths(delta))
        case .year: setCursor(stepYears(delta))
        }
    }

    private func refresh() async { await store.refreshRange(fromKey: win.from, toKey: win.to) }

    /// What ‹ › move by in each view.
    private func step(_ delta: Int) -> String {
        switch view {
        case .day: return CalDate.addingDays(delta, toKey: cursor, in: cal)
        case .week: return CalDate.addingDays(delta * 7, toKey: cursor, in: cal)
        case .month: return stepMonths(delta)
        case .year: return stepYears(delta)
        }
    }

    private func stepMonths(_ delta: Int) -> String {
        guard let d = CalDate.date(fromKey: cursor, in: cal) else { return cursor }
        return CalDate.key(CalDate.addingMonths(delta, to: d, in: cal), in: cal)
    }

    private func stepYears(_ delta: Int) -> String {
        guard let d = CalDate.date(fromKey: cursor, in: cal) else { return cursor }
        return CalDate.key(CalDate.addingMonths(delta * 12, to: d, in: cal), in: cal)
    }

    // MARK: Toolbar

    /// Month and year of the visible period: the week's Thursday, the day, the month; the year alone.
    private var title: String {
        switch view {
        case .year: return String(cursor.prefix(4))
        case .week:
            let ws = CalUI.weekStart(cursor, cal)
            let thursday = (0..<7).map { CalDate.addingDays($0, toKey: ws, in: cal) }.first { CalUI.dow($0, cal) == 4 } ?? ws
            return CalUI.monthLabel(thursday, cal)
        default: return CalUI.monthLabel(cursor, cal)
        }
    }

    private var toolbar: some View {
        let syncing = store.calendars.contains { $0.syncStatus == "syncing" }
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                WButton(icon: "chevronLeft", variant: .ghost, size: .iconSm, help: "Previous") { reveal(step(-1)) }
                WButton(icon: "chevronRight", variant: .ghost, size: .iconSm, help: "Next") { reveal(step(1)) }
            }
            Button { reveal(today) } label: { Text("Today") }
                .buttonStyle(.web(.ghost, .sm))
                .help("Today  t")
            Text(title).font(W.font(15, 600)).foregroundStyle(W.foreground).lineLimit(1)
            Spacer(minLength: 0)
            ViewSwitch(view: view) { setView($0) }
            WButton(icon: "calendarDays", variant: .ghost, size: .iconSm, expanded: pops.isOpen("cal-visible"), help: "Calendars") {
                pops.toggle("cal-visible", side: .bottom, align: .end) { CalendarsMenu(store: store) }
            }
            .popAnchor("cal-visible")
            // `h-8 px-3 text-[13px]` with the plus icon: the editor for the next half hour, an hour long.
            Button {
                let m = CalUI.nextHalfHour(cal)
                create(day: cursor, start: m, end: m + 60)
            } label: {
                HStack(spacing: 6) {
                    Icon("plus", size: 16)
                    Text("New").font(W.font(13, 500))
                }
                .padding(.horizontal, 2)
            }
            .buttonStyle(.web(.default))
            .help("New  n")
            if store.loading || syncing { RingSpinner().help("Loading") }
        }
        .frame(height: 44)
        .edgeLine(.bottom)
    }

    // MARK: Editor

    private func edit(_ e: CalEventFull) {
        sheet.present(title: "Event", width: 480) { EventSheet(store: store, target: .edit(e)) }
    }

    /// A sketch drawn on a column: the editor opens on those instants.
    private func createSpan(_ startsAt: Double, _ endsAt: Double) {
        let day = CalDate.key(Date(timeIntervalSince1970: startsAt / 1000), in: cal)
        let base = CalDate.ms(day, minutes: 0, in: cal)
        create(day: day, start: Int((startsAt - base) / 60_000), end: Int((endsAt - base) / 60_000))
    }

    private func create(day: String, start: Int, end: Int, draft: EventDraft? = nil) {
        sheet.present(title: "New event", width: 480) { EventSheet(store: store, target: .create(day: day, startMinutes: start, endMinutes: end, allDay: false), draft: draft) }
    }
}

/// The four views, in the order the switch shows them.
enum CalView: String, CaseIterable {
    case day, week, month, year

    var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }

    var key: String { String(rawValue.prefix(1)) }

    /// The settings' `default_view`, which still says `days` for the day.
    init?(pref: String) {
        switch pref {
        case "day", "days": self = .day
        case "week": self = .week
        case "month": self = .month
        case "year": self = .year
        default: return nil
        }
    }
}

/// `revealAt`: a date and a nonce, so asking twice for the same day still asks.
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

/// The view switch: a `bg-muted` pill, radius 6, padding 2; items `h-7 px-3 text-[13px]`, the
/// active one `bg-background text-foreground shadow-sm` at radius 4.
private struct ViewSwitch: View {
    let view: CalView
    var onPick: (CalView) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CalView.allCases, id: \.self) { v in
                SwitchItem(label: v.label, key: v.key, active: v == view) { onPick(v) }
            }
        }
        .padding(2)
        .background(W.muted)
        .rounded(W.radiusLg)
    }
}

private struct SwitchItem: View {
    let label: String
    let key: String
    let active: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(W.font(13))
                .foregroundStyle(active ? W.foreground : (hovering ? W.foreground : W.mutedForeground))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(active ? W.background : Color.clear)
                .rounded(W.radiusMd)
                .shadow(color: .black.opacity(active ? 0.05 : 0), radius: 1, y: 1)
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

/// The calendars popover — a dot, the name, an eye, and along the bottom Refresh all and Manage.
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
                Circle().fill(EventSurface.eventBar(calendar.color)).frame(width: 8, height: 8)
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

// MARK: - Shared helpers

enum CalUI {
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdayAbbr = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let monthAbbr = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let dayMs: Double = 86_400_000
    static let hourMs: Double = 3_600_000

    /// The one accent: `#ff3b30` in light, `#ff453a` in dark.
    static let red = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0x45 / 255, blue: 0x3a / 255, alpha: 1)
            : NSColor(srgbRed: 1, green: 0x3b / 255, blue: 0x30 / 255, alpha: 1)
    })

    /// The first day of the week containing `key`, by the owner's first weekday.
    static func weekStart(_ key: String, _ cal: Calendar) -> String {
        guard let d = CalDate.date(fromKey: key, in: cal) else { return key }
        let weekday = cal.component(.weekday, from: d) - 1
        let ws = cal.firstWeekday - 1
        let back = (weekday - ws + 7) % 7
        return CalDate.addingDays(-back, toKey: key, in: cal)
    }

    /// Calendar days from `a` to `b`, positive when `b` is later.
    static func daysBetween(_ a: String, _ b: String, _ cal: Calendar) -> Int {
        guard let x = CalDate.date(fromKey: a, in: cal), let y = CalDate.date(fromKey: b, in: cal) else { return 0 }
        return cal.dateComponents([.day], from: cal.startOfDay(for: x), to: cal.startOfDay(for: y)).day ?? 0
    }

    /// `getDay()`: 0 = Sunday.
    static func dow(_ key: String, _ cal: Calendar) -> Int {
        guard let d = CalDate.date(fromKey: key, in: cal) else { return 0 }
        return cal.component(.weekday, from: d) - 1
    }

    static func isWeekend(_ key: String, _ cal: Calendar) -> Bool { let d = dow(key, cal); return d == 0 || d == 6 }
    static func dayNumber(_ key: String) -> Int { Int(key.suffix(2)) ?? 0 }
    static func monthIndex(_ key: String) -> Int { (Int(key.dropFirst(5).prefix(2)) ?? 1) - 1 }

    /// "September 2026".
    static func monthLabel(_ key: String, _ cal: Calendar) -> String {
        "\(monthNames[monthIndex(key)]) \(key.prefix(4))"
    }

    /// Minutes past midnight of the next half hour from now.
    static func nextHalfHour(_ cal: Calendar) -> Int {
        let now = Date()
        let h = cal.component(.hour, from: now), m = cal.component(.minute, from: now)
        return (h * 60 + (m < 30 ? 30 : 60)) % 1440
    }

    static func is24(_ format: String) -> Bool { format == "24" }

    /// The gutter's hour: `12 AM`, `1 AM`, … `Noon`, … `11 PM`; `00:00` … `23:00` on a 24-hour clock.
    static func hourLabel(_ h: Int, _ format: String) -> String {
        if is24(format) { return String(format: "%02d:00", h) }
        if h == 0 { return "12 AM" }
        if h == 12 { return "Noon" }
        return h < 12 ? "\(h) AM" : "\(h - 12) PM"
    }

    /// A time: `9 AM`, `2:30 PM`; `09:00`, `14:30` on a 24-hour clock.
    static func timeLabel(_ ms: Double, _ format: String, _ cal: Calendar) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        if is24(format) { return String(format: "%02d:%02d", h, m) }
        let hh = h % 12 == 0 ? 12 : h % 12
        let ap = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(hh) \(ap)" : "\(hh):\(String(format: "%02d", m)) \(ap)"
    }

    /// `9:00 AM – 10:30 AM`, the line under a block's title.
    static func rangeLabel(_ a: Double, _ b: Double, _ format: String, _ cal: Calendar) -> String {
        "\(timeLabel(a, format, cal)) – \(timeLabel(b, format, cal))"
    }

    /// The now pill's `9:21` (`09:21` on a 24-hour clock).
    static func clockLabel(_ ms: Double, _ format: String, _ cal: Calendar) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        if is24(format) { return String(format: "%02d:%02d", h, m) }
        return "\(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", m))"
    }

    /// The first and last day keys an event covers: an all-day item's dates, a timed one's
    /// days on the clock (the end instant exclusive).
    static func dayRange(_ e: CalEventFull, _ cal: Calendar) -> (first: String, last: String) {
        if e.allDay, let s = e.startDate { return (s, e.endDate ?? s) }
        let first = CalDate.key(e.start, in: cal)
        let last = CalDate.key(Date(timeIntervalSince1970: max(e.endsAt - 1, e.startsAt) / 1000), in: cal)
        return (first, max(first, last))
    }
}

// MARK: - Event surfaces (`eventColors`)

/// A calendar's colour as the three things drawn from it: the fill at 22%, the bar at full
/// strength, and the ink — the colour pulled 25% toward black in light mode and toward white
/// in dark mode, so the title reads on the fill.
struct EventSurface {
    /// The colour a calendar without one gets.
    static let defaultHex = "#6b6b6b"

    let hex: String
    let fill: Color
    let bar: Color
    let ink: Color

    init(hex raw: String) {
        let hex = Self.normalize(raw) ?? Self.defaultHex
        self.hex = hex
        fill = Self.eventFill(hex)
        bar = Self.eventBar(hex)
        ink = Self.ink(hex)
    }

    init(_ e: CalEventFull) { self.init(hex: e.calendarColor) }

    /// `eventFill(hex)`: the colour at 22% alpha.
    static func eventFill(_ raw: String, alpha: Double = 0.22) -> Color {
        Color(hex: normalize(raw) ?? defaultHex).opacity(alpha)
    }

    /// `eventBar(hex)`: the colour itself.
    static func eventBar(_ raw: String) -> Color { Color(hex: normalize(raw) ?? defaultHex) }

    /// `eventInk(hex, dark)`: mixed 25% toward white in dark mode, toward black in light mode.
    static func eventInk(_ raw: String, dark: Bool) -> Color {
        let (r, g, b) = rgb(normalize(raw) ?? defaultHex)
        let t = dark ? 1.0 : 0.0
        return Color(.sRGB, red: r + (t - r) * 0.25, green: g + (t - g) * 0.25, blue: b + (t - b) * 0.25, opacity: 1)
    }

    /// The ink as one colour that follows the window's appearance.
    static func ink(_ raw: String) -> Color {
        let hex = normalize(raw) ?? defaultHex
        let (r, g, b) = rgb(hex)
        func mixed(_ t: CGFloat) -> NSColor { NSColor(srgbRed: r + (t - r) * 0.25, green: g + (t - g) * 0.25, blue: b + (t - b) * 0.25, alpha: 1) }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? mixed(1) : mixed(0)
        })
    }

    private static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x6b6b6b
        return (CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255)
    }

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

// MARK: - Scroll control

/// The scroll view behind a SwiftUI `ScrollView`, so a view can read and set the offset the
/// way the web reads `scrollTop` and calls `scrollTo`.
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

    /// No scroller at all, ever — the grid's hour scroll, whose gutter is its own ruler.
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
    func updateNSView(_ view: HookView, context: Context) {
        view.controller = controller
        if let sv = view.enclosingScrollView { controller.attach(sv) }
    }
    final class HookView: NSView {
        var controller: ScrollController?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let sv = enclosingScrollView { controller?.attach(sv) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Lane packing (all-day and multi-day spans)

/// An event laid across a run of day columns: which columns it covers, which lane it sits in,
/// and whether it was cut at either end by the visible range.
struct SpanPlacement: Identifiable {
    let event: CalEventFull
    let start: Int
    let end: Int
    let lane: Int
    let cutStart: Bool
    let cutEnd: Bool
    var id: String { event.id }
}

enum SpanLanes {
    /// Packs `events` over `days`: earliest first, longer first among equals, each taking the
    /// first lane free at its start column.
    static func place(_ events: [CalEventFull], days: [String], cal: Calendar) -> [SpanPlacement] {
        guard let first = days.first else { return [] }
        let n = days.count
        struct Raw { let e: CalEventFull; let start: Int; let end: Int; let cutStart: Bool; let cutEnd: Bool }
        var raw: [Raw] = []
        var seen: Set<String> = []
        for e in events where !seen.contains(e.id) {
            seen.insert(e.id)
            let r = CalUI.dayRange(e, cal)
            let a = CalUI.daysBetween(first, r.first, cal), b = CalUI.daysBetween(first, r.last, cal)
            if b < 0 || a > n - 1 { continue }
            raw.append(Raw(e: e, start: max(a, 0), end: min(max(b, a), n - 1), cutStart: a < 0, cutEnd: b > n - 1))
        }
        raw.sort { x, y in
            if x.start != y.start { return x.start < y.start }
            if x.end != y.end { return x.end > y.end }
            return (x.e.title, x.e.id) < (y.e.title, y.e.id)
        }
        var laneEnds: [Int] = []
        var out: [SpanPlacement] = []
        for r in raw {
            let lane = laneEnds.firstIndex { $0 < r.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(r.end) } else { laneEnds[lane] = r.end }
            out.append(SpanPlacement(event: r.e, start: r.start, end: r.end, lane: lane, cutStart: r.cutStart, cutEnd: r.cutEnd))
        }
        return out
    }
}

// MARK: - The time grid (week and day)

/// The grid both the week and the day draw: a 56px hour gutter, then equal day columns; a
/// 44px day header, an all-day row, and a scrolling 24-hour body at twelve hours a viewport.
struct TimeGrid: View {
    enum Style { case week, day }

    let store: CalendarStore
    let days: [String]
    let style: Style
    let cursor: String
    let revealAt: RevealAt
    let scroll: ScrollController
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void
    var onSetCursor: (String) -> Void
    var onRefresh: () async -> Void

    static let gutter: CGFloat = 56
    static let headerH: CGFloat = 44
    static let pillH: CGFloat = 20
    static let pillGap: CGFloat = 2
    static let maxPillRows = 3

    @State private var live: EventPreview?
    @State private var pending: EventPreview?
    @State private var now = Date()
    /// "week-2026-09-07-3": what the grid last scrolled into place for.
    @State private var landedFor = ""

    private var cal: Calendar { store.calendar }
    private var space: String { "grid" }
    private var preview: EventPreview? { live ?? pending }
    private var format: String { store.prefs.timeFormat }

    var body: some View {
        GeometryReader { g in
            let width = g.size.width
            let colW = max(1, (width - Self.gutter) / CGFloat(days.count))
            let pills = allDayPlacements()
            let lanes = (pills.map(\.lane).max() ?? -1) + 1
            let shownLanes = min(lanes, Self.maxPillRows)
            let extra = (0..<days.count).map { col in pills.filter { $0.lane >= shownLanes && $0.start <= col && $0.end >= col }.count }
            let more = extra.contains { $0 > 0 }
            let allDayH = max(28, 8 + CGFloat(shownLanes) * Self.pillH + CGFloat(max(0, shownLanes - 1)) * Self.pillGap + (more ? 16 : 0))
            let gridH = max(0, g.size.height - Self.headerH - allDayH)
            let pph = max(44, floor(gridH / 12))
            VStack(spacing: 0) {
                header(colW: colW).frame(width: width, height: Self.headerH, alignment: .topLeading).edgeLine(.bottom)
                allDayRow(colW: colW, pills: pills, shownLanes: shownLanes, extra: extra).frame(width: width, height: allDayH, alignment: .topLeading).edgeLine(.bottom)
                ScrollView(.vertical) {
                    gridBody(width: width, colW: colW, pph: pph)
                        .frame(width: width, height: 24 * pph, alignment: .topLeading)
                        .coordinateSpace(name: space)
                        .background(ScrollHook(controller: scroll))
                }
                .scrollIndicators(.hidden)
                .frame(height: gridH)
            }
        }
        .onAppear { land() }
        .onChange(of: scroll.viewport.height) { _, _ in land() }
        .onChange(of: scroll.content.height) { _, _ in land() }
        .onChange(of: landKey) { _, _ in land() }
        .task {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); now = Date() }
        }
    }

    // MARK: Scroll

    private var landKey: String { "\(days.first ?? "")-\(days.count)-\(revealAt.nonce)" }

    /// Where the body opens: the current time in the middle when the grid holds today, else 8 AM
    /// at the top. Re-applied whenever the shown days change and whenever "Today" or ‹ › ask.
    private func land() {
        let key = landKey
        guard landedFor != key, scroll.viewport.height > 0 else { return }
        let vh = scroll.viewport.height
        let pph = max(44, floor(vh / 12))
        guard scroll.content.height >= 24 * pph - 1 else { return }
        landedFor = key
        let today = CalDate.todayKey
        let y: CGFloat
        if days.contains(today) {
            let ms = Date().timeIntervalSince1970 * 1000
            let dayStart = CalDate.ms(today, minutes: 0, in: cal)
            y = CGFloat((ms - dayStart) / CalUI.hourMs) * pph - vh / 2
        } else {
            y = 8 * pph
        }
        scroll.scrollTo(y: max(0, y), animated: false)
    }

    // MARK: Header

    private func header(colW: CGFloat) -> some View {
        let today = CalDate.todayKey
        return ZStack(alignment: .topLeading) {
            ForEach(Array(days.enumerated()), id: \.element) { i, day in
                HStack(spacing: 4) {
                    Text(style == .day ? CalUI.weekdayNames[CalUI.dow(day, cal)] : CalUI.weekdayAbbr[CalUI.dow(day, cal)])
                        .font(W.font(13)).foregroundStyle(W.mutedForeground)
                    DayNumber(number: CalUI.dayNumber(day), today: day == today, cursor: day == cursor, size: 24, font: W.font(13, 600))
                }
                .frame(width: colW, height: Self.headerH)
                .offset(x: Self.gutter + CGFloat(i) * colW)
            }
            separators(colW: colW, height: Self.headerH)
        }
    }

    /// Column separators: `border-l border-border` on every day column.
    private func separators(colW: CGFloat, height: CGFloat?) -> some View {
        ForEach(0..<days.count, id: \.self) { i in
            Rectangle().fill(W.border).frame(width: 1).frame(height: height).frame(maxHeight: height == nil ? .infinity : nil).offset(x: Self.gutter + CGFloat(i) * colW)
        }
        .allowsHitTesting(false)
    }

    // MARK: All-day row

    /// Every all-day event touching the shown days, the dragged one drawn where it is going.
    private func allDayPlacements() -> [SpanPlacement] {
        var events: [CalEventFull] = []
        var seen: Set<String> = []
        for day in days {
            for e in store.events(onKey: day).allDay where !seen.contains(e.id) { seen.insert(e.id); events.append(e) }
        }
        if let p = preview, p.event.allDay {
            events = events.filter { $0.id != p.id } + [p.shown]
        }
        return SpanLanes.place(events, days: days, cal: cal)
    }

    private func allDayRow(colW: CGFloat, pills: [SpanPlacement], shownLanes: Int, extra: [Int]) -> some View {
        ZStack(alignment: .topLeading) {
            Text("all-day").font(W.font(11)).foregroundStyle(W.mutedForeground)
                .frame(width: Self.gutter - 8, height: Self.pillH, alignment: .trailing)
                .offset(y: 4)
            separators(colW: colW, height: nil)
            ForEach(pills.filter { $0.lane < shownLanes }) { p in
                AllDayPill(event: p.event, bar: !p.cutStart, dragging: preview?.id == p.event.id, space: space,
                           onTap: { onSetCursor(days[p.start]); onEvent(p.event) },
                           onDrag: { p0, p1, ended in drag(p.event, dayIndex: p.start, mode: .move, p0: p0, p1: p1, ended: ended, colW: colW, pph: 1) })
                    .frame(width: CGFloat(p.end - p.start + 1) * colW - 4, height: Self.pillH)
                    .offset(x: Self.gutter + CGFloat(p.start) * colW + 2, y: 4 + CGFloat(p.lane) * (Self.pillH + Self.pillGap))
            }
            ForEach(Array(extra.enumerated()), id: \.offset) { i, n in
                if n > 0 {
                    Text("+\(n) more").font(W.font(11)).foregroundStyle(W.mutedForeground).lineLimit(1)
                        .frame(width: colW - 4, height: 16, alignment: .leading)
                        .padding(.leading, 6)
                        .offset(x: Self.gutter + CGFloat(i) * colW + 2, y: 4 + CGFloat(shownLanes) * (Self.pillH + Self.pillGap))
                }
            }
        }
        .coordinateSpace(name: space)
    }

    // MARK: Body

    private func gridBody(width: CGFloat, colW: CGFloat, pph: CGFloat) -> some View {
        let today = CalDate.todayKey
        let nowMs = now.timeIntervalSince1970 * 1000
        let todayIndex = days.firstIndex(of: today)
        let nowY: CGFloat? = todayIndex.map { _ in CGFloat((nowMs - CalDate.ms(today, minutes: 0, in: cal)) / CalUI.hourMs) * pph }
        let daysW = width - Self.gutter
        return ZStack(alignment: .topLeading) {
            // Column tints: weekends `bg-muted/30`, today and the cursor day `bg-muted/50`.
            ForEach(Array(days.enumerated()), id: \.element) { i, day in
                let strong = day == today || day == cursor
                let weekend = CalUI.isWeekend(day, cal)
                if strong || weekend {
                    Rectangle().fill(W.muted.opacity(strong ? 0.5 : 0.3)).frame(width: colW, height: 24 * pph).offset(x: Self.gutter + CGFloat(i) * colW)
                }
            }
            // Hour lines across the day columns; half hours dotted.
            ForEach(1..<24, id: \.self) { h in
                Rectangle().fill(W.border).frame(width: daysW, height: 1).offset(x: Self.gutter, y: CGFloat(h) * pph)
            }
            ForEach(0..<24, id: \.self) { h in
                DottedRule().frame(width: daysW, height: 1).offset(x: Self.gutter, y: (CGFloat(h) + 0.5) * pph)
            }
            separators(colW: colW, height: 24 * pph)
            // The gutter: every hour but midnight, centred on its line; the one under the now pill hides.
            ForEach(1..<24, id: \.self) { h in
                let y = CGFloat(h) * pph
                if nowY.map({ abs($0 - y) >= 10 }) ?? true {
                    Text(CalUI.hourLabel(h, format)).font(W.font(11)).foregroundStyle(W.mutedForeground).lineLimit(1)
                        .frame(width: Self.gutter - 8, height: 16, alignment: .trailing)
                        .offset(y: y - 8)
                }
            }
            ForEach(Array(days.enumerated()), id: \.element) { i, day in
                GridColumn(store: store, day: day, dayIndex: i, colW: colW, pph: pph, preview: preview, space: space, format: format,
                           onEvent: onEvent, onCreate: onCreate, onSetCursor: onSetCursor,
                           onDrag: { e, mode, p0, p1, ended in drag(e, dayIndex: i, mode: mode, p0: p0, p1: p1, ended: ended, colW: colW, pph: pph) })
                    .frame(width: colW, height: 24 * pph)
                    .offset(x: Self.gutter + CGFloat(i) * colW)
            }
            if let i = todayIndex, let nowY, nowY >= 0, nowY <= 24 * pph {
                let x = Self.gutter + CGFloat(i) * colW
                Rectangle().fill(CalUI.red).frame(width: colW, height: 1).offset(x: x, y: nowY)
                Circle().fill(CalUI.red).frame(width: 7, height: 7).offset(x: x - 3.5, y: nowY - 3)
                Text(CalUI.clockLabel(nowMs, format, cal)).font(W.font(10, 600)).foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(CalUI.red))
                    .frame(width: Self.gutter - 8, alignment: .trailing)
                    .offset(y: nowY - 8)
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: Drags

    /// The pointer's travel as a column shift and a delta in time; the helpers do the rest.
    private func drag(_ e: CalEventFull, dayIndex: Int, mode: EventDrag.Mode, p0: CGPoint, p1: CGPoint, ended: Bool, colW: CGFloat, pph: CGFloat) {
        let dx = p1.x - p0.x
        let shift = mode == .move && colW > 0 ? max(-dayIndex, min(days.count - 1 - dayIndex, Int((dx / colW).rounded()))) : 0
        let span: EventDrag.Span
        if e.allDay {
            span = EventDrag.allDaySpan(e, days: shift, in: cal)
        } else {
            let delta = Double((p1.y - p0.y) / pph) * CalUI.hourMs
            let dayStart = CalDate.ms(days[dayIndex], minutes: 0, in: cal)
            span = EventDrag.span(e, mode: mode, deltaMs: delta, days: shift, bounds: (EventDrag.shiftDays(dayStart, shift, in: cal), EventDrag.shiftDays(dayStart, shift + 1, in: cal)), in: cal)
        }
        if !ended { live = EventPreview(event: e, span: span); return }
        live = nil
        guard EventDrag.moved(e, span) else { return }
        let p = EventPreview(event: e, span: span)
        pending = p
        DragCommit.commit(p, refresh: onRefresh) { if pending == p { pending = nil } }
    }
}

/// `border-border/50` dotted: one-point dots, one point apart.
private struct DottedRule: View {
    var body: some View {
        GeometryReader { g in
            Path { p in p.move(to: CGPoint(x: 0, y: 0.5)); p.addLine(to: CGPoint(x: g.size.width, y: 0.5)) }
                .stroke(W.border.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [1, 1]))
        }
        .allowsHitTesting(false)
    }
}

/// A day's number in a header: plain, or in a filled circle for today, or ringed for the cursor.
struct DayNumber: View {
    let number: Int
    let today: Bool
    let cursor: Bool
    var size: CGFloat = 24
    var font: Font = W.font(13, 600)

    var body: some View {
        Text("\(number)")
            .font(font)
            .foregroundStyle(today ? W.background : W.foreground)
            .frame(width: size, height: size)
            .background(today ? W.foreground : Color.clear)
            .overlay { if cursor && !today { Circle().strokeBorder(W.foreground, lineWidth: 1) } }
            .clipShape(Circle())
    }
}

/// One day column of the body: its events as blocks, the dragged ghost, and the sketch you
/// draw on empty space.
private struct GridColumn: View {
    let store: CalendarStore
    let day: String
    let dayIndex: Int
    let colW: CGFloat
    let pph: CGFloat
    let preview: EventPreview?
    let space: String
    let format: String
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void
    var onSetCursor: (String) -> Void
    var onDrag: (CalEventFull, EventDrag.Mode, CGPoint, CGPoint, Bool) -> Void

    @State private var sketch: (from: Double, to: Double)?

    private var cal: Calendar { store.calendar }
    private var dayStart: Double { CalDate.ms(day, minutes: 0, in: cal) }
    private var dayEnd: Double { CalDate.ms(CalDate.addingDays(1, toKey: day, in: cal), minutes: 0, in: cal) }
    private func y(_ ms: Double) -> CGFloat { CGFloat((ms - dayStart) / CalUI.hourMs) * pph }
    private func msAt(_ y: CGFloat) -> Double { EventDrag.snap(min(max(dayStart + Double(y / pph) * CalUI.hourMs, dayStart), dayEnd)) }

    var body: some View {
        let dayStart = dayStart, dayEnd = dayEnd
        // The dragged event is drawn where it is going, which may be another column: every
        // column drops it from its own list, and the ones its span lands in draw the ghost.
        let events = store.events(onKey: day).timed.filter { $0.id != preview?.id }
        let ghost: CalEventFull? = preview.flatMap { p in (!p.event.allDay && p.span.endsAt > dayStart && p.span.startsAt < dayEnd) ? p.shown : nil }
        let layout = CalDate.layoutColumns(events, floorMs: 0)
        let placed = CalDate.placeBlocks(events.map { (top: y(max($0.startsAt, dayStart)), bottom: y(min($0.endsAt, dayEnd))) }, slots: layout, minPx: 16, gapPx: 2)
        ZStack(alignment: .topLeading) {
            // Press to set the cursor; drag down the column to draw out a new event; a plain
            // click makes a half hour at the snapped time.
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    if sketch == nil {
                        onSetCursor(day)
                        let from = msAt(v.startLocation.y)
                        sketch = (from, from + 30 * 60_000)
                    }
                    if v.translation != .zero { sketch = (sketch!.from, msAt(v.location.y)) }
                }.onEnded { _ in
                    guard let s = sketch else { return }
                    sketch = nil
                    let a = min(s.from, s.to), b = max(s.from, s.to)
                    onCreate(a, b - a < EventDrag.minEventMs ? a + 30 * 60_000 : b)
                })
            ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                EventBlock(event: e, top: placed[i].top, height: placed[i].height, column: layout[i].column, columns: layout[i].columns, colW: colW, format: format, space: space,
                           onTap: { onSetCursor(day); onEvent(e) },
                           onDrag: { mode, p0, p1, ended in onDrag(e, mode, p0, p1, ended) })
                    .zIndex(Double(20 + i))
            }
            if let g = ghost {
                let top = y(max(g.startsAt, dayStart))
                EventBlock(event: g, top: top, height: y(min(g.endsAt, dayEnd)) - top, colW: colW, format: format, space: space, dragging: true, onTap: {})
                    .zIndex(90)
            }
            if let sketch {
                let a = y(min(sketch.from, sketch.to)), b = y(max(sketch.from, sketch.to))
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(W.foreground.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(W.foreground.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .frame(width: colW - 4, height: max(b - a, 4))
                    .offset(x: 2, y: a)
                    .allowsHitTesting(false)
                    .zIndex(95)
            }
        }
    }
}

/// A timed event: `rounded-[5px]`, the calendar colour at 22% with a 3px bar at full strength
/// down the left, the title in the event ink and — from 34 tall — the time under it.
struct EventBlock: View {
    let event: CalEventFull
    let top: CGFloat
    let height: CGFloat
    var column = 0
    var columns = 1
    let colW: CGFloat
    let format: String
    /// The coordinate space the drag reports in: the whole grid, so a move can cross columns.
    let space: String
    var dragging = false
    var onTap: () -> Void
    /// (mode, point at press, point now, ended) — nil for a block that cannot be dragged.
    var onDrag: ((EventDrag.Mode, CGPoint, CGPoint, Bool) -> Void)? = nil
    @State private var mode: EventDrag.Mode?
    @State private var hovering = false

    var body: some View {
        let s = EventSurface(event)
        let n = CGFloat(max(columns, 1))
        let width = max((colW - 4) / n - 1, 8)
        let left = (colW - 4) / n * CGFloat(column) + 2
        let h = max(height, 16)
        let showTime = h >= 34
        let declined = event.isDeclined
        let tentative = event.isTentative || event.rsvp == .tentative
        let struck = declined || (event.isTodo && event.done)
        let grab = EventDrag.handle(h)
        let cal = CalDate.cal
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                Text(event.displayTitle).font(W.font(12, 600)).strikethrough(struck).lineLimit(1)
                if event.recurring && width >= 90 { Spacer(minLength: 0); Icon("repeat", size: 10).padding(.top, 1) }
            }
            if showTime {
                Text(CalUI.rangeLabel(event.startsAt, event.endsAt, format, cal)).font(W.font(11)).opacity(0.8).lineLimit(1)
            }
        }
        .foregroundStyle(s.ink)
        .padding(.leading, 3 + 6).padding(.trailing, 6).padding(.vertical, 3)
        .frame(width: width, height: h, alignment: .topLeading)
        .background(EventSurface.eventFill(s.hex, alpha: (hovering && !dragging ? 0.30 : 0.22) * (tentative ? 0.6 : 1)))
        .overlay(alignment: .leading) { Rectangle().fill(s.bar).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay { if tentative { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(s.bar, style: StrokeStyle(lineWidth: 1, dash: [3])) } }
        .opacity(declined ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        // Press the block to move it, or either end (6px) to take that edge with you.
        .highPriorityGesture(DragGesture(minimumDistance: EventDrag.slop, coordinateSpace: .named(space)).onChanged { v in
            guard let onDrag, event.writable else { return }
            if mode == nil {
                let yIn = v.startLocation.y - top
                mode = yIn < grab ? .start : (yIn > h - grab ? .end : .move)
            }
            onDrag(mode!, v.startLocation, v.location, false)
        }.onEnded { v in
            guard let onDrag, let m = mode else { return }
            mode = nil
            onDrag(m, v.startLocation, v.location, true)
        })
        .offset(x: left, y: top)
        .help("\(event.displayTitle)\(event.location.isEmpty ? "" : " · \(event.location)") · \(CalUI.rangeLabel(event.startsAt, event.endsAt, format, cal))")
    }
}

/// An all-day pill: 20 tall, radius 4, `text-[11px] font-medium` in the ink on the 22% fill,
/// a 3px bar at the left unless the pill continues from before the visible range.
struct AllDayPill: View {
    let event: CalEventFull
    var bar = true
    var dragging = false
    var space = "grid"
    var onTap: () -> Void
    var onDrag: ((CGPoint, CGPoint, Bool) -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        let s = EventSurface(event)
        let declined = event.isDeclined
        Text(event.displayTitle)
            .font(W.font(11, 500))
            .strikethrough(declined || (event.isTodo && event.done))
            .lineLimit(1)
            .foregroundStyle(s.ink)
            .padding(.leading, (bar ? 3 : 0) + 6).padding(.trailing, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(EventSurface.eventFill(s.hex, alpha: hovering && !dragging ? 0.30 : 0.22))
            .overlay(alignment: .leading) { if bar { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(s.bar).frame(width: 3) } }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(declined ? 0.45 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onTap)
            .highPriorityGesture(DragGesture(minimumDistance: EventDrag.slop, coordinateSpace: .named(space)).onChanged { v in
                guard let onDrag, event.writable else { return }
                onDrag(v.startLocation, v.location, false)
            }.onEnded { v in
                guard let onDrag, event.writable else { return }
                onDrag(v.startLocation, v.location, true)
            })
            .help(event.displayTitle)
    }
}

// MARK: - Week

/// Seven columns from the owner's first weekday.
struct WeekView: View {
    let store: CalendarStore
    let cursor: String
    let revealAt: RevealAt
    let scroll: ScrollController
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void
    var onSetCursor: (String) -> Void
    var onRefresh: () async -> Void

    var body: some View {
        let cal = store.calendar
        let ws = CalUI.weekStart(cursor, cal)
        TimeGrid(store: store, days: (0..<7).map { CalDate.addingDays($0, toKey: ws, in: cal) }, style: .week, cursor: cursor, revealAt: revealAt, scroll: scroll,
                 onEvent: onEvent, onCreate: onCreate, onSetCursor: onSetCursor, onRefresh: onRefresh)
    }
}
