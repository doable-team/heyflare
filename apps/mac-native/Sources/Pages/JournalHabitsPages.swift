import SwiftUI
import AppKit

// MARK: - Shared bits

/// The small header both pages use: `text-[15px] font-semibold tracking-[-0.01em]`, a 12px
/// muted line under it, `pb-3 mb-1 border-b`.
private struct SmallHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(W.font(15, 600)).tracking(-0.15).foregroundStyle(W.foreground).webLine(15, weight: 600)
                Text(subtitle).font(W.font(12)).foregroundStyle(W.mutedForeground).webLine(12).padding(.top, 2)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, 12)
        .edgeLine(.bottom)
        .padding(.bottom, 4)
    }
}

extension SmallHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) { self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }) }
}

/// "Monday, 8 September 2026": `longDayLabel` in caldate.ts.
private func longDayLabel(_ key: String) -> String {
    guard let d = CalDate.date(fromKey: key) else { return key }
    let f = DateFormatter(); f.calendar = CalDate.cal; f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE, d MMMM yyyy"
    return f.string(from: d)
}

/// "Today" / "Tomorrow" / "Yesterday", else nothing.
private func relativeDay(_ key: String) -> String? {
    guard let d = CalDate.date(fromKey: key) else { return nil }
    return CalDate.relativeDay(d)
}

@MainActor private func fail(_ error: Error) {
    Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
}

private let HEX = try! NSRegularExpression(pattern: "^#[0-9a-fA-F]{6}$")

/// `ColorPicker` in Habits.tsx: the label shades, then a hex field.
private struct HabitColorPicker: View {
    let id: String
    let value: String
    var onPick: (String) -> Void
    @Environment(PopLayerState.self) private var pops
    @State private var hex = ""

    private var valid: Bool { HEX.firstMatch(in: hex.trimmingCharacters(in: .whitespaces), range: NSRange(location: 0, length: hex.trimmingCharacters(in: .whitespaces).utf16.count)) != nil }

    var body: some View {
        Button {
            hex = value
            pops.toggle(id, side: .bottom, align: .start) {
                PopCard(padding: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        // `flex-wrap gap-1.5 max-w-[184px]`: six 24pt swatches to a row.
                        let rows = stride(from: 0, to: labelShades.count, by: 6).map { Array(labelShades[$0..<min($0 + 6, labelShades.count)]) }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 6) {
                                    ForEach(row, id: \.self) { c in
                                        Button { onPick(c); pops.closeAll() } label: {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(colorFromHex(c))
                                                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(W.foreground.opacity(0.15), lineWidth: 1)
                                                if value.lowercased() == c.lowercased() { Icon("check", size: 12, strokeWidth: 3).foregroundStyle(.white).blendMode(.difference) }
                                            }
                                            .frame(width: 24, height: 24)
                                            .overlay { if value.lowercased() == c.lowercased() { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(W.foreground, lineWidth: 2).padding(-3) } }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        HStack(spacing: 6) {
                            WTextField(placeholder: "#37352f", text: $hex, mono: true, height: 24, fontSize: 12, onSubmit: { use() }).frame(width: 96)
                            WButton("Use", size: .xs) { use() }.disabled(!valid)
                        }
                        .padding(.top, 8).edgeLine(.top).padding(.top, 8)
                    }
                }
            }
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(colorFromHex(value))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.15), lineWidth: 1))
                .frame(width: 14, height: 14)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popAnchor(id)
        .help("Colour")
    }

    private func use() {
        guard valid else { return }
        onPick(hex.trimmingCharacters(in: .whitespaces).lowercased()); pops.closeAll()
    }
}

// MARK: - Habits

private let habitWeeks = 12
private let habitSpan = habitWeeks * 7
private let weekdays: [(d: Int, short: String, long: String)] = [(0, "S", "Sunday"), (1, "M", "Monday"), (2, "T", "Tuesday"), (3, "W", "Wednesday"), (4, "T", "Thursday"), (5, "F", "Friday"), (6, "S", "Saturday")]

