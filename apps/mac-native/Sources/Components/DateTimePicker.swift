import SwiftUI

/// `DateTimePicker`: presets, then a calendar and a time, for Bubble Up and Send Later.
struct DateTimePicker: View {
    var title = "Bubble up"
    var verb = "Bubble up"
    var embedded = false
    var onPick: (Date) -> Void
    var onCancel: (() -> Void)? = nil

    @State private var day: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var minutes = 9 * 60
    @State private var showCalendar = false
    @State private var month: Date = Date()

    struct Preset: Identifiable { let id: String; let label: String; let at: Date; let icon: String }

    static func presets(now: Date = Date()) -> [Preset] {
        let cal = Calendar.current
        func at(_ d: Date, _ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d }
        var out: [Preset] = []
        let hour = cal.component(.hour, from: now)
        let laterToday = at(now, min(hour + 3, 22))
        if laterToday.timeIntervalSince(now) > 15 * 60 {
            out.append(Preset(id: "later", label: "Later today", at: laterToday, icon: "coffee"))
        } else {
            let tonight = at(now, 20)
            if tonight > now { out.append(Preset(id: "evening", label: "This evening", at: tonight, icon: "moon")) }
        }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        out.append(Preset(id: "tomorrow", label: "Tomorrow morning", at: at(tomorrow, 8), icon: "sunrise"))
        let weekday = cal.component(.weekday, from: now) - 1 // 0 = Sunday, like JS
        let daysToSat = ((6 - weekday + 7) % 7) == 0 ? 7 : (6 - weekday + 7) % 7
        let weekend = cal.date(byAdding: .day, value: daysToSat, to: now)!
        out.append(Preset(id: "weekend", label: "This weekend", at: at(weekend, 9), icon: "sun"))
        let daysToMon = ((1 - weekday + 7) % 7) == 0 ? 7 : (1 - weekday + 7) % 7
        let nextWeek = cal.date(byAdding: .day, value: daysToMon, to: now)!
        out.append(Preset(id: "week", label: "Next week", at: at(nextWeek, 8), icon: "calendarDays"))
        let monthLater = cal.date(byAdding: .month, value: 1, to: now)!
        out.append(Preset(id: "month", label: "In a month", at: at(monthLater, 8), icon: "calendarClock"))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                Text(title).font(W.font(12, 500)).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).frame(height: 32)
            }
            ForEach(Self.presets()) { p in
                row(icon: p.icon, label: p.label, hint: Fmt.hintDate(p.at)) { onPick(p.at) }
            }
            row(icon: "calendarDays", label: "Pick a date…", hint: nil) { showCalendar.toggle() }
            if showCalendar {
                WSeparator().padding(.vertical, 4)
                MiniCalendar(month: $month, selected: $day, minDate: Calendar.current.startOfDay(for: Date()))
                    .padding(4)
                HStack(spacing: 6) {
                    TimeSelect(minutes: $minutes)
                    WButton(verb, size: .sm) {
                        let cal = Calendar.current
                        onPick(cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 4)
            }
            if let onCancel, !embedded {
                HStack { Spacer(); WButton("Cancel", variant: .ghost, size: .xs, muted: true, action: onCancel) }.padding(.horizontal, 4).padding(.bottom, 4)
            }
        }
        .frame(width: 300)
        .padding(embedded ? 0 : 4)
    }

    private func row(icon: String, label: String, hint: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(icon, size: 14).foregroundStyle(W.mutedForeground)
                Text(label).font(W.font(12.8)).foregroundStyle(W.foreground)
                Spacer()
                if let hint { Text(hint).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground) }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.web(.ghost, .sm))
    }
}

/// The time-of-day select: half-hour steps.
struct TimeSelect: View {
    @Binding var minutes: Int
    @Environment(PopLayerState.self) private var pops
    @State private var id = "time-select-\(UUID().uuidString)"

    var body: some View {
        Button {
            pops.toggle(id, side: .bottom, align: .start) {
                PopCard(width: 160) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(0..<48, id: \.self) { i in
                                MenuItem(label(i * 30), checked: minutes == i * 30) { minutes = i * 30 }
                            }
                        }
                    }
                    .frame(height: 256)
                }
            }
        } label: {
            HStack {
                Text(label(minutes)).font(W.font(12.8))
                Spacer()
                Icon("chevronDown", size: 14).foregroundStyle(W.mutedForeground)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popAnchor(id)
        .frame(maxWidth: .infinity)
    }

    private func label(_ m: Int) -> String {
        let cal = Calendar.current
        let d = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        return Fmt.clock(d)
    }
}

/// shadcn's `Calendar`: a month grid, 32pt cells.
struct MiniCalendar: View {
    @Binding var month: Date
    @Binding var selected: Date
    var minDate: Date? = nil
    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                WButton(icon: "chevronLeft", variant: .outline, size: .iconSm) { month = cal.date(byAdding: .month, value: -1, to: month) ?? month }
                Spacer()
                Text(Fmt.monthKey(month.timeIntervalSince1970 * 1000)).font(W.font(14, 500))
                Spacer()
                WButton(icon: "chevronRight", variant: .outline, size: .iconSm) { month = cal.date(byAdding: .month, value: 1, to: month) ?? month }
            }
            let symbols = cal.veryShortStandaloneWeekdaySymbols
            let shift = cal.firstWeekday - 1
            let ordered = Array(symbols[shift...] + symbols[..<shift])
            HStack(spacing: 0) {
                ForEach(ordered, id: \.self) { s in Text(s).font(W.font(12.8)).foregroundStyle(W.mutedForeground).frame(width: 32, height: 32) }
            }
            let days = grid()
            ForEach(0..<(days.count / 7), id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let d = days[row * 7 + col]
                        let inMonth = cal.isDate(d, equalTo: month, toGranularity: .month)
                        let disabled = minDate.map { d < $0 } ?? false
                        let isSelected = cal.isDate(d, inSameDayAs: selected)
                        Button { if !disabled { selected = d } } label: {
                            Text("\(cal.component(.day, from: d))")
                                .font(W.font(14))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? W.primaryForeground : (inMonth ? W.foreground : W.mutedForeground))
                                .frame(width: 32, height: 32)
                                .background(isSelected ? W.primary : (cal.isDateInToday(d) ? W.accent : Color.clear))
                                .rounded(W.radiusMd)
                                .opacity(disabled ? 0.4 : 1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                    }
                }
            }
        }
    }

    private func grid() -> [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let lead = (cal.component(.weekday, from: interval.start) - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: interval.start) ?? interval.start
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }
}
