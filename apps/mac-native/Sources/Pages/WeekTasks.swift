import SwiftUI

/// `WeekTasks.tsx`: "Sometime this week" — the things that have to happen but not at any
/// particular hour. Anything still unticked when the week turns rolls forward, so the list is
/// a standing promise. Every week row in the stack has its own strip.
struct WeekTasksView: View {
    let weekStart: String
    @State private var tasks: [FlexTask] = []
    @State private var draft = ""
    @State private var adding = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Text("SOMETIME THIS WEEK:").font(W.font(10.5)).tracking(1.155).foregroundStyle(W.tertiary).fixedSize()
                ForEach(tasks) { t in
                    TaskPill(task: t, onToggle: { update(t, done: !t.done) }, onRemove: { remove(t) })
                }
                if adding {
                    ZStack(alignment: .leading) {
                        if draft.isEmpty { Text("Oil change, call the bank…").font(W.font(11)).foregroundStyle(W.tertiary).padding(.horizontal, 8) }
                        TextField("", text: $draft)
                            .textFieldStyle(.plain)
                            .font(W.font(11)).foregroundStyle(W.foreground)
                            .focused($focused)
                            .onSubmit { submit() }
                            .onKeys(["Escape": { draft = ""; adding = false }], priority: 10, whileTyping: true)
                            .onChange(of: focused) { was, now in if was && !now && adding { submit() } }
                            .padding(.horizontal, 8)
                    }
                    .frame(width: 208, height: 20)
                    .overlay(Capsule().strokeBorder(focused ? W.foreground.opacity(0.3) : W.border, lineWidth: 1))
                    .onAppear { focused = true }
                } else {
                    AddDot { adding = true }
                }
            }
            .padding(.horizontal, 4)
            .frame(height: WeekGeom.tasks)
        }
        .scrollIndicators(.never)
        .frame(height: WeekGeom.tasks)
        .task(id: weekStart) { await load() }
        .onChange(of: CalendarBus.shared.revision) { _, _ in Task { await load() } }
    }

    private func load() async {
        if let list = try? await CalendarAPI.flexTasks(week: weekStart) { tasks = list }
    }

    private func submit() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        adding = false
        guard !title.isEmpty else { return }
        Task {
            do { _ = try await CalendarAPI.createFlexTask(title: title, week: weekStart); await load() }
            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    private func update(_ t: FlexTask, done: Bool) {
        Task {
            do { _ = try await CalendarAPI.updateFlexTask(id: t.id, done: done); await load() }
            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    private func remove(_ t: FlexTask) {
        Task {
            do { try await CalendarAPI.deleteFlexTask(id: t.id); await load() }
            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
}

/// `rounded-full border border-border py-[2px] pl-[3px] pr-1.5 text-[11px]`: a round box
/// ticked the way todos are everywhere else, the title, and a ✕ that shows on hover.
private struct TaskPill: View {
    let task: FlexTask
    var onToggle: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false
    @State private var hoverBox = false
    @State private var hoverX = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                ZStack {
                    Circle().fill(task.done ? W.foreground : Color.clear)
                    Circle().strokeBorder(task.done ? W.foreground : (hoverBox ? W.foreground.opacity(0.5) : W.border), lineWidth: 1)
                    Icon("check", size: 9, strokeWidth: 3).foregroundStyle(task.done ? W.background : Color.clear)
                }
                .frame(width: 13, height: 13)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoverBox = $0 }
            .help(task.done ? "Not done" : "Done")
            Text(task.title).font(W.font(11)).webLine(11, 11).strikethrough(task.done).truncate().frame(maxWidth: 192)
            Button(action: onRemove) {
                Icon("x", size: 10).foregroundStyle(hoverX ? W.foreground : (hovering ? W.tertiary : Color.clear)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverX = $0 }
            .help("Remove")
        }
        .foregroundStyle(task.done ? W.mutedForeground : W.foreground)
        .padding(.leading, 4).padding(.trailing, 7).padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(W.border, lineWidth: 1))
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// The dashed `+` that becomes the input.
private struct AddDot: View {
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Icon("plus", size: 10)
                .foregroundStyle(hovering ? W.foreground : W.tertiary)
                .frame(width: 17, height: 17)
                .overlay(Circle().strokeBorder(hovering ? W.foreground.opacity(0.3) : W.border, style: StrokeStyle(lineWidth: 1, dash: [3])))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add something for this week")
    }
}