@MainActor
@Observable
private final class HabitsStore {
    var habits: [CalHabit] = []
    var loading = true
    var error: String?
    let to = CalDate.todayKey
    var from: String { CalDate.addingDays(-(habitSpan - 1), toKey: to) }

    func load() async {
        do { habits = try await CalendarAPI.habits(from: from, to: to); error = nil }
        catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
        loading = false
    }

    func replace(_ h: CalHabit) { if let i = habits.firstIndex(where: { $0.id == h.id }) { habits[i] = h } }

    /// Optimistic, as the web's mutation is: the square flips at once, the answer settles it.
    func toggle(_ id: String, date: String) {
        guard let i = habits.firstIndex(where: { $0.id == id }) else { return }
        if let j = habits[i].completions.firstIndex(of: date) { habits[i].completions.remove(at: j) } else { habits[i].completions.append(date) }
        Task {
            do { replace(try await CalendarAPI.toggleHabit(id: id, date: date, from: from, to: to)) }
            catch { fail(error); await load() }
        }
    }
}

/// `Habits.tsx`: the last twelve weeks, a square a day.
struct HabitsPage: View {
    @Environment(UIState.self) private var ui
    @State private var store = HabitsStore()
    @State private var name = ""
    @State private var color = labelShades[0]
    @State private var cursor = -1
    @State private var creating = false
    @State private var width: CGFloat = 768

    private var list: [CalHabit] { store.habits.filter { !$0.archived } }
    private var days: [String] { (0..<habitSpan).map { CalDate.addingDays($0, toKey: store.from) } }

    var body: some View {
        let list = list
        let days = days
        VStack(alignment: .leading, spacing: 0) {
            SmallHeader(title: "Habits", subtitle: "The last \(habitWeeks) weeks, a square a day. Click one to tick it off.")
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            else if store.loading { SkeletonRows(rows: 4) }
            else if list.isEmpty { EmptyStateView(icon: "flame", title: "No habits yet.", body: "Name one below. Pick the days you mean to do it, then keep the row filled in.") }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, h in
                HabitRow(habit: h, days: days, focused: cursor == i, store: store, width: width)
            }
            HStack(spacing: 8) {
                HabitColorPicker(id: "new-habit-color", value: color) { color = $0 }
                TextField("Add habit…", text: $name).textFieldStyle(.plain).font(W.font(13)).foregroundStyle(W.foreground).onSubmit { create() }
                WButton("Add", icon: "plus", variant: .ghost, size: .sm, muted: true) { create() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
            .padding(.horizontal, 8).frame(height: 44)
        }
        .frame(maxWidth: 768)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        // The row splits 46% / the rest (`lg:w-[46%]`), so it needs to know how wide it is.
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width - 8 }.onChange(of: g.size.width) { _, w in width = w - 8 } })
        .task { await store.load() }
        .onChange(of: CalendarBus.shared.revision) { _, _ in Task { await store.load() } }
        // `useItemCursor`: Enter on the focused row ticks today off.
        .onKeys([
            "j": { cursor = min(cursor + 1, list.count - 1) }, "k": { cursor = max(cursor - 1, 0) },
            "ArrowDown": { cursor = min(cursor + 1, list.count - 1) }, "ArrowUp": { cursor = max(cursor - 1, 0) },
            "Enter": { if list.indices.contains(cursor) { store.toggle(list[cursor].id, date: store.to) } },
        ], enabled: ui.region == .content && !list.isEmpty)
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !creating else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                let h = try await CalendarAPI.createHabit(name: n, icon: "", days: [0, 1, 2, 3, 4, 5, 6], color: color)
                store.habits.append(h)
                name = ""; color = labelShades[(list.count + 1) % labelShades.count]
            } catch { fail(error) }
        }
    }
}

