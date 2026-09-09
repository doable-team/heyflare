import SwiftUI
import AppKit

/// cmdk's `command-score`, ported so the palette ranks and filters exactly as the web does:
/// every character of the query has to appear in order, with continuing matches scoring
/// best, word starts next, and jumps inside a word a distant third.
enum CommandScore {
    private static let continueMatch = 1.0
    private static let spaceWordJump = 0.9
    private static let nonSpaceWordJump = 0.8
    private static let characterJump = 0.17
    private static let transposition = 0.1
    private static let penaltySkipped = 0.999
    private static let penaltyCaseMismatch = 0.9999
    private static let penaltyNotComplete = 0.99

    private static let gapChars: Set<Character> = ["\\", "/", "_", "+", ".", "#", "\"", "@", "[", "(", "{", "&"]
    private static func isGap(_ c: Character) -> Bool { gapChars.contains(c) }
    private static func isSpace(_ c: Character) -> Bool { c == "-" || c.isWhitespace }

    private static func format(_ s: String) -> [Character] {
        Array(s.lowercased()).map { isSpace($0) ? " " : $0 }
    }

    static func score(_ value: String, _ query: String, keywords: [String] = []) -> Double {
        let string = keywords.isEmpty ? value : value + " " + keywords.joined(separator: " ")
        let s = Array(string), a = Array(query)
        var memo: [Int: Double] = [:]
        return inner(s, a, format(string), format(query), 0, 0, &memo)
    }

    private static func inner(_ string: [Character], _ abbr: [Character], _ lowerString: [Character], _ lowerAbbr: [Character], _ stringIndex: Int, _ abbrIndex: Int, _ memo: inout [Int: Double]) -> Double {
        if abbrIndex >= abbr.count {
            return stringIndex == string.count ? continueMatch : penaltyNotComplete
        }
        let key = stringIndex &* 4096 &+ abbrIndex
        if let m = memo[key] { return m }
        let abbrChar = lowerAbbr[abbrIndex]
        var index = indexOf(lowerString, abbrChar, from: stringIndex)
        var highScore = 0.0
        while let i = index {
            var score = inner(string, abbr, lowerString, lowerAbbr, i + 1, abbrIndex + 1, &memo)
            if score > highScore {
                if i == stringIndex {
                    score *= continueMatch
                } else if i > 0, isGap(string[i - 1]) {
                    score *= nonSpaceWordJump
                    let breaks = string[stringIndex..<max(stringIndex, i - 1)].filter(isGap).count
                    if breaks > 0, stringIndex > 0 { score *= pow(penaltySkipped, Double(breaks)) }
                } else if i > 0, isSpace(string[i - 1]) {
                    score *= spaceWordJump
                    let breaks = string[stringIndex..<max(stringIndex, i - 1)].filter(isSpace).count
                    if breaks > 0, stringIndex > 0 { score *= pow(penaltySkipped, Double(breaks)) }
                } else {
                    score *= characterJump
                    if stringIndex > 0 { score *= pow(penaltySkipped, Double(i - stringIndex)) }
                }
                if string[i] != abbr[abbrIndex] { score *= penaltyCaseMismatch }
            }
            let prev: Character? = i > 0 ? lowerString[i - 1] : nil
            let nextAbbr: Character? = abbrIndex + 1 < lowerAbbr.count ? lowerAbbr[abbrIndex + 1] : nil
            if let nextAbbr, (score < transposition && prev == nextAbbr) || (nextAbbr == abbrChar && prev != abbrChar) {
                let transposed = inner(string, abbr, lowerString, lowerAbbr, i + 1, abbrIndex + 2, &memo)
                if transposed * transposition > score { score = transposed * transposition }
            }
            if score > highScore { highScore = score }
            index = indexOf(lowerString, abbrChar, from: i + 1)
        }
        memo[key] = highScore
        return highScore
    }

    private static func indexOf(_ chars: [Character], _ c: Character, from: Int) -> Int? {
        guard from < chars.count else { return nil }
        for i in from..<chars.count where chars[i] == c { return i }
        return nil
    }
}

/// ⌘K: search mail, jump anywhere, or run an action.
struct CommandPalette: View {
    @Environment(UIState.self) private var ui
    @Environment(Router.self) private var router
    @Environment(AppState.self) private var app
    @Environment(Toasts.self) private var toasts

