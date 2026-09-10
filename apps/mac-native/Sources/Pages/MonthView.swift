import SwiftUI

/// The month: a weekday header, then six equal rows of seven cells filling the height. Each
/// cell carries its number at the top right and, under it, the day's events as 18px rows —
/// all-day and multi-day things as pills laid across the cells they span, timed things as a
/// dot, the time and the title — and `+N more` when they run out of room.
struct MonthView: View {
    let store: CalendarStore
    let cursor: String
    var onEvent: (CalEventFull) -> Void
    var onSetCursor: (String) -> Void
    var onOpenDay: (String) -> Void

    static let headerH: CGFloat = 28
    static let pad: CGFloat = 4
    static let numberH: CGFloat = 22
    static let rowH: CGFloat = 18
    static let rowGap: CGFloat = 1
    /// Where the first event row starts inside a cell: the padding, the number line, 2 of air.
    static let rowsTop: CGFloat = pad + numberH + 2

    private var cal: Calendar { store.calendar }

    var body: some View {
        let month = String(cursor.prefix(7))
        let monthDate = CalDate.date(fromKey: "\(month)-01", in: cal) ?? Date()
        let grid = CalDate.monthGrid(for: monthDate, in: cal).map { CalDate.key($0, in: cal) }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(CalUI.weekdayAbbr[(cal.firstWeekday - 1 + i) % 7])
                        .font(W.font(11, 500)).foregroundStyle(W.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                }
            }
            .frame(height: Self.headerH)
            .edgeLine(.bottom)
            GeometryReader { g in
                let rowH = g.size.height / 6
                let colW = g.size.width / 7
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { r in
                        MonthRow(store: store, days: Array(grid[(r * 7)..<(r * 7 + 7)]), month: month, cursor: cursor, colW: colW, rowH: rowH,
                                 onEvent: onEvent, onSetCursor: onSetCursor, onOpenDay: onOpenDay)
                            .frame(width: g.size.width, height: rowH)
                    }
                }
            }
        }
    }
}

/// One week of cells, with the spanning pills laid over them so a trip is a single bar.
private struct MonthRow: View {
    let store: CalendarStore
    let days: [String]
    let month: String
    let cursor: String
    let colW: CGFloat
    let rowH: CGFloat
    var onEvent: (CalEventFull) -> Void
    var onSetCursor: (String) -> Void
    var onOpenDay: (String) -> Void

    /// What the row draws: the packed pills, the per-cell timed rows, how many rows fit.
    private struct Plan {
        var pills: [SpanPlacement]
        var drawn: [SpanPlacement]
        var timed: [[CalEventFull]]
        var overflow: [Bool]
        var n: Int
    }

    private func plan() -> Plan {
        let cal = store.calendar
        // Pills: every all-day event, plus any timed one that crosses midnight. Timed events
        // that stay inside their day are rows in that day's cell.
        var spans: [CalEventFull] = []
        var seen: Set<String> = []
        var timed: [[CalEventFull]] = Array(repeating: [], count: days.count)
        for (c, d) in days.enumerated() {
            let ev = store.events(onKey: d)
            for e in ev.allDay where !seen.contains(e.id) { seen.insert(e.id); spans.append(e) }
            for e in ev.timed {
                let r = CalUI.dayRange(e, cal)
                if r.first != r.last {
                    if !seen.contains(e.id) { seen.insert(e.id); spans.append(e) }
                } else {
                    timed[c].append(e)
                }
            }
        }
        let pills = SpanLanes.place(spans, days: days, cal: cal)
        // How many 18px rows fit under the number.
        let n = max(0, Int(floor((rowH - MonthView.rowsTop - MonthView.pad + MonthView.rowGap) / (MonthView.rowH + MonthView.rowGap))))
        let needed = days.indices.map { c in ((pills.filter { Self.covers($0, c) }.map(\.lane).max() ?? -1) + 1) + timed[c].count }
        let overflow = needed.map { $0 > n }
        // A pill is drawn when its lane sits above the `+N more` line, or on it while no cell
        // it covers needs that line.
        let drawn = pills.filter { p in p.lane < n - 1 || (p.lane == n - 1 && !(p.start...p.end).contains { overflow[$0] }) }
        return Plan(pills: pills, drawn: drawn, timed: timed, overflow: overflow, n: n)
    }

    private static func covers(_ p: SpanPlacement, _ c: Int) -> Bool { p.start <= c && p.end >= c }

