import SwiftUI
import AppKit

/// `CalendarCover.tsx`: HEY's "cover art" — the next three days sitting at the top of the
/// Imbox, so checking the day and checking the mail are the same glance. Off by default;
/// turned on in Settings → Calendar (`cover_art`).
struct CalendarCoverView: View {
    @Environment(Router.self) private var router
    @State private var prefs: CalPrefs? = ContentCache.shared.value(CalPrefs.self, for: .calendarSettings)
    @State private var events: [CalEventFull] = []
    @State private var habits: [CalHabit] = []

    private var on: Bool { prefs?.coverArt ?? false }
    private var cal: Calendar { CalDate.calendar(prefs ?? CalDate.prefs) }

    var body: some View {
        Group {
            if on { section } else { Color.clear.frame(height: 0) }
        }
        .task { await load() }
        .onChange(of: CalendarBus.shared.revision) { _, _ in Task { await load() } }
    }

    private var section: some View {
        let today = CalDate.todayKey
        let days = [today, CalDate.addingDays(1, toKey: today, in: cal), CalDate.addingDays(2, toKey: today, in: cal)]
        let fmt = prefs?.timeFormat == "24" ? "24" : "12"
        let live = habits.filter { !$0.archived }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("NEXT THREE DAYS").font(W.font(11)).tracking(0.275).foregroundStyle(W.tertiary)
                Spacer(minLength: 0)
                CoverLink(label: "Calendar", chevron: true) { router.go(.calendar(nil)) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .edgeLine(.bottom)

            if !live.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(live) { h in
                        HabitChip(habit: h, done: h.completions.contains(today)) { toggle(h, date: today) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .edgeLine(.bottom)
            }

            HStack(spacing: 1) {
                ForEach(days, id: \.self) { d in
                    let list = Array(events.filter { onDay($0, d) }
                        .sorted { a, b in a.allDay != b.allDay ? a.allDay : a.startsAt < b.startsAt }
                        .prefix(4))
                    VStack(alignment: .leading, spacing: 0) {
                        CoverLink(label: CalUI.relativeDay(d, cal) ?? CalUI.weekdayLong(d, cal), chevron: false) { router.go(.calendar(d)) }
                        VStack(alignment: .leading, spacing: 4) {
                            if list.isEmpty { Text("Nothing scheduled.").font(W.font(11.5)).foregroundStyle(W.tertiary) }
                            ForEach(list) { e in EventLine(event: e, format: fmt, date: d, cal: cal) }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .background(W.background)
                }
            }
            .background(W.border)

            if events.isEmpty {
                Text("Connect a calendar in Settings to fill this in.").font(W.font(11.5)).foregroundStyle(W.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1))
        .rounded(W.radiusMd)
        .padding(.bottom, 20)
    }

    private func load() async {
        if let fresh = try? await CalendarAPI.settings() {
            prefs = fresh
            ContentCache.shared.store(fresh, for: .calendarSettings)
        }
        guard on else { return }
        let today = CalDate.todayKey
        if let range = try? await CalendarAPI.range(from: today, to: CalDate.addingDays(2, toKey: today, in: cal)) {
            events = range.events
            habits = range.habits
        }
    }

    private func toggle(_ h: CalHabit, date: String) {
        Task {
            do {
                let fresh = try await CalendarAPI.toggleHabit(id: h.id, date: date, from: date, to: date)
                if let i = habits.firstIndex(where: { $0.id == h.id }) {
                    var row = habits[i]
                    row.completions.removeAll { $0 == date }
                    if fresh.completions.contains(date) { row.completions.append(date) }
                    habits[i] = row
                }
            } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    private func onDay(_ e: CalEventFull, _ date: String) -> Bool {
        if e.allDay { return (e.startDate ?? "") <= date && date <= (e.endDate ?? e.startDate ?? "") }
        return CalDate.key(e.start, in: cal) == date
    }
}

/// `text-[11px] text-muted-foreground hover:text-foreground`, with `ChevronRight size 12` for the header link.
private struct CoverLink: View {
    let label: String
    let chevron: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(label).font(W.font(11))
                if chevron { Icon("chevronRight", size: 12) }
            }
            .foregroundStyle(hovering ? W.foreground : W.mutedForeground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `rounded-full border px-1.5 py-0.5 text-[11px]`, filled in the habit's colour once done.
private struct HabitChip: View {
    let habit: CalHabit
    let done: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if habit.icon.isEmpty { Icon("check", size: 9) } else { Text(habit.icon) }
                Text(habit.name)
            }
            .font(W.font(11))
            .foregroundStyle(done ? W.background : W.mutedForeground)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(done ? (habit.color.isEmpty ? W.mutedForeground : Color(hex: habit.color)) : Color.clear)
            .overlay(Capsule().strokeBorder(done ? Color.clear : (hovering ? W.foreground.opacity(0.3) : W.border), lineWidth: 1))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One line of a day: the time in a 48pt column, the title, a countdown, and Join when a
/// call starts within a quarter of an hour.
private struct EventLine: View {
    let event: CalEventFull
    let format: String
    let date: String
    let cal: Calendar

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        let soon = !event.allDay && !event.conferenceURL.isEmpty && event.startsAt - now < 15 * 60_000 && event.endsAt > now
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(event.allDay ? "All day" : CalUI.fmtTime(event.startsAt, format, cal)).monospacedDigit().foregroundStyle(W.tertiary).frame(width: 48, alignment: .leading)
            Text(event.title.isEmpty ? "(no title)" : event.title).truncate().frame(maxWidth: .infinity, alignment: .leading)
            if event.countdown { Text(CalUI.countdownLabel(event.startDate ?? date, cal)).font(W.font(10.5)).foregroundStyle(W.tertiary) }
            if soon {
                JoinButton { if let url = URL(string: event.conferenceURL) { NSWorkspace.shared.open(url) } }
            }
        }
        .font(W.font(11.5))
        .foregroundStyle(W.foreground)
    }
}

/// `Button size="xs" variant="ghost" className="h-4 px-1 text-[10.5px]"`.
private struct JoinButton: View {
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { Icon("video", size: 12); Text("Join") }
                .font(W.font(10.5, 500))
                .foregroundStyle(W.foreground)
                .padding(.horizontal, 4)
                .frame(height: 16)
                .background(hovering ? W.muted : Color.clear)
                .rounded(W.radiusMd)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension CalUI {
    /// `relativeDay`: "Today", "Tomorrow", "Yesterday", or nil.
    static func relativeDay(_ key: String, _ cal: Calendar) -> String? {
        let d = daysBetween(CalDate.todayKey, key, cal)
        if d == 0 { return "Today" }
        if d == 1 { return "Tomorrow" }
        if d == -1 { return "Yesterday" }
        return nil
    }

    /// `weekdayLabel`: "Thursday".
    static func weekdayLong(_ key: String, _ cal: Calendar) -> String {
        guard let d = CalDate.date(fromKey: key, in: cal) else { return key }
        let f = DateFormatter(); f.calendar = cal; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    /// `fmtTime`: "9:30 AM" (12h) or "09:30" (24h).
    static func fmtTime(_ ms: Double, _ format: String, _ cal: Calendar) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter(); f.calendar = cal; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format == "24" ? "HH:mm" : "h:mm a"
        return f.string(from: d)
    }

    /// `countdownLabel`: "in 12 days", "tomorrow", "today", "yesterday", "8 days ago".
    static func countdownLabel(_ key: String, _ cal: Calendar) -> String {
        let d = daysBetween(CalDate.todayKey, key, cal)
        if d == 0 { return "today" }
        if d == 1 { return "tomorrow" }
        if d == -1 { return "yesterday" }
        if d > 0 { return "in \(d) days" }
        return "\(-d) days ago"
    }
}

