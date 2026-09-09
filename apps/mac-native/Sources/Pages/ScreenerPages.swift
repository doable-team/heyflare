import SwiftUI

/// `Screener.tsx`: one card per first-time sender.
struct ScreenerPage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @Environment(\.pageScrollProxy) private var pageScroll
    @State private var store = ScreenerStore()
    @State private var cursor = 0
    @State private var leaving: [String: Bool] = [:]
    /// The width the page gets; with the shell's padding and the sidebar added back it stands
    /// in for the browser viewport that `min-[1100px]:grid-cols-2` measures.
    @State private var pageWidth: CGFloat = 0

    private var columns: Int { pageWidth + 64 + (ui.sidebarOpen ? 256 : 48) >= 1100 ? 2 : 1 }

    private var preferred: ScreenStatus? {
        switch app.user?.settings.defaultScreenTarget { case "feed": return .feed; case "paper_trail": return .paperTrail; case "imbox": return .imbox; default: return nil }
    }

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() } else {
            let waiting = store.entries.count
            PageColumn(width: 1100) {
                PageHeader(title: "The Screener", subtitle: waiting > 0 ? "\(waiting) \(waiting == 1 ? "sender" : "senders") waiting. Say yes and pick where their mail goes, or say no and never hear from them again." : "First-time senders wait here. Nobody waiting right now.") {
                    WButton("Screened out", icon: "shieldOff", variant: .ghost, size: .sm, muted: true) { router.go(.screenedOut) }
                }
                .padding(.horizontal, 8)
                if let error = store.error, store.entries.isEmpty { ErrorStateView(message: error) { Task { await store.load(force: true) } } }
                else if store.loading && store.entries.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top, spacing: 12) { SkeletonBlock(width: 32, height: 32, radius: 4); VStack(alignment: .leading, spacing: 8) { PctSkeleton(pct: 0.4); PctSkeleton(pct: 0.6) }.padding(.top, 4) }
                                SkeletonBlock(height: 56); PctSkeleton(pct: 0.6, height: 28)
                            }
                            .padding(16).background(W.muted40).rounded(W.radiusMd)
                        }
                    }
                } else if waiting == 0 {
                    EmptyStateView(icon: "shieldOff", title: "Nobody at the door.", body: "Every new sender has been dealt with.") {
                        WButton("Back to the Imbox", variant: .ghost, size: .sm) { router.go(.imbox) }
                    }
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), alignment: .leading, spacing: 12) {
                        ForEach(Array(store.entries.enumerated()), id: \.element.id) { i, e in
                            SenderCard(entry: e, focused: i == cursor, leaving: leaving[e.id] != nil, target: store.target(for: e, defaultTarget: preferred),
                                       onTarget: { store.setTarget($0, for: e) }, onDecide: { d, scope in decide(e, d, scope) }, onFocus: { cursor = i })
                                .id(e.id)
                        }
                    }
                    HStack(spacing: 6) {
                        Kbd("j"); Kbd("k"); Text("move"); Text("·").padding(.horizontal, 4); Kbd("y"); Text("let in"); Text("·").padding(.horizontal, 4); Kbd("n"); Text("screen out"); Text("·").padding(.horizontal, 4); Kbd("1"); Kbd("2"); Kbd("3"); Text("pick a place")
                    }
                    .font(W.xs).foregroundStyle(W.mutedForeground).frame(maxWidth: .infinity).padding(.top, 32)
                }
            }
            .background(GeometryReader { g in Color.clear.onChange(of: g.size.width, initial: true) { _, w in pageWidth = w } })
            .task { await store.loadIfNeeded() }
            .syncsWithMail { await store.load(force: true) }
            .onKeys([
                "j": { move(1) }, "k": { move(-1) },
                "ArrowDown": { move(1) }, "ArrowUp": { move(-1) },
                "y": { if let e = current { decide(e, store.target(for: e, defaultTarget: preferred), "all") } },
                "n": { if let e = current { decide(e, .screenedOut, "all") } },
                "1": { if let e = current { store.setTarget(.imbox, for: e) } },
                "2": { if let e = current { store.setTarget(.feed, for: e) } },
                "3": { if let e = current { store.setTarget(.paperTrail, for: e) } },
            ], enabled: !store.entries.isEmpty && ui.region == .content)
            .onChange(of: store.entries.count) { _, n in if cursor >= n { cursor = max(n - 1, 0) } }
        }
    }

    private var current: ScreenerEntry? { store.entries.indices.contains(cursor) ? store.entries[cursor] : nil }

    /// Nowhere left to go: the arrows scroll the page instead of doing nothing; otherwise the
    /// focused card is scrolled into view (`block: "nearest"`).
    private func move(_ delta: Int) {
        let next = min(max(cursor + delta, 0), store.entries.count - 1)
        if next == cursor { PageScroll.by(CGFloat(delta) * 0.25); return }
        cursor = next
        if store.entries.indices.contains(next) { withAnimation(nil) { pageScroll?.scrollTo(store.entries[next].id, anchor: nil) } }
    }

    private func decide(_ e: ScreenerEntry, _ d: ScreenStatus, _ scope: String) {
        guard leaving[e.id] == nil else { return }
        leaving[e.id] = d != .screenedOut
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // A refresh during the fade can have dropped the row already; the decision still
            // goes to the server, there is just nothing to put back if it fails.
            let index = store.index(of: e.id) ?? store.entries.count
            store.remove(e.id)
            leaving[e.id] = nil
            Task {
                do {
                    try await APIClient.shared.decide(contactID: e.contact.id, decision: d, scope: scope)
                    store.persist(); Mail.invalidate()
                } catch {
                    store.insert(e, at: index)
                    Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
    }
}

struct SenderCard: View {
    let entry: ScreenerEntry
    var focused = false
    var leaving = false
    let target: ScreenStatus
    var onTarget: (ScreenStatus) -> Void
    var onDecide: (ScreenStatus, String) -> Void
    var onFocus: () -> Void

    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router

    private var reason: (text: String, icon: String) {
        switch entry.suggestion {
        case .feed: return (entry.threads.contains { $0.snippet.range(of: "unsubscribe", options: .caseInsensitive) != nil } ? "Has an unsubscribe link" : "Looks like a newsletter", "rss")
        case .paperTrail: return ("Looks like a receipt", "receipt")
        default: return ("Probably a person", "userRound")
        }
    }
    private var targetLabel: String { target == .feed ? "The Feed" : target == .paperTrail ? "Paper Trail" : "Imbox" }

    var body: some View {
        let c = entry.contact
        let domain = c.email.split(separator: "@").last.map(String.init) ?? ""
        let previews = entry.threads.prefix(3)
        let acct = app.account(c.accountID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                WAvatar(c.address, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(c.name.isEmpty ? String(c.email.split(separator: "@").first ?? "") : c.name).font(W.font(14, 600)).lineLimit(1)
                        if app.accounts.count > 1, let acct { AccountGlyph(glyph: app.glyph(for: acct.id), label: acct.email) }
                    }
                    Text(c.email).font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1)
                    HStack(spacing: 6) {
                        WBadge(reason.text, icon: reason.icon, variant: .outline, muted: true)
                        if !domain.isEmpty { WBadge("@\(domain)", variant: .outline, muted: true) }
                        Text("\(c.messageCount) message\(c.messageCount == 1 ? "" : "s") · first wrote \(Fmt.time(c.firstSeenAt))").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).lineLimit(1)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16).padding(.top, 16)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(previews) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Button { router.go(.thread(t.id, peek: true)) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(t.displaySubject).font(W.sm).lineLimit(1)
                                if t.hasAttachments { Icon("paperclip", size: 12).foregroundStyle(W.mutedForeground) }
                                Spacer()
                                Text(Fmt.time(t.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !t.snippet.isEmpty { Text(t.snippet).font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1) }
                    }
                    .padding(.vertical, 6)
                }
                if entry.threads.count > 3 { Text("+\(entry.threads.count - 3) more").font(W.xs).foregroundStyle(W.mutedForeground).padding(.vertical, 4) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 8) {
                WToggleGroup(options: [ToggleOption(id: "imbox", label: "Imbox", icon: "inbox", help: "Deliver to Imbox  1"), ToggleOption(id: "feed", label: "The Feed", icon: "rss", help: "Deliver to The Feed  2"), ToggleOption(id: "paper_trail", label: "Paper Trail", icon: "fileText", help: "Deliver to Paper Trail  3")],
                             value: Binding(get: { target.rawValue }, set: { onTarget(ScreenStatus(rawValue: $0) ?? .imbox) }), outline: true)
                HStack(spacing: 4) {
                    if app.accounts.count > 1, let acct {
                        WButton("Just for \(acct.email.split(separator: "@").first ?? "")", variant: .ghost, size: .sm, muted: true, help: "Deliver to \(targetLabel) on \(acct.email) only — other accounts keep asking") { onDecide(target, "account") }
                    }
                    Spacer()
                    WButton("Screen out", icon: "x", variant: .ghost, size: .sm, muted: true, help: "Never see them again  n") { onDecide(.screenedOut, "all") }
                    WButton("Let them in", icon: "check", size: .sm, help: "Deliver to \(targetLabel)  y") { onDecide(target, "all") }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(W.muted40)
        .overlay { if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1) } }
        .rounded(W.radiusMd)
        .opacity(leaving ? 0 : 1)
        .animation(.easeOut(duration: 0.1), value: leaving)
        // `onMouseEnter={onFocus} onClick={onFocus}`
        .onHover { if $0 { onFocus() } }
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
    }
}

