import Foundation

/// `makeRibbon` in calendar/scale.ts: one continuous run of time mapped to one axis, drawn
/// strictly to scale except for the night hours, which are squeezed into a fixed length. The
/// same ribbon serves the vertical week columns (one per day) and the horizontal day view (one
/// spanning several days), which is why it works in instants rather than minutes.
struct CalRibbon {
    struct Run {
        let from: Double
        let to: Double
        let pos: CGFloat
        let size: CGFloat
        let night: Bool
    }
    struct Hour { let ms: Double; let pos: CGFloat; let hour: Int }

    /// 10pm–6am, condensed to this many points however long it really is.
    static let nightPx: CGFloat = 80
    static let dayPxPerHour: CGFloat = 43

    let from: Double
    let to: Double
    let length: CGFloat
    let pxPerHour: CGFloat
    let runs: [Run]
    /// Whole hours inside the waking runs, for labelling.
    let hours: [Hour]

    init(from: Double, to: Double, pxPerHour: CGFloat = CalRibbon.dayPxPerHour, nightStart: Int = 22, nightEnd: Int = 6, nightPx: CGFloat = CalRibbon.nightPx, collapseNight: Bool = true, in cal: Calendar = CalDate.cal) {
        self.from = from
        self.to = to
        self.pxPerHour = pxPerHour
        let nightPx = collapseNight ? nightPx : 0
        let collapse = collapseNight && nightStart != nightEnd
        let perMs = pxPerHour / 3_600_000
        let wraps = nightStart > nightEnd
        func hour(_ ms: Double) -> Int { cal.component(.hour, from: Date(timeIntervalSince1970: ms / 1000)) }
        func edge(_ ms: Double, _ h: Int) -> Double {
            let d = Date(timeIntervalSince1970: ms / 1000)
            let day = cal.startOfDay(for: d)
            return (cal.date(byAdding: .hour, value: h, to: day) ?? day).timeIntervalSince1970 * 1000
        }
        func isNight(_ ms: Double) -> Bool {
            guard collapse else { return false }
            let h = hour(ms)
            return wraps ? (h >= nightStart || h < nightEnd) : (h >= nightStart && h < nightEnd)
        }
        func nextEdge(_ ms: Double) -> Double {
            guard collapse else { return to }
            let h = hour(ms)
            if wraps {
                if h >= nightStart { return edge(ms + 86_400_000, nightEnd) }
                if h < nightEnd { return edge(ms, nightEnd) }
                return edge(ms, nightStart)
            }
            if h < nightStart { return edge(ms, nightStart) }
            if h < nightEnd { return edge(ms, nightEnd) }
            return edge(ms + 86_400_000, nightStart)
        }

        var runs: [Run] = []
        var pos: CGFloat = 0
        var cur = from
        var guardCount = 0
        while cur < to && guardCount < 2000 {
            guardCount += 1
            let night = isNight(cur)
            let full = nextEdge(cur)
            let e = min(full, to)
            let size: CGFloat = night ? nightPx * CGFloat((e - cur) / max(1, full - cur)) : CGFloat(e - cur) * perMs
            runs.append(Run(from: cur, to: e, pos: pos, size: size, night: night))
            pos += size
            cur = e
        }
        self.runs = runs
        self.length = pos

        var hours: [Hour] = []
        for r in runs where !r.night {
            let firstHour = edge(r.from + 3_599_999, hour(r.from + 3_599_999))
            var t = firstHour
            while t < r.to {
                if t >= r.from {
                    let p = Self.position(of: t, runs: runs, from: from, to: to, length: pos)
                    hours.append(Hour(ms: t, pos: p, hour: hour(t)))
                }
                t += 3_600_000
            }
        }
        self.hours = hours
    }

    private static func position(of ms: Double, runs: [Run], from: Double, to: Double, length: CGFloat) -> CGFloat {
        if ms <= from { return 0 }
        if ms >= to { return length }
        for r in runs where ms <= r.to {
            return r.pos + CGFloat((ms - r.from) / (r.to - r.from)) * r.size
        }
        return length
    }

    /// Offset along the axis of an instant.
    func pos(_ ms: Double) -> CGFloat { Self.position(of: ms, runs: runs, from: from, to: to, length: length) }

    /// The instant at an offset — for click and drag.
    func at(_ px: CGFloat) -> Double {
        let p = max(0, min(length, px))
        for r in runs where p <= r.pos + r.size {
            return r.from + Double((p - r.pos) / max(1, r.size)) * (r.to - r.from)
        }
        return to
    }

    /// `freeGaps`: the gaps between busy events, merged first so two overlapping meetings
    /// leave one gap, not none.
    static func freeGaps(_ events: [CalEventFull], from: Double, to: Double) -> [(from: Double, to: Double)] {
        let busy = events
            .filter { !$0.allDay && $0.busy && $0.endsAt > from && $0.startsAt < to }
            .map { (a: max($0.startsAt, from), b: min($0.endsAt, to)) }
            .sorted { $0.a < $1.a }
        var merged: [(a: Double, b: Double)] = []
        for s in busy {
            if let last = merged.last, s.a <= last.b { merged[merged.count - 1].b = max(last.b, s.b) }
            else { merged.append(s) }
        }
        var gaps: [(from: Double, to: Double)] = []
        var cur = from
        for m in merged {
            if m.a > cur { gaps.append((cur, m.a)) }
            cur = max(cur, m.b)
        }
        if cur < to { gaps.append((cur, to)) }
        return gaps
    }

    /// "2hrs", "45min", "1hr 30min" — the stamp on a free-time band.
    static func spanLabel(_ ms: Double) -> String {
        let mins = Int((ms / 60000).rounded())
        if mins < 60 { return "\(mins)min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h)hr\(h == 1 ? "" : "s")" : "\(h)hr \(m)min"
    }

    /// Where to stamp a free-time band: the middle of the widest waking stretch it covers.
    func stampPos(from: Double, to: Double) -> CGFloat? {
        var best: (a: Double, b: Double)?
        for r in runs where !r.night {
            let a = max(r.from, from), b = min(r.to, to)
            if b <= a { continue }
            if best == nil || b - a > best!.b - best!.a { best = (a, b) }
        }
        guard let best else { return nil }
        return (pos(best.a) + pos(best.b)) / 2
    }
}
