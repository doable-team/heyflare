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
            case "days": DayRibbonView(store: store, cursor: cursor, reveal: reveal, onEvent: edit, onCreate: createSpan)
            default: WeekStack(store: store, cursor: cursor, reveal: reveal, onEvent: edit, onCreate: createSpan)
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

// MARK: - Week

/// Three weeks stacked, the cursor's in the middle, each week seven columns with the hours
/// down the left and all-day events pinned to the bottom, as HEY draws it.
struct WeekStack: View {
    let store: CalendarStore
    let cursor: String
    var reveal = 0
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void

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
    /// A new event, from one instant to another — the sketch drawn out on a column.
    var onCreate: (Double, Double) -> Void

    @State private var live: EventPreview?
    @State private var pending: EventPreview?
    @State private var sketch: (from: Double, to: Double)?
    @State private var gridWidth: CGFloat = 0

    private var cal: Calendar { store.calendar }
    /// Three hours measure 57.5pt on the web's week.
    private let pxPerHour: CGFloat = 57.5 / 3
    /// The night, folded: this tall for the whole of it, unless something is scheduled in it.
    private let nightBand: CGFloat = 16
    private let headerH: CGFloat = 40
    private var days: [Date] { (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) } }
    private var space: String { "week-\(CalDate.key(start, in: cal))" }
    private var preview: EventPreview? { live ?? pending }

    /// The week shows the waking hours from Settings; the night is folded to a thin band, and
    /// opens to full scale only when something in this week is actually scheduled in it.
    private var collapse: Bool {
        guard store.prefs.collapseNight else { return false }
        for day in days {
            let r = ribbon(for: day, collapse: true)
            for run in r.runs where run.night {
                if store.events(onKey: CalDate.key(day, in: cal)).timed.contains(where: { $0.startsAt < run.to && $0.endsAt > run.from }) { return false }
            }
        }
        return true
    }

    private func ribbon(for day: Date, collapse: Bool) -> CalRibbon {
        let from = cal.startOfDay(for: day).timeIntervalSince1970 * 1000
        let to = (cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day)) ?? day).timeIntervalSince1970 * 1000
        return CalRibbon(from: from, to: to, pxPerHour: pxPerHour, nightStart: store.prefs.nightStart, nightEnd: store.prefs.nightEnd, nightPx: nightBand, collapseNight: collapse, in: cal)
    }

    var body: some View {
        let collapse = collapse
        let first = ribbon(for: days[0], collapse: collapse)
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
                    Color.clear.frame(height: headerH)
                    ZStack(alignment: .topTrailing) {
                        ForEach(first.hours.filter { $0.hour % 3 == 0 }, id: \.ms) { h in
                            Text(hourLabel(h.hour)).font(W.font(9.5)).foregroundStyle(W.tertiary).offset(y: h.pos - 4.75)
                        }
                    }
                    .frame(height: first.length, alignment: .top)
                    .padding(.trailing, 4)
                }
                .frame(width: 36)
                HStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element) { col, day in
                        column(col: col, day: day, collapse: collapse)
                    }
                }
                .coordinateSpace(name: space)
                .background(GeometryReader { g in Color.clear.onAppear { gridWidth = g.size.width }.onChange(of: g.size.width) { _, w in gridWidth = w } })
            }
            HStack(spacing: 8) {
                Text("SOMETIME THIS WEEK:").font(W.font(10.5)).tracking(1.155).foregroundStyle(W.tertiary)
                WButton(icon: "plus", variant: .outline, size: .iconXs, muted: true) { onCreate(CalDate.ms(start, minutes: 9 * 60, in: cal), CalDate.ms(start, minutes: 10 * 60, in: cal)) }
                Spacer()
            }
            .padding(.leading, 4).padding(.vertical, 8)
        }
        .padding(.horizontal, 1)
        .overlay { if current { RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.border, lineWidth: 1) } }
        .rounded(W.radiusLg)
    }

    @ViewBuilder
    private func column(col: Int, day: Date, collapse: Bool) -> some View {
        let key = CalDate.key(day, in: cal)
        let events = store.events(onKey: key)
        let ribbon = ribbon(for: day, collapse: collapse)
        let dayStart = ribbon.from, dayEnd = ribbon.to
        // A dragged event is drawn where it is going, which may be another column: every
        // column drops it from its own list, and the one its span lands in draws it on top,
        // full width, out of the overlap layout.
        let rest = events.timed.filter { $0.id != preview?.id }
        let ghost: CalEventFull? = preview.flatMap { p in (!p.event.allDay && p.span.endsAt > dayStart && p.span.startsAt < dayEnd) ? p.shown : nil }
        let pills: [CalEventFull] = {
            var out = events.allDay.filter { $0.id != preview?.id }
            if let p = preview, p.event.allDay, let a = p.span.startDate, let b = p.span.endDate, key >= a, key <= b { out.append(p.shown) }
            return out
        }()
        let layout = CalDate.layoutColumns(rest, floorMs: 8 / pxPerHour * 3_600_000)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(weekdayLabel(day)).font(W.font(11, 500)).tracking(1).foregroundStyle(W.mutedForeground)
                Text("\(cal.component(.day, from: day))").font(W.font(15, 700)).monospacedDigit()
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(cal.isDateInToday(day) ? W.foreground : Color.clear)
            .foregroundStyle(cal.isDateInToday(day) ? W.primaryForeground : W.foreground)
            .clipShape(Capsule())
            .frame(height: headerH)
            ZStack(alignment: .top) {
                ForEach(ribbon.hours, id: \.ms) { h in
                    Rectangle().fill(W.border.opacity(0.6)).frame(height: 1).offset(y: h.pos)
                }
                // The folded night: a darker band, so the fold reads as one.
                ForEach(ribbon.runs.filter(\.night), id: \.from) { r in
                    Rectangle().fill(W.muted60).frame(height: r.size).offset(y: r.pos)
                }
                ForEach(Array(rest.enumerated()), id: \.element.id) { i, e in
                    let top = ribbon.pos(max(e.startsAt, dayStart))
                    let height = max(8, ribbon.pos(min(e.endsAt, dayEnd)) - top)
                    EventBlock(event: e, height: height, column: layout[i].column, columns: layout[i].columns, timeFormat: store.prefs.timeFormat, space: space,
                               onTap: { onEvent(e) }, onDrag: { mode, p0, p1, ended in drag(e, col: col, mode: mode, p0: p0, p1: p1, ended: ended, ribbon: ribbon) })
                        .offset(y: top)
                }
                if let g = ghost {
                    let top = ribbon.pos(max(g.startsAt, dayStart))
                    let height = max(8, ribbon.pos(min(g.endsAt, dayEnd)) - top)
                    EventBlock(event: g, height: height, timeFormat: store.prefs.timeFormat, space: space, dragging: true, onTap: {}).offset(y: top).zIndex(35)
                }
                if let sketch {
                    let a = ribbon.pos(min(sketch.from, sketch.to)), b = ribbon.pos(max(sketch.from, sketch.to))
                    if sketch.from >= dayStart && sketch.from < dayEnd {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(W.foreground.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                            .frame(height: max(b - a, 6)).padding(.horizontal, 2).offset(y: a).allowsHitTesting(false)
                    }
                }
                if cal.isDateInToday(day) {
                    let now = ribbon.pos(Date().timeIntervalSince1970 * 1000)
                    HStack(spacing: 4) {
                        Text(heyTime(Date())).font(W.font(10)).foregroundStyle(.red)
                        Rectangle().fill(.red).frame(height: 1).overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [2])).foregroundStyle(.red))
                    }
                    .offset(y: now - 6)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: ribbon.length, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
            // Drag down the column to draw out a new event; a plain click makes a half hour.
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let from = sketch?.from ?? EventDrag.snap(ribbon.at(v.startLocation.y))
                sketch = (from, EventDrag.snap(ribbon.at(v.location.y)))
            }.onEnded { v in
                let from = sketch?.from ?? EventDrag.snap(ribbon.at(v.startLocation.y))
                let to = sketch?.to ?? from
                sketch = nil
                let a = min(from, to), b = max(from, to)
                onCreate(a, b == a ? a + 30 * 60_000 : b)
            })
            VStack(spacing: 2) {
                ForEach(pills) { e in
                    let s = EventSurface(e)
                    Text(e.displayTitle).font(W.font(11, 500)).lineLimit(1).foregroundStyle(s.ink).padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 18).background(s.fill).clipShape(Capsule())
                        .overlay { if e.isTentative { Capsule().strokeBorder(W.foreground.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3])) } }
                        .opacity(e.isCancelled || e.isDeclined ? 0.45 : 1)
                        .contentShape(Capsule())
                        .onTapGesture { onEvent(e) }
                        // An all-day pill has no time to change, only a day, so it only ever moves.
                        .gesture(DragGesture(minimumDistance: EventDrag.slop, coordinateSpace: .named(space)).onChanged { v in
                            guard e.writable else { return }
                            drag(e, col: col, mode: .move, p0: v.startLocation, p1: v.location, ended: false, ribbon: ribbon)
                        }.onEnded { v in
                            guard e.writable else { return }
                            drag(e, col: col, mode: .move, p0: v.startLocation, p1: v.location, ended: true, ribbon: ribbon)
                        })
                }
            }
            .padding(.top, 4)
            .frame(minHeight: 28, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .edgeLine(.leading, W.border.opacity(0.6))
    }

    /// The pointer's travel, as a column shift and a delta in time read off the ribbon — so
    /// the folded night counts for what it is rather than what it measures.
    private func drag(_ e: CalEventFull, col: Int, mode: EventDrag.Mode, p0: CGPoint, p1: CGPoint, ended: Bool, ribbon: CalRibbon) {
        let colW = gridWidth / 7
        let dx = p1.x - p0.x
        let days = mode == .move && colW > 0 ? max(-col, min(6 - col, Int((dx / colW).rounded()))) : 0
        let span: EventDrag.Span
        if e.allDay {
            span = EventDrag.allDaySpan(e, days: days, in: cal)
        } else {
            let delta = ribbon.at(p1.y - headerH) - ribbon.at(p0.y - headerH)
            let dayStart = ribbon.from
            span = EventDrag.span(e, mode: mode, deltaMs: delta, days: days, bounds: (EventDrag.shiftDays(dayStart, days, in: cal), EventDrag.shiftDays(dayStart, days + 1, in: cal)), in: cal)
        }
        if !ended { live = EventPreview(event: e, span: span); return }
        live = nil
        guard EventDrag.moved(e, span) else { return }
        let p = EventPreview(event: e, span: span)
        pending = p
        DragCommit.commit(p, store: store, month: start) { if pending == p { pending = nil } }
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
    /// The coordinate space the drag reports in: the week's grid, so a move can cross columns.
    var space = "week"
    var dragging = false
    var onTap: () -> Void
    /// (mode, point at press, point now, ended) — nil for a block that cannot be dragged.
    var onDrag: ((EventDrag.Mode, CGPoint, CGPoint, Bool) -> Void)? = nil
    @State private var mode: EventDrag.Mode?
    /// The block's top edge in the drag's coordinate space, for telling a grab at an end apart.
    @State private var blockTop: CGFloat = 0

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
            let grab = EventDrag.handle(height)
            Group {
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
                .overlay { if dragging { RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.4), lineWidth: 1) } }
                .shadow(color: .black.opacity(dragging ? 0.2 : 0), radius: 8, y: 4)
                .contentShape(Rectangle())
            }
            .onTapGesture(perform: onTap)
            // Press the block to move it, or either end to take that edge with you.
            .gesture(DragGesture(minimumDistance: EventDrag.slop, coordinateSpace: .named(space)).onChanged { v in
                guard let onDrag, event.writable else { return }
                if mode == nil {
                    // Where on the block the press landed decides which end moves.
                    let atTop = (v.startLocation.y - blockTop) < grab
                    let atBottom = (blockTop + height - v.startLocation.y) < grab
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
