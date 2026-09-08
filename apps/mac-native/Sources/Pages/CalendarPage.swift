import SwiftUI

/// `Calendar.tsx`: toolbar, then the week stack, a day, or the year. Drawn to scale, with
/// the shared `CalendarStore` behind it. (The horizontal day ribbon and the journal stay
/// on the web for now; the day view here is a single vertical column.)
struct CalendarPage: View {
    @Environment(UIState.self) private var ui
    @Environment(SheetState.self) private var sheet
    @Environment(DialogState.self) private var dialogs
    @Environment(PopLayerState.self) private var pops
    @Environment(Router.self) private var router
    @State private var store = CalendarStore()
    @State private var view = "week"
    @State private var viewChosen = false
    @State private var cursor: String = CalDate.todayKey
    @State private var revision = 0
    /// Bumped by Today/`t` so the week stack re-centres even when the cursor did not move.
    @State private var reveal = 0

    private var cal: Calendar { store.calendar }
    private var cursorDate: Date { CalDate.date(fromKey: cursor, in: cal) ?? Date() }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            switch view {
            case "year": YearView(store: store, cursor: $cursor, onPick: { cursor = $0; view = "week" })
            case "days": ScrollView { DayColumnView(store: store, dayKey: cursor, onEvent: edit, onCreate: create).padding(.bottom, 24) }
            default: WeekStack(store: store, cursor: cursor, reveal: reveal, onEvent: edit, onCreate: create)
            }
        }
        .task {
            await store.loadPrefs()
            // `CalendarContext.tsx`: the saved default view applies until a view is picked.
            if !viewChosen, ["days", "week", "year"].contains(store.prefs.defaultView) { view = store.prefs.defaultView }
            await ensure()
            if let draft = ui.pendingEvent { ui.pendingEvent = nil; create(day: draft.dayKey, start: draft.startMinutes, end: draft.endMinutes, draft: draft) }
        }
        .onChange(of: cursor) { _, _ in Task { await ensure() } }
        .onChange(of: CalendarBus.shared.revision) { _, _ in Task { await store.refresh(month: cursorDate); revision += 1 } }
        .onKeys([
            "ArrowUp": { step(-1) }, "ArrowDown": { step(1) },
            "t": { goToday() }, "d": { pick("days") }, "w": { pick("week") }, "y": { pick("year") },
            "n": { create(day: cursor, start: 9 * 60, end: 10 * 60) },
            "j": { router.go(.journal(nil)) }, "b": { router.go(.habits) },
            "PageUp": { cursor = CalDate.addingDays(-7, toKey: cursor, in: cal) }, "PageDown": { cursor = CalDate.addingDays(7, toKey: cursor, in: cal) },
        ], enabled: ui.region == .content && !sheet.isOpen && !dialogs.isOpen)
    }

    private func ensure() async {
        await store.ensure(month: cursorDate)
        await store.ensure(month: cal.date(byAdding: .month, value: 1, to: cursorDate) ?? cursorDate)
        await store.ensure(month: cal.date(byAdding: .month, value: -1, to: cursorDate) ?? cursorDate)
    }

    private func pick(_ v: String) { view = v; viewChosen = true }
    private func goToday() { cursor = CalDate.todayKey; reveal += 1 }

    private func step(_ d: Int) {
        switch view {
        case "week": cursor = CalDate.addingDays(d * 7, toKey: cursor, in: cal)
        case "year": cursor = CalDate.key(cal.date(byAdding: .year, value: d, to: cursorDate) ?? cursorDate, in: cal)
        default: cursor = CalDate.addingDays(d, toKey: cursor, in: cal)
        }
    }

    private var title: String {
        view == "year" ? String(cursor.prefix(4)) : Fmt.monthKey(cursorDate.timeIntervalSince1970 * 1000)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            WButton(icon: "chevronLeft", variant: .ghost, size: .iconSm, help: "Previous") { step(-1) }
            WButton(icon: "chevronRight", variant: .ghost, size: .iconSm, help: "Next") { step(1) }
            WButton("Today", variant: .ghost, size: .sm) { goToday() }
            Text(title).font(W.font(14, 500)).monospacedDigit().padding(.leading, 4)
            Spacer()
            HStack(spacing: 0) {
                ForEach([("days", "Day", "d"), ("week", "Week", "w"), ("year", "Year", "y")], id: \.0) { v in
                    Button { pick(v.0) } label: {
                        Text(v.1).font(W.font(12.8, 500)).foregroundStyle(view == v.0 ? W.foreground : W.mutedForeground)
                            .padding(.horizontal, 10).frame(height: 24).background(view == v.0 ? W.muted : Color.clear).rounded(W.radiusSm + 2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("\(v.1)  \(v.2)")
                }
            }
            .padding(2).overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1))
            WButton(icon: "calendarDays", variant: .ghost, size: .iconSm, muted: true, help: "Calendars") {
                pops.toggle("cal-visible", side: .bottom, align: .end) { CalendarsMenu(store: store) }
            }
            .popAnchor("cal-visible")
            WButton("New", icon: "plus", size: .sm, kbd: "n") { create(day: cursor, start: 9 * 60, end: 10 * 60) }
        }
        .padding(.bottom, 8)
    }

    private func edit(_ e: CalEventFull) {
        sheet.present(title: "Event", width: 480) { EventSheet(store: store, target: .edit(e)) }
    }

    private func create(day: String, start: Int, end: Int, draft: EventDraft? = nil) {
        sheet.present(title: "New event", width: 480) { EventSheet(store: store, target: .create(day: day, startMinutes: start, endMinutes: end, allDay: false), draft: draft) }
    }
}

