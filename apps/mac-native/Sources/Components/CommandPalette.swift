import SwiftUI
import AppKit

/// ⌘K: search mail, jump anywhere, or run an action.
struct CommandPalette: View {
    @Environment(UIState.self) private var ui
    @Environment(Router.self) private var router
    @Environment(AppState.self) private var app
    @Environment(Toasts.self) private var toasts

    @State private var q = ""
    @State private var store = SearchStore()
    @State private var selected = 0

    private struct Item: Identifiable { let id: String; let group: String; let label: String; let icon: String?; let kbd: String?; let avatar: Address?; let sub: String?; let time: String?; let run: () -> Void }

    private var destinations: [(String, String, String, String?, String)] {[
        ("/", "Imbox", "inbox", nil, ""), ("/feed", "The Feed", "rss", nil, "newsletters"), ("/paper-trail", "Paper Trail", "fileText", nil, "receipts"),
        ("/screener", "Screener", "shield", nil, "new senders"), ("/reply-later", "Reply Later", "clock", nil, "focus reply"), ("/set-aside", "Set Aside", "bookmark", nil, ""),
        ("/bubble-up", "Bubble Up", "arrowUpCircle", nil, "snooze"), ("/previously-seen", "Previously Seen", "eye", nil, ""), ("/contacts", "Contacts", "users", nil, ""),
        ("/clips", "Clips", "scissors", nil, ""), ("/collections", "Collections", "folderOpen", nil, ""), ("/files", "Files", "files", nil, "attachments"),
        ("/labels", "Labels", "tag", nil, ""), ("/sent", "Sent", "send", nil, ""), ("/drafts", "Drafts", "penSquare", nil, ""), ("/scheduled", "Scheduled", "calendarClock", nil, "send later"),
        ("/everything", "Everything", "mail", nil, ""), ("/screened-out", "Screened out", "shieldOff", nil, ""), ("/trash", "Trash", "trash2", nil, ""),
        ("/calendar", "Calendar", "calendarDays", "0", "events schedule meetings agenda"), ("/journal", "Journal", "notebookPen", nil, "diary write day"), ("/habits", "Habits", "repeat", nil, "streak daily routine"),
        ("/settings", "Settings", "settings", nil, ""),
    ]}

    private var items: [Item] {
        let dq = q.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Item] = []
        if !dq.isEmpty {
            for t in store.threads.prefix(8) {
                out.append(Item(id: "mail-\(t.id)", group: "Mail", label: t.lastFrom.name.isEmpty ? t.lastFrom.email : t.lastFrom.name, icon: nil, kbd: nil, avatar: t.lastFrom, sub: t.displaySubject, time: Fmt.time(t.lastMessageAt)) { router.go(.thread(t.id, peek: false)) })
            }
            if !store.threads.isEmpty {
                out.append(Item(id: "search-all", group: "Mail", label: "See all results for “\(q.trimmingCharacters(in: .whitespaces))”", icon: "mail", kbd: nil, avatar: nil, sub: nil, time: nil) { router.go(.search(q.trimmingCharacters(in: .whitespaces))) })
            }
        }
        let theme = app.user?.settings.theme ?? "system"
        // "system" resolves to whatever the Mac is showing, as `prefers-color-scheme` does.
        let dark = theme == "dark" || (theme != "light" && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        var actions: [Item] = [
            Item(id: "act-compose", group: "Actions", label: "Compose a new message", icon: "penSquare", kbd: "c", avatar: nil, sub: nil, time: nil) { Compose.open() },
            Item(id: "act-assistant", group: "Actions", label: "Open the Assistant", icon: "sparkles", kbd: "⌘J", avatar: nil, sub: nil, time: nil) { ui.openAssistant() },
        ]
        if app.googleConfigured {
            actions.append(Item(id: "act-connect", group: "Actions", label: "Connect a Gmail account", icon: "plus", kbd: nil, avatar: nil, sub: nil, time: nil) { GoogleConnect.start(toasts: toasts) })
        }
        actions += [
            Item(id: "act-theme", group: "Actions", label: dark ? "Switch to light theme" : "Switch to dark theme", icon: dark ? "sun" : "moon", kbd: nil, avatar: nil, sub: nil, time: nil) {
                Task { if let u = try? await APIClient.shared.updateMe(settings: ["theme": dark ? "light" : "dark"]) { await app.adopt(user: u) } }
            },
            Item(id: "act-shortcuts", group: "Actions", label: "Keyboard shortcuts", icon: "keyboard", kbd: "?", avatar: nil, sub: nil, time: nil) { ui.shortcutsOpen = true },
        ]
        let go: [Item] = destinations.map { d in
            Item(id: "go-\(d.0)", group: "Jump to", label: d.1, icon: d.2, kbd: d.3, avatar: nil, sub: nil, time: nil) {
                router.go(NavItem(key: d.0, label: d.1, icon: d.2).route)
            }
        }
        func matches(_ i: Item, _ keywords: String) -> Bool {
            dq.isEmpty || i.label.lowercased().contains(dq) || keywords.contains(dq) || dq.split(separator: " ").allSatisfy { (i.label.lowercased() + " " + keywords).contains($0) }
        }
        out += zip(go, destinations).filter { matches($0.0, $0.1.4) }.map(\.0)
        out += actions.filter { matches($0, "") }
        return out
    }

