import SwiftUI

/// The Calendar tab: a month grid with the selected day's agenda under it.
///
/// DESIGN.md §9 spends most of its length on the desktop calendar — time drawn strictly to
/// scale, a horizontal day ribbon, colour as the one exception to monochrome — and then ends
/// by saying the phone is deliberately conventional, "a month grid plus agenda", because the
/// ribbon does not survive a thumb. This screen is that ending, taken literally: a month of
/// 44pt-plus squares a finger can actually hit, each carrying at most three marks, with the
/// detail moved down into a list rather than crammed into a 40pt cell.
///
/// A day is not the end of the road any more. One tap selects it, a second opens
/// `CalendarDayScreen` — the same two-step the web's own phone grid uses
/// (`MobileCalendar.tsx:129`) — and everything the calendar can *write* lives either there or
/// in the editor this screen's plus button opens.
///
/// The one place this departs from §9 is colour. On the desktop, a calendar's own colour is
/// the user's data and a week of forty grey events would be unreadable — but this app is
/// grayscale end to end, and a single hue here would be the only one on the phone. So
/// `calendar_color` is read and ignored: identity is carried instead by two hueless
/// channels — a stable gray step derived from the *calendar id* (not from the hex, so
/// recolouring a calendar in Google does not reshuffle the phone), and by shape, since an
/// all-day item is a bar, a timed one a dot, and a todo a hollow circle. See
/// `CalEventFull.calendarTone`.
struct CalendarScreen: View {
    // The range endpoint is owner-wide rather than account-scoped, so unlike every mail
    // screen this one has nothing to read out of `AppState` and does not take it.
    @Environment(ToastCenter.self) private var toasts
    @Environment(Navigator.self) private var nav

    @State private var store = CalendarStore()
    /// The selected day. There is no second cursor for the month on screen: the month *is*
    /// the selected day's month, which is what makes a month swipe keep the agenda under it.
    @State private var cursor = CalDate.cal.startOfDay(for: Date())
    @State private var gridOffset: CGFloat = 0
    @State private var armed = false
    @State private var editing: EventEditorTarget?

    private var cal: Calendar { store.calendar }
    private var monthKey: String { CalDate.monthKey(cursor, in: cal) }
    private var cursorKey: String { CalDate.key(cursor, in: cal) }

    var body: some View {
        VStack(spacing: 0) {
            bar

            ScrollView {
                VStack(spacing: 0) {
                    weekdayHeader
                    monthGrid
                    agenda
                }
                .padding(.bottom, 24)
            }
            .refreshable {
                // Ask the sources to pull first, then re-read the window — otherwise a refresh
                // just re-fetches whatever the last cron run happened to leave behind. A source
                // that refuses to sync must not swallow the refresh, so the error is dropped.
                try? await CalendarAPI.syncSources()
                await store.refresh(month: cursor)
            }
        }
        .screenBackground()
        .overlay(alignment: .bottomTrailing) { newEventButton }
        // Keyed on the month rather than on the day: stepping a day inside a month it already
        // holds must not start a fetch, and stepping a month always must.
        .task(id: monthKey) { await store.ensure(month: cursor) }
        // The owner's preferences decide which weekday the grid starts on and what a time
        // reads as, so they are asked for once and the grid redraws when the answer lands.
        .task { await store.loadPrefs() }
        .onChange(of: store.error) { _, message in
            if let message { toasts.error(message) }
        }
        // A write from the day screen or the editor lands here as a bumped revision.
        .onChange(of: CalendarBus.shared.revision) { _, _ in
            Task { await store.invalidate(around: cursor) }
        }
        .sheet(item: $editing) { target in
            EventEditor(target: target, store: store)
        }
    }

    // MARK: - Chrome