// MARK: - Week

/// Three weeks stacked, the cursor's in the middle, each week seven columns with the hours
/// down the left and all-day events pinned to the bottom, as HEY draws it.
struct WeekStack: View {
    let store: CalendarStore
    let cursor: String
    var reveal = 0
    var onEvent: (CalEventFull) -> Void
    var onCreate: (String, Int, Int, EventDraft?) -> Void

    private var cal: Calendar { store.calendar }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    ForEach([-1, 0, 1], id: \.self) { offset in
                        let start = weekStart(offset)
                        WeekView(store: store, start: start, current: offset == 0, onEvent: onEvent, onCreate: onCreate).id(offset)
                    }
                }
                .padding(.vertical, 8)
            }
            // Overlay scrollers, like the browser's: the grid keeps the full width.
            .scrollIndicators(.never)
            .onAppear { proxy.scrollTo(0, anchor: .top) }
            .onChange(of: cursor) { _, _ in proxy.scrollTo(0, anchor: .top) }
            .onChange(of: reveal) { _, _ in proxy.scrollTo(0, anchor: .top) }
        }
    }

    private func weekStart(_ offset: Int) -> Date {
        let d = CalDate.date(fromKey: cursor, in: cal) ?? Date()
        let weekday = cal.component(.weekday, from: d) - 1
        // Before prefs load `weekStart` is -1; `cal` already carries the resolved first weekday.
        let ws = cal.firstWeekday - 1
        let back = (weekday - ws + 7) % 7
        let start = cal.date(byAdding: .day, value: -back, to: cal.startOfDay(for: d)) ?? d
        return cal.date(byAdding: .day, value: offset * 7, to: start) ?? start
    }
}

struct WeekView: View {
    let store: CalendarStore
    let start: Date
    var current = false
    var onEvent: (CalEventFull) -> Void
    var onCreate: (String, Int, Int, EventDraft?) -> Void

