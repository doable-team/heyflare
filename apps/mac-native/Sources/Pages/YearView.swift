import SwiftUI
import AppKit

/// `YearView.tsx`: not twelve little month grids but one continuous ribbon of every day in
/// the year, wrapped into rows of four weeks (two, then one, when the cells would clip), the
/// wrapping weekday-aligned so the weekend stripes run straight down the page. A month
/// announces itself on the day it starts, with a badge and a hairline tick. Only all-day and
/// multi-day events are drawn, as stadium pills cut per row and packed into lanes.
struct YearView: View {
    let store: CalendarStore
    let cursor: String
    let revealAt: RevealAt
    var onPick: (String) -> Void
    var onEvent: (CalEventFull) -> Void

    @State private var model = YearModel()
    @State private var width: CGFloat = 0

    static let weekOptions = [4, 2, 1]
    static let minCell: CGFloat = 52
    /// Enough for the date line plus a couple of pills or a glimpse of a photo.
    static let rowPx: CGFloat = 84
    /// Where the pill overlay starts — clear of the date line.
    static let datePx: CGFloat = 19
    static let pillPx: CGFloat = 14
    static let pillGap: CGFloat = 2
    static let maxLanes = max(1, Int((rowPx - datePx - 2) / (pillPx + pillGap)))

    struct Segment: Identifiable {
        let e: CalEventFull
        let start: Int
        let end: Int
        let lane: Int
        var id: String { "\(e.id):\(start)" }
    }

    private var cal: Calendar { store.calendar }

    var body: some View {
        let year = String(cursor.prefix(4))
        let jan1 = "\(year)-01-01", dec31 = "\(year)-12-31"
        // How many weeks fit a row at this width: measured, because the sidebar and the
        // assistant both change how much room this actually has.
        let weeksPerRow = Self.weekOptions.first { width / CGFloat($0 * 7) >= Self.minCell } ?? 1
        let cols = weeksPerRow * 7
        // Back to the Sunday on or before Jan 1, forward to fill the last row.
        let gridStart = CalDate.addingDays(-CalUI.dow(jan1, cal), toKey: jan1, in: cal)
        let dayCount = CalUI.daysBetween(gridStart, dec31, cal) + 1
        let rowCount = max(1, Int(ceil(Double(dayCount) / Double(cols))))
        let totalDays = rowCount * cols
        let segments = segmentsByRow(gridStart: gridStart, rowCount: rowCount, totalDays: totalDays, cols: cols)
        let dayByKey = store.dayByKey
        let rowOf = max(0, min(rowCount - 1, CalUI.daysBetween(gridStart, cursor, cal) / cols))
        model.rowCount = rowCount; model.cursorRow = rowOf
        return GeometryReader { g in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<rowCount, id: \.self) { r in
                        YearRow(rowStart: CalDate.addingDays(r * cols, toKey: gridStart, in: cal), cols: cols, jan1: jan1, dec31: dec31, cursor: cursor,
                                dayByKey: dayByKey, segments: segments[r], cal: cal, onPick: onPick, onEvent: onEvent)
                            .frame(height: Self.rowPx)
                    }
                }
                .background(ScrollHook(controller: model.scroll))
            }
            .scrollIndicators(.never)
            .onAppear { width = g.size.width }
            .onChange(of: g.size.width) { _, w in width = w }
        }
        .background(W.background)
        .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1))
        .rounded(W.radiusMd)
        .onAppear {
            model.scroll.onContentResize = { _, _ in model.tryLand() }
            model.tryLand()
        }
        .onChange(of: model.scroll.viewport.height) { _, _ in model.tryLand() }
        .onChange(of: cursor) { _, _ in model.show(force: false) }
        .onChange(of: cols) { _, _ in model.show(force: false) }
        .onChange(of: rowCount) { _, _ in model.show(force: false) }
        .onChange(of: store.loading) { _, loading in if !loading { model.show(force: false) } }
        .onChange(of: revealAt.nonce) { _, _ in model.show(force: true) }
    }

    /// Every all-day event, cut into per-row segments and packed into lanes — longest first
    /// inside a start column, so a trip claims the top lane and the one-day things fill in
    /// underneath it.
    private func segmentsByRow(gridStart: String, rowCount: Int, totalDays: Int, cols: Int) -> [[Segment]] {
        var rows = Array(repeating: [Segment](), count: rowCount)
        struct Raw { let row: Int; let start: Int; let end: Int; let e: CalEventFull }
        var raw: [Raw] = []
        for e in store.allEvents() where e.allDay {
            let from = e.startDate ?? CalDate.key(e.start, in: cal)
            let to = e.endDate ?? from
            var a = CalUI.daysBetween(gridStart, from, cal)
            var b = CalUI.daysBetween(gridStart, to, cal)
            if b < a { b = a }
            a = max(a, 0)
            b = min(b, totalDays - 1)
            if b < a { continue }
            var i = a
            while i <= b {
                let row = i / cols
                let rowStart = row * cols
                let last = min(b, rowStart + cols - 1)
                raw.append(Raw(row: row, start: i - rowStart, end: last - rowStart, e: e))
                i = last + 1
            }
        }
        raw.sort { x, y in
            if x.start != y.start { return x.start < y.start }
            if x.end != y.end { return x.end > y.end }
            return x.e.id < y.e.id
        }
        var laneEnds = Array(repeating: [Int](), count: rowCount)
        for s in raw {
            var lane = laneEnds[s.row].firstIndex { $0 < s.start } ?? -1
            if lane == -1 {
                lane = laneEnds[s.row].count
                laneEnds[s.row].append(s.end)
            } else {
                laneEnds[s.row][lane] = s.end
            }
            if lane >= Self.maxLanes { continue }
            rows[s.row].append(Segment(e: s.e, start: s.start, end: s.end, lane: lane))
        }
        return rows
    }
}