/// `ScreenedOut.tsx`.
struct ScreenedOutPage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @Environment(UIState.self) private var ui
    @State private var store = ScreenedOutStore()
    @State private var cursor = -1

    var body: some View {
        let contacts = store.contacts
        PageColumn {
            PageHeader(title: "Screened out", subtitle: contacts.isEmpty ? "People you said no to. Change your mind any time." : "\(contacts.count) \(contacts.count == 1 ? "sender" : "senders") you said no to. Change your mind any time.") {
                WButton("Screener", icon: "shieldOff", variant: .ghost, size: .sm, muted: true) { router.go(.screener) }
            }
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            else if store.loading && contacts.isEmpty { SkeletonRows(compact: true) }
            else if contacts.isEmpty { EmptyStateView(icon: "shieldOff", title: "Nobody's screened out.", body: "Say no in the Screener and they'll be listed here.") }
            ForEach(Array(contacts.enumerated()), id: \.element.id) { i, c in
                ScreenedOutRow(contact: c, focused: cursor == i, working: store.working.contains(c.id)) { status, label in
                    Task { if let e = await store.admit(c, to: status, scope: "all") { Toasts.shared.error(e) } else { Mail.invalidate(); Toasts.shared.success("\(c.name.isEmpty ? c.email : c.name) → \(label)") } }
                }
                .id(c.id)
            }
        }
        .task { await store.load() }
        .itemCursorKeys(ids: contacts.map(\.id), cursor: $cursor) { i in if contacts.indices.contains(i) { router.go(.contact(contacts[i].id)) } }
    }
}

