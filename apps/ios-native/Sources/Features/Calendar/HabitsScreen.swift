import SwiftUI

// Habits, ported from `src/web/pages/Habits.tsx`. Daily, small and time-bound, which is
// exactly why they belong on a phone rather than at a desk.

/// The last twelve weeks, a square a day. Tap one to tick it off.
///
/// The per-habit colour the web offers is deliberately not drawn. This app is grayscale end to
/// end, and a row of coloured squares would be the only hue on the phone; a habit is told apart
/// by its icon and by the shape of its own tick grid instead. The field is still round-tripped
/// — `CalHabit.color` decodes it and a created habit sends a neutral value — so editing a habit
/// here never wipes a colour chosen in the browser.
struct HabitsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    /// Twelve weeks, which is long enough to see a habit hold and short enough to fit a phone.
    private static let weeks = 12
    private static let span = weeks * 7

    @State private var habits: [CalHabit] = []
    @State private var loading = false
    @State private var newName = ""
    @State private var editing: CalHabit?
    @State private var deleting: CalHabit?
    @FocusState private var naming: Bool

    private var to: String { CalDate.todayKey }
    private var from: String { CalDate.addingDays(-(Self.span - 1), toKey: to) }
    private var days: [String] { (0..<Self.span).map { CalDate.addingDays($0, toKey: from) } }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    if habits.isEmpty {
                        if loading {
                            ProgressView()
                                .tint(Theme.Colors.mutedForeground)
                                .padding(.vertical, 56)
                        } else {
                            EmptyState(icon: "flame",
                                       message: "No habits yet.\nName one below. Pick the days you mean to do it, then keep the row filled in.")
                        }
                    } else {
                        ForEach(habits) { habit in
                            HabitRow(
                                habit: habit,
                                days: days,
                                toggle: { date in await toggle(habit, on: date) },
                                rename: { editing = habit },
                                remove: { deleting = habit }
                            )
                        }
                    }
                    addRow
                }
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .screenBackground()
        .tint(Theme.Colors.foreground)
        .task { await load() }
        .sheet(item: $editing) { habit in
            HabitEditor(habit: habit) { updated in
                replace(updated)
            }
            .presentationDetents([.height(340)])
        }
        .confirmationDialog(deleting.map { "Delete “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            // Named, never tinted. There is no undo behind this one, so the wording says so.
            Button("Delete habit") {
                if let habit = deleting { Task { await remove(habit) } }
                deleting = nil
            }
            Button("Keep it", role: .cancel) { deleting = nil }
        } message: {
            Text("Every tick you've ever made on it goes too. There's no undo.")
        }
    }

    private var bar: some View {
        TopBar(title: "Habits") {
            BarButton(icon: "chevron.left", label: "Back") { dismiss() }
        } trailing: {
            EmptyView()
        }
    }

    private var header: some View {
        Text("The last \(Self.weeks) weeks, a square a day. Tap one to tick it off.")
            .font(Theme.Typography.small)
            .foregroundStyle(Theme.Colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.top, 12)
            .padding(.bottom, 14)
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Colors.mutedForeground)
                .frame(width: 24)
            TextField("Add habit…", text: $newName)
                .font(Theme.Typography.body)
                .focused($naming)
                .submitLabel(.done)
                .onSubmit { Task { await create() } }
                .accessibilityLabel("New habit name")
            Button("Add") { Task { await create() } }
                .font(Theme.Typography.bodyMedium)
                .foregroundStyle(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                .frame(height: Theme.Metrics.minTouchTarget)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .frame(minHeight: Theme.Metrics.minTouchTarget)
        .padding(.vertical, 6)
        .hairline(.top)
    }

    // MARK: Mutations

    private func load() async {
        loading = habits.isEmpty
        defer { loading = false }
        do {
            habits = try await CalendarAPI.habits(from: from, to: to).filter { !$0.archived }
        } catch {
            guard !(error is CancellationError) else { return }
            toasts.error(message(error, "Couldn't load your habits."))
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            // Every weekday to start with, which is what the web's add form sends; the row's
            // own day picker is where that gets narrowed.
            let habit = try await CalendarAPI.createHabit(name: name, icon: "", days: [0, 1, 2, 3, 4, 5, 6])
            newName = ""
            naming = false
            habits.append(habit)
            Haptics.success()
        } catch {
            toasts.error(message(error, "Couldn't add that habit."))
        }
    }

    private func toggle(_ habit: CalHabit, on date: String) async {
        do {
            let updated = try await CalendarAPI.toggleHabit(id: habit.id, date: date, from: from, to: to)
            Haptics.select()
            replace(updated)
        } catch {
            toasts.error(message(error, "Couldn't change that."))
        }
    }

    private func remove(_ habit: CalHabit) async {
        do {
            try await CalendarAPI.deleteHabit(id: habit.id)
            habits.removeAll { $0.id == habit.id }
            Haptics.success()
        } catch {
            toasts.error(message(error, "Couldn't delete that habit."))
        }
    }

    /// The toggle and patch endpoints both answer with the whole habit, streak recomputed, so
    /// the row is swapped rather than reloaded.
    private func replace(_ habit: CalHabit) {
        guard let index = habits.firstIndex(where: { $0.id == habit.id }) else { return }
        habits[index] = habit
    }

    private func message(_ error: Error, _ fallback: String) -> String {
        (error as? APIError)?.errorDescription ?? fallback
    }
}