/// `HabitRow`: icon, name, the seven weekday toggles, colour, delete, then the grid.
private struct HabitRow: View {
    let habit: CalHabit
    let days: [String]
    var focused = false
    let store: HabitsStore
    /// The row's width, less its own padding.
    var width: CGFloat = 768
    @Environment(DialogState.self) private var dialogs
    @State private var name = ""
    @State private var editingName = false
    @State private var icon = ""
    @State private var editingIcon = false
    @FocusState private var nameFocused: Bool
    @FocusState private var iconFocused: Bool

    private var scheduled: [Int] { habit.expectedDays }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 8) {
                if editingIcon {
                    TextField("", text: $icon).textFieldStyle(.plain).font(W.font(13)).multilineTextAlignment(.center)
                        .frame(width: 24, height: 24).background(W.muted).rounded(4)
                        .focused($iconFocused)
                        .onSubmit { saveIcon() }
                        .onChange(of: iconFocused) { _, f in if !f && editingIcon { saveIcon() } }
                        .onKeys(["Escape": { icon = habit.icon; editingIcon = false }], priority: 10, whileTyping: true)
                        .onAppear { iconFocused = true }
                } else {
                    Button { icon = habit.icon; editingIcon = true } label: {
                        Group {
                            if habit.icon.isEmpty { Text(String(habit.name.prefix(1)).uppercased()).font(W.font(11)).foregroundStyle(W.tertiary) }
                            else { Text(habit.icon).font(W.font(13)) }
                        }
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Change the icon for \(habit.name)")
                }
                if editingName {
                    TextField("", text: $name).textFieldStyle(.plain).font(W.font(13, 500)).foregroundStyle(W.foreground)
                        .focused($nameFocused)
                        .onSubmit { saveName() }
                        .onChange(of: nameFocused) { _, f in if !f && editingName { saveName() } }
                        .onKeys(["Escape": { name = habit.name; editingName = false }], priority: 10, whileTyping: true)
                        .onAppear { nameFocused = true }
                } else {
                    Button { name = habit.name; editingName = true } label: {
                        Text(habit.name).font(W.font(13, 500)).foregroundStyle(W.foreground).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 1) {
                    ForEach(weekdays, id: \.d) { w in
                        let on = scheduled.contains(w.d)
                        Button { toggleDay(w.d) } label: {
                            Text(w.short).font(W.font(9.5)).foregroundStyle(on ? W.primaryForeground : W.tertiary)
                                .frame(width: 18, height: 18).background(on ? W.foreground : Color.clear).rounded(3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(w.long)
                    }
                }
                HabitColorPicker(id: "habit-color-\(habit.id)", value: habit.color.isEmpty ? "#37352f" : habit.color) { c in
                    Task { do { store.replace(try await CalendarAPI.updateHabit(id: habit.id, color: c)) } catch { fail(error) } }
                }
                WButton(icon: "trash2", variant: .ghost, size: .iconXs, muted: true, help: "Delete \(habit.name)") {
                    dialogs.confirm("delete-habit-\(habit.id)", title: "Delete “\(habit.name)”?", description: "Every tick you've ever made on it goes too. There's no undo.", cancel: "Keep it", action: "Delete habit") {
                        Task {
                            do { try await CalendarAPI.deleteHabit(id: habit.id); store.habits.removeAll { $0.id == habit.id } } catch { fail(error) }
                        }
                    }
                }
            }
            .frame(width: max(0, (width - 16) * 0.46))
            HabitGrid(habit: habit, days: days) { store.toggle(habit.id, date: $0) }
                .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 12).padding(.horizontal, 8)
        .background(focused ? W.muted : Color.clear)
        .overlay(alignment: .leading) { if focused { RoundedRectangle(cornerRadius: 1).fill(W.foreground).frame(width: 2).padding(.vertical, 12) } }
        .edgeLine(.bottom)
        .onAppear { name = habit.name; icon = habit.icon }
    }

    private func saveName() {
        editingName = false
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { name = habit.name; return }
        guard n != habit.name else { return }
        Task { do { store.replace(try await CalendarAPI.updateHabit(id: habit.id, name: n)) } catch { fail(error) } }
    }

    /// One grapheme: an emoji can be several code points.
    private func saveIcon() {
        editingIcon = false
        let g = icon.trimmingCharacters(in: .whitespaces).first.map { String($0).prefix(16) }.map(String.init) ?? ""
        icon = g
        guard g != habit.icon else { return }
        Task { do { store.replace(try await CalendarAPI.updateHabit(id: habit.id, icon: g)) } catch { fail(error) } }
    }

    private func toggleDay(_ d: Int) {
        let next = scheduled.contains(d) ? scheduled.filter { $0 != d } : (scheduled + [d]).sorted()
        // The server reads an empty list as "no change", so a habit always keeps one day.
        guard !next.isEmpty else { return }
        Task { do { store.replace(try await CalendarAPI.updateHabit(id: habit.id, days: next)) } catch { fail(error) } }
    }
}

/// `Grid`: the streak line, then twelve weeks of 10pt squares, today at the right-hand end.
private struct HabitGrid: View {
    let habit: CalHabit
    let days: [String]
    var onToggle: (String) -> Void

    var body: some View {
        let done = Set(habit.completions)
        let scheduled = Set(habit.expectedDays)
        let count = days.filter { done.contains($0) }.count
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                HStack(spacing: 4) { Icon("flame", size: 11); Text("\(habit.streak) day\(habit.streak == 1 ? "" : "s")") }
                Text("\(count) in \(habitWeeks) weeks")
            }
            .font(W.font(11)).monospacedDigit().foregroundStyle(W.tertiary)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(days, id: \.self) { d in
                            let isDone = done.has(d)
                            let isFor = scheduled.contains(weekday(d))
                            Button { onToggle(d) } label: {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(isDone ? colorFromHex(habit.color.isEmpty ? "#37352f" : habit.color) : Color.clear)
                                    .overlay { if !isDone && isFor { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(W.border, lineWidth: 1) } }
                                    .frame(width: 10, height: 10)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(longDayLabel(d))\(isDone ? " · done" : isFor ? " · missed" : "")")
                            .id(d)
                        }
                    }
                    .padding(.horizontal, 4).padding(.bottom, 4)
                }
                .scrollIndicators(.never)
                .frame(height: 14)
                .padding(.horizontal, -4)
                .onAppear { if let last = days.last { proxy.scrollTo(last, anchor: .trailing) } }
            }
        }
    }

    private func weekday(_ key: String) -> Int {
        guard let d = CalDate.date(fromKey: key) else { return -1 }
        return CalDate.cal.component(.weekday, from: d) - 1
    }
}