    var body: some View {
        let cal = store.calendar
        let plan = plan()
        let pills = plan.pills, drawn = plan.drawn, timed = plan.timed, overflow = plan.overflow, n = plan.n
        let drawnIDs = Set(drawn.map(\.id))
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { c, d in
                    let mine = pills.filter { Self.covers($0, c) }
                    let firstRow = (mine.filter { drawnIDs.contains($0.id) }.map(\.lane).max() ?? -1) + 1
                    let hiddenPills = mine.filter { !drawnIDs.contains($0.id) }.count
                    let capacity = max(0, (overflow[c] ? n - 1 : n) - firstRow)
                    let shown = Array(timed[c].prefix(capacity))
                    let more = hiddenPills + (timed[c].count - shown.count)
                    MonthCell(day: d, inMonth: d.hasPrefix(month), cursor: d == cursor, timed: shown, firstRow: firstRow,
                              more: overflow[c] ? more : 0, moreRow: n - 1, last: c == days.count - 1, format: store.prefs.timeFormat, cal: cal,
                              onEvent: onEvent, onSetCursor: onSetCursor, onOpenDay: onOpenDay)
                        .frame(width: colW, height: rowH)
                }
            }
            ForEach(drawn) { p in
                AllDayPill(event: p.event, bar: !p.cutStart, onTap: { onSetCursor(days[p.start]); onEvent(p.event) })
                    .frame(width: CGFloat(p.end - p.start + 1) * colW - 4, height: MonthView.rowH)
                    .offset(x: CGFloat(p.start) * colW + 2, y: MonthView.rowsTop + CGFloat(p.lane) * (MonthView.rowH + MonthView.rowGap))
            }
        }
    }
}

/// One day: `border-r border-b`, padding 4, the number top-right, the timed rows beneath.
private struct MonthCell: View {
    let day: String
    let inMonth: Bool
    let cursor: Bool
    let timed: [CalEventFull]
    let firstRow: Int
    let more: Int
    let moreRow: Int
    let last: Bool
    let format: String
    let cal: Calendar
    var onEvent: (CalEventFull) -> Void
    var onSetCursor: (String) -> Void
    var onOpenDay: (String) -> Void
    @State private var hovering = false

    var body: some View {
        let today = day == CalDate.todayKey
        let number = CalUI.dayNumber(day)
        ZStack(alignment: .topLeading) {
            (hovering ? W.muted.opacity(0.3) : Color.clear)
            // The number, top-right: `Sep 1` on the first, a 22px filled circle on today, a ring on the cursor.
            Group {
                if today || cursor {
                    DayNumber(number: number, today: today, cursor: cursor, size: 22, font: W.font(12, 500))
                } else {
                    Text(number == 1 ? "\(CalUI.monthAbbr[CalUI.monthIndex(day)]) 1" : "\(number)")
                        .font(W.font(12, 500))
                        .foregroundStyle(inMonth ? W.foreground : W.tertiary)
                        .frame(height: MonthView.numberH)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, MonthView.pad)
            .padding(.top, MonthView.pad)
            ForEach(Array(timed.enumerated()), id: \.element.id) { i, e in
                TimedRow(event: e, format: format, cal: cal) { onSetCursor(day); onEvent(e) }
                    .padding(.horizontal, MonthView.pad)
                    .offset(y: MonthView.rowsTop + CGFloat(firstRow + i) * (MonthView.rowH + MonthView.rowGap))
            }
            if more > 0 && moreRow >= 0 {
                Text("+\(more) more").font(W.font(11)).foregroundStyle(W.mutedForeground).lineLimit(1)
                    .frame(height: MonthView.rowH)
                    .padding(.horizontal, MonthView.pad)
                    .offset(y: MonthView.rowsTop + CGFloat(moreRow) * (MonthView.rowH + MonthView.rowGap))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .trailing) { if !last { Rectangle().fill(W.border).frame(width: 1) } }
        .edgeLine(.bottom)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpenDay(day) }
        .onTapGesture { onSetCursor(day) }
    }
}

/// A timed event in a cell: a 6px dot in the calendar colour, the time, the title.
private struct TimedRow: View {
    let event: CalEventFull
    let format: String
    let cal: Calendar
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        let struck = event.isDeclined || (event.isTodo && event.done)
        HStack(spacing: 4) {
            Circle().fill(EventSurface.eventBar(event.calendarColor)).frame(width: 6, height: 6)
            Text(CalUI.timeLabel(event.startsAt, format, cal)).font(W.font(11)).monospacedDigit().foregroundStyle(W.mutedForeground).lineLimit(1).fixedSize()
            Text(event.displayTitle).font(W.font(11)).foregroundStyle(W.foreground).strikethrough(struck).truncate()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MonthView.rowH)
        .opacity(event.isDeclined ? 0.45 : (hovering ? 0.7 : 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .help(event.displayTitle)
    }
}