// MARK: - One habit

private struct HabitRow: View {
    let habit: CalHabit
    let days: [String]
    let toggle: (String) async -> Void
    let rename: () -> Void
    let remove: () -> Void

    private var done: Set<String> { Set(habit.completions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(habit.icon.isEmpty ? String(habit.name.prefix(1)).uppercased() : habit.icon)
                    .font(Theme.Typography.body)
                    .frame(width: 26, height: 26)
                    .background(Theme.Colors.muted)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                Button(action: rename) {
                    Text(habit.name)
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Colors.foreground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(habit.name)")

                Button(action: remove) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Delete \(habit.name)")
            }

            HStack(spacing: 10) {
                Label("\(habit.streak) day\(habit.streak == 1 ? "" : "s")", systemImage: "flame")
                    .font(Theme.Typography.micro)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.mutedForeground)
                Text("\(days.reduce(0) { $0 + (done.contains($1) ? 1 : 0) }) in 12 weeks")
                    .font(Theme.Typography.micro)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }

            TickGrid(habit: habit, days: days, toggle: toggle)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.vertical, 12)
        .hairline(.bottom)
    }
}

/// Twelve weeks as a wall of squares — a week to a column, so the grid reads as weeks going
/// across and weekdays going down, and today sits at the right-hand end where you want it.
private struct TickGrid: View {
    let habit: CalHabit
    let days: [String]
    let toggle: (String) async -> Void

    /// Small enough for twelve weeks to fit a phone; the touch target is the padded cell
    /// around it, not the square itself.
    private static let cell: CGFloat = 13
    private static let gap: CGFloat = 3

    private var scheduled: Set<Int> { Set(habit.expectedDays) }
    private var done: Set<String> { Set(habit.completions) }