private extension Set where Element == String {
    func has(_ s: String) -> Bool { contains(s) }
}

// MARK: - Journal index

@MainActor
@Observable
private final class JournalIndexStore {
    var days: [CalDay] = []
    var loading = true
    var error: String?
    func load() async {
        do { days = try await CalendarAPI.journalIndex(); error = nil }
        catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
        loading = false
    }
}

/// `JournalIndex`: every day with an entry, newest first.
struct JournalIndexPage: View {
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @State private var store = JournalIndexStore()
    @State private var cursor = -1

    var body: some View {
        let list = store.days
        let today = CalDate.todayKey
        VStack(alignment: .leading, spacing: 0) {
            SmallHeader(title: "Journal", subtitle: "One entry a day. Nobody reads it but you.") {
                WButton("Today", icon: "notebookPen", variant: .ghost, size: .sm, muted: true) { router.go(.journal(today)) }
            }
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            else if store.loading { SkeletonRows(rows: 5, compact: true) }
            else if list.isEmpty {
                EmptyStateView(icon: "notebookPen", title: "Nothing written down yet.", body: "A line about the day is enough. It'll sit beside that day in the calendar forever.") {
                    WButton("Write today's", variant: .outline, size: .sm) { router.go(.journal(today)) }
                }
            }
            ForEach(Array(list.enumerated()), id: \.element.date) { i, e in
                JournalIndexRow(day: e, focused: cursor == i) { router.go(.journal(e.date)) }
            }
        }
        .frame(maxWidth: 672)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .task { await store.load() }
        .onKeys([
            "j": { cursor = min(cursor + 1, list.count - 1) }, "k": { cursor = max(cursor - 1, 0) },
            "ArrowDown": { cursor = min(cursor + 1, list.count - 1) }, "ArrowUp": { cursor = max(cursor - 1, 0) },
            "Enter": { if list.indices.contains(cursor) { router.go(.journal(list[cursor].date)) } },
        ], enabled: ui.region == .content && !list.isEmpty)
    }
}