/// Open on the row you are actually on: a year is thirteen screens of grid.
@MainActor
final class YearModel {
    let scroll = ScrollController()
    var rowCount = 0
    var cursorRow = 0
    var landed = false

    private func target(_ row: Int) -> CGFloat { max(0, CGFloat(row) * YearView.rowPx - (scroll.viewport.height - YearView.rowPx) / 2) }

    func tryLand() {
        guard !landed, scroll.viewport.height > 0, rowCount > 0 else { return }
        let t = target(cursorRow)
        guard scroll.content.height >= CGFloat(rowCount) * YearView.rowPx - 1 || scroll.content.height >= t + scroll.viewport.height else { return }
        landed = true
        scroll.scrollTo(y: t, animated: false)
    }

    func show(force: Bool) {
        guard landed else { tryLand(); return }
        let vh = scroll.viewport.height
        let top = CGFloat(cursorRow) * YearView.rowPx - scroll.offset.y
        // Already comfortably on screen: leave the scroll where the reader put it.
        if !force && top >= 0 && top + YearView.rowPx <= vh { return }
        scroll.scrollTo(y: target(cursorRow), animated: true)
    }
}

/// Four weeks: cells of equal fractional width — no horizontal scrollbar, ever.
private struct YearRow: View {
    let rowStart: String
    let cols: Int
    let jan1: String
    let dec31: String
    let cursor: String
    let dayByKey: [String: CalDay]
    let segments: [YearView.Segment]
    let cal: Calendar
    var onPick: (String) -> Void
    var onEvent: (CalEventFull) -> Void

    var body: some View {
        let days = (0..<cols).map { CalDate.addingDays($0, toKey: rowStart, in: cal) }
        GeometryReader { g in
            let cellW = g.size.width / CGFloat(cols)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element) { c, d in
                        YearCell(date: d, col: c, inYear: d >= jan1 && d <= dec31, selected: d == cursor, day: dayByKey[d], onPick: onPick)
                            .frame(width: cellW)
                    }
                }
                // The pills float over the cells rather than living inside one of them: a
                // week-long trip is a single bar.
                ForEach(segments) { s in
                    YearPill(event: s.e) { onEvent(s.e) }
                        .padding(.horizontal, 1)
                        .frame(width: CGFloat(s.end - s.start + 1) * cellW)
                        .offset(x: CGFloat(s.start) * cellW, y: YearView.datePx + CGFloat(s.lane) * (YearView.pillPx + YearView.pillGap))
                        .zIndex(20)
                }
            }
        }
    }
}

