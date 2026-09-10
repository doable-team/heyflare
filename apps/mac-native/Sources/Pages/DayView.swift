import SwiftUI

/// The day: exactly the week's grid with a single column — the cursor day — the same
/// gutter, header, all-day row, body, now line, events and drags. The header reads
/// `Wednesday 9`.
struct DayView: View {
    let store: CalendarStore
    let cursor: String
    let revealAt: RevealAt
    let scroll: ScrollController
    var onEvent: (CalEventFull) -> Void
    var onCreate: (Double, Double) -> Void
    var onSetCursor: (String) -> Void
    var onRefresh: () async -> Void

    var body: some View {
        TimeGrid(store: store, days: [cursor], style: .day, cursor: cursor, revealAt: revealAt, scroll: scroll,
                 onEvent: onEvent, onCreate: onCreate, onSetCursor: onSetCursor, onRefresh: onRefresh)
    }
}