private struct JournalIndexRow: View {
    let day: CalDay
    var focused = false
    var onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(longDayLabel(day.date)).font(W.font(13, 500)).foregroundStyle(W.foreground)
                    if !day.label.isEmpty { Text(day.label).font(W.font(12)).foregroundStyle(W.mutedForeground).lineLimit(1) }
                    Spacer(minLength: 0)
                    if let rel = relativeDay(day.date) { Text(rel).font(W.font(11)).foregroundStyle(W.tertiary) }
                }
                if let excerpt = day.excerpt, !excerpt.isEmpty {
                    Text(excerpt).font(W.font(12.5)).webLine(12.5, 12.5 * 1.55).foregroundStyle(W.mutedForeground).lineLimit(2).padding(.top, 4)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? W.muted : (hovering ? W.muted60 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .edgeLine(.bottom)
    }
}

// MARK: - Journal entry

/// `JournalEntry`: one day's page, autosaved as it is written.
struct JournalEntryPage: View {
    let date: String
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @State private var day: CalDay?
    @State private var index: [String] = []
    @State private var error: String?
    @State private var loading = true
    @State private var editor = RichTextController()
    @State private var editorHeight: CGFloat = 200
    @State private var dirty = false
    @State private var saveTask: Task<Void, Never>?
    @State private var status = ""
    @State private var statusOn = false
    @State private var statusFade: Task<Void, Never>?
    @State private var bar: CGRect?
    @State private var marks: (bold: Bool, italic: Bool, heading: Bool) = (false, false, false)
    @State private var linkOpen = false
    @State private var linkURL = ""

