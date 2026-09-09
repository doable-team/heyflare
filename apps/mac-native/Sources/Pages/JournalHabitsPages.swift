import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

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
    @State private var hovering = false

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
                            // `text-destructive` when non-empty and invalid: the web's
                            // `--destructive` is the foreground colour in both themes, which is
                            // what the field already draws, so there is nothing more to show.
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
                .frame(width: 24, height: 24).background(hovering ? W.muted : Color.clear).rounded(4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popAnchor(id)
        .onHover { hovering = $0 }
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
    @State private var viewport: CGFloat = 1200

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
                // `lg:flex-row`: the row only splits side by side from a 1024 viewport up.
                HabitRow(habit: h, days: days, focused: cursor == i, store: store, width: width, stacked: viewport < 1024).id(h.id)
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
        .viewportWidth($viewport)
        .task { await store.load() }
        .onChange(of: CalendarBus.shared.revision) { _, _ in Task { await store.load() } }
        // `useItemCursor`: Enter or `o` on the focused row ticks today off.
        .itemCursorKeys(ids: list.map(\.id), cursor: $cursor) { i in store.toggle(list[i].id, date: store.to) }
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
    /// Below the `lg` breakpoint the controls sit above the grid rather than beside it.
    var stacked = false
    @Environment(DialogState.self) private var dialogs
    @State private var name = ""
    @State private var editingName = false
    @State private var icon = ""
    @State private var editingIcon = false
    @State private var iconHover = false
    @FocusState private var nameFocused: Bool
    @FocusState private var iconFocused: Bool

    private var scheduled: [Int] { habit.expectedDays }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 10) {
                    controls.frame(maxWidth: .infinity)
                    HabitGrid(habit: habit, days: days) { store.toggle(habit.id, date: $0) }.frame(maxWidth: .infinity)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    controls.frame(width: max(0, (width - 16) * 0.46))
                    HabitGrid(habit: habit, days: days) { store.toggle(habit.id, date: $0) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 12).padding(.horizontal, 8)
        .background(focused ? W.muted : Color.clear)
        .overlay(alignment: .leading) { if focused { RoundedRectangle(cornerRadius: 1).fill(W.foreground).frame(width: 2).padding(.vertical, 12) } }
        .edgeLine(.bottom)
        .onAppear { name = habit.name; icon = habit.icon }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if editingIcon {
                TextField("", text: $icon).textFieldStyle(.plain).font(W.font(13)).multilineTextAlignment(.center)
                    .frame(width: 24, height: 24).background(W.muted).rounded(4)
                    .focused($iconFocused)
                    .onSubmit { saveIcon() }
                    .onChange(of: iconFocused) { _, f in if !f && editingIcon { saveIcon() } }
                    // `maxLength={16}`.
                    .onChange(of: icon) { _, v in if v.count > 16 { icon = String(v.prefix(16)) } }
                    .onKeys(["Escape": { icon = habit.icon; editingIcon = false }], priority: 10, whileTyping: true)
                    .onAppear { iconFocused = true }
            } else {
                Button { icon = habit.icon; editingIcon = true } label: {
                    Group {
                        if habit.icon.isEmpty { Text(String(habit.name.prefix(1)).uppercased()).font(W.font(11)).foregroundStyle(W.tertiary) }
                        else { Text(habit.icon).font(W.font(13)) }
                    }
                    .frame(width: 24, height: 24).background(iconHover ? W.muted : Color.clear).rounded(4).contentShape(Rectangle())
                }
                .buttonStyle(.plain).onHover { iconHover = $0 }.help("Change the icon for \(habit.name)")
            }
            if editingName {
                TextField("", text: $name).textFieldStyle(.plain).font(W.font(13, 500)).foregroundStyle(W.foreground)
                    .focused($nameFocused)
                    .onSubmit { saveName() }
                    .onChange(of: nameFocused) { _, f in if !f && editingName { saveName() } }
                    .onKeys(["Escape": { name = habit.name; editingName = false }], priority: 10, whileTyping: true)
                    .onAppear { nameFocused = true }
            } else {
                // `hover:text-foreground` on a name that is already foreground: no change to draw.
                Button { name = habit.name; editingName = true } label: {
                    Text(habit.name).font(W.font(13, 500)).foregroundStyle(W.foreground).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 1) {
                ForEach(weekdays, id: \.d) { w in
                    WeekdayToggle(short: w.short, long: w.long, on: scheduled.contains(w.d)) { toggleDay(w.d) }
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

/// One of the seven `size-[18px]` weekday buttons: filled when expected, `hover:bg-muted` when not.
private struct WeekdayToggle: View {
    let short: String
    let long: String
    let on: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(short).font(W.font(9.5)).foregroundStyle(on ? W.primaryForeground : W.tertiary)
                .frame(width: 18, height: 18).background(on ? W.foreground : (hovering ? W.muted : Color.clear)).rounded(3).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help(long)
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
                            HabitSquare(color: colorFromHex(habit.color.isEmpty ? "#37352f" : habit.color), isDone: isDone, isFor: isFor) { onToggle(d) }
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

/// One `size-[10px]` square: done is filled; expected-but-missed is bordered and darkens its
/// border on hover (`hover:border-foreground/40`); an off day washes on hover (`hover:bg-muted`).
private struct HabitSquare: View {
    let color: Color
    let isDone: Bool
    let isFor: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isDone ? color : (!isFor && hovering ? W.muted : Color.clear))
                .overlay { if !isDone && isFor { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(hovering ? W.foreground.opacity(0.4) : W.border, lineWidth: 1) } }
                .frame(width: 10, height: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                JournalIndexRow(day: e, focused: cursor == i) { router.go(.journal(e.date)) }.id(e.date)
            }
        }
        .frame(maxWidth: 672)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .task { await store.load() }
        .itemCursorKeys(ids: list.map(\.date), cursor: $cursor) { i in router.go(.journal(list[i].date)) }
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

// MARK: - Journal HTML

extension NSAttributedString.Key {
    /// The block an entry paragraph came from ("h1", "h2", "h3", "blockquote"), so the round
    /// trip through the text view can put it back.
    static let journalBlock = NSAttributedString.Key("heyflare.journal.block")
    /// An inline `<code>` run.
    static let journalCode = NSAttributedString.Key("heyflare.journal.code")
    /// The `src` an `<img>` arrived with (a data: URI), written back out verbatim.
    static let journalImageSrc = NSAttributedString.Key("heyflare.journal.imageSrc")
}

/// The journal's HTML, in and out. `sanitize` is the DOMPurify allowlist from Journal.tsx as a
/// string pass; `attributed` and `html` are the text view's round trip, which keeps headings,
/// quotes, real `<ul>`/`<ol>` lists, inline code, `<pre>`, links and data-URI images.
enum JournalHTML {
    static let allowedTags: Set<String> = ["p", "div", "br", "hr", "h1", "h2", "h3", "strong", "b", "em", "i", "u", "s", "strike", "ul", "ol", "li", "a", "blockquote", "code", "pre", "img", "span"]
    static let allowedAttrs: Set<String> = ["href", "target", "rel", "src", "alt", "title"]
    /// DOMPurify's `FORBID_CONTENTS`: elements whose content goes with them.
    private static let dropWithContent: Set<String> = ["annotation-xml", "audio", "colgroup", "desc", "foreignobject", "head", "iframe", "math", "mi", "mn", "mo", "ms", "mtext", "noembed", "noframes", "noscript", "plaintext", "script", "style", "svg", "template", "thead", "title", "video", "xmp"]
    private static let voidTags: Set<String> = ["br", "hr", "img"]
    private static let safeSchemes: Set<String> = ["ftp", "ftps", "http", "https", "mailto", "tel", "callto", "sms", "cid", "xmpp", "matrix"]

    private static let tagRegex = try! NSRegularExpression(pattern: "<\\s*(/?)\\s*([a-zA-Z][a-zA-Z0-9-]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>", options: [])
    private static let attrRegex = try! NSRegularExpression(pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+)))?", options: [])
    private static let commentRegex = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->|<![^>]*>|<\\?[\\s\\S]*?\\?>", options: [])
    private static let imgRegex = try! NSRegularExpression(pattern: "<img\\b((?:[^>\"']|\"[^\"]*\"|'[^']*')*)>", options: .caseInsensitive)
    private static let tokenRegex = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}", options: [])

    /// `sanitizeJournalHtml`: only the allowed tags and attributes survive; a disallowed tag is
    /// dropped but its text kept (DOMPurify's `KEEP_CONTENT`), except for the script-like ones
    /// whose content goes too. `href`/`src` must carry a known scheme, or none; `data:` is only
    /// let through on an image.
    static func sanitize(_ html: String) -> String {
        let stripped = commentRegex.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "")
        let ns = stripped as NSString
        var out = ""
        var cursor = 0
        var skipping: String?
        for m in tagRegex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
            let closing = m.range(at: 1).length > 0
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            let rawAttrs = ns.substring(with: m.range(at: 3))
            if let s = skipping {
                if closing && name == s { skipping = nil }
                cursor = NSMaxRange(m.range)
                continue
            }
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = NSMaxRange(m.range)
            if dropWithContent.contains(name) {
                if !closing && !rawAttrs.hasSuffix("/") { skipping = name }
                continue
            }
            guard allowedTags.contains(name) else { continue }
            if closing {
                if !voidTags.contains(name) { out += "</\(name)>" }
                continue
            }
            out += "<\(name)\(attributes(rawAttrs, tag: name))>"
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func attributes(_ raw: String, tag: String) -> String {
        let ns = raw as NSString
        var out = ""
        for m in attrRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            guard allowedAttrs.contains(name) else { continue }
            var value = ""
            for g in 2...4 where m.range(at: g).location != NSNotFound { value = ns.substring(with: m.range(at: g)); break }
            if name == "href" || name == "src" {
                guard let v = safeURL(value, allowData: name == "src" && tag == "img") else { continue }
                value = v
            }
            out += " \(name)=\"\(value.replacingOccurrences(of: "\"", with: "&quot;"))\""
        }
        return out
    }

    /// DOMPurify's `IS_ALLOWED_URI` with `ALLOW_UNKNOWN_PROTOCOLS: false`.
    private static func safeURL(_ raw: String, allowData: Bool) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isASCII || ($0.asciiValue ?? 32) >= 32 }
        let lower = v.lowercased()
        guard let colon = lower.firstIndex(of: ":") else { return v }
        let scheme = String(lower[..<colon])
        if scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) == nil { return v }
        if safeSchemes.contains(scheme) { return v }
        if scheme == "data" && allowData && lower.hasPrefix("data:image/") { return v }
        return nil
    }

    // MARK: Import

    /// The stored HTML as the text view's content. `<img>` tags are lifted out before the
    /// system importer sees them and put back as attachments carrying their original `src`.
    static func attributed(from html: String, fontSize: CGFloat, lineHeightMultiple: CGFloat, maxImageWidth: CGFloat) -> NSAttributedString {
        var images: [String] = []
        let ns = html as NSString
        var work = ""
        var cursor = 0
        for m in imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            work += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let raw = ns.substring(with: m.range(at: 1)) as NSString
            var src = ""
            for a in attrRegex.matches(in: raw as String, range: NSRange(location: 0, length: raw.length)) {
                guard raw.substring(with: a.range(at: 1)).lowercased() == "src" else { continue }
                for g in 2...4 where a.range(at: g).location != NSNotFound { src = raw.substring(with: a.range(at: g)); break }
            }
            work += "\u{E000}\(images.count)\u{E001}"
            images.append(src)
            cursor = NSMaxRange(m.range)
        }
        work += ns.substring(from: cursor)

        let out = NSMutableAttributedString()
        if !work.isEmpty, let data = work.data(using: .utf8),
           let parsed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            out.append(parsed)
        }
        // The importer closes the document with a newline the editor would show as an empty line.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        normalize(out, fontSize: fontSize, lineHeightMultiple: lineHeightMultiple)

        // Tokens back into images.
        let base = baseAttributes(fontSize: fontSize, lineHeightMultiple: lineHeightMultiple)
        for m in tokenRegex.matches(in: out.string, range: NSRange(location: 0, length: out.length)).reversed() {
            let i = Int((out.string as NSString).substring(with: m.range(at: 1))) ?? -1
            guard images.indices.contains(i) else { out.replaceCharacters(in: m.range, with: ""); continue }
            out.replaceCharacters(in: m.range, with: image(src: images[i], base: base, maxWidth: maxImageWidth))
        }
        return out
    }

    static func baseAttributes(fontSize: CGFloat, lineHeightMultiple: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: Geist.nsFont(size: fontSize, weight: 400), .foregroundColor: NSColor(W.foreground), .paragraphStyle: paragraphStyle(lists: [], block: nil, lineHeightMultiple: lineHeightMultiple)]
    }

    /// An `<img>` as an attachment, sized to the column (`max-w-full`), remembering its `src`.
    static func image(src: String, base: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> NSAttributedString {
        let att = NSTextAttachment()
        if let data = dataURIBytes(src), let img = NSImage(data: data), img.size.width > 0 {
            att.image = img
            let w = min(img.size.width, maxWidth)
            att.bounds = CGRect(x: 0, y: 0, width: w, height: img.size.height * (w / img.size.width))
        } else {
            att.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        }
        let a = NSMutableAttributedString(attachment: att)
        var attrs = base
        attrs[.journalImageSrc] = src
        a.addAttributes(attrs, range: NSRange(location: 0, length: a.length))
        return a
    }

    static func dataURIBytes(_ src: String) -> Data? {
        guard src.lowercased().hasPrefix("data:"), let comma = src.firstIndex(of: ",") else { return nil }
        let header = src[src.index(src.startIndex, offsetBy: 5)..<comma].lowercased()
        let payload = String(src[src.index(after: comma)...])
        if header.hasSuffix(";base64") { return Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    /// `<ul>`/`<ol>` sit `pl-5` (20pt) with the marker inside that; a quote is `pl-3` behind a
    /// 2pt rule, drawn here as a 14pt indent in the muted colour.
    static func paragraphStyle(lists: [NSTextList], block: String?, lineHeightMultiple: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeightMultiple
        if !lists.isEmpty {
            p.textLists = lists
            p.headIndent = 20
            p.firstLineHeadIndent = 0
            p.tabStops = [NSTextTab(textAlignment: .left, location: 6), NSTextTab(textAlignment: .left, location: 20)]
            p.defaultTabInterval = 20
        } else if block == "blockquote" {
            p.headIndent = 14
            p.firstLineHeadIndent = 14
        }
        return p
    }

    /// The web's editor sizes: h1 16 / h2 14 / h3 13, all semibold; body at `fontSize`.
    static func font(block: String?, fontSize: CGFloat, bold: Bool, italic: Bool, mono: Bool) -> NSFont {
        var f: NSFont
        switch block {
        case "h1": f = Geist.nsFont(size: 16, weight: bold ? 700 : 600)
        case "h2": f = Geist.nsFont(size: 14, weight: bold ? 700 : 600)
        case "h3": f = Geist.nsFont(size: 13, weight: bold ? 700 : 600)
        default: f = Geist.nsFont(size: fontSize, weight: bold ? 700 : 400, mono: mono)
        }
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    /// Every run onto Geist at the web's sizes, keeping what the entry's markup said: a
    /// heading by the importer's size, a quote by its indent, a list by its paragraph, code by
    /// its fixed-pitch face, plus bold/italic/underline/strike/link.
    private static func normalize(_ out: NSMutableAttributedString, fontSize: CGFloat, lineHeightMultiple: CGFloat) {
        out.beginEditing()
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttributes(in: full) { attrs, range, _ in
            var next: [NSAttributedString.Key: Any] = [:]
            let f = attrs[.font] as? NSFont
            let traits = f?.fontDescriptor.symbolicTraits ?? []
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)
            let name = f?.fontName.lowercased() ?? ""
            let mono = traits.contains(.monoSpace) || name.contains("courier") || name.contains("mono")
            let size = f?.pointSize ?? 12
            let ps = attrs[.paragraphStyle] as? NSParagraphStyle
            let lists = ps?.textLists ?? []
            var block: String?
            if size >= 22 { block = "h1" } else if size >= 16 { block = "h2" } else if size > 13 && bold { block = "h3" }
            if block == nil, lists.isEmpty, (ps?.headIndent ?? 0) > 0 { block = "blockquote" }
            // The importer's own bold is the heading's; a `<strong>` inside one is not told apart.
            let runBold = block == nil && bold
            next[.font] = font(block: block, fontSize: fontSize, bold: runBold, italic: italic, mono: mono)
            next[.foregroundColor] = NSColor(block == "blockquote" ? W.mutedForeground : W.foreground)
            if let u = attrs[.underlineStyle] { next[.underlineStyle] = u }
            if let s = attrs[.strikethroughStyle] { next[.strikethroughStyle] = s }
            if let l = attrs[.link] { next[.link] = l }
            if let a = attrs[.attachment] { next[.attachment] = a }
            if let block { next[.journalBlock] = block }
            if mono { next[.journalCode] = true }
            next[.paragraphStyle] = paragraphStyle(lists: lists, block: block, lineHeightMultiple: lineHeightMultiple)
            out.setAttributes(next, range: range)
        }
        out.endEditing()
    }

    // MARK: Export

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func escapeAttr(_ s: String) -> String { escape(s).replacingOccurrences(of: "\"", with: "&quot;") }

    /// The Geist weight axis, when the font was made from it.
    static func weight(of font: NSFont) -> CGFloat {
        if let v = font.fontDescriptor.object(forKey: .variation) as? [NSNumber: NSNumber], let w = v[NSNumber(value: 0x77676874)] { return CGFloat(w.doubleValue) }
        return font.fontDescriptor.symbolicTraits.contains(.bold) ? 700 : 400
    }

    /// The text view's content as the HTML the web writes: `<div>` per line, `<h2>` for a
    /// heading, `<blockquote>`, `<pre>`, `<ul>`/`<ol>` with `<li>`s, and inline
    /// strong/em/u/s/code/a/img.
    static func html(from storage: NSAttributedString) -> String {
        let ns = storage.string as NSString
        struct Block { let kind: String; let ordered: Bool; let inner: String }
        var blocks: [Block] = []
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(pr)
            var content = pr
            while content.length > 0, let last = Unicode.Scalar(ns.character(at: NSMaxRange(content) - 1)), CharacterSet.newlines.contains(last) { content.length -= 1 }
            let attrs = pr.length > 0 ? storage.attributes(at: pr.location, effectiveRange: nil) : [:]
            let lists = (attrs[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
            var kind = "div"
            var ordered = false
            if let list = lists.last {
                kind = "li"
                let fmt = list.markerFormat.rawValue
                ordered = fmt.contains("decimal") || fmt.contains("alpha") || fmt.contains("roman")
            } else if let b = attrs[.journalBlock] as? String { kind = b }
            else if content.length > 0 {
                var allCode = true, sawCode = false
                storage.enumerateAttributes(in: content) { a, _, _ in
                    if a[.attachment] != nil { return }
                    if a[.journalCode] == nil { allCode = false } else { sawCode = true }
                }
                if allCode && sawCode { kind = "pre" }
            }
            var runRange = content
            if kind == "li", content.length > 0 {
                // The marker is text (`\t•\t`); the `<li>` carries its own.
                let text = ns.substring(with: content)
                if let m = text.range(of: "^\t[^\t]*\t", options: .regularExpression) {
                    let n = (String(text[..<m.upperBound]) as NSString).length
                    runRange = NSRange(location: content.location + n, length: content.length - n)
                }
            }
            blocks.append(Block(kind: kind, ordered: ordered, inner: inline(storage, range: runRange, pre: kind == "pre")))
        }

        var out = ""
        var i = 0
        while i < blocks.count {
            let b = blocks[i]
            switch b.kind {
            case "li":
                let tag = b.ordered ? "ol" : "ul"
                out += "<\(tag)>"
                while i < blocks.count, blocks[i].kind == "li", blocks[i].ordered == b.ordered { out += "<li>\(blocks[i].inner)</li>"; i += 1 }
                out += "</\(tag)>"
                continue
            case "h1", "h2", "h3": out += "<\(b.kind)>\(b.inner)</\(b.kind)>"
            case "blockquote": out += "<blockquote>\(b.inner)</blockquote>"
            case "pre": out += "<pre>\(b.inner)</pre>"
            default: out += b.inner.isEmpty ? "<div><br></div>" : "<div>\(b.inner)</div>"
            }
            i += 1
        }
        return out
    }

    private static func inline(_ storage: NSAttributedString, range: NSRange, pre: Bool) -> String {
        guard range.length > 0 else { return "" }
        var out = ""
        let ns = storage.string as NSString
        let heading = (storage.attributes(at: range.location, effectiveRange: nil)[.journalBlock] as? String).map { $0.hasPrefix("h") } ?? false
        storage.enumerateAttributes(in: range) { attrs, r, _ in
            if let att = attrs[.attachment] as? NSTextAttachment {
                var src = attrs[.journalImageSrc] as? String
                if src == nil, let img = att.image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    src = "data:image/png;base64," + png.base64EncodedString()
                }
                if let src { out += "<img src=\"\(escapeAttr(src))\" alt=\"\">" }
                return
            }
            var text = escape(ns.substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: ""))
            text = text.replacingOccurrences(of: "\u{2028}", with: "<br>")
            guard !text.isEmpty else { return }
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let w = font.map { weight(of: $0) } ?? 400
            let bold = heading ? w >= 700 : (w >= 600 || traits.contains(.boldFontMask))
            let italic = traits.contains(.italicFontMask) || (font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
            // The importer underlines links itself; that is the `<a>`'s, not a `<u>`.
            let underline = attrs[.link] == nil && ((attrs[.underlineStyle] as? Int) ?? 0) != 0
            let strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
            let code = !pre && (attrs[.journalCode] != nil || (font?.fontName.lowercased().contains("mono") ?? false))
            var open = "", close = ""
            if let l = attrs[.link] {
                let href = (l as? URL)?.absoluteString ?? (l as? String) ?? ""
                if !href.isEmpty { open += "<a href=\"\(escapeAttr(href))\">"; close = "</a>" + close }
            }
            if bold { open += "<strong>"; close = "</strong>" + close }
            if italic { open += "<em>"; close = "</em>" + close }
            if underline { open += "<u>"; close = "</u>" + close }
            if strike { open += "<s>"; close = "</s>" + close }
            if code { open += "<code>"; close = "</code>" + close }
            out += open + text + close
        }
        return out
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
    @State private var marks: (bold: Bool, italic: Bool, ul: Bool, h2: Bool) = (false, false, false, false)
    @State private var linkOpen = false
    @State private var linkURL = ""
    @State private var pasteMonitor: Any?

    private let fontSize: CGFloat = 13
    private let lineHeightMultiple: CGFloat = 1.7 / 1.2
    private var older: String? { index.filter { $0 < date }.max() }
    private var newer: String? { index.filter { $0 > date }.min() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error { ErrorStateView(message: error) { Task { await load() } } }
            else if loading { SkeletonRows(rows: 4, compact: true) }
            ZStack(alignment: .topLeading) {
                RichTextEditor(controller: editor, height: $editorHeight, placeholder: "How did it go?", autoFocus: true, onEdit: { markDirty(); readMarks() })
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
        .onDisappear {
            saveTask?.cancel()
            Task { await flush() }
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
        .onAppear {
            editor.fontSize = fontSize
            editor.lineHeightMultiple = lineHeightMultiple
            editor.onSelection = { rect in
                guard !linkOpen else { return }
                bar = rect
                readMarks()
            }
            installPasteMonitor()
        }
        // `onBlur={() => void flush()}`: leaving the editor writes what is there.
        .onReceive(NotificationCenter.default.publisher(for: NSText.didEndEditingNotification)) { note in
            guard let tv = note.object as? NSTextView, tv === editor.textView else { return }
            saveTask?.cancel()
            Task { await flush() }
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
            // `/calendar?d={date}`: the calendar opens revealed on this day.
            WButton("In the calendar", icon: "calendarDays", variant: .ghost, size: .sm, muted: true) { router.go(.calendar(date)) }
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
                    tool("heading2", "Heading", active: marks.h2) { toggleHeading(); after() }
                    tool("list", "Bulleted list", active: marks.ul) { toggleList(); after() }
                    tool("link2", "Link") { linkURL = ""; linkOpen = true }
                    tool("removeFormatting", "Clear formatting") { clearFormatting(); after() }
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

    private func after() { readMarks(); markDirty() }

    private func applyLink() {
        let url = linkURL.trimmingCharacters(in: .whitespaces)
        linkOpen = false
        guard !url.isEmpty else { return }
        editor.insertLink(url)
        markDirty()
    }

    // MARK: Marks and block formatting

    private var baseAttributes: [NSAttributedString.Key: Any] { JournalHTML.baseAttributes(fontSize: fontSize, lineHeightMultiple: lineHeightMultiple) }

    /// `readMarks`: bold/italic from the run, `ul` from the paragraph's list, `h2` from its block.
    private func readMarks() {
        guard let tv = editor.textView, let storage = tv.textStorage else { marks = (false, false, false, false); return }
        let sel = tv.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if sel.length > 0, sel.location < storage.length { attrs = storage.attributes(at: sel.location, effectiveRange: nil) }
        else { attrs = tv.typingAttributes }
        let pr = (storage.string as NSString).paragraphRange(for: sel)
        let para = pr.length > 0 ? storage.attributes(at: pr.location, effectiveRange: nil) : tv.typingAttributes
        let font = attrs[.font] as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        let bold = (font.map { JournalHTML.weight(of: $0) >= 600 } ?? false) || traits.contains(.boldFontMask)
        let italic = traits.contains(.italicFontMask) || (font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        let ul = !((para[.paragraphStyle] as? NSParagraphStyle)?.textLists.isEmpty ?? true)
        let h2 = (para[.journalBlock] as? String) == "h2"
        marks = (bold, italic, ul, h2)
    }

    /// `formatBlock h2` / `formatBlock p` on the paragraph under the selection.
    private func toggleHeading() {
        guard let tv = editor.textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let pr = (storage.string as NSString).paragraphRange(for: sel)
        let current = pr.length > 0 ? storage.attributes(at: pr.location, effectiveRange: nil) : tv.typingAttributes
        let on = (current[.journalBlock] as? String) == "h2"
        let block: String? = on ? nil : "h2"
        let font = JournalHTML.font(block: block, fontSize: fontSize, bold: false, italic: false, mono: false)
        if pr.length > 0 {
            storage.beginEditing()
            storage.enumerateAttributes(in: pr) { attrs, r, _ in
                var next = attrs
                let lists = (attrs[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
                next[.font] = font
                next[.journalBlock] = block
                next[.paragraphStyle] = JournalHTML.paragraphStyle(lists: lists, block: block, lineHeightMultiple: lineHeightMultiple)
                storage.setAttributes(next, range: r)
            }
            storage.endEditing()
            tv.didChangeText()
        }
        var t = tv.typingAttributes
        t[.font] = font
        t[.journalBlock] = block
        let lists = (t[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
        t[.paragraphStyle] = JournalHTML.paragraphStyle(lists: lists, block: block, lineHeightMultiple: lineHeightMultiple)
        tv.typingAttributes = t
    }

    /// `insertUnorderedList`: the paragraphs under the selection become `<li>`s of a real
    /// list (an `NSTextList` on the paragraph, the marker as text the way AppKit keeps it),
    /// or stop being ones.
    private func toggleList() {
        guard let tv = editor.textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let ns = storage.string as NSString
        let pr = ns.paragraphRange(for: sel)
        let marker = "\t•\t"
        let list = NSTextList(markerFormat: .disc, options: 0)
        let markerPattern = "^\t[^\t]*\t"
        if pr.length == 0 {
            // An empty document, or the caret on an empty last line: start a list there.
            let on = !((tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.textLists.isEmpty ?? true)
            var t = tv.typingAttributes
            t[.paragraphStyle] = JournalHTML.paragraphStyle(lists: on ? [] : [list], block: nil, lineHeightMultiple: lineHeightMultiple)
            if !on { tv.insertText(NSAttributedString(string: marker, attributes: t), replacementRange: sel) }
            tv.typingAttributes = t
            return
        }
        let on = !((storage.attributes(at: pr.location, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle)?.textLists.isEmpty ?? true)
        let result = NSMutableAttributedString()
        var loc = pr.location
        while loc < NSMaxRange(pr) {
            let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(p)
            let para = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: p))
            let text = para.string
            if on {
                if let m = text.range(of: markerPattern, options: .regularExpression) {
                    para.deleteCharacters(in: NSRange(location: 0, length: (String(text[..<m.upperBound]) as NSString).length))
                }
            } else if text.range(of: markerPattern, options: .regularExpression) == nil {
                let attrs = para.length > 0 ? para.attributes(at: 0, effectiveRange: nil) : tv.typingAttributes
                para.insert(NSAttributedString(string: marker, attributes: attrs), at: 0)
            }
            para.enumerateAttributes(in: NSRange(location: 0, length: para.length)) { attrs, r, _ in
                let block = attrs[.journalBlock] as? String
                para.addAttribute(.paragraphStyle, value: JournalHTML.paragraphStyle(lists: on ? [] : [list], block: block, lineHeightMultiple: lineHeightMultiple), range: r)
            }
            result.append(para)
        }
        tv.insertText(result, replacementRange: pr)
        var t = tv.typingAttributes
        t[.paragraphStyle] = JournalHTML.paragraphStyle(lists: on ? [] : [list], block: t[.journalBlock] as? String, lineHeightMultiple: lineHeightMultiple)
        tv.typingAttributes = t
        let caret = min(pr.location + (on ? 0 : (marker as NSString).length), (tv.string as NSString).length)
        tv.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// `removeFormat`: the selection back to plain body text, keeping its paragraph.
    private func clearFormatting() {
        guard let tv = editor.textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        var base = baseAttributes
        if sel.length > 0 {
            storage.beginEditing()
            storage.enumerateAttributes(in: sel) { attrs, r, _ in
                var next = base
                if let p = attrs[.paragraphStyle] { next[.paragraphStyle] = p }
                if let a = attrs[.attachment] { next[.attachment] = a; if let s = attrs[.journalImageSrc] { next[.journalImageSrc] = s } }
                storage.setAttributes(next, range: r)
            }
            storage.endEditing()
            tv.didChangeText()
        }
        if let p = tv.typingAttributes[.paragraphStyle] { base[.paragraphStyle] = p }
        tv.typingAttributes = base
    }

    // MARK: Paste

    /// `onPaste`: images become data-URI `<img>`s (under 250 KB each, or a toast), and HTML
    /// or rich text is sanitised before it lands. Plain text pastes as it always did.
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option),
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let tv = editor.textView, tv.window?.firstResponder === tv else { return event }
            return handlePaste(into: tv) ? nil : event
        }
    }

    private func handlePaste(into tv: NSTextView) -> Bool {
        let pb = NSPasteboard.general
        let maxImageBytes = 250_000
        let maxWidth = max(200, tv.bounds.width - 4)
        var images: [(data: Data, mime: String)] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL], !urls.isEmpty {
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                images.append((data, UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"))
            }
        } else if pb.availableType(from: [.png, .tiff]) != nil {
            if let png = pb.data(forType: .png) { images.append((png, "image/png")) }
            else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { images.append((png, "image/png")) }
        }
        if !images.isEmpty {
            for img in images {
                if img.data.count > maxImageBytes {
                    Toasts.shared.error("That image is too big to keep in an entry — under 250 KB, please.")
                    continue
                }
                let src = "data:\(img.mime);base64,\(img.data.base64EncodedString())"
                tv.insertText(JournalHTML.image(src: src, base: baseAttributes, maxWidth: maxWidth), replacementRange: tv.selectedRange())
            }
            markDirty()
            return true
        }
        if let html = pb.string(forType: .html) {
            // Never let a page's markup land in the editor as-is; it is about to become our stored HTML.
            let a = JournalHTML.attributed(from: JournalHTML.sanitize(html), fontSize: fontSize, lineHeightMultiple: lineHeightMultiple, maxImageWidth: maxWidth)
            tv.insertText(a, replacementRange: tv.selectedRange())
            markDirty()
            return true
        }
        if let rtf = pb.data(forType: .rtf), let a = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            // Rich text from another app: through the same door as the web's HTML paste.
            let html = (try? a.data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])).flatMap { String(data: $0, encoding: .utf8) } ?? a.string
            let clean = JournalHTML.attributed(from: JournalHTML.sanitize(html), fontSize: fontSize, lineHeightMultiple: lineHeightMultiple, maxImageWidth: maxWidth)
            tv.insertText(clean, replacementRange: tv.selectedRange())
            markDirty()
            return true
        }
        return false
    }

    // MARK: Load and save

    private func load() async {
        loading = true
        async let entry = CalendarAPI.journal(date: date)
        async let all = CalendarAPI.journalIndex()
        do {
            let d = try await entry
            day = d
            // Sanitised on the way in, as on the web: an older client may have written anything.
            setContent(JournalHTML.sanitize(d.journalHTML ?? ""))
            dirty = false
            error = nil
        } catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
        index = ((try? await all) ?? []).map(\.date)
        loading = false
    }

    /// The editor is made and placed in separate passes; the content waits for its text view.
    private func setContent(_ html: String, attempt: Int = 0) {
        guard let tv = editor.textView else {
            if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { setContent(html, attempt: attempt + 1) } }
            return
        }
        let a = JournalHTML.attributed(from: html, fontSize: fontSize, lineHeightMultiple: lineHeightMultiple, maxImageWidth: max(200, tv.bounds.width - 4))
        tv.textStorage?.setAttributedString(a)
        tv.typingAttributes = baseAttributes
        tv.needsDisplay = true
        editor.onContentSet?()
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
        guard dirty, !loading, let storage = editor.textView?.textStorage else { return }
        // Sanitised on the way out too: what is in the view can be anything ever pasted into it.
        let html = JournalHTML.sanitize(JournalHTML.html(from: storage))
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
