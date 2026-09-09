import SwiftUI

/// `dragEvent.ts`: moving and resizing an event by dragging it. The week reads time off a
/// column and the day off a sideways ribbon, so nothing here knows about points: each view
/// turns the pointer's travel into a delta in milliseconds (and, in the week, whole columns),
/// and everything after that — snapping, the minimum length, which end moves, staying inside
/// the day — is the same in both and lives here.
enum EventDrag {
    /// Below this the press is still a click: the block opens instead of moving.
    static let slop: CGFloat = 4
    /// The grab zone at either end of a block.
    static let edge: CGFloat = 6
    /// Every edge lands on a quarter hour.
    static let snapMs: Double = 15 * 60_000
    /// However hard you squeeze it, an event stays a quarter of an hour long.
    static let minEventMs: Double = 15 * 60_000

    enum Mode { case move, start, end }

    struct Span: Equatable {
        var startsAt: Double
        var endsAt: Double
        var startDate: String?
        var endDate: String?
    }

    static func snap(_ ms: Double, step: Double = snapMs) -> Double { (ms / step).rounded() * step }

    /// How thick to draw a grab handle on a block of this size — never more than a third of it.
    static func handle(_ size: CGFloat) -> CGFloat { max(2, min(edge, floor(size / 3))) }

    /// `ms` shifted by whole calendar days: 9AM stays 9AM across a daylight-saving boundary.
    static func shiftDays(_ ms: Double, _ days: Int, in cal: Calendar) -> Double {
        guard days != 0 else { return ms }
        let d = Date(timeIntervalSince1970: ms / 1000)
        return (cal.date(byAdding: .day, value: days, to: d) ?? d).timeIntervalSince1970 * 1000
    }

    /// Where a timed event lands, given how far the pointer has travelled. `days` is the week's
    /// column shift and only applies to a move; `bounds` keeps a move inside the day it was
    /// dragged into and an edge from crossing midnight, unless the event already sat outside.
    static func span(_ e: CalEventFull, mode: Mode, deltaMs: Double, days: Int = 0, bounds: (min: Double, max: Double)? = nil, in cal: Calendar) -> Span {
        let duration = max(minEventMs, e.endsAt - e.startsAt)
        switch mode {
        case .move:
            var s = snap(shiftDays(e.startsAt, days, in: cal) + deltaMs)
            if let b = bounds, duration <= b.max - b.min { s = min(max(s, b.min), b.max - duration) }
            return Span(startsAt: s, endsAt: s + duration)
        case .start:
            var s = snap(e.startsAt + deltaMs)
            if let b = bounds { s = max(s, min(b.min, e.startsAt)) }
            return Span(startsAt: min(s, e.endsAt - minEventMs), endsAt: e.endsAt)
        case .end:
            var t = snap(e.endsAt + deltaMs)
            if let b = bounds { t = min(t, max(b.max, e.endsAt)) }
            return Span(startsAt: e.startsAt, endsAt: max(t, e.startsAt + minEventMs))
        }
    }

    /// An all-day event moved `days` columns: only the day changes, never the time.
    static func allDaySpan(_ e: CalEventFull, days: Int, in cal: Calendar) -> Span {
        let start = e.startDate ?? CalDate.key(e.start, in: cal)
        let end = e.endDate ?? start
        let s = CalDate.addingDays(days, toKey: start, in: cal), t = CalDate.addingDays(days, toKey: end, in: cal)
        return Span(startsAt: CalDate.ms(s, minutes: 0, in: cal), endsAt: CalDate.ms(CalDate.addingDays(1, toKey: t, in: cal), minutes: 0, in: cal), startDate: s, endDate: t)
    }

    static func moved(_ e: CalEventFull, _ span: Span) -> Bool { span.startsAt != e.startsAt || span.endsAt != e.endsAt }

    /// The patch that commits a drag. All-day events carry their dates; timed ones must not.
    static func patch(_ e: CalEventFull, _ span: Span) -> EventInput {
        var input = EventInput()
        input.startsAt = span.startsAt
        input.endsAt = span.endsAt
        if e.allDay {
            if let s = span.startDate { input.startDate = .some(s) }
            if let t = span.endDate { input.endDate = .some(t) }
        }
        return input
    }

    /// The event as the preview would have it — a copy, so the store is never written through.
    static func previewed(_ e: CalEventFull, _ span: Span) -> CalEventFull {
        var c = e
        c.startsAt = span.startsAt; c.endsAt = span.endsAt
        if let s = span.startDate { c.startDate = s }
        if let t = span.endDate { c.endDate = t }
        return c
    }
}

/// A drag that is under the pointer, or let go of but not yet answered by the server. Both are
/// the same thing to a view: draw this event at these times instead.
struct EventPreview: Equatable {
    let event: CalEventFull
    var span: EventDrag.Span
    var id: String { event.id }
    var shown: CalEventFull { EventDrag.previewed(event, span) }
}

/// Commits a drag: the moved event goes to the server, the preview is held until the loaded
/// window has been fetched again (`refresh`, the view's own window — never a wipe of the
/// store, which would blank every other week on screen), and a refusal (Google can decline
/// to move some events) is said out loud.
@MainActor
enum DragCommit {
    static func commit(_ p: EventPreview, refresh: @escaping () async -> Void, clear: @escaping () -> Void) {
        Task {
            do {
                _ = try await CalendarAPI.updateEvent(id: p.event.id, scope: nil, input: EventDrag.patch(p.event, p.span))
                await refresh()
            } catch {
                Toasts.shared.error((error as? APIError)?.errorDescription ?? "Couldn't move this event.")
            }
            clear()
        }
    }
}
