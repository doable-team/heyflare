import SwiftUI

/// Grayscale only (`LABEL_COLORS`).
let labelColors = ["#37352f", "#5c5a55", "#787774", "#9b9a97", "#b3b1ac", "#cfcdc8"]
/// The Labels page's shades.
let labelShades = ["#37352f", "#5f5b54", "#7d7972", "#9b978f", "#b5b1a9", "#cfcbc3", "#e2dfd8", "#f1efe9"]

func colorFromHex(_ h: String) -> Color {
    var s = h; if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0
    return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
}

struct LabelChip: View {
    let label: MailLabel
    var small = false
    var body: some View {
        // `LabelChip small` keeps the badge's own `px-1.5`, not the small badge's tighter 4.
        WBadge(label.name, variant: .outline, small: small, dot: colorFromHex(label.color), paddingX: small ? 6 : nil)
    }
}

/// `CommandInput`: a `p-1 pb-0` wrapper around an `h-8 rounded-lg` group with a faint
/// `input/30` wash and border, the search glyph at the start at half opacity.
struct CommandSearchField: View {
    let placeholder: String
    @Binding var text: String
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Icon("search", size: 16).foregroundStyle(W.foreground).opacity(0.5).padding(.leading, 8)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(W.mutedForeground))
                .textFieldStyle(.plain)
                .font(W.sm)
                .foregroundStyle(W.foreground)
                .focused($focused)
                .padding(.horizontal, 10)
        }
        .frame(height: 32)
        .background(W.input.opacity(0.3))
        .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.input.opacity(0.3), lineWidth: 1))
        .rounded(W.radiusLg)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .onAppear { if autofocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } } }
    }
}

/// Command-style toggle list with an inline "Create" row. Shared by labels and collections.
struct TogglePicker: View {
    let placeholder: String
    let items: [(id: String, name: String, dot: String?)]
    let current: Set<String>
    var loading = false
    var creating = false
    var icon: String? = nil
    let emptyText: String
    var onToggle: (String, Bool) -> Void
    var onCreate: (String) -> Void
    var onClose: (() -> Void)? = nil

    @State private var q = ""
    @State private var local: Set<String> = []
    @State private var seeded = false

    private var filtered: [(id: String, name: String, dot: String?)] {
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty ? items : items.filter { $0.name.lowercased().contains(t) }
    }
    private var exact: Bool { items.contains { $0.name.lowercased() == q.trimmingCharacters(in: .whitespaces).lowercased() } }