    private var older: String? { index.filter { $0 < date }.max() }
    private var newer: String? { index.filter { $0 > date }.min() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error { ErrorStateView(message: error) { Task { await load() } } }
            else if loading { SkeletonRows(rows: 4, compact: true) }
            ZStack(alignment: .topLeading) {
                RichTextEditor(controller: editor, height: $editorHeight, placeholder: "How did it go?", autoFocus: true, onEdit: { markDirty() })
                    .frame(height: max(editorHeight, ui.viewportHeight * 0.55))
                if let bar { toolbar(at: bar) }
            }
            .opacity(loading ? 0 : 1)
        }
        .frame(maxWidth: 672)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.bottom, 96)
        .task { await load() }
        .onDisappear { saveTask?.cancel(); Task { await flush() } }
        .onAppear {
            editor.fontSize = 13
            editor.lineHeightMultiple = 1.7 / 1.2
            editor.onSelection = { rect in
                guard !linkOpen else { return }
                bar = rect
                marks = editor.marks()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            WButton(icon: "chevronLeft", variant: .ghost, size: .iconXs, muted: true, help: "Previous entry") { if let older { router.go(.journal(older)) } }.opacity(older == nil ? 0 : 1)
            WButton(icon: "chevronRight", variant: .ghost, size: .iconXs, muted: true, help: "Next entry") { if let newer { router.go(.journal(newer)) } }.opacity(newer == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(longDayLabel(date)).font(W.font(15, 600)).tracking(-0.15).foregroundStyle(W.foreground).lineLimit(1)
                    if let rel = relativeDay(date) { Text(rel).font(W.font(12)).foregroundStyle(W.mutedForeground) }
                }
                Text(day?.label.isEmpty == false ? day!.label : "Whatever's worth remembering.").font(W.font(12)).foregroundStyle(W.mutedForeground).lineLimit(1).padding(.top, 2)
            }
            .padding(.leading, 4)
            Spacer(minLength: 0)
            Text(status.isEmpty ? "Saved" : status).font(W.font(11)).monospacedDigit().foregroundStyle(W.tertiary)
                .opacity(statusOn ? 1 : 0).animation(.easeOut(duration: 0.7), value: statusOn).padding(.trailing, 4)
            WButton("In the calendar", icon: "calendarDays", variant: .ghost, size: .sm, muted: true) { router.go(.calendar) }
        }
        .padding(.bottom, 12)
        .edgeLine(.bottom)
        .padding(.bottom, 16)
    }

    /// The floating bar over a selection: `top - 38`, centred on it, kept 90pt off each edge.
    @ViewBuilder
    private func toolbar(at rect: CGRect) -> some View {
        GeometryReader { g in
            let x = min(max(rect.midX, 90), max(g.size.width - 90, 90))
            HStack(spacing: 2) {
                if linkOpen {
                    WTextField(placeholder: "https://", text: $linkURL, height: 24, fontSize: 12, onSubmit: { applyLink() }, autofocus: true).frame(width: 192)
                        .onKeys(["Escape": { linkOpen = false }], priority: 10, whileTyping: true)
                    WButton("Link", size: .xs) { applyLink() }.disabled(linkURL.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    tool("bold", "Bold", active: marks.bold) { editor.toggleBold(); after() }
                    tool("italic", "Italic", active: marks.italic) { editor.toggleItalic(); after() }
                    tool("heading2", "Heading", active: marks.heading) { editor.toggleHeading(); after() }
                    tool("list", "Bulleted list") { editor.bulletList(); after() }
                    tool("link2", "Link") { linkURL = ""; linkOpen = true }
                    tool("removeFormatting", "Clear formatting") { editor.clearFormatting(); after() }
                }
            }
            .padding(4)
            .background(W.background)
            .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1))
            .rounded(W.radiusMd)
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .fixedSize()
            .alignmentGuide(.leading) { d in d.width / 2 - x }
            .offset(y: rect.minY - 38)
        }
    }

    private func tool(_ icon: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(icon, size: 13).foregroundStyle(active ? W.foreground : W.mutedForeground)
                .frame(width: 24, height: 24).background(active ? W.muted : Color.clear).rounded(4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label)
    }

    private func after() { marks = editor.marks(); markDirty() }

    private func applyLink() {
        let url = linkURL.trimmingCharacters(in: .whitespaces)
        linkOpen = false
        guard !url.isEmpty else { return }
        editor.insertLink(url)
        markDirty()
    }

    private func load() async {
        loading = true
        async let entry = CalendarAPI.journal(date: date)
        async let all = CalendarAPI.journalIndex()
        do {
            let d = try await entry
            day = d
            editor.setHTML(d.journalHTML ?? "")
            dirty = false
            error = nil
        } catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
        index = ((try? await all) ?? []).map(\.date)
        loading = false
    }

    /// Debounced autosave, 900 ms after the last keystroke.
    private func markDirty() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    private func flush() async {
        guard dirty, !loading else { return }
        let html = editor.html()
        dirty = false
        show("Saving…", fade: false)
        do {
            day = try await CalendarAPI.saveJournal(date: date, html: html)
            show("Saved", fade: true)
            CalendarBus.shared.changed()
        } catch {
            dirty = true
            show((error as? APIError)?.errorDescription ?? "Couldn't save", fade: false)
        }
    }

    private func show(_ text: String, fade: Bool) {
        status = text; statusOn = true
        statusFade?.cancel()
        if fade { statusFade = Task { try? await Task.sleep(for: .seconds(2.4)); if !Task.isCancelled { statusOn = false } } }
    }
}
