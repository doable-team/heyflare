import Foundation

/// `src/web/lib/format.ts`, ported so the two clients print the same strings.
enum Fmt {
    private static func toDate(_ ms: Double) -> Date { Date(timeIntervalSince1970: (ms < 1e12 ? ms * 1000 : ms) / 1000) }

    private static let time: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("jmm"); return f }()
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f }()
    private static let monthDay: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d"); return f }()
    private static let monthDayYear: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d, yyyy"); return f }()
    private static let full: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d, yyyy jmm"); return f }()
    private static let monthYear: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMM yyyy"); return f }()
    private static let hint: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE MMM d"); return f }()

    /// `fmtTime`: the clock today, the weekday this week, the day this year, else the date.
    static func time(_ ms: Double, now: Date = Date()) -> String {
        let d = toDate(ms)
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return time.string(from: d) }
        let diff = now.timeIntervalSince(d)
        if diff > 0 && diff < 6 * 86_400 { return weekday.string(from: d) }
        if cal.component(.year, from: d) == cal.component(.year, from: now) { return monthDay.string(from: d) }
        return monthDayYear.string(from: d)
    }

    /// `toLocaleString(month, day, year, hour, minute)`: "Sep 6, 2026, 2:54 PM".
    static func full(_ ms: Double) -> String { let d = toDate(ms); return "\(monthDayYear.string(from: d)), \(time.string(from: d))" }
    static func date(_ ms: Double) -> String { monthDayYear.string(from: toDate(ms)) }
    static func monthKey(_ ms: Double) -> String { monthYear.string(from: toDate(ms)) }
    static func clock(_ d: Date) -> String { time.string(from: d) }

    /// `fmtRelative`: "in 3 hours", "2 days ago".
    static func relative(_ ms: Double, now: Date = Date()) -> String {
        let diff = toDate(ms).timeIntervalSince(now) * 1000
        let abs = Swift.abs(diff)
        let future = diff > 0
        let units: [(Double, String)] = [(60_000, "minute"), (3_600_000, "hour"), (86_400_000, "day"), (7 * 86_400_000, "week"), (30 * 86_400_000, "month")]
        if abs < 60_000 { return future ? "in a moment" : "just now" }
        var value = 0
        var unit = "minute"
        for (size, name) in units.reversed() where abs >= size {
            value = Int((abs / size).rounded())
            unit = name
            break
        }
        let label = "\(value) \(unit)\(value == 1 ? "" : "s")"
        return future ? "in \(label)" : "\(label) ago"
    }

    /// The DateTimePicker's "Today, 3:00 PM" / "Sat, Sep 12, 9:00 AM".
    static func hintDate(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today, \(time.string(from: d))" }
        return "\(hint.string(from: d)), \(time.string(from: d))"
    }

    static func size(_ bytes: Int) -> String {
        if bytes == 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(bytes)
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return (v < 10 && i > 0 ? String(format: "%.1f", v) : String(Int(v.rounded()))) + " " + units[i]
    }

    static func initials(_ name: String, _ email: String) -> String {
        let source = name.trimmingCharacters(in: .whitespaces).isEmpty ? (email.split(separator: "@").first.map(String.init) ?? "?") : name.trimmingCharacters(in: .whitespaces)
        let cleaned = source.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " ._-".unicodeScalars.contains($0) }
        let parts = String(String.UnicodeScalarView(cleaned)).split(whereSeparator: { " ._-".contains($0) }).filter { !$0.isEmpty }
        if parts.isEmpty { return String(source.prefix(2)).uppercased() }
        if parts.count == 1 { return String(parts[0].prefix(2)).uppercased() }
        return (String(parts[0].prefix(1)) + String(parts[parts.count - 1].prefix(1))).uppercased()
    }
}