private struct ScreenedOutRow: View {
    let contact: Contact
    var focused = false
    var working = false
    var admit: (ScreenStatus, String) -> Void
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            WAvatar(contact.address, size: 20)
            Button { router.go(.contact(contact.id)) } label: {
                HStack(spacing: 8) {
                    Text(contact.name.isEmpty ? contact.email : contact.name).font(W.sm).lineLimit(1)
                    if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: contact.accountID), label: app.account(contact.accountID)?.email) }
                    Text("\(contact.name.isEmpty ? "" : "\(contact.email) · ")\(contact.messageCount) message\(contact.messageCount == 1 ? "" : "s")\(contact.screenedAt.map { " · screened out \(Fmt.time($0))" } ?? "")").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            WButton("Let them in", trailingIcon: "chevronDown", variant: .ghost, size: .sm, muted: true, expanded: pops.isOpen("so-\(contact.id)")) {
                pops.toggle("so-\(contact.id)", side: .bottom, align: .end) {
                    PopCard(width: 208) {
                        // `DropdownMenuLabel className="text-xs text-muted-foreground font-normal"`
                        Text("Deliver their mail to").font(W.font(12, 400)).webLine(12).foregroundStyle(W.mutedForeground)
                            .padding(.horizontal, 6).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                        MenuItem("Imbox", icon: "inbox") { admit(.imbox, "Imbox") }
                        MenuItem("The Feed", icon: "rss") { admit(.feed, "The Feed") }
                        MenuItem("Paper Trail", icon: "fileText") { admit(.paperTrail, "Paper Trail") }
                    }
                }
            }
            .popAnchor("so-\(contact.id)")
            .disabled(working)
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(focused ? W.muted : (hovering ? W.accent : Color.clear))
        .rounded(W.radiusMd)
        .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
        .onHover { hovering = $0 }
    }
}
