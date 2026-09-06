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
        WBadge(label.name, variant: .outline, small: small, dot: colorFromHex(label.color))
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
            HStack(spacing: 8) {
                Icon("search", size: 16).foregroundStyle(W.mutedForeground)
                TextField(placeholder, text: $q).textFieldStyle(.plain).font(W.sm).foregroundStyle(W.foreground)
            }
            .padding(.horizontal, 12).frame(height: 40).edgeLine(.bottom)
            ScrollView {
                VStack(spacing: 0) {
                    if loading {
                        Spinner(size: 16).foregroundStyle(W.mutedForeground).frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        if filtered.isEmpty && !(q.trimmingCharacters(in: .whitespaces).isEmpty == false && !exact) {
                            Text(q.trimmingCharacters(in: .whitespaces).isEmpty ? emptyText : "No matches.").font(W.sm).foregroundStyle(W.mutedForeground).padding(24).frame(maxWidth: .infinity)
                        }
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
                        if !q.trimmingCharacters(in: .whitespaces).isEmpty && !exact {
                            WSeparator().padding(.vertical, 4)
                            CommandRow(selected: false) {
                                HStack(spacing: 8) {
                                    if creating { Spinner(size: 16) } else { Icon("plus", size: 16) }
                                    Text("Create “\(q.trimmingCharacters(in: .whitespaces))”").font(W.sm).lineLimit(1)
                                }
                            } action: { onCreate(q.trimmingCharacters(in: .whitespaces)); q = "" }
                        }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 256)
            if let onClose {
                HStack { Spacer(); WButton("Done", variant: .ghost, size: .xs, muted: true, action: onClose) }.padding(4).edgeLine(.top)
            }
        }
        .frame(width: 256)
        .onAppear { if !seeded { local = current; seeded = true } }
    }
}

/// A `CommandItem` row: 32pt, rounded, muted wash when selected/hovered.
struct CommandRow<Content: View>: View {
    var selected: Bool
    @ViewBuilder var content: () -> Content
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .frame(height: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected || hovering ? W.muted : Color.clear)
                .rounded(W.radiusLg)
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
        TogglePicker(placeholder: "Collection…", items: store.collections.map { ($0.id, $0.name, nil) }, current: current, loading: store.loading && store.collections.isEmpty, creating: creating, icon: "folderOpen", emptyText: "No collections yet. Type to make one.", onToggle: onToggle, onCreate: { name in
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

/// Search-and-pick a thread (merge, assistant context).
struct ThreadPicker: View {
    var placeholder = "Search threads…"
    var hint: String? = nil
    var exclude: [String] = []
    var onPick: (ThreadSummary) -> Void
    @State private var q = ""
    @State private var store = SearchStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Icon("search", size: 16).foregroundStyle(W.mutedForeground)
                WTextFieldPlain(placeholder: placeholder, text: $q, autofocus: true)
                if store.searching { Spinner(size: 14).foregroundStyle(W.mutedForeground) }
            }
            .padding(.horizontal, 12).frame(height: 40).edgeLine(.bottom)
            ScrollView {
                VStack(spacing: 0) {
                    let list = store.threads.filter { !exclude.contains($0.id) }
                    if let hint, q.isEmpty { Text(hint).font(W.s13).foregroundStyle(W.mutedForeground).padding(16) }
                    if !q.isEmpty && list.isEmpty && !store.searching { Text("No matches.").font(W.sm).foregroundStyle(W.mutedForeground).padding(24) }
                    ForEach(list) { t in
                        CommandRow(selected: false) {
                            HStack(spacing: 8) {
                                WAvatar(t.lastFrom, size: 20)
                                Text(t.lastFrom.name.isEmpty ? t.lastFrom.email : t.lastFrom.name).font(W.font(14, 500)).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
                                Text(t.displaySubject).font(W.sm).foregroundStyle(W.mutedForeground).lineLimit(1)
                                Spacer()
                                Text(Fmt.time(t.lastMessageAt)).font(W.xs).foregroundStyle(W.mutedForeground)
                            }
                        } action: { onPick(t) }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 360)
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