    @State private var q = ""
    @State private var store = SearchStore()
    @State private var selected = 0
    @State private var listHeight: CGFloat = 0

    private struct Item: Identifiable {
        let id: String
        let group: String
        /// cmdk's `value`: what the scorer sees.
        let value: String
        let label: String
        let icon: String?
        let kbd: String?
        let avatar: Address?
        let sub: String?
        let time: String?
        let run: () -> Void
    }

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

    private var dq: String { q.trimmingCharacters(in: .whitespaces) }

    /// `CommandPalette.tsx`: the Mail, Jump to and Actions groups, filtered and ranked by
    /// cmdk when there is a query (items by score, then groups by their best score).
    private var items: [Item] {
        var groups: [(String, [Item])] = []
        if !dq.isEmpty {
            var mail: [Item] = []
            for t in store.threads.prefix(8) {
                mail.append(Item(id: "mail-\(t.id)", group: "Mail", value: "mail \(t.id) \(t.subject) \(t.lastFrom.name) \(t.lastFrom.email)", label: t.lastFrom.name.isEmpty ? t.lastFrom.email : t.lastFrom.name, icon: nil, kbd: nil, avatar: t.lastFrom, sub: t.subject.isEmpty ? "(no subject)" : t.subject, time: Fmt.time(t.lastMessageAt)) { router.go(.thread(t.id, peek: false)) })
            }
            if !mail.isEmpty {
                mail.append(Item(id: "search-all", group: "Mail", value: "search-all \(dq)", label: "See all results for “\(dq)”", icon: "mail", kbd: nil, avatar: nil, sub: nil, time: nil) { router.go(.search(dq)) })
                groups.append(("Mail", mail))
            }
        }
        groups.append(("Jump to", destinations.map { d in
            Item(id: "go-\(d.0)", group: "Jump to", value: "go \(d.1) \(d.4)", label: d.1, icon: d.2, kbd: d.3, avatar: nil, sub: nil, time: nil) {
                router.go(NavItem(key: d.0, label: d.1, icon: d.2).route)
            }
        }))
        let theme = app.user?.settings.theme ?? "system"
        // The label reads the setting; the toggle resolves "system" against the OS, as the web does.
        let resolvedDark = theme == "dark" || (theme == "system" && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        var actions: [Item] = [
            Item(id: "act-compose", group: "Actions", value: "act Compose a new message write new email", label: "Compose a new message", icon: "penSquare", kbd: "c", avatar: nil, sub: nil, time: nil) { Compose.open() },
            Item(id: "act-assistant", group: "Actions", value: "act Open the Assistant ai chat help", label: "Open the Assistant", icon: "sparkles", kbd: "⌘J", avatar: nil, sub: nil, time: nil) { ui.openAssistant() },
        ]
        if app.googleConfigured {
            actions.append(Item(id: "act-connect", group: "Actions", value: "act Connect a Gmail account google add account", label: "Connect a Gmail account", icon: "plus", kbd: nil, avatar: nil, sub: nil, time: nil) { GoogleConnect.start(toasts: toasts) })
        }
        if app.microsoftConfigured {
            actions.append(Item(id: "act-connect-ms", group: "Actions", value: "act Connect an Outlook account microsoft outlook office365 add account", label: "Connect an Outlook account", icon: "plus", kbd: nil, avatar: nil, sub: nil, time: nil) { GoogleConnect.start(toasts: toasts, provider: "microsoft") })
        }
        let themeLabel = theme == "dark" ? "Switch to light theme" : "Switch to dark theme"
        actions += [
            Item(id: "act-theme", group: "Actions", value: "act \(themeLabel) dark light mode appearance", label: themeLabel, icon: theme == "dark" ? "sun" : "moon", kbd: nil, avatar: nil, sub: nil, time: nil) {
                Task { if let u = try? await APIClient.shared.updateMe(settings: ["theme": resolvedDark ? "light" : "dark"]) { await app.adopt(user: u) } }
            },
            Item(id: "act-shortcuts", group: "Actions", value: "act Keyboard shortcuts ", label: "Keyboard shortcuts", icon: "keyboard", kbd: "?", avatar: nil, sub: nil, time: nil) { ui.shortcutsOpen = true },
        ]
        groups.append(("Actions", actions))

        if dq.isEmpty { return groups.flatMap(\.1) }
        var ranked: [(String, [Item], Double)] = []
        for (name, list) in groups {
            let scored = list.map { ($0, CommandScore.score($0.value, dq)) }.filter { $0.1 > 0 }
            guard !scored.isEmpty else { continue }
            // A stable sort keeps the original order among equal scores, as the DOM shuffle does.
            let sorted = scored.enumerated().sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }.map(\.element.0)
            ranked.append((name, sorted, scored.map(\.1).max() ?? 0))
        }
        let ordered = ranked.enumerated().sorted { a, b in a.element.2 != b.element.2 ? a.element.2 > b.element.2 : a.offset < b.offset }.map(\.element)
        return ordered.flatMap(\.1)
    }