    var body: some View {
        VStack(spacing: 0) {
            CommandSearchField(placeholder: placeholder, text: $q)
            ScrollView {
                VStack(spacing: 0) {
                    if loading {
                        Spinner(size: 16).foregroundStyle(W.mutedForeground).frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        if filtered.isEmpty && !(q.trimmingCharacters(in: .whitespaces).isEmpty == false && !exact) {
                            // `CommandEmpty`: py-6 text-center text-sm.
                            Text(q.trimmingCharacters(in: .whitespaces).isEmpty ? emptyText : "No matches.").font(W.sm).foregroundStyle(W.mutedForeground).padding(.vertical, 24).frame(maxWidth: .infinity)
                        }
                        if !filtered.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(filtered, id: \.id) { it in
                                    let on = local.contains(it.id)
                                    CommandRow(selected: false) {
                                        HStack(spacing: 8) {
                                            if let dot = it.dot { Circle().fill(colorFromHex(dot)).frame(width: 8, height: 8).padding(.horizontal, 4) }
                                            else if let icon { Icon(icon, size: 16).foregroundStyle(W.mutedForeground) }
                                            Text(it.name).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                                            Spacer()
                                            Icon("check", size: 16).opacity(on ? 1 : 0)
                                        }
                                    } action: {
                                        if on { local.remove(it.id) } else { local.insert(it.id) }
                                        onToggle(it.id, !on)
                                    }
                                }
                            }
                            .padding(4)
                        }
                        if !q.trimmingCharacters(in: .whitespaces).isEmpty && !exact {
                            WSeparator()
                            CommandRow(selected: false) {
                                HStack(spacing: 8) {
                                    if creating { Spinner(size: 16) } else { Icon("plus", size: 16) }
                                    Text("Create “\(q.trimmingCharacters(in: .whitespaces))”").font(W.sm).lineLimit(1)
                                }
                            } action: { onCreate(q.trimmingCharacters(in: .whitespaces)); q = "" }
                            .padding(4)
                            .opacity(creating ? 0.5 : 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 256)
            if let onClose {
                HStack { Spacer(); WButton("Done", variant: .ghost, size: .xs, muted: true, action: onClose) }.padding(4).edgeLine(.top)
            }
        }
        .frame(width: 256)
        .onAppear { if !seeded { local = current; seeded = true } }
        .onChange(of: current) { _, c in local = c }
    }
}

/// A `CommandItem` row: px-2 py-1.5 (32pt), rounded-sm, muted wash when selected/hovered.
/// Inside a dialog the corners are `rounded-lg`.
struct CommandRow<Content: View>: View {
    var selected: Bool
    var height: CGFloat = 32
    var radius: CGFloat = W.radiusSm
    @ViewBuilder var content: () -> Content
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected || hovering ? W.muted : Color.clear)
                .rounded(radius)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct LabelPicker: View {
    let current: Set<String>
    var onToggle: (String, Bool) -> Void
    var onClose: (() -> Void)? = nil
    @State private var store = LabelsStore()
    @State private var creating = false

    var body: some View {
        TogglePicker(placeholder: "Label…", items: store.labels.map { ($0.id, $0.name, $0.color) }, current: current, loading: store.loading && store.labels.isEmpty, creating: creating, emptyText: "No labels yet. Type to make one.", onToggle: onToggle, onCreate: { name in
            creating = true
            Task {
                defer { creating = false }
                do {
                    let l = try await APIClient.shared.post("/api/labels", body: ["name": name, "color": labelColors[store.labels.count % labelColors.count]], as: MailLabel.self)
                    await store.load()
                    onToggle(l.id, true)
                } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
            }
        }, onClose: onClose)
        .task { await store.load() }
    }
}

struct CollectionPicker: View {
    let current: Set<String>
    var onToggle: (String, Bool) -> Void
    var onClose: (() -> Void)? = nil
    @State private var store = CollectionsStore()
    @State private var creating = false

    var body: some View {
        TogglePicker(placeholder: "Collection…", items: store.collections.map { ($0.id, $0.name, nil) }, current: current, loading: store.loading && store.collections.isEmpty, creating: creating, icon: "folderOpen", emptyText: "No collections yet. Type to start one.", onToggle: onToggle, onCreate: { name in
            creating = true
            Task {
                defer { creating = false }
                do {
                    let c = try await APIClient.shared.post("/api/collections", body: ["name": name, "description": ""], as: MailCollection.self)
                    await store.load()
                    onToggle(c.id, true)
                } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
            }
        }, onClose: onClose)
        .task { await store.load() }
    }
}

// MARK: - Menu submenus (`DropdownMenuSub`)

/// `DropdownMenuSubTrigger`: px-1.5 py-1 text-sm gap-1.5 with a ChevronRight at the end,
/// `bg-accent` while its submenu is open. Opens on hover, as radix does, and on click; the
/// content lands to the right of the row, top-aligned with it.
struct SubMenuItem<Content: View>: View {
    let id: String
    let label: String
    var icon: String? = nil
    var width: CGFloat = 208
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @State private var opener: Task<Void, Never>?
    @Environment(PopLayerState.self) private var pops

    private var open: Bool { pops.isOpen(id) }

    var body: some View {
        Button { openSub() } label: {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 16).foregroundStyle(hovering || open ? W.foreground : W.mutedForeground) }
                Text(label).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                Spacer(minLength: 12)
                Icon("chevronRight", size: 16).foregroundStyle(W.mutedForeground)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering || open ? W.accent : Color.clear)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popAnchor(id)
        .onHover { over in
            hovering = over
            opener?.cancel()
            guard over, !open else { return }
            opener = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                openSub()
            }
        }
    }

    private func openSub() {
        guard !open else { return }
        pops.open(id, side: .right, align: .start, offset: 0) {
            PopCard(width: width) { content() }
        }
    }
}

/// `DropdownMenuCheckboxItem`: py-1 pr-8 pl-1.5 gap-1.5 text-sm, the check at `right-2`.
/// Picking one keeps the menu open (`onSelect={(e) => e.preventDefault()}`).
struct CheckMenuItem: View {
    let label: String
    var dot: String? = nil
    let checked: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(colorFromHex(dot)).frame(width: 8, height: 8) }
                Text(label).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 32)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { Icon("check", size: 16).opacity(checked ? 1 : 0).padding(.trailing, 8) }
            .background(hovering ? W.accent : Color.clear)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `LabelMenuItems`: checkbox items for a submenu, ending in "New label…".