    /// The days grouped into columns of seven, padded at the front so that each *row* is one
    /// weekday. Without the padding the twelve weeks would still be twelve columns, but the
    /// rows would be an arbitrary rotation of the week and the grid would read as noise.
    private var columns: [[String?]] {
        guard let first = days.first, let start = CalDate.date(fromKey: first) else { return [] }
        let cal = CalDate.cal
        var lead = cal.component(.weekday, from: start) - cal.firstWeekday
        if lead < 0 { lead += 7 }
        let padded: [String?] = Array(repeating: nil, count: lead) + days.map { Optional($0) }
        return stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<min($0 + 7, padded.count)]) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.gap) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                        VStack(spacing: Self.gap) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                if let day {
                                    square(day)
                                } else {
                                    // A day before the window opened: space held, nothing drawn.
                                    Color.clear.frame(width: Self.cell, height: Self.cell)
                                }
                            }
                        }
                        .id(index)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                // Today is at the far end; that is the end you want to be looking at.
                proxy.scrollTo(columns.count - 1, anchor: .trailing)
            }
        }
        .frame(height: (Self.cell + Self.gap) * 7)
    }

    private func square(_ day: String) -> some View {
        let isDone = done.contains(day)
        let date = CalDate.date(fromKey: day) ?? Date()
        let expected = scheduled.contains(CalDate.cal.component(.weekday, from: date) - 1)
        return Button {
            Task { await toggle(day) }
        } label: {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isDone ? Theme.Colors.foreground : Color.clear)
                .overlay {
                    if !isDone {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            // A day the habit was expected on and missed keeps an outline; a
                            // day it was never expected on is left blank. That contrast is what
                            // colour does on the web.
                            .strokeBorder(expected ? Theme.Colors.border : Theme.Colors.border.opacity(0.35), lineWidth: 1)
                    }
                }
                .frame(width: Self.cell, height: Self.cell)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(habit.name) on \(CalDate.spokenDate(date))")
        .accessibilityValue(isDone ? "Done" : (expected ? "Missed" : "Not expected"))
        .accessibilityAddTraits(isDone ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Editing one

/// Rename, re-icon, and choose which weekdays the habit is expected on.
private struct HabitEditor: View {
    let habit: CalHabit
    let saved: (CalHabit) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    @State private var name: String
    @State private var icon: String
    @State private var days: Set<Int>
    @State private var busy = false
    @State private var error: String?

    /// `0 = Sunday`, matching `Habit.days` on the wire and `Date`'s weekday index minus one.
    private static let weekdays: [(day: Int, short: String, long: String)] = [
        (0, "S", "Sunday"), (1, "M", "Monday"), (2, "T", "Tuesday"), (3, "W", "Wednesday"),
        (4, "T", "Thursday"), (5, "F", "Friday"), (6, "S", "Saturday"),
    ]

    init(habit: CalHabit, saved: @escaping (CalHabit) -> Void) {
        self.habit = habit
        self.saved = saved
        _name = State(initialValue: habit.name)
        _icon = State(initialValue: habit.icon)
        _days = State(initialValue: Set(habit.expectedDays))
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Habit") {
                Button("Cancel") { dismiss() }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .padding(.horizontal, 8)
            } trailing: {
                Button("Save") { Task { await save() } }
                    .font(Theme.Typography.bodyStrong)
                    .foregroundStyle(busy ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .padding(.horizontal, 8)
                    .disabled(busy)
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    TextField("🙂", text: $icon)
                        .font(Theme.Typography.body)
                        .multilineTextAlignment(.center)
                        .frame(width: 44, height: Theme.Metrics.minTouchTarget)
                        .background(Theme.Colors.muted)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                        .accessibilityLabel("Icon")
                    TextField("Habit name", text: $name)
                        .font(Theme.Typography.body)
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .accessibilityLabel("Habit name")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Expected on")
                        .font(Theme.Typography.caps)
                        .tracking(0.6)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                    HStack(spacing: 6) {
                        ForEach(Self.weekdays, id: \.day) { weekday in
                            let on = days.contains(weekday.day)
                            Button {
                                // The server reads an empty list as "no change", so a habit
                                // always keeps at least one day — `Habits.tsx:180-185`.
                                if on && days.count == 1 { return }
                                if on { days.remove(weekday.day) } else { days.insert(weekday.day) }
                                Haptics.select()
                            } label: {
                                Text(weekday.short)
                                    .font(Theme.Typography.small)
                                    .foregroundStyle(on ? Theme.Colors.background : Theme.Colors.mutedForeground)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Theme.Metrics.minTouchTarget)
                                    .background {
                                        RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                            .fill(on ? Theme.Colors.foreground : Color.clear)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                            .strokeBorder(Theme.Colors.border, lineWidth: on ? 0 : 1)
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(weekday.long)\(on ? " — expected" : " — off")")
                            .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                    Text("A habit has to be expected on at least one day.")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }

                if let error {
                    Text(error)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.foreground)
                }

                Spacer(minLength: 0)
            }
            .padding(Theme.Metrics.hPadding)
        }
        .screenBackground()
        .tint(Theme.Colors.foreground)
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Give the habit a name."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let updated = try await CalendarAPI.updateHabit(
                id: habit.id,
                name: trimmed,
                // An emoji can be several code points (skin tones, ZWJ sequences), so one
                // *character* is taken rather than one scalar — `Habits.tsx:32`.
                icon: icon.trimmingCharacters(in: .whitespaces).first.map(String.init) ?? "",
                days: days.sorted()
            )
            saved(updated)
            Haptics.success()
            dismiss()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Couldn't save that habit."
        }
    }
}