    var body: some View {
        ZStack {
            if ui.paletteOpen {
                W.overlay.ignoresSafeArea().onTapGesture { close() }.transition(.opacity)
                GeometryReader { geo in
                    // `CommandDialog`: `top-1/3 translate-y-0`, centred horizontally.
                    VStack(spacing: 0) {
                        Color.clear.frame(height: geo.size.height / 3)
                        palette
                            .frame(width: 600)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .animation(.easeOut(duration: 0.1), value: ui.paletteOpen)
    }

    @ViewBuilder
    private var palette: some View {
        let list = items
        VStack(spacing: 0) {
            // `CommandInput`: a 32pt `rounded-lg bg-input/30 border-input/30` box inside `p-1 pb-0`.
            HStack(spacing: 0) {
                Icon("search", size: 16).foregroundStyle(W.foreground).opacity(0.5).padding(.leading, 8).padding(.trailing, 8)
                WTextFieldPlain(placeholder: app.accounts.isEmpty ? "Jump anywhere or run an action…" : "Search mail, jump anywhere, or run an action…", text: $q, autofocus: true)
                    .padding(.leading, 6)
                if store.searching { Spinner(size: 14).foregroundStyle(W.mutedForeground).padding(.trailing, 8) }
            }
            .frame(height: 32)
            .background(W.input.opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.input.opacity(0.3), lineWidth: 1))
            .rounded(W.radiusLg)
            .padding(.horizontal, 4).padding(.top, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if list.isEmpty {
                            // `CommandEmpty`: py-6 text-center text-sm.
                            Group {
                                if store.searching {
                                    Text("Searching…").font(W.sm).foregroundStyle(W.foreground)
                                } else if !dq.isEmpty {
                                    EmptySearchButton(query: dq) { close(); router.go(.search(dq)) }
                                } else {
                                    Text("Nothing here.").font(W.sm).foregroundStyle(W.foreground)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                        let groups = list.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        ForEach(groups, id: \.self) { g in
                            // `CommandGroup`: p-1, heading px-2 py-1.5 text-xs font-medium.
                            VStack(alignment: .leading, spacing: 0) {
                                Text(g).font(W.font(12, 500)).webLine(12).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 6)
                                ForEach(list.filter { $0.group == g }) { item in
                                    let idx = list.firstIndex { $0.id == item.id } ?? 0
                                    row(item, selected: idx == selected)
                                        .id(item.id)
                                        .onHover { if $0 { selected = idx } }
                                }
                            }
                            .padding(4)
                            // cmdk hides separators while there is a query.
                            if g != groups.last, dq.isEmpty { Rectangle().fill(W.border).frame(height: 1) }
                        }
                    }
                    .background(GeometryReader { g in Color.clear.onAppear { listHeight = g.size.height }.onChange(of: g.size.height) { _, h in listHeight = h } })
                }
                .scrollIndicators(.hidden)
                // `max-h-72`: the list hugs its rows and scrolls past 288.
                .frame(height: min(listHeight, 288))
                .onChange(of: selected) { _, s in if list.indices.contains(s) { proxy.scrollTo(list[s].id) } }
            }
        }
        .padding(4)
        .background(W.popover)
        .overlay(RoundedRectangle(cornerRadius: W.radiusXl, style: .continuous).strokeBorder(W.popoverRing, lineWidth: 1))
        .rounded(W.radiusXl)
        .onAppear { q = ""; selected = 0; store.clear() }
        .onChange(of: q) { _, _ in selected = 0 }
        .task(id: q) {
            let t = dq
            guard !t.isEmpty, !app.accounts.isEmpty else { store.clear(); return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await store.run(t)
        }
        .onKeys([
            "Escape": { close() },
            // `<Command loop>`: ↓ at the bottom wraps to the top, ↑ at the top to the bottom.
            "ArrowDown": { let n = items.count; if n > 0 { selected = (selected + 1) % n } },
            "ArrowUp": { let n = items.count; if n > 0 { selected = (selected - 1 + n) % n } },
            "Home": { selected = 0 },
            "End": { selected = max(items.count - 1, 0) },
            // Enter with nothing selected does nothing; the empty state's button is the way out.
            "Enter": { if items.indices.contains(selected) { let i = items[selected]; close(); i.run() } },
        ], priority: 60, whileTyping: true)
        .blockKeys()
    }

    /// `CommandItem`: px-2 py-1.5 text-sm gap-2 rounded-lg, `bg-muted` when selected.
    private func row(_ item: Item, selected: Bool) -> some View {
        CommandRow(selected: selected) {
            HStack(spacing: 8) {
                if let a = item.avatar { WAvatar(a, size: 20) }
                if let icon = item.icon { Icon(icon, size: 16).foregroundStyle(W.foreground) }
                if item.avatar != nil {
                    // `truncate font-medium max-w-[40%]`.
                    Text(item.label).font(W.font(14, 500)).foregroundStyle(W.foreground).lineLimit(1)
                        .frame(maxWidth: (600 - 8 - 8 - 16) * 0.4, alignment: .leading)
                } else {
                    Text(item.label).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                }
                if let sub = item.sub { Text(sub).font(W.sm).foregroundStyle(W.mutedForeground).lineLimit(1) }
                Spacer(minLength: 0)
                // `CommandShortcut`: ml-auto text-xs tracking-widest, foreground when selected.
                if let t = item.time { Text(t).font(W.xs).tracking(1.2).foregroundStyle(selected ? W.foreground : W.mutedForeground) }
                if let k = item.kbd { Text(k).font(W.xs).tracking(1.2).foregroundStyle(selected ? W.foreground : W.mutedForeground) }
            }
        } action: { close(); item.run() }
    }

    private func close() { ui.paletteOpen = false }
}

/// The empty state's "Search everything for …" button: text-sm muted, foreground on hover.
private struct EmptySearchButton: View {
    let query: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text("Search everything for “\(query)”").font(W.sm).foregroundStyle(hovering ? W.foreground : W.mutedForeground).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
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
        ("Lists", [("j / k", "Move down / up"), ("↵ or o", "Open thread"), ("x", "Select thread"), ("l", "Reply later"), ("a", "Set aside"), ("z", "Bubble up"), ("e", "Done (mark seen)"), ("u", "Mark unread"), ("#", "Trash"), ("b", "Labels (with selection)"), ("g", "Merge selected")]),
        ("The Feed", [("↑ / ↓ or j / k", "Scroll"), ("space / PgDn", "Scroll a page"), ("e", "Done with the card you're reading")]),
        ("Power through new", [("o", "Start (from the Imbox)"), ("j / k", "Next / previous"), ("r", "Reply inline"), ("l", "Reply later"), ("a", "Set aside"), ("e", "Mark seen"), ("#", "Trash"), ("↵", "Open the full thread"), ("esc", "Back to the Imbox")]),
        ("Calendar", [("0", "Mail ⇄ Calendar"), ("↑ / ↓", "Previous / next"), ("←", "Jump to the sidebar"), ("→", "Open the Assistant"), ("t", "Today"), ("d / w / y", "Day, week, year"), ("n", "New event"), ("j", "Journal"), ("b", "Habits")]),
        ("Everywhere", [("c", "Compose"), ("⌘↵", "Send message"), ("q", "Undo send"), ("i", "Back to Imbox"), ("esc", "Close / clear"), ("?", "This overlay")]),
    ]

    var body: some View {
        ZStack {
            if ui.shortcutsOpen {
                W.overlay.ignoresSafeArea().onTapGesture { ui.shortcutsOpen = false }.transition(.opacity)
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
                    WButton(icon: "x", variant: .ghost, size: .iconSm) { ui.shortcutsOpen = false }.padding(8)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .blockKeys()
            }
        }
        .animation(.easeOut(duration: 0.1), value: ui.shortcutsOpen)
    }
}