struct LabelMenuItems: View {
    let current: Set<String>
    var onToggle: (String, Bool) -> Void
    var onManage: (() -> Void)? = nil
    @State private var store = LabelsStore()
    @State private var local: Set<String> = []
    @State private var seeded = false
    @Environment(PopLayerState.self) private var pops

    var body: some View {
        VStack(spacing: 0) {
            if store.labels.isEmpty { MenuItem("No labels yet", disabled: true) {} }
            ForEach(store.labels) { l in
                CheckMenuItem(label: l.name, dot: l.color, checked: local.contains(l.id)) {
                    let on = !local.contains(l.id)
                    if on { local.insert(l.id) } else { local.remove(l.id) }
                    onToggle(l.id, on)
                }
            }
            if let onManage {
                MenuSeparator()
                MenuItem("New label…", icon: "plus") { onManage() }
            }
        }
        .onAppear { if !seeded { local = current; seeded = true } }
        .onChange(of: current) { _, c in local = c }
        .task { await store.load() }
    }
}

struct CollectionMenuItems: View {
    let current: Set<String>
    var onToggle: (String, Bool) -> Void
    var onManage: (() -> Void)? = nil
    @State private var store = CollectionsStore()
    @State private var local: Set<String> = []
    @State private var seeded = false

    var body: some View {
        VStack(spacing: 0) {
            if store.collections.isEmpty { MenuItem("No collections yet", disabled: true) {} }
            ForEach(store.collections) { c in
                CheckMenuItem(label: c.name, checked: local.contains(c.id)) {
                    let on = !local.contains(c.id)
                    if on { local.insert(c.id) } else { local.remove(c.id) }
                    onToggle(c.id, on)
                }
            }
            if let onManage {
                MenuSeparator()
                MenuItem("New collection…", icon: "plus") { onManage() }
            }
        }
        .onAppear { if !seeded { local = current; seeded = true } }
        .onChange(of: current) { _, c in local = c }
        .task { await store.load() }
    }
}

// MARK: - Thread picker (merge)

/// Search & pick a thread (merge, assistant context). `Command shouldFilter={false}` with an
/// autofocused input, a hint while empty, `h-11` rows of subject over "sender · snippet".
struct ThreadPicker: View {
    var placeholder = "Search threads to merge…"
    var hint: String? = "Type to find the thread you want to fold into this one."
    var exclude: [String] = []
    /// Inside a dialog the rows are `rounded-lg`; in a popover `rounded-sm`.
    var inDialog = false
    var onPick: (ThreadSummary) -> Void
    @State private var q = ""
    @State private var store = SearchStore()

    private var typed: Bool { !q.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            CommandSearchField(placeholder: placeholder, text: $q, autofocus: true)
            ScrollView {
                VStack(spacing: 0) {
                    let list = store.threads.filter { !exclude.contains($0.id) }
                    if !typed, let hint {
                        Text(hint).font(W.s13).foregroundStyle(W.mutedForeground).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    if typed && store.searching && list.isEmpty {
                        Spinner(size: 16).foregroundStyle(W.mutedForeground).frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    if typed && !store.searching && list.isEmpty && store.query == q.trimmingCharacters(in: .whitespaces) {
                        Text("No matches.").font(W.s13).foregroundStyle(W.mutedForeground).frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    if !list.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(list) { t in
                                CommandRow(selected: false, height: 44, radius: inDialog ? W.radiusLg : W.radiusSm) {
                                    HStack(spacing: 10) {
                                        WAvatar(t.lastFrom, size: 20)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(t.subject.isEmpty ? "(no subject)" : t.subject).font(W.s13).foregroundStyle(W.foreground).lineLimit(1)
                                            Text("\(t.lastFrom.name.isEmpty ? t.lastFrom.email : t.lastFrom.name) · \(t.snippet)").font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(Fmt.time(t.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).fixedSize()
                                    }
                                } action: { onPick(t) }
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: inDialog ? 448 : 360)
        .task(id: q) {
            let t = q.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { store.clear(); return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await store.run(t)
        }
    }
}

/// A bare text field (no wash) for search rows.
struct WTextFieldPlain: View {
    let placeholder: String
    @Binding var text: String
    var autofocus = false
    var fontSize: CGFloat = 14
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(W.font(fontSize))
            .foregroundStyle(W.foreground)
            .focused($focused)
            .onAppear { if autofocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } } }
    }
}
