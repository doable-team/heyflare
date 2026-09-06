import SwiftUI

/// The week as a to-do list and a stopwatch, ported from the desk client's week bar.
///
/// Two things live here that have no hour attached: what has to happen sometime this
/// week, and how long things took. Both are week-shaped rather than day-shaped, which is
/// why they get a screen of their own instead of a strip on the day.
struct WeekScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    /// The `yyyy-MM-dd` key of the week being shown, on the owner's week-start day.
    @State private var week: String = WeekScreen.weekStart(containing: Date())
    @State private var tasks: [FlexTask] = []
    @State private var entries: [TimeEntry] = []
    @State private var loading = false
    @State private var newTask = ""
    @State private var newTimer = ""
    @State private var editingTask: FlexTask?
    @State private var editingEntry: TimeEntry?
    @State private var deletingEntry: TimeEntry?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case task, timer }

    private var cal: Calendar { CalDate.cal }
    private var weekEnd: String { CalDate.addingDays(6, toKey: week) }
    private var isCurrentWeek: Bool { week == Self.weekStart(containing: Date()) }
    private var running: TimeEntry? { entries.first { $0.isRunning } }

    var body: some View {
        VStack(spacing: 0) {
            bar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    tasksSection
                    timeSection
                }
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
            .scrollDismissesKeyboard(.interactively)
        }
        .screenBackground()
        .tint(Theme.Colors.foreground)
        .task(id: week) { await load() }
        .sheet(item: $editingTask) { task in
            RenameSheet(title: "Rename task", text: task.title) { text in
                await rename(task, to: text)
            }
        }
        .sheet(item: $editingEntry) { entry in
            RenameSheet(title: "Rename entry", text: entry.title) { text in
                await rename(entry, to: text)
            }
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: Binding(get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }),
            titleVisibility: .visible,
            presenting: deletingEntry
        ) { entry in
            Button("Delete", role: .destructive) { Task { await remove(entry) } }
            Button("Keep", role: .cancel) {}
        } message: { entry in
            Text(entry.title.isEmpty ? "Untitled" : entry.title)
        }
    }

    // MARK: Chrome

    private var bar: some View {
        TopBar(title: "This week") {
            BarButton(icon: "chevron.left", label: "Back") { dismiss() }
        } trailing: {
            HStack(spacing: 0) {
                BarButton(icon: "chevron.up", label: "Previous week") { step(-1) }
                BarButton(icon: "chevron.down", label: "Next week") { step(1) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isCurrentWeek ? "This week" : Self.rangeLabel(week, weekEnd))
                .font(Theme.Typography.title)
                .tracking(-0.5)
                .foregroundStyle(Theme.Colors.foreground)
            Text(isCurrentWeek ? Self.rangeLabel(week, weekEnd) : "Swipe the bar to come back to now.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func step(_ delta: Int) {
        Haptics.select()
        week = CalDate.addingDays(delta * 7, toKey: week)
    }

    // MARK: Sometime this week

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Sometime this week", trailing: tasks.isEmpty ? nil : "\(tasks.filter { !$0.done }.count) left")

            if tasks.isEmpty && !loading {
                Text("Things that have to happen this week but at no particular hour. Anything unticked rolls into next week.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.bottom, 8)
            }

            ForEach(tasks) { task in
                SwipeRow(
                    trailing: .init(icon: "trash", label: "Delete") { Task { await remove(task) } }
                ) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await toggle(task) }
                        } label: {
                            Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 21))
                                .foregroundStyle(task.done ? Theme.Colors.foreground : Theme.Colors.border)
                                .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(task.done ? "Done, \(task.title)" : "Not done, \(task.title)")

                        Button {
                            editingTask = task
                        } label: {
                            Text(task.title)
                                .font(Theme.Typography.body)
                                .foregroundStyle(task.done ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                                .strikethrough(task.done, color: Theme.Colors.mutedForeground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: Theme.Metrics.minTouchTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Theme.Metrics.hPadding - 4)
                }
                .hairline()
            }

            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 24)
                TextField("Add something for this week…", text: $newTask)
                    .font(Theme.Typography.body)
                    .focused($focus, equals: .task)
                    .submitLabel(.done)
                    .onSubmit { Task { await addTask() } }
                Button("Add") { Task { await addTask() } }
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(newTask.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
            .padding(.vertical, 6)

            if isCurrentWeek {
                Button {
                    Task { await roll() }
                } label: {
                    Text("Pull in unfinished tasks from earlier weeks")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(height: Theme.Metrics.minTouchTarget)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.Metrics.hPadding)
            }
        }
    }

    // MARK: Time

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Time", trailing: entries.isEmpty ? nil : Self.duration(entries.reduce(0) { $0 + $1.elapsed() }))

            if let running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(running.title.isEmpty ? "Untitled" : running.title)
                                .font(Theme.Typography.bodyMedium)
                                .foregroundStyle(Theme.Colors.foreground)
                                .lineLimit(1)
                            Text("Running since \(RelativeTime.long(running.start))")
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.mutedForeground)
                        }
                        Spacer(minLength: 8)
                        Text(Self.duration(running.elapsed(at: context.date)))
                            .font(Theme.Typography.large.monospacedDigit())
                            .foregroundStyle(Theme.Colors.foreground)
                        Button {
                            Task { await stop(running) }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.Colors.background)
                                .frame(width: 36, height: 36)
                                .background(Theme.Colors.foreground)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("Stop timer")
                    }
                    .padding(12)
                    .background(Theme.Colors.muted)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.bottom, 8)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 24)
                TextField(running == nil ? "What are you working on?" : "Start something else…", text: $newTimer)
                    .font(Theme.Typography.body)
                    .focused($focus, equals: .timer)
                    .submitLabel(.go)
                    .onSubmit { Task { await start() } }
                Button("Start") { Task { await start() } }
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(newTimer.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.Colors.mutedForeground : Theme.Colors.foreground)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .disabled(newTimer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
            .padding(.vertical, 6)
            .hairline()

            ForEach(entries.filter { !$0.isRunning }) { entry in
                SwipeRow(
                    trailing: .init(icon: "trash", label: "Delete", resets: true) { deletingEntry = entry }
                ) {
                    Button {
                        editingEntry = entry
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Colors.foreground)
                                    .lineLimit(1)
                                Text(RelativeTime.long(entry.start))
                                    .font(Theme.Typography.small)
                                    .foregroundStyle(Theme.Colors.mutedForeground)
                            }
                            Spacer(minLength: 8)
                            Text(Self.duration(entry.elapsed()))
                                .font(Theme.Typography.body.monospacedDigit())
                                .foregroundStyle(Theme.Colors.mutedForeground)
                        }
                        .padding(.horizontal, Theme.Metrics.hPadding)
                        .frame(minHeight: Theme.Metrics.denseRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableRowStyle())
                }
                .hairline()
            }

            if entries.isEmpty && !loading {
                Text("Nothing timed this week.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: Loading and mutations

    private func load() async {
        loading = true
        defer { loading = false }
        async let taskList = CalendarAPI.flexTasks(week: week)
        async let timeList = CalendarAPI.timeEntries(from: week, to: weekEnd)
        do {
            tasks = try await taskList
            entries = try await timeList
        } catch {
            guard !(error is CancellationError) else { return }
            toasts.error((error as? APIError)?.errorDescription ?? "Could not load this week.")
        }
    }

    private func addTask() async {
        let title = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let task = try await CalendarAPI.createFlexTask(title: title, week: week)
            tasks.append(task)
            newTask = ""
            Haptics.success()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Could not add that.")
        }
    }

    private func toggle(_ task: FlexTask) async {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].done.toggle()
        Haptics.select()
        do {
            tasks[index] = try await CalendarAPI.updateFlexTask(id: task.id, done: !task.done)
        } catch {
            if let again = tasks.firstIndex(where: { $0.id == task.id }) { tasks[again].done = task.done }
            toasts.error((error as? APIError)?.errorDescription ?? "Could not change that.")
        }
    }

    private func rename(_ task: FlexTask, to title: String) async {
        guard !title.isEmpty, title != task.title else { return }
        do {
            let fresh = try await CalendarAPI.updateFlexTask(id: task.id, title: title)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = fresh }
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Could not rename that.")
        }
    }

    private func remove(_ task: FlexTask) async {
        let index = tasks.firstIndex { $0.id == task.id }
        withAnimation(Theme.Motion.rowExit) { tasks.removeAll { $0.id == task.id } }
        do {
            try await CalendarAPI.deleteFlexTask(id: task.id)
        } catch {
            if let index { withAnimation(Theme.Motion.rowExit) { tasks.insert(task, at: min(index, tasks.count)) } }
            toasts.error((error as? APIError)?.errorDescription ?? "Could not delete that.")
        }
    }

    private func roll() async {
        do {
            let result = try await CalendarAPI.rollFlexTasks(into: week)
            tasks = result.tasks
            Haptics.select()
            toasts.show(result.moved == 0 ? "Nothing left over from earlier weeks" : "Pulled in \(result.moved) task\(result.moved == 1 ? "" : "s")")
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Could not pull those in.")
        }
    }

    private func start() async {
        let title = newTimer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let entry = try await CalendarAPI.startTimer(title: title)
            // The worker stopped whatever was running; reload so its end time is right.
            newTimer = ""
            Haptics.success()
            await load()
            if !entries.contains(where: { $0.id == entry.id }) { entries.insert(entry, at: 0) }
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Could not start that.")
        }
    }

    private func stop(_ entry: TimeEntry) async {
        do {
            let fresh = try await CalendarAPI.stopTimer(id: entry.id)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = fresh }
            Haptics.select()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Could not stop that.")
        }
    }

    private func rename(_ entry: TimeEntry, to title: String) async {
        guard title != entry.title else { return }
        do {
            let fresh = try await CalendarAPI.updateTimeEntry(id: entry.id, title: title)
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = fresh }
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? "Could not rename that.")
        }
    }

    private func remove(_ entry: TimeEntry) async {
        let index = entries.firstIndex { $0.id == entry.id }
        withAnimation(Theme.Motion.rowExit) { entries.removeAll { $0.id == entry.id } }
        do {
            try await CalendarAPI.deleteTimeEntry(id: entry.id)
        } catch {
            if let index { withAnimation(Theme.Motion.rowExit) { entries.insert(entry, at: min(index, entries.count)) } }
            toasts.error((error as? APIError)?.errorDescription ?? "Could not delete that.")
        }
    }

    // MARK: Helpers

    /// The `yyyy-MM-dd` of the first day of the week `date` falls in, on the owner's
    /// week-start day, which is what the worker keys flex tasks by.
    static func weekStart(containing date: Date) -> String {
        let cal = CalDate.cal
        let start = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return CalDate.key(start, in: cal)
    }

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    static func rangeLabel(_ from: String, _ to: String) -> String {
        guard let a = CalDate.date(fromKey: from), let b = CalDate.date(fromKey: to) else { return from }
        return "\(dayMonth.string(from: a)) – \(dayMonth.string(from: b))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// One line, one Save: shared by the task and the time entry.
private struct RenameSheet: View {
    let title: String
    let text: String
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var focused: Bool

    init(title: String, text: String, onSave: @escaping (String) async -> Void) {
        self.title = title
        self.text = text
        self.onSave = onSave
        _draft = State(initialValue: text)
    }

    var body: some View {
        VStack(spacing: 12) {
            ThreadSheetHeader(title: title)
            TextField("Title", text: $draft)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { commit() }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Theme.Colors.muted)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            Button("Save") { commit() }
                .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 16)
        .screenBackground()
        .presentationDetents([.height(220)])
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            focused = true
        }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task { await onSave(value) }
        dismiss()
    }
}
