import SwiftUI

/// The year: twelve month blocks in a grid that scrolls — four across at 1100 and up, three at
/// 820, otherwise two. A block is the month's name over a 7-column grid of 32px cells: the
/// weekday letters, then the days; today in a filled circle, days with an event in semibold,
/// days with a journal entry carrying a dot. Click a day to open it.
struct YearView: View {
    let store: CalendarStore
    let cursor: String
    var onPick: (String) -> Void

    static let cell: CGFloat = 32
    static let gapX: CGFloat = 24
    static let gapY: CGFloat = 32
    static let padding: CGFloat = 24

    var body: some View {
        let year = String(cursor.prefix(4))
        GeometryReader { g in
            let cols = g.size.width >= 1100 ? 4 : (g.size.width >= 820 ? 3 : 2)
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gapX, alignment: .topLeading), count: cols), alignment: .leading, spacing: Self.gapY) {
                    ForEach(0..<12, id: \.self) { m in
                        YearMonth(store: store, month: String(format: "%@-%02d", year, m + 1), cursor: cursor, onPick: onPick)
                    }
                }
                .padding(Self.padding)
            }
            // The thin overlay scrollbar is allowed here.
            .scrollIndicators(.automatic)
        }
    }
}

private struct YearMonth: View {
    let store: CalendarStore
    /// `yyyy-MM`.
    let month: String
    let cursor: String
    var onPick: (String) -> Void

    var body: some View {
        let cal = store.calendar
        let today = CalDate.todayKey
        let first = "\(month)-01"
        let grid = CalDate.monthGrid(for: CalDate.date(fromKey: first, in: cal) ?? Date(), in: cal).map { CalDate.key($0, in: cal) }
        let journal = store.journalDays
        VStack(alignment: .leading, spacing: 8) {
            Text(CalUI.monthNames[CalUI.monthIndex(first)])
                .font(W.font(13, 600))
                .foregroundStyle(today.hasPrefix(month) ? CalUI.red : W.foreground)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(String(CalUI.weekdayAbbr[(cal.firstWeekday - 1 + i) % 7].prefix(1)))
                            .font(W.font(10)).foregroundStyle(W.mutedForeground)
                            .frame(width: YearView.cell, height: YearView.cell)
                    }
                }
                ForEach(0..<6, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { c in
                            let day = grid[r * 7 + c]
                            if day.hasPrefix(month) {
                                YearDay(day: day, today: day == today, cursor: day == cursor, hasEvent: !store.events(onKey: day).isEmpty, journal: journal.contains(day)) { onPick(day) }
                            } else {
                                Color.clear.frame(width: YearView.cell, height: YearView.cell)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 7 * YearView.cell, alignment: .leading)
    }
}

private struct YearDay: View {
    let day: String
    let today: Bool
    let cursor: Bool
    let hasEvent: Bool
    let journal: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if today { Circle().fill(W.foreground).frame(width: 24, height: 24) }
                else if cursor { Circle().strokeBorder(W.foreground, lineWidth: 1).frame(width: 24, height: 24) }
                else if hovering { Circle().fill(W.muted).frame(width: 24, height: 24) }
                Text("\(CalUI.dayNumber(day))")
                    .font(W.font(12, hasEvent ? 600 : 400))
                    .foregroundStyle(today ? W.background : W.foreground)
            }
            .frame(width: YearView.cell, height: YearView.cell)
            .overlay(alignment: .bottom) {
                if journal { Circle().fill(W.foreground.opacity(0.5)).frame(width: 3, height: 3).padding(.bottom, 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(day)
    }
}