    private var cal: Calendar { store.calendar }
    private let hourHeight: CGFloat = 57.5 / 3  // three hours measure 57.5pt on the web
    private var days: [Date] { (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // `w-6` rail: the month once, on its side, taking no width from the days.
                Text(monthLabel)
                    .font(W.font(15)).tracking(0.9).foregroundStyle(W.foreground.opacity(0.25))
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                    .clipped()
                // Hour gutter: `text-[9.5px] text-tertiary`, `right-1`, centred on its line.
                VStack(alignment: .trailing, spacing: 0) {
                    Color.clear.frame(height: 40)
                    ZStack(alignment: .topTrailing) {
                        ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { h in
                            Text(hourLabel(h)).font(W.font(9.5)).foregroundStyle(W.tertiary).offset(y: CGFloat(h) * hourHeight - 4.75)
                        }
                    }
                    .frame(height: 24 * hourHeight, alignment: .top)
                    .padding(.trailing, 4)
                }
                .frame(width: 36)
                ForEach(days, id: \.self) { day in
                    let key = CalDate.key(day, in: cal)
                    let events = store.events(onKey: key)
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Text(weekdayLabel(day)).font(W.font(11, 500)).tracking(1).foregroundStyle(W.mutedForeground)
                            Text("\(cal.component(.day, from: day))").font(W.font(15, 700)).monospacedDigit()
                        }
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(cal.isDateInToday(day) ? W.foreground : Color.clear)
                        .foregroundStyle(cal.isDateInToday(day) ? W.primaryForeground : W.foreground)
                        .clipShape(Capsule())
                        .frame(height: 40)
                        ZStack(alignment: .top) {
                            VStack(spacing: 0) {
                                ForEach(0..<24, id: \.self) { _ in Rectangle().fill(Color.clear).frame(height: hourHeight).overlay(alignment: .top) { Rectangle().fill(W.border.opacity(0.6)).frame(height: 1) } }
                            }
                            // The floor is the week's, 8pt: at this scale a taller floor would
                            // reserve room a short lunch never takes and shoulder the next
                            // meeting into a second column for an overlap that never happens.
                            let layout = CalDate.layoutColumns(events.timed, floorMs: 8 / hourHeight * 3_600_000)
                            ForEach(Array(events.timed.enumerated()), id: \.element.id) { i, e in
                                let span = CalDate.clipToDay(e, day: day, in: cal)
                                let top = CGFloat(span.start) / 60 * hourHeight
                                let height = max(8, CGFloat(span.end - span.start) / 60 * hourHeight)
                                EventBlock(event: e, height: height, column: layout[i].column, columns: layout[i].columns, timeFormat: store.prefs.timeFormat, onTap: { onEvent(e) })
                                    .offset(y: top)
                            }
                            if cal.isDateInToday(day) {
                                let now = CGFloat(cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())) / 60 * hourHeight
                                HStack(spacing: 4) {
                                    Text(heyTime(Date())).font(W.font(10)).foregroundStyle(.red)
                                    Rectangle().fill(.red).frame(height: 1).overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [2])).foregroundStyle(.red))
                                }
                                .offset(y: now - 6)
                            }
                        }
                        .frame(height: 24 * hourHeight, alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let minutes = Int(location.y / hourHeight * 60 / 30) * 30
                            onCreate(key, minutes, minutes + 60, nil)
                        }
                        VStack(spacing: 2) {
                            ForEach(events.allDay) { e in
                                Button { onEvent(e) } label: {
                                    let s = EventSurface(e)
                                    Text(e.displayTitle).font(W.font(11, 500)).lineLimit(1).foregroundStyle(s.ink).padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 18).background(s.fill).clipShape(Capsule())
                                        .overlay { if e.isTentative { Capsule().strokeBorder(W.foreground.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3])) } }
                                        .opacity(e.isCancelled ? 0.45 : 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                        .frame(minHeight: 28, alignment: .top)
                    }
                    .frame(maxWidth: .infinity)
                    .edgeLine(.leading, W.border.opacity(0.6))
                }
            }
            HStack(spacing: 8) {
                Text("SOMETIME THIS WEEK:").font(W.font(10.5)).tracking(1.155).foregroundStyle(W.tertiary)
                WButton(icon: "plus", variant: .outline, size: .iconXs, muted: true) { onCreate(CalDate.key(start, in: cal), 9 * 60, 10 * 60, nil) }
                Spacer()
            }
            .padding(.leading, 4).padding(.vertical, 8)
        }
        .padding(.horizontal, 1)
        .overlay { if current { RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.border, lineWidth: 1) } }
        .rounded(W.radiusLg)
    }

    private var monthLabel: String {
        let f = DateFormatter(); f.calendar = cal; f.setLocalizedDateFormatFromTemplate("MMMM")
        return f.string(from: days[3]).uppercased()
    }
    private func weekdayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = cal; f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: d).uppercased()
    }
    /// `heyTime` in calendar/scale.ts: "11:34AM", "11AM", or "23:34" — never a space.
    private func heyTime(_ d: Date) -> String {
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        if store.prefs.timeFormat == "24" { return String(format: "%02d:%02d", h, m) }
        let hh = h % 12 == 0 ? 12 : h % 12
        let ap = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(hh)\(ap)" : "\(hh):\(String(format: "%02d", m))\(ap)"
    }
    private func hourLabel(_ h: Int) -> String {
        if store.prefs.timeFormat == "24" { return String(format: "%02d", h) }
        let x = h % 12 == 0 ? 12 : h % 12
        return "\(x)\(h < 12 ? "a" : "p")"
    }
}