    private var bar: some View {
        TopBar(title: CalDate.monthLabel(cursor)) {
            Button {
                let today = cal.startOfDay(for: Date())
                guard today != cursor else { return }
                Haptics.select()
                cursor = today
            } label: {
                Text("Today")
                    .font(Theme.Typography.body)
                    // Dimmed when it would do nothing, rather than disabled: a control that
                    // vanishes as you arrive is harder to find again than one that greys.
                    .foregroundStyle(showingToday ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                    .padding(.horizontal, 8)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Go to today")
        } trailing: {
            // Journal and Habits used to sit here; four bar buttons plus "Today" left the
            // month name nowhere to go and it drew over them. They live under More now,
            // which is where the web build keeps them too.
            HStack(spacing: 0) {
                BarButton(icon: "chevron.left", label: "Previous month") { step(-1) }
                BarButton(icon: "chevron.right", label: "Next month") { step(1) }
            }
        }
    }

    /// The button moves the cursor to today's *day*, so it is only inert when the cursor is
    /// already on today. Comparing months alone dimmed it on 20 September while tapping it
    /// would still have moved the selection — a control that lies about doing nothing.
    /// One test covers both halves because `cursor` is the month as well as the selected day:
    /// the same day implies the same month.
    private var showingToday: Bool {
        cal.isDateInToday(cursor)
    }

    /// New events start at nine on the selected day, the same slot the web's own phone button
    /// picks (`MobileCalendar.tsx:161`). A more precise time is a press-and-hold away on the
    /// day screen; this is the "something at some point today" button.
    private var newEventButton: some View {
        Button {
            editing = .create(day: cursorKey, startMinutes: 9 * 60, endMinutes: 10 * 60, allDay: false)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.Colors.background)
                .frame(width: 52, height: 52)
                .background(Theme.Colors.foreground)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .accessibilityLabel("New event on \(CalDate.spokenDate(cursor))")
        .padding(.trailing, Theme.Metrics.hPadding)
        .padding(.bottom, 12)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(CalDate.weekdaySymbols(in: cal).enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased())
                    .font(Theme.Typography.caps)
                    .tracking(0.6)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
        .accessibilityHidden(true)   // every cell already says its own full date
    }

    // MARK: - Month grid

    private var monthGrid: some View {
        // The calendar is built once for the whole grid rather than per cell: `CalDate.cal`
        // assembles a fresh one every time it is read, and forty-two cells is enough for that
        // to matter on every scroll frame.
        let cal = self.cal
        let days = CalDate.monthGrid(for: cursor, in: cal)
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }

        return VStack(spacing: 0) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.timeIntervalSince1970) { day in
                        let key = CalDate.key(day, in: cal)
                        DayCell(
                            day: day,
                            number: String(cal.component(.day, from: day)),
                            events: store.events(onKey: key),
                            inMonth: cal.isDate(day, equalTo: cursor, toGranularity: .month),
                            isToday: cal.isDateInToday(day),
                            isSelected: cal.isDate(day, inSameDayAs: cursor),
                            isWeekend: cal.isDateInWeekend(day),
                            hasJournal: store.journalDays.contains(key)
                        ) {
                            // One tap selects, a second opens the day. A grid whose first tap
                            // pushed a screen would make browsing a month cost a push and a
                            // pop per square.
                            guard !cal.isDate(day, inSameDayAs: cursor) else {
                                nav.push(.calendarDay(key))
                                return
                            }
                            Haptics.select()
                            cursor = day
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .offset(x: gridOffset)
        // A UIKit pan, not a `DragGesture`: the grid is made of buttons, and a SwiftUI
        // drag under buttons never engaged, so the month could only be changed by chevron.
        .background(HorizontalPan(onChange: monthMoved(to:), onEnd: monthReleased(at:cancelled:)))
        .overlay(alignment: .top) {
            if store.loading && !store.isLoaded(month: cursor) {
                ProgressView()
                    .tint(Theme.Colors.mutedForeground)
                    .padding(.top, 24)
            }
        }
    }

    /// A month step is a swipe, because that is how every phone calendar behaves and the
    /// chevrons are there for anyone who would rather tap. Past the threshold the change
    /// happens instantly and the offset snaps back with no animation — the new month must
    /// not slide in from the edge the finger just left.
    private func monthMoved(to translation: CGFloat) {
        gridOffset = translation
        let past = abs(translation) >= 64
        if past != armed {
            armed = past
            if past { Haptics.threshold() }
        }
    }

    private func monthReleased(at translation: CGFloat, cancelled: Bool) {
        armed = false
        // `gridOffset != 0` proves the grid actually moved with the finger.
        if !cancelled, gridOffset != 0, abs(translation) >= 64 {
            step(translation < 0 ? 1 : -1, haptic: false)
        }
        gridOffset = 0
    }

    private func step(_ delta: Int, haptic: Bool = true) {
        if haptic { Haptics.select() }
        cursor = CalDate.addingMonths(delta, to: cursor, in: cal)
    }

    // MARK: - Agenda

    private var agenda: some View {
        let day = store.events(onKey: cursorKey)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                nav.push(.calendarDay(cursorKey))
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(CalDate.dayLabel(cursor))
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(Theme.Colors.foreground)
                    if let relative = CalDate.relativeDay(cursor, in: cal) {
                        Text(relative)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                    Spacer(minLength: 0)
                    if !day.isEmpty {
                        CountBadge(count: day.count)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .frame(minHeight: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Open \(CalDate.spokenDate(cursor))")

            if day.isEmpty {
                EmptyState(icon: "calendar", message: "Nothing scheduled.")
            } else {
                ForEach(day.ordered) { event in
                    AgendaRow(event: event) { editing = .edit(event) }
                        .hairline(.top)
                }
            }
        }
    }
}

// MARK: - Day cell

/// One square of the month. Big enough to hit, quiet enough that six rows of them still read
/// as a month rather than as a table.
private struct DayCell: View {
    let day: Date
    let number: String
    let events: CalendarStore.DayEvents
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let isWeekend: Bool
    let hasJournal: Bool
    let onTap: () -> Void

    /// 46pt clears the 44pt minimum with six rows still fitting above the agenda.
    private static let height: CGFloat = 46

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text(number)
                    .font(.system(size: 13, weight: isSelected || isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.Colors.background : Theme.Colors.foreground)
                    .frame(width: 26, height: 26)
                    .background {
                        if isSelected {
                            Circle().fill(Theme.Colors.foreground)
                        }
                    }
                    .overlay {
                        // Today keeps its ring even when selected, so the inverted disc never
                        // hides which day it actually is.
                        if isToday {
                            Circle()
                                .strokeBorder(isSelected ? Theme.Colors.foreground : Theme.Colors.foreground.opacity(0.55),
                                              lineWidth: 1.5)
                                .padding(isSelected ? -3 : 0)
                        }
                    }

                marks
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(isWeekend ? Theme.Colors.muted.opacity(0.5) : Color.clear)
            .overlay(alignment: .topTrailing) {
                // A day with a journal entry gets a small square in the corner, so it never
                // reads as one of the event marks below it.
                if hasJournal {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Theme.Colors.foreground.opacity(0.5))
                        .frame(width: 3, height: 3)
                        .padding(.top, 4)
                        .padding(.trailing, 5)
                }
            }
            .opacity(inMonth ? 1 : 0.35)
            .contentShape(Rectangle())
            .hairline(.top)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(isSelected ? "Opens the day" : "Selects the day")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Three marks at most: an all-day item is a short filled bar, a timed one a dot. Shape
    /// is doing the work colour does on the desktop — see the note on `CalendarScreen`.
    private var marks: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(events.allDay.count, 3), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.Colors.foreground.opacity(0.75))
                    .frame(width: 10, height: 3)
            }
            ForEach(0..<max(0, min(events.timed.count, 3 - min(events.allDay.count, 3))), id: \.self) { _ in
                Circle()
                    .fill(Theme.Colors.foreground.opacity(0.6))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(height: 5)
    }

    /// The full date, spoken: a bare "14" tells a VoiceOver user nothing about which month
    /// or year the grid has been swiped to.
    private var label: String {
        var parts = [CalDate.spokenDate(day)]
        if isToday { parts.append("Today") }
        switch events.count {
        case 0: parts.append("No events")
        case 1: parts.append("1 event")
        case let n: parts.append("\(n) events")
        }
        if hasJournal { parts.append("Journal written") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Agenda row

/// One event under the grid. Tapping it opens the editor, which is the same thing tapping an
/// agenda row does on the web (`MobileCalendar.tsx:151`) — the row is the only handle a phone
/// has on an event, so making it inert to protect against a mis-tap costs more than it saves.
/// Nothing here mutates on touch: the destructive half is behind a named, confirmed button
/// inside the editor.
private struct AgendaRow: View {
    let event: CalEventFull
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                marker
                    .padding(.top, 2)

                Text(when)
                    .font(Theme.Typography.micro)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 58, alignment: .leading)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.displayTitle)
                        .font(Theme.Typography.body)
                        .strikethrough(struckThrough, color: Theme.Colors.mutedForeground)
                        .foregroundStyle(struckThrough ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !event.location.isEmpty {
                        Text(event.location)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let url = URL(string: event.conferenceURL), !event.conferenceURL.isEmpty {
                    Link(destination: url) {
                        Image(systemName: "video")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.Colors.foreground)
                            .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Join call")
                }
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.vertical, 10)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
            // A declined invitation only arrives at all when the owner asked to see declined
            // events; when it does, it must not read like something they are going to.
            .opacity(event.isCancelled || event.isDeclined ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    /// A rule for an event, a checkbox-ish circle for a todo. The rule's gray step comes from
    /// the calendar id so two calendars stay told apart without a hue; a cancelled item loses
    /// its fill entirely, which is the monochrome version of the desktop's dashed ghost.
    @ViewBuilder
    private var marker: some View {
        if event.isTodo {
            Circle()
                .strokeBorder(Theme.Colors.foreground.opacity(0.55), lineWidth: 1.5)
                .background {
                    if event.done { Circle().fill(Theme.Colors.foreground) }
                }
                .frame(width: 14, height: 14)
                .overlay {
                    if event.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.Colors.background)
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(event.isCancelled ? Color.clear : Theme.Colors.foreground.opacity(event.calendarTone))
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .strokeBorder(Theme.Colors.border, lineWidth: event.isCancelled ? 1 : 0)
                )
                .frame(width: 3, height: 26)
        }
    }

    private var when: String {
        event.allDay ? "All day" : CalDate.time(event.start)
    }

    /// Cancelled events are struck through, and so is a finished todo — both are things that
    /// are no longer going to happen.
    private var struckThrough: Bool { event.isCancelled || (event.isTodo && event.done) }

    private var spoken: String {
        var parts = [when, event.displayTitle]
        if !event.location.isEmpty { parts.append(event.location) }
        if event.isCancelled { parts.append("Cancelled") }
        if event.isDeclined { parts.append("Declined") }
        if event.isTodo { parts.append(event.done ? "Done" : "To do") }
        if !event.calendarName.isEmpty { parts.append(event.calendarName) }
        return parts.joined(separator: ", ")
    }
}