/// One day. The date line reads `SUN 12`, with the month's three letters badged in front of
/// it on the day a month turns, and a hairline dropping down the cell's left edge.
private struct YearCell: View {
    let date: String
    let col: Int
    let inYear: Bool
    let selected: Bool
    let day: CalDay?
    var onPick: (String) -> Void

    var body: some View {
        // Column 0 is a Sunday by construction, so the weekend is the same pair of columns in every week.
        let dow = col % 7
        let weekend = dow == 0 || dow == 6
        if !inYear {
            // Before January and after December: the stripe carries on, the day does not.
            (weekend ? W.muted.opacity(0.25) : Color.clear).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let today = date == CalDate.todayKey
            let photo = !(day?.coverURL.isEmpty ?? true)
            let first = date.hasSuffix("-01")
            let past = date < CalDate.todayKey
            Button { onPick(date) } label: {
                ZStack(alignment: .topLeading) {
                    (weekend ? W.muted.opacity(0.25) : Color.clear)
                    DayPhotoBackdrop(day: day)
                    if first {
                        Rectangle().fill(W.foreground.opacity(0.3)).frame(width: 1).frame(maxHeight: .infinity).zIndex(10)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(CalUI.weekdays[dow]).font(W.font(8)).tracking(0.32).webLine(8, 8)
                            .foregroundStyle(today ? W.background : (photo ? Color.white : W.tertiary))
                        Text("\(CalUI.dayNumber(date))").font(W.font(11, 600)).monospacedDigit().webLine(11, 11, weight: 600)
                            .foregroundStyle(today ? W.background : (photo ? Color.white : W.foreground))
                    }
                    .padding(.horizontal, today ? 4 : 0).padding(.vertical, today ? 2 : 0)
                    .background(today ? W.foreground : Color.clear)
                    .clipShape(Capsule())
                    .shadow(color: photo ? Color.black.opacity(0.9) : .clear, radius: 1.5)
                    .shadow(color: photo ? Color.black.opacity(0.8) : .clear, radius: 1, y: 1)
                    .opacity(!photo && !today && past ? 0.7 : 1)
                    .padding(.leading, 4).padding(.trailing, 7).padding(.top, 4)
                    .lineLimit(1)
                    .zIndex(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .overlay { if selected { Rectangle().strokeBorder(W.foreground.opacity(0.25), lineWidth: 1) } }
                // On the boundary, not inside the cell — the badge overhangs the left edge.
                .overlay(alignment: .topLeading) {
                    if first {
                        Text(CalUI.months[CalUI.monthIndex(date)]).font(W.font(8, 600)).tracking(0.48).webLine(8, 8, weight: 600)
                            .foregroundStyle(W.mutedForeground)
                            .padding(.horizontal, 3).padding(.vertical, 2)
                            .background(W.background)
                            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.border, lineWidth: 1))
                            .rounded(3)
                            .offset(x: -9, y: 2)
                            .zIndex(20)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(date)
        }
    }
}

/// A date-shaped thing, drawn the way an all-day event is drawn everywhere else: a solid stadium.
private struct YearPill: View {
    let event: CalEventFull
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let s = EventSurface(hex: event.calendarColor)
        let declined = event.rsvp == .declined
        let title = event.title.isEmpty ? "(no title)" : event.title
        Button(action: action) {
            HStack(spacing: 4) {
                if !event.emoji.isEmpty { Text(event.emoji).fixedSize() }
                Text(title).truncate()
            }
            .font(W.font(9.5, 500))
            .strikethrough(event.done || declined)
            .foregroundStyle(s.ink)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: YearView.pillPx)
            .background(s.fill)
            .clipShape(Capsule())
            .opacity(declined ? 0.45 : (hovering ? 0.85 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}