/// `eventColors` in calendar/colors.ts: the calendar's colour as a solid fill, the text
/// flipped to whichever of near-white or near-black actually contrasts. A maybe (tentative)
/// is drawn without colour, on white with a dashed edge.
struct EventSurface {
    let fill: Color
    let ink: Color
    static let defaultFill = "#1f1f1f"

    init(_ e: CalEventFull) {
        if e.isTentative || e.rsvp == .tentative {
            fill = Color(hex: "#ffffff"); ink = Color(hex: "#131313")
            return
        }
        let hex = Self.normalize(e.calendarColor) ?? Self.defaultFill
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0x1f1f1f
        let r = Double((v >> 16) & 0xff) / 255, g = Double((v >> 8) & 0xff) / 255, b = Double(v & 0xff) / 255
        let lin: (Double) -> Double = { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let L = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        fill = Color(hex: hex)
        ink = Color(hex: 1.05 / (L + 0.05) >= (L + 0.05) / 0.05 ? "#fbfbfa" : "#131313")
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

/// `EventBlock` (timed) in EventBlock.tsx: a proportional box in its calendar's colour, the
/// title flipped to contrast. Under 13pt it is a bare bar of colour; under 34pt the time and
/// the title share one line; taller blocks carry the range over the title, and from 64pt the
/// small icons along the floor. Overlapping neighbours split the column between them with
/// two points of air at each edge and a hairline between.
struct EventBlock: View {
    let event: CalEventFull
    var height: CGFloat
    var column = 0
    var columns = 1
    var timeFormat = "12"
    var onTap: () -> Void

    private var bare: Bool { height < 13 }
    private var oneLine: Bool { height < 34 }
    private var roomy: Bool { height >= 64 }
    private var titleLines: Int { max(1, min(3, Int((height - 6 - 12) / 14))) }
    private var declined: Bool { event.rsvp == .declined }
    private var maybe: Bool { event.isTentative || event.rsvp == .tentative }

    var body: some View {
        let s = EventSurface(event)
        GeometryReader { g in
            let n = CGFloat(max(columns, 1))
            let width = (g.size.width - 4) / n - (n > 1 ? 1 : 0)
            let left = (g.size.width - 4) / n * CGFloat(column) + 2
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 0) {
                    if bare {
                        EmptyView()
                    } else if oneLine {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(heyTime(event.start)).font(W.font(9.5)).monospacedDigit().opacity(0.7).fixedSize()
                            Text(titleText).font(W.font(11, 600)).italic(maybe).strikethrough(event.done || declined).lineLimit(1)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    } else {
                        Text("\(heyTime(event.start))- \(heyTime(event.end))").font(W.font(9.5)).monospacedDigit().opacity(0.7).lineLimit(1).frame(height: 12)
                        Text(titleText).font(W.font(12, 600)).italic(maybe).strikethrough(event.done || declined).lineLimit(titleLines).webLine(12, 14, weight: 600)
                        if roomy && (!event.conferenceURL.isEmpty || !event.attendees.isEmpty || event.recurring || !event.writable) {
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
                }
                .foregroundStyle(s.ink)
                .padding(.horizontal, 6).padding(.vertical, oneLine ? 0 : 3)
                .frame(width: width, height: height, alignment: .topLeading)
                .background(s.fill)
                .clipped()
                .overlay { if maybe { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3])) } }
                .opacity(declined || event.isCancelled ? 0.45 : 1)
                .rounded(3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(x: left)
        }
        .frame(height: height)
        .help("\(titleText)\(event.location.isEmpty ? "" : " · \(event.location)") · \(heyTime(event.start))- \(heyTime(event.end))")
    }

    private var titleText: String { (event.emoji.isEmpty ? "" : "\(event.emoji) ") + (event.title.isEmpty ? "(no title)" : event.title) }

    private func heyTime(_ d: Date) -> String {
        let cal = CalDate.cal
        let h = cal.component(.hour, from: d), m = cal.component(.minute, from: d)
        if timeFormat == "24" { return String(format: "%02d:%02d", h, m) }
        let hh = h % 12 == 0 ? 12 : h % 12
        let ap = h < 12 ? "AM" : "PM"
        return m == 0 ? "\(hh)\(ap)" : "\(hh):\(String(format: "%02d", m))\(ap)"
    }
}

// MARK: - Day

struct DayColumnView: View {
    let store: CalendarStore
    let dayKey: String
    var onEvent: (CalEventFull) -> Void
    var onCreate: (String, Int, Int, EventDraft?) -> Void
    private var cal: Calendar { store.calendar }
    private let hourHeight: CGFloat = 48

    var body: some View {
        let events = store.events(onKey: dayKey)
        let day = CalDate.date(fromKey: dayKey, in: cal) ?? Date()
        VStack(alignment: .leading, spacing: 8) {
            Text(CalDate.dayLabel(day)).font(W.font(20, 600)).tracking(-0.2).padding(.horizontal, 8)
            if !events.allDay.isEmpty {
                HStack(spacing: 6) { ForEach(events.allDay) { e in Button { onEvent(e) } label: { let s = EventSurface(e); Text(e.displayTitle).font(W.font(12, 500)).foregroundStyle(s.ink).padding(.horizontal, 10).frame(height: 24).background(s.fill).clipShape(Capsule()) }.buttonStyle(.plain) } }.padding(.horizontal, 8)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(0..<24, id: \.self) { h in Text(String(format: "%d:00", h)).font(W.font(11)).monospacedDigit().foregroundStyle(W.mutedForeground).frame(height: hourHeight, alignment: .top).offset(y: -6) }
                }
                .frame(width: 48)
                ZStack(alignment: .top) {
                    VStack(spacing: 0) { ForEach(0..<24, id: \.self) { _ in Rectangle().fill(Color.clear).frame(height: hourHeight).overlay(alignment: .top) { Rectangle().fill(W.border).frame(height: 1) } } }
                    let layout = CalDate.layoutColumns(events.timed, floorMs: 22 / hourHeight * 3_600_000)
                    ForEach(Array(events.timed.enumerated()), id: \.element.id) { i, e in
                        let span = CalDate.clipToDay(e, day: day, in: cal)
                        let top = CGFloat(span.start) / 60 * hourHeight
                        let height = max(22, CGFloat(span.end - span.start) / 60 * hourHeight)
                        EventBlock(event: e, height: height, column: layout[i].column, columns: layout[i].columns, timeFormat: store.prefs.timeFormat, onTap: { onEvent(e) })
                            .offset(y: top)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { location in let m = Int(location.y / hourHeight * 60 / 30) * 30; onCreate(dayKey, m, m + 60, nil) }
            }
            .frame(maxWidth: 760)
        }
    }
}

// MARK: - Year

struct YearView: View {
    let store: CalendarStore
    @Binding var cursor: String
    var onPick: (String) -> Void
    private var cal: Calendar { store.calendar }

    var body: some View {
        let year = Int(cursor.prefix(4)) ?? cal.component(.year, from: Date())
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 4), spacing: 24) {
                ForEach(1...12, id: \.self) { m in
                    let first = cal.date(from: DateComponents(year: year, month: m, day: 1)) ?? Date()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Fmt.monthKey(first.timeIntervalSince1970 * 1000).components(separatedBy: " ").first ?? "").font(W.font(13, 600))
                        let grid = CalDate.monthGrid(for: first, in: cal)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                            ForEach(grid, id: \.self) { d in
                                let key = CalDate.key(d, in: cal)
                                let inMonth = cal.isDate(d, equalTo: first, toGranularity: .month)
                                let busy = !store.events(onKey: key).isEmpty
                                Button { onPick(key) } label: {
                                    Text("\(cal.component(.day, from: d))").font(W.font(11, busy ? 600 : 400)).monospacedDigit()
                                        .foregroundStyle(cal.isDateInToday(d) ? W.primaryForeground : inMonth ? W.foreground : W.tertiary.opacity(0.4))
                                        .frame(width: 22, height: 22)
                                        .background(cal.isDateInToday(d) ? W.foreground : Color.clear)
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .task { await store.ensure(month: first) }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Editor

enum MacEventTarget: Hashable {
    case create(day: String, startMinutes: Int, endMinutes: Int, allDay: Bool)
    case edit(CalEventFull)
}

/// `EventSheet`: the event editor in the right-hand sheet.
struct EventSheet: View {
    let store: CalendarStore
    let target: MacEventTarget
    var draft: EventDraft? = nil

    @Environment(SheetState.self) private var sheet
    @Environment(DialogState.self) private var dialogs
    @Environment(PopLayerState.self) private var pops
    @State private var title = ""
    @State private var calendarID = ""
    @State private var allDay = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var location = ""
    @State private var notes = ""
    @State private var url = ""
    @State private var busy = false

    private var event: CalEventFull? { if case .edit(let e) = target { return e }; return nil }
    private var writable: Bool { event?.writable ?? true }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Title", text: $title).textFieldStyle(.plain).font(W.font(20, 600)).tracking(-0.2).foregroundStyle(W.foreground)
                    field("Calendar") {
                        Button {
                            pops.toggle("event-cal", side: .bottom, align: .start) { PopCard(width: 224) { ForEach(store.calendars.filter(\.writable)) { c in MenuItem(c.name, checked: c.id == calendarID) { calendarID = c.id } } } }
                        } label: { HStack(spacing: 6) { Text(store.calendars.first { $0.id == calendarID }?.name ?? "Calendar").font(W.sm); Icon("chevronDown", size: 14).foregroundStyle(W.mutedForeground) }.padding(.horizontal, 10).frame(height: 32).background(W.input).rounded(W.radiusMd).contentShape(Rectangle()) }
                        .buttonStyle(.plain).popAnchor("event-cal")
                    }
                    field("All day") { WSwitch(on: $allDay) }
                    field("Starts") { DatePicker("", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.field) }
                    field("Ends") { DatePicker("", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.field) }
                    field("Location") { WTextField(placeholder: "Where", text: $location) }
                    field("Link") { WTextField(placeholder: "https://", text: $url) }
                    VStack(alignment: .leading, spacing: 6) { Text("Notes").font(W.s13).foregroundStyle(W.mutedForeground); WTextArea(placeholder: "Anything to remember", text: $notes, minHeight: 96) }
                    if let e = event, !e.attendees.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("People").font(W.s13).foregroundStyle(W.mutedForeground)
                            ForEach(e.attendees, id: \.email) { a in HStack(spacing: 8) { WAvatar(email: a.email, name: a.name, size: 20); Text(a.name.isEmpty ? a.email : a.name).font(W.sm) } }
                        }
                    }
                }
                .padding(16)
            }
            HStack(spacing: 8) {
                if let e = event, e.writable {
                    WButton("Delete", icon: "trash2", variant: .ghost, size: .sm, muted: true) {
                        if e.recurring { askScope(delete: true) { scope in Task { await remove(e, scope: scope) } } }
                        else { dialogs.confirm(title: "Delete this event?", action: "Delete") { Task { await remove(e, scope: nil) } } }
                    }
                }
                Spacer()
                WButton("Cancel", variant: .ghost) { sheet.dismiss() }
                WButton(event == nil ? "Create" : "Save") { requestSave() }.disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty || !writable)
            }
            .padding(12).edgeLine(.top)
        }
        .onAppear(perform: seed)
    }

    /// `requestSave` in EventSheet.tsx: a repeating event asks which occurrences a save means.
    /// Not a Google-expanded series, whose rows carry no rule, so every scope would be the same.
    private func requestSave() {
        if let e = event, e.recurring, !e.series { askScope(delete: false) { scope in Task { await save(scope: scope) } } }
        else { Task { await save(scope: nil) } }
    }

    private func askScope(delete: Bool, then: @escaping (EventScope) -> Void) {
        let id = "event-scope"
        dialogs.present(id) {
            VStack(alignment: .leading, spacing: 8) {
                Text(delete ? "Delete which events?" : "Save to which events?").font(W.font(16, 500)).webLine(16, weight: 500).foregroundStyle(W.foreground)
                Text("“\(title.trimmingCharacters(in: .whitespaces).isEmpty ? "This event" : title.trimmingCharacters(in: .whitespaces))” repeats. Choose how far the change reaches.")
                    .font(W.sm).foregroundStyle(W.mutedForeground).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    ForEach(EventScope.allCases, id: \.self) { scope in
                        WButton(scope.title, variant: .outline, fullWidth: true) { dialogs.dismiss(id); then(scope) }
                    }
                }
                .padding(.top, 8)
                HStack { Spacer(); WButton("Cancel", variant: .outline) { dialogs.dismiss(id) } }.padding(.top, 8)
            }
            .padding(16)
        }
    }

    private func remove(_ e: CalEventFull, scope: EventScope?) async {
        do { try await CalendarAPI.deleteEvent(id: e.id, scope: scope); CalendarBus.shared.changed(); sheet.dismiss() }
        catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? "Couldn't delete this event.") }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) { Text(label).font(W.s13).foregroundStyle(W.mutedForeground).frame(width: 72, alignment: .leading); content(); Spacer(minLength: 0) }
    }

    private func seed() {
        let cal = store.calendar
        calendarID = store.defaultCalendarID
        switch target {
        case .create(let day, let from, let to, let isAllDay):
            allDay = isAllDay
            let base = cal.startOfDay(for: CalDate.date(fromKey: day, in: cal) ?? Date())
            start = cal.date(byAdding: .minute, value: from, to: base) ?? base
            end = cal.date(byAdding: .minute, value: to, to: base) ?? base
            if let draft { title = draft.title; notes = draft.description; start = Date(timeIntervalSince1970: draft.startsAt / 1000); end = Date(timeIntervalSince1970: draft.endsAt / 1000) }
        case .edit(let e):
            title = e.title; calendarID = e.calendarID; allDay = e.allDay
            location = e.location; notes = e.description; url = e.url
            if e.allDay {
                // `ends_at` on an all-day row is the midnight *after* the last day, and Google's
                // rows carry UTC midnights: the date strings are the days the person means
                // (`makeForm` in EventSheet.tsx). Seeding from the instants grew the event by a
                // day on every save.
                start = CalDate.date(fromKey: e.startDate ?? CalDate.key(e.start, in: cal), in: cal) ?? e.start
                end = CalDate.date(fromKey: e.endDate ?? CalDate.key(e.end.addingTimeInterval(-1), in: cal), in: cal) ?? e.end
            } else {
                start = e.start; end = e.end
            }
        }
    }

    private func save(scope: EventScope?) async {
        busy = true; defer { busy = false }
        let cal = store.calendar
        var input = EventInput()
        input.calendarID = calendarID
        input.title = title.trimmingCharacters(in: .whitespaces)
        input.location = location.trimmingCharacters(in: .whitespaces)
        input.description = notes
        input.url = url
        input.allDay = allDay
        input.timezone = store.prefs.timezone.isEmpty ? TimeZone.current.identifier : store.prefs.timezone
        if allDay {
            let s = CalDate.key(start, in: cal), e = CalDate.key(max(start, end), in: cal)
            input.startDate = .some(s); input.endDate = .some(e)
            input.startsAt = CalDate.ms(s, minutes: 0, in: cal); input.endsAt = CalDate.ms(CalDate.addingDays(1, toKey: e, in: cal), minutes: 0, in: cal)
        } else {
            input.startDate = .some(nil); input.endDate = .some(nil)
            input.startsAt = start.timeIntervalSince1970 * 1000
            input.endsAt = max(end, start.addingTimeInterval(900)).timeIntervalSince1970 * 1000
        }
        if let draft, !draft.attendees.isEmpty { input.attendees = draft.attendees.map { ["email": $0.email, "name": $0.name] } }
        do {
            if let event { _ = try await CalendarAPI.updateEvent(id: event.id, scope: scope, input: input) } else { _ = try await CalendarAPI.createEvent(input) }
            CalendarBus.shared.changed()
            sheet.dismiss()
        } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? "Couldn't save this event.") }
    }
}


/// `CalendarToolbar.tsx`: the calendars, ticked to show, with Refresh all and Manage.
private struct CalendarsMenu: View {
    let store: CalendarStore
    @Environment(PopLayerState.self) private var pops
    @Environment(Router.self) private var router
    @State private var syncing = false

    var body: some View {
        PopCard(width: 240) {
            if store.calendars.isEmpty {
                Text("No calendars yet.").font(W.sm).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 6)
            }
            ForEach(store.calendars) { c in
                MenuItem(c.name, checked: c.visible) {
                    Task {
                        do { _ = try await CalendarAPI.updateSource(id: c.id, visible: !c.visible); await store.loadCalendars(); CalendarBus.shared.changed() }
                        catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
                    }
                }
            }
            MenuSeparator()
            MenuItem(syncing ? "Refreshing…" : "Refresh all", icon: "refreshCw") {
                guard !syncing else { return }
                syncing = true
                Task { defer { syncing = false }; try? await CalendarAPI.syncSources(); CalendarBus.shared.changed() }
            }
            MenuItem("Manage calendars", icon: "settings") { pops.closeAll(); router.go(.settings("calendar")) }
        }
    }
}