    var body: some View {
        if ui.paletteOpen {
            ZStack {
                W.overlay.ignoresSafeArea().onTapGesture { close() }
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Icon("search", size: 16).foregroundStyle(W.mutedForeground)
                        WTextFieldPlain(placeholder: app.accounts.isEmpty ? "Jump anywhere or run an action…" : "Search mail, jump anywhere, or run an action…", text: $q, autofocus: true)
                        if store.searching { Spinner(size: 14).foregroundStyle(W.mutedForeground) }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .edgeLine(.bottom)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                let list = items
                                if list.isEmpty {
                                    Text(store.searching ? "Searching…" : (q.isEmpty ? "Nothing here." : "Search everything for “\(q)”"))
                                        .font(W.sm).foregroundStyle(W.mutedForeground).frame(maxWidth: .infinity).padding(24)
                                        .onTapGesture { if !q.isEmpty { close(); router.go(.search(q)) } }
                                }
                                let groups = Array(Dictionary(grouping: list, by: \.group).keys.sorted { ["Mail", "Jump to", "Actions"].firstIndex(of: $0) ?? 9 < ["Mail", "Jump to", "Actions"].firstIndex(of: $1) ?? 9 })
                                ForEach(groups, id: \.self) { g in
                                    Text(g).font(W.font(12, 500)).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 6)
                                    ForEach(list.filter { $0.group == g }) { item in
                                        let idx = list.firstIndex { $0.id == item.id } ?? 0
                                        CommandRow(selected: idx == selected) {
                                            HStack(spacing: 8) {
                                                if let a = item.avatar { WAvatar(a, size: 20) }
                                                if let icon = item.icon { Icon(icon, size: 16).foregroundStyle(idx == selected ? W.foreground : W.mutedForeground) }
                                                Text(item.label).font(W.font(14, item.avatar != nil ? 500 : 400)).foregroundStyle(W.foreground).lineLimit(1).frame(maxWidth: item.avatar != nil ? 220 : nil, alignment: .leading)
                                                if let sub = item.sub { Text(sub).font(W.sm).foregroundStyle(W.mutedForeground).lineLimit(1) }
                                                Spacer()
                                                if let t = item.time { Text(t).font(W.xs).foregroundStyle(W.mutedForeground) }
                                                if let k = item.kbd { Text(k).font(W.xs).foregroundStyle(W.mutedForeground) }
                                            }
                                        } action: { close(); item.run() }
                                        .id(item.id)
                                        .onHover { if $0 { selected = idx } }
                                    }
                                    if g != groups.last { WSeparator().padding(.vertical, 4) }
                                }
                            }
                            .padding(4)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: selected) { _, s in if items.indices.contains(s) { proxy.scrollTo(items[s].id) } }
                    }
                }
                .frame(width: 600)
                .background(W.popover)
                .overlay(RoundedRectangle(cornerRadius: W.radiusXl, style: .continuous).strokeBorder(W.popoverRing, lineWidth: 1))
                .rounded(W.radiusXl)
            }
            .onAppear { q = ""; selected = 0; store.clear() }
            .onChange(of: q) { _, _ in selected = 0 }
            .task(id: q) {
                let t = q.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !app.accounts.isEmpty else { store.clear(); return }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await store.run(t)
            }
            .onKeys([
                "Escape": { close() },
                "ArrowDown": { selected = min(selected + 1, max(items.count - 1, 0)) },
                "ArrowUp": { selected = max(selected - 1, 0) },
                "Enter": { if items.indices.contains(selected) { let i = items[selected]; close(); i.run() } else if !q.isEmpty { close(); router.go(.search(q)) } },
            ], priority: 60, whileTyping: true)
            .blockKeys()
        }
    }

    private func close() { ui.paletteOpen = false }
}

/// While an overlay owns the keyboard, page shortcuts stay quiet.
struct BlockKeys: ViewModifier {
    @State private var id: UUID?
    func body(content: Content) -> some View {
        content
            .onAppear { id = KeyBus.shared.register(priority: 50) { _ in true } }
            .onDisappear { if let id { KeyBus.shared.unregister(id) }; id = nil }
    }
}
extension View { func blockKeys() -> some View { modifier(BlockKeys()) } }

/// `?`: every shortcut, in two columns.
struct ShortcutsOverlay: View {
    @Environment(UIState.self) private var ui

    private let groups: [(String, [(String, String)])] = [
        ("Moving around", [("↑ / ↓", "Move through mail"), ("←", "Jump to the sidebar"), ("→", "Open the Assistant"), ("↵", "Open (sidebar: go there)"), ("esc", "Back to the list")]),
        ("Go to", [("⌘K", "Search & commands"), ("⌘B", "Toggle sidebar"), ("⌘J", "Assistant (open / close)")]),
        ("Lists", [("j / k", "Move down / up"), ("↵ or o", "Open thread"), ("x", "Select thread"), ("l", "Reply later"), ("a", "Set aside"), ("z", "Bubble up"), ("u", "Mark unread"), ("#", "Trash"), ("b", "Labels (with selection)"), ("g", "Merge selected")]),
        ("Power through new", [("o", "Start (from the Imbox)"), ("j / k", "Next / previous"), ("r", "Reply inline"), ("l", "Reply later"), ("a", "Set aside"), ("e", "Mark seen"), ("#", "Trash"), ("↵", "Open the full thread"), ("esc", "Back to the Imbox")]),
        ("Calendar", [("0", "Mail ⇄ Calendar"), ("↑ / ↓", "Previous / next"), ("←", "Jump to the sidebar"), ("→", "Open the Assistant"), ("t", "Today"), ("d / w / y", "Day, week, year"), ("n", "New event"), ("j", "Journal"), ("b", "Habits")]),
        ("Everywhere", [("c", "Compose"), ("⌘↵", "Send message"), ("q", "Undo send"), ("i", "Back to Imbox"), ("esc", "Close / clear"), ("?", "This overlay")]),
    ]

    var body: some View {
        if ui.shortcutsOpen {
            ZStack {
                W.overlay.ignoresSafeArea().onTapGesture { ui.shortcutsOpen = false }
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keyboard shortcuts").font(W.font(16, 500)).webLine(16, weight: 500).foregroundStyle(W.foreground)
                        Text("The whole app works without a mouse.").font(W.sm).webLine(14).foregroundStyle(W.mutedForeground)
                    }
// `pt-1` on the grid, over the dialog's `gap-4`.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 32), GridItem(.flexible(), spacing: 32)], alignment: .leading, spacing: 24) {
                        ForEach(groups, id: \.0) { g in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(g.0).font(W.font(12, 500)).foregroundStyle(W.mutedForeground).padding(.bottom, 2)
                                ForEach(g.1, id: \.0) { k in
                                    HStack { Text(k.1).font(W.s13).foregroundStyle(W.foreground); Spacer(); Kbd(k.0) }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(width: 672)
                .background(W.popover)
                .overlay(RoundedRectangle(cornerRadius: W.radiusXl, style: .continuous).strokeBorder(W.popoverRing, lineWidth: 1))
                .rounded(W.radiusXl)
                .overlay(alignment: .topTrailing) {
                    WButton(icon: "x", variant: .ghost, size: .iconSm, muted: true) { ui.shortcutsOpen = false }.padding(8)
                }
            }
            .blockKeys()
        }
    }
}
