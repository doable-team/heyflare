import SwiftUI
import AppKit

let statusMeta: [ScreenStatus: (label: String, icon: String)] = [
    .pending: ("In Screener", "shield"), .imbox: ("Imbox", "inbox"), .feed: ("The Feed", "rss"), .paperTrail: ("Paper Trail", "fileText"), .screenedOut: ("Screened out", "shieldOff"),
]

// MARK: - Shared bits (cardKeys.ts and the odd shadcn piece the library pages use)

/// `useItemCursor` in cardKeys.ts: ↑/↓ (or j/k) walk the items, Enter/`o` open the focused one,
/// Page Up/Down scroll by most of the window, and an empty page falls back to scrolling by a
/// quarter so the keys never feel dead. Only listens while the content region has focus.
/// The focused row is kept on screen through the page's own scroll view (`scrollIntoView`).
@MainActor
struct ItemCursorKeys: ViewModifier {
    let ids: [String]
    @Binding var cursor: Int
    var enabled = true
    var onOpen: (Int) -> Void
    @Environment(UIState.self) private var ui
    @Environment(\.pageScrollProxy) private var pageScroll
    /// The key map is captured once when it is installed; the list it walks is not.
    @State private var latest = Latest()

    final class Latest {
        var ids: [String] = []
        var onOpen: (Int) -> Void = { _ in }
    }

    func body(content: Content) -> some View {
        latest.ids = ids
        latest.onOpen = onOpen
        return content
            // Keep the cursor inside the list when items disappear (a draft sent, a clip deleted).
            .onChange(of: ids.count) { _, n in if cursor >= n { cursor = n - 1 } }
            .onChange(of: cursor) { _, c in
                if ids.indices.contains(c) { withAnimation(nil) { pageScroll?.scrollTo(ids[c], anchor: nil) } }
            }
            .onKeys([
                "ArrowDown": { step(1) }, "ArrowUp": { step(-1) }, "j": { step(1) }, "k": { step(-1) },
                "Enter": { open() }, "o": { open() },
                "PageDown": { PageScroll.by(0.9) }, "PageUp": { PageScroll.by(-0.9) },
            ], enabled: enabled && ui.region == .content)
    }

    private func step(_ delta: Int) {
        let n = latest.ids.count
        if n == 0 { PageScroll.by(CGFloat(delta) * 0.25); return }
        cursor = min(max(cursor + delta, 0), n - 1)
    }

    private func open() {
        guard cursor >= 0, latest.ids.indices.contains(cursor) else { return }
        latest.onOpen(cursor)
    }
}

extension View {
    func itemCursorKeys(ids: [String], cursor: Binding<Int>, enabled: Bool = true, onOpen: @escaping (Int) -> Void) -> some View {
        modifier(ItemCursorKeys(ids: ids, cursor: cursor, enabled: enabled, onOpen: onOpen))
    }
}

/// The window's width, for the web's viewport breakpoints (`sm` 640, `lg` 1024).
struct WindowWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat

    func makeNSView(context: Context) -> Hook {
        let v = Hook()
        v.onChange = { w in DispatchQueue.main.async { if abs(w - width) > 0.5 { width = w } } }
        return v
    }
    func updateNSView(_ view: Hook, context: Context) {
        view.onChange = { w in DispatchQueue.main.async { if abs(w - width) > 0.5 { width = w } } }
    }

    final class Hook: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observer: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            guard let window else { return }
            onChange?(window.frame.width)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let window else { return }
                self?.onChange?(window.frame.width)
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

extension View {
    /// Publishes the window width into `width`, so a layout can follow the web's breakpoints.
    func viewportWidth(_ width: Binding<CGFloat>) -> some View {
        background(WindowWidthReader(width: width).frame(width: 0, height: 0))
    }
}

/// `max-w-[60%]` on the first item of a row: the lead is capped at a fraction of the row and
/// the rest take what is left, each truncating in turn. A plain `.frame(maxWidth:)` would
/// expand a short lead to the cap and leave a hole before its neighbour.
struct CappedLeadLayout: Layout {
    var fraction: CGFloat = 0.6
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width } + spacing * CGFloat(max(0, subviews.count - 1))
        let h = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: min(proposal.width ?? ideal, ideal), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var remaining = bounds.width
        for (i, s) in subviews.enumerated() {
            let ideal = s.sizeThatFits(.unspecified).width
            let cap = max(0, i == 0 ? min(ideal, bounds.width * fraction, remaining) : min(ideal, remaining))
            s.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: cap, height: bounds.height))
            x += cap + spacing
            remaining -= cap + spacing
        }
    }
}

/// A `Badge` at `text-[11px] px-1.5` (h-5): the Contacts "In Screener" chip and the Mixed mark.
private struct SmallChip: View {
    let text: String
    var icon: String? = nil
    var outline = false
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Icon(icon, size: 12) }
            Text(text).lineLimit(1)
        }
        .font(W.font(11))
        .foregroundStyle(W.mutedForeground)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(outline ? Color.clear : W.secondary)
        .overlay { if outline { Capsule().strokeBorder(W.border, lineWidth: 1) } }
        .clipShape(Capsule())
    }
}

/// shadcn `SelectItem`: 28pt, `py-1 pr-8 pl-1.5 text-sm gap-1.5`, hover `bg-accent`, and the
/// check mark sits at the right (`absolute right-2 size-4`), not before the icon.
private struct SelectRow: View {
    let label: String
    let icon: String
    let checked: Bool
    var action: () -> Void
    @State private var hovering = false
    @Environment(PopLayerState.self) private var pops

    var body: some View {
        Button {
            pops.closeAll()
            action()
        } label: {
            HStack(spacing: 8) {
                Icon(icon, size: 14).foregroundStyle(W.mutedForeground)
                Text(label).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6).padding(.trailing, 32)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { if checked { Icon("check", size: 16).frame(width: 16, height: 16).padding(.trailing, 8) } }
            .background(hovering ? W.accent : Color.clear)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// shadcn `Textarea` with `bg-muted/40` (the contact's notes), otherwise `WTextArea`.
private struct MutedTextArea: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 72
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(W.sm).foregroundStyle(W.mutedForeground).padding(.horizontal, 10).padding(.vertical, 6)
            }
            TextEditor(text: $text)
                .font(W.sm)
                .foregroundStyle(W.foreground)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        }
        .frame(minHeight: minHeight)
        .background(focused ? W.background : W.muted40)
        .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(focused ? W.ring : Color.clear, lineWidth: 1))
        .rounded(W.radiusMd)
    }
}

/// `SelectTrigger` at rest: `bg-transparent`, but `dark:bg-input/30`.
private let selectRestWash = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.055 * 0.3) : .clear
})

// MARK: - Contacts

/// `Contacts.tsx`: a table of everyone who has written, and where their mail goes.
struct ContactsPage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @State private var store = ContactsStore()

    var body: some View {
        @Bindable var store = store
        let list = store.contacts
        let screened = list.filter { $0.screenStatus != .pending }
        let pending = list.filter { $0.screenStatus == .pending }
        // `res.isLoading`: no answer yet for *this* query — the web keys its cache on the term.
        let loading = store.loading && (!store.fresh || store.answeredQuery != store.query)
        PageColumn {
            PageHeader(title: "Contacts", subtitle: "Everyone who's written to you, and where their mail goes.") {
                HStack(spacing: 8) {
                    Icon("search", size: 14).foregroundStyle(W.mutedForeground)
                    WTextFieldPlain(placeholder: "Search people…", text: $store.query)
                }
                .padding(.horizontal, 10).frame(width: 224, height: 32).background(W.input).rounded(W.radiusMd)
            }
            .padding(.horizontal, -8)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            if loading { SkeletonRows(rows: 8, compact: true) }
            else if list.isEmpty && store.error == nil { EmptyStateView(icon: "shield", title: store.query.isEmpty ? "No one's written yet." : "Nobody by that name.", body: store.query.isEmpty ? "People show up here as their mail arrives, along with where you've decided it goes." : "Try a different spelling, or just part of the address.") }
            if !loading && !screened.isEmpty {
                SectionTitle("People", count: screened.count)
                ContactsTable(list: screened, multi: app.accounts.count > 1)
            }
            if !loading && !pending.isEmpty {
                SectionTitle("Waiting in the Screener", count: pending.count).padding(.top, screened.isEmpty ? 0 : 32)
                ContactsTable(list: pending, multi: app.accounts.count > 1)
            }
        }
        .task { await store.load() }
        .syncsWithMail { await store.load() }
        // The web asks on every keystroke; there is no debounce.
        .onChange(of: store.query) { _, _ in store.search() }
        // `useCardScroll`: this page is a table to read, not a list to walk.
        .cardScrollKeys(enabled: ui.region == .content)
    }
}

/// `table-fixed` with percentage columns: Name 28%, Email the rest, Accounts 12% (when more
/// than one mailbox), Goes to 24%, Last 11%. Every cell carries the table's `p-2`.
private struct ContactsTable: View {
    let list: [Contact]
    let multi: Bool
    @State private var width: CGFloat = 768

    private var name: CGFloat { (width * 0.28).rounded() }
    private var accounts: CGFloat { multi ? (width * 0.12).rounded() : 0 }
    private var goesTo: CGFloat { (width * 0.24).rounded() }
    private var last: CGFloat { (width * 0.11).rounded() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name").frame(width: name, alignment: .leading).padding(.leading, 8)
                Text("Email").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                if multi { Text("Accounts").frame(width: accounts, alignment: .leading).padding(.horizontal, 8) }
                Text("Goes to").frame(width: goesTo, alignment: .leading).padding(.horizontal, 8)
                Text("Last").frame(width: last, alignment: .trailing).padding(.horizontal, 8)
            }
            .font(W.xs).foregroundStyle(W.mutedForeground).frame(height: 28)
            ForEach(list) { c in ContactRow(contact: c, multi: multi, widths: (name, accounts, goesTo, last)) }
        }
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
    }
}

private struct ContactRow: View {
    let contact: Contact
    let multi: Bool
    let widths: (name: CGFloat, accounts: CGFloat, goesTo: CGFloat, last: CGFloat)
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var hovering = false

    private func email(_ id: String) -> String { app.account(id)?.email ?? id }

    var body: some View {
        HStack(spacing: 0) {
            Button { router.go(.contact(contact.id)) } label: {
                HStack(spacing: 10) {
                    WAvatar(contact.address, size: 20)
                    Text(contact.name.isEmpty ? String(contact.email.split(separator: "@").first ?? "") : contact.name).font(W.font(14, 500)).lineLimit(1)
                    if contact.messageCount > 0 { Text("\(contact.messageCount)").font(W.xs).monospacedDigit().foregroundStyle(W.tertiary) }
                }
                .frame(height: 40)
                .frame(width: widths.name - 8, alignment: .leading).padding(.leading, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { router.go(.contact(contact.id)) } label: { Text(contact.email).font(W.sm).foregroundStyle(W.mutedForeground).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                .padding(.horizontal, 8)
            if multi {
                HStack(spacing: 4) {
                    ForEach(contact.accounts.prefix(4), id: \.accountID) { a in AccountGlyph(glyph: app.glyph(for: a.accountID)) }
                    if contact.accounts.count > 4 { Text("+\(contact.accounts.count - 4)").monospacedDigit() }
                }
                .font(W.xs).foregroundStyle(W.mutedForeground)
                .help(contact.accounts.map { email($0.accountID) }.joined(separator: ", "))
                .frame(width: widths.accounts - 16, alignment: .leading).padding(.horizontal, 8)
            }
            HStack(spacing: 6) {
                StatusSelect(contact: contact)
                if contact.mixed == true {
                    SmallChip(text: "Mixed", outline: true)
                        .help(contact.accounts.map { "\(email($0.accountID)): \(statusMeta[$0.screenStatus]?.label ?? "")" }.joined(separator: " · "))
                }
            }
            .frame(width: widths.goesTo - 16, alignment: .leading).padding(.horizontal, 8).clipped()
            Text(Fmt.time(contact.lastSeenAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).frame(width: widths.last - 16, alignment: .trailing).padding(.horizontal, 8)
        }
        .frame(height: 40)
        .background(hovering ? W.muted : Color.clear)
        .onHover { hovering = $0 }
    }
}

/// Inline "where their mail goes" property: a quiet select that mutates on change.
struct StatusSelect: View {
    let contact: Contact
    @Environment(PopLayerState.self) private var pops
    @Environment(Router.self) private var router
    @State private var hovering = false

    var body: some View {
        let m = statusMeta[contact.screenStatus] ?? ("", "")
        if contact.screenStatus == .pending {
            Button { router.go(.screener) } label: { SmallChip(text: "In Screener", icon: "shield") }.buttonStyle(.plain)
        } else {
            let id = "status-\(contact.id)"
            Button {
                pops.toggle(id, side: .bottom, align: .end) {
                    PopCard(width: 176) {
                        ForEach([ScreenStatus.imbox, .feed, .paperTrail, .screenedOut], id: \.self) { s in
                            SelectRow(label: statusMeta[s]!.label, icon: statusMeta[s]!.icon, checked: s == contact.screenStatus) { update(s) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Icon(m.icon, size: 14)
                    Text(m.label).font(W.s13).lineLimit(1)
                    Icon("chevronDown", size: 12).opacity(hovering ? 1 : 0)
                }
                .foregroundStyle(hovering || pops.isOpen(id) ? W.foreground : W.mutedForeground)
                .padding(.horizontal, 6).frame(height: 28)
                // `bg-transparent` at rest in light mode, `dark:bg-input/30` in dark.
                .background(hovering || pops.isOpen(id) ? W.muted : selectRestWash)
                .rounded(W.radiusMd)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popAnchor(id)
            .onHover { hovering = $0 }
        }
    }

    private func update(_ s: ScreenStatus) {
        Task {
            do { _ = try await APIClient.shared.updateContact(contact.id, screenStatus: s); Mail.invalidate() }
            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
}

/// `/contacts/email/:email` → the contact's page. The `account` query parameter rides along,
/// as it does on the web; the route carries no `name`, so that one cannot.
struct ContactByEmailPage: View {
    let email: String
    var account: String? = nil
    @Environment(Router.self) private var router
    @State private var error: String?
    var body: some View {
        Group {
            if let error { ErrorStateView(message: error) }
            else { Text("Opening contact…").font(W.sm).foregroundStyle(W.mutedForeground).padding(24) }
        }
        .task {
            do {
                struct R: Decodable { let id: String }
                var query: [String: String?] = ["email": email]
                if let account, !account.isEmpty { query["account_id"] = account }
                let r = try await APIClient.shared.get("/api/contacts/by-email", query: query, as: R.self)
                router.replace(.contact(r.id))
            } catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
        }
    }
}

/// `ContactDetail.tsx`.
struct ContactDetailPage: View {
    let contactID: String
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var store = ContactDetailStore()
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var notes = ""
    @State private var saveState = "idle"
    @State private var loaded = false
    @State private var autosave: Task<Void, Never>?
    /// `DecisionScope`: whether a screening / bundling change applies to every mailbox or
    /// only the one it came from. Page state, as on the web — not remembered.
    @State private var scope = "all"
    @State private var emailHover = false

    private let blurb: [ScreenStatus: String] = [
        .pending: "Still waiting at the door. Decide in the Screener, or pick a place here.",
        .imbox: "Their mail lands in your Imbox, front and centre.",
        .feed: "Their mail goes to The Feed — browse it when you feel like it.",
        .paperTrail: "Their mail files itself into the Paper Trail.",
        .screenedOut: "Their mail never reaches you. They won't know.",
    ]

    private func email(_ id: String) -> String { app.account(id)?.email ?? id }

    var body: some View {
        if let error = store.error { ErrorStateView(message: error) { Task { await store.load(id: contactID) } } }
        else if store.fresh, let d = store.detail {
            let c = d.contact
            let status = c.screenStatus
            let multi = app.accounts.count > 1
            PageColumn {
                WButton("Back", icon: "arrowLeft", variant: .ghost, size: .sm, muted: true, kbd: "esc") { router.back() }.padding(.bottom, 16)
                HStack(alignment: .top, spacing: 16) {
                    WAvatar(c.address, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(String(c.email.split(separator: "@").first ?? ""), text: $name)
                            .textFieldStyle(.plain).font(W.font(24, 600)).tracking(-0.48).foregroundStyle(W.foreground)
                            .focused($nameFocused)
                            .onSubmit { commitName(c) }
                            // The web's input saves on blur too, not only on Enter.
                            .onChange(of: nameFocused) { was, now in if was && !now { commitName(c) } }
                        FlowLayout(spacing: 8) {
                            // `<a href="mailto:…">`, hover → foreground.
                            Button { if let url = URL(string: "mailto:\(c.email)") { NSWorkspace.shared.open(url) } } label: {
                                Text(c.email).font(W.sm).foregroundStyle(emailHover ? W.foreground : W.mutedForeground)
                            }
                            .buttonStyle(.plain).onHover { emailHover = $0 }
                            WBadge(String(c.email.split(separator: "@").last ?? ""), variant: .outline, muted: true)
                            if multi {
                                ForEach(c.accounts, id: \.accountID) { a in
                                    HStack(spacing: 4) { AccountGlyph(glyph: app.glyph(for: a.accountID)); Text(email(a.accountID)) }.font(W.xs).foregroundStyle(W.mutedForeground)
                                }
                            }
                        }
                    }
                    Spacer()
                    WButton("Write", icon: "penSquare", variant: .outline, size: .sm) { Compose.open(ComposerInitial(to: [c.address])) }
                }
                .padding(.horizontal, 8)

                VStack(alignment: .leading, spacing: 4) {
                    property("Messages") { Text("\(c.messageCount) · first seen \(Fmt.date(c.firstSeenAt)) · last \(Fmt.relative(c.lastSeenAt))").font(W.sm).monospacedDigit().padding(.top, 6) }
                    property("Mail goes to") {
                        VStack(alignment: .leading, spacing: 6) {
                            WToggleGroup(options: [ScreenStatus.imbox, .feed, .paperTrail, .screenedOut].map { ToggleOption(id: $0.rawValue, label: statusMeta[$0]!.label, icon: statusMeta[$0]!.icon) },
                                         value: Binding(get: { status == .pending ? "" : status.rawValue }, set: { v in Task { if let e = await store.save(id: contactID, screenStatus: ScreenStatus(rawValue: v), scope: scope) { Toasts.shared.error(e) } else { Mail.invalidate() } } }))
                            Text(blurb[status] ?? "").font(W.s13).foregroundStyle(W.mutedForeground)
                        }
                    }
                    if c.accounts.count > 1 {
                        property("Applies to") {
                            VStack(alignment: .leading, spacing: 6) {
                                WToggleGroup(options: [ToggleOption(id: "all", label: "All accounts"), ToggleOption(id: "account", label: "Only \(app.account(c.accountID)?.email ?? "this account")")], value: $scope)
                                if c.mixed == true {
                                    Text(c.accounts.map { "\(statusMeta[$0.screenStatus]?.label ?? "") on \(email($0.accountID))" }.joined(separator: " · ")).font(W.s13).foregroundStyle(W.mutedForeground)
                                }
                            }
                        }
                    }
                    property("Bundled up") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                WSwitch(on: Binding(get: { c.bundled }, set: { on in Task { if let e = await store.save(id: contactID, bundled: on, scope: scope) { Toasts.shared.error(e) } else { Mail.invalidate() } } }))
                                    .disabled(status != .imbox && status != .paperTrail)
                                HStack(spacing: 6) { Icon("layers", size: 14).foregroundStyle(W.mutedForeground); Text(c.bundled ? "Bundled up" : "Not bundled").font(W.sm) }
                            }
                            .opacity(status == .imbox || status == .paperTrail ? 1 : 0.6)
                            .padding(.top, 6)
                            Text(status == .imbox || status == .paperTrail ? "All their mail shows as one row in the \(status == .imbox ? "Imbox" : "Paper Trail"), no matter how much they send." : "Bundles work for senders delivered to the Imbox or the Paper Trail.").font(W.s13).foregroundStyle(W.mutedForeground)
                        }
                    }
                    property("Notes") {
                        ZStack(alignment: .topTrailing) {
                            MutedTextArea(placeholder: "Met at the conference. Owes me a coffee.", text: $notes, minHeight: 72)
                            HStack(spacing: 4) {
                                if saveState == "saving" { Text("Saving…") } else if saveState == "saved" { Icon("check", size: 11); Text("Saved") }
                            }
                            .font(W.font(11)).foregroundStyle(W.mutedForeground).padding(8).opacity(saveState == "idle" ? 0 : 1)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 24).padding(.bottom, 16)
                .edgeLine(.bottom)

                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle("Conversations", count: d.threads.count)
                    ThreadListView(sections: [ListSection(threads: d.threads, emptyTitle: "Nothing between you two yet.", emptyBody: "Threads with this person will collect here.")], showBucket: true)
                }
                .padding(.top, 24)
            }
            .onAppear { if !loaded { loaded = true; name = c.name; notes = c.notes } }
            .onChange(of: notes) { _, n in
                guard loaded, n != c.notes else { return }
                saveState = "saving"
                autosave?.cancel()
                autosave = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    if await store.save(id: contactID, notes: n) == nil { saveState = "saved"; try? await Task.sleep(for: .seconds(2)); if saveState == "saved" { saveState = "idle" } } else { saveState = "idle" }
                }
            }
            // The web shows the `esc` hint but binds no Escape handler on this page.
            .syncsWithMail { await store.load(id: contactID) }
        } else {
            // `Skeleton h-6 w-20 mb-6`, then the 40pt avatar beside `h-7 w-1/2` and `h-4 w-1/3`.
            PageColumn {
                SkeletonBlock(width: 80, height: 24).padding(.bottom, 24)
                HStack(alignment: .top, spacing: 16) {
                    SkeletonBlock(width: 40, height: 40, radius: 4)
                    GeometryReader { g in
                        VStack(alignment: .leading, spacing: 12) { SkeletonBlock(width: g.size.width / 2, height: 28); SkeletonBlock(width: g.size.width / 3, height: 16) }
                    }
                    .frame(height: 56)
                }
            }
            .padding(.horizontal, 8)
            .task { await store.load(id: contactID) }
        }
    }

    private func property<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(W.s13).foregroundStyle(W.mutedForeground).frame(width: 112, alignment: .leading).padding(.top, 6)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
    }

    private func commitName(_ c: Contact) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n != c.name else { return }
        Task { if let e = await store.save(id: contactID, name: n) { Toasts.shared.error(e) } }
    }
}

// MARK: - Clips

struct ClipsPage: View {
    @Environment(Router.self) private var router
    @State private var store = ClipsStore()
    @State private var cursor = -1

    var body: some View {
        let list = store.clips
        PageColumn {
            PageHeader(title: "Clips", subtitle: "Bits of text you saved. Codes, addresses, the good sentence.").padding(.horizontal, -8)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            if !store.fresh { SkeletonRows(rows: 5) }
            else if list.isEmpty && store.error == nil { EmptyStateView(icon: "scissors", title: "Nothing clipped yet.", body: "Select any text inside an email and hit Save clip. It'll wait here so you never dig for it again.") }
            if store.fresh {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, c in ClipRow(clip: c, focused: cursor == i) { Task { await store.load() } }.id(c.id) }
                }
            }
        }
        .task { await store.load() }
        .syncsWithMail { await store.load() }
        .itemCursorKeys(ids: list.map(\.id), cursor: $cursor) { i in router.go(.thread(list[i].threadID, peek: false)) }
    }
}

private struct ClipRow: View {
    let clip: Clip
    var focused = false
    var onDeleted: () -> Void
    @Environment(Router.self) private var router
    @State private var hovering = false
    @State private var copied = false
    @State private var leaving = false

    var body: some View {
        let text = clip.text
        let codeLike = text.count < 80 && text.trimmingCharacters(in: .whitespaces).range(of: #"^[A-Z0-9\-]{4,24}$"#, options: .regularExpression) != nil
        VStack(alignment: .leading, spacing: 6) {
            if codeLike {
                Text(text.trimmingCharacters(in: .whitespaces)).font(W.mono(16)).tracking(1).textSelection(.enabled).padding(.vertical, 4)
            } else {
                Text(text).font(W.sm).lineSpacing(5).lineLimit(6).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button { router.go(.thread(clip.threadID, peek: false)) } label: {
                    HStack(spacing: 6) { Icon("messageSquare", size: 12); Text(clip.threadSubject ?? "Open thread").lineLimit(1).frame(maxWidth: 280, alignment: .leading) }
                }
                .buttonStyle(.plain)
                Text("·").foregroundStyle(W.tertiary)
                Text(Fmt.date(clip.createdAt)).monospacedDigit()
                Spacer()
                HStack(spacing: 0) {
                    WButton(icon: copied ? "check" : "copy", variant: .ghost, size: .iconXs, muted: true, help: copied ? "Copied" : "Copy") {
                        Platform.copy(text); copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                    }
                    WButton(icon: "trash2", variant: .ghost, size: .iconXs, muted: true, help: "Delete") {
                        leaving = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Task { do { try await APIClient.shared.deleteClip(clip.id); onDeleted() } catch { leaving = false; Toasts.shared.error(error.localizedDescription) } } }
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
            .font(W.xs).foregroundStyle(W.mutedForeground)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? W.muted : Color.clear)
        .overlay { if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.ring, lineWidth: 1) } }
        .rounded(W.radiusMd)
        .opacity(leaving ? 0 : 1)
        .onHover { hovering = $0 }
    }
}

// MARK: - Collections

struct CollectionsPage: View {
    @Environment(Router.self) private var router
    @Environment(DialogState.self) private var dialogs
    @State private var store = CollectionsStore()
    @State private var cursor = -1

    var body: some View {
        let list = store.collections
        PageColumn {
            PageHeader(title: "Collections", subtitle: "Bundle related threads and files into one tidy place.") {
                WButton("New", icon: "plus", variant: .ghost, size: .sm, muted: true) { newCollection() }
            }
            .padding(.horizontal, -8)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            if !store.fresh { SkeletonRows(rows: 4, compact: true) }
            else if list.isEmpty && store.error == nil { EmptyStateView(icon: "folderOpen", title: "No collections yet.", body: "Gather every thread and attachment about one thing, so you stop hunting across your mail.") { WButton("Start one", icon: "plus", variant: .outline, size: .sm) { newCollection() } } }
            if store.fresh {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                    CollectionRow(collection: c, focused: cursor == i).id(c.id)
                }
            }
        }
        .task { await store.load() }
        .itemCursorKeys(ids: list.map(\.id), cursor: $cursor) { i in router.go(.collection(list[i].id)) }
    }

    private func newCollection() {
        dialogs.present("new-collection", width: 448) {
            CollectionForm(title: "New collection", description: "A project, a trip, a house move — anything with a lot of email around it.", submit: "Create") { name, desc in
                do {
                    _ = try await APIClient.shared.post("/api/collections", body: ["name": name, "description": desc], as: MailCollection.self)
                    await store.load()
                    dialogs.dismiss("new-collection")
                } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
            } onCancel: { dialogs.dismiss("new-collection") }
        }
    }
}

/// `NewCollectionModal`, and the edit dialog on a collection's page. The two differ in copy:
/// the new form asks "What's it for?" with placeholders and an "Optional." note; the edit
/// form is plain "Name" / "Description" with neither.
struct CollectionForm: View {
    let title: String
    var description: String? = nil
    var submit: String
    var initialName = ""
    var initialDesc = ""
    var descLabel = "What's it for?"
    var namePlaceholder = "Kitchen renovation"
    var descPlaceholder = "Quotes, contractor threads, the permit saga…"
    var hint: String? = "Optional."
    var onSubmit: (String, String) async -> Void
    var onCancel: () -> Void
    @State private var name = ""
    @State private var desc = ""
    @State private var busy = false

    var body: some View {
        FormDialog(title: title, description: description) {
            VStack(alignment: .leading, spacing: 16) {
                // `<form onSubmit>`: Enter in the Name field submits.
                VStack(alignment: .leading, spacing: 6) { FieldLabel("Name"); WTextField(placeholder: namePlaceholder, text: $name, onSubmit: { send() }, autofocus: true) }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(descLabel)
                    WTextArea(placeholder: descPlaceholder, text: $desc, minHeight: 72)
                    if let hint { Text(hint).font(W.xs).foregroundStyle(W.mutedForeground) }
                }
            }
        } footer: {
            WButton("Cancel", variant: .ghost, action: onCancel)
            WButton(submit) { send() }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
        .onAppear { name = initialName; desc = initialDesc }
    }

    private func send() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !busy else { return }
        busy = true
        Task { await onSubmit(n, desc.trimmingCharacters(in: .whitespaces)); busy = false }
    }
}

private struct CollectionRow: View {
    let collection: MailCollection
    var focused = false
    @Environment(Router.self) private var router
    @State private var hovering = false
    var body: some View {
        Button { router.go(.collection(collection.id)) } label: {
            HStack(spacing: 12) {
                Icon("folderOpen", size: 16).foregroundStyle(W.mutedForeground).frame(width: 20)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(collection.name).font(W.font(14, 500)).lineLimit(1)
                    if !collection.description.isEmpty { Text(collection.description).font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1) }
                }
                Spacer()
                HStack(spacing: 12) {
                    HStack(spacing: 4) { Icon("messagesSquare", size: 12); Text("\(collection.threadCount)") }
                    HStack(spacing: 4) { Icon("paperclip", size: 12); Text("\(collection.fileCount)") }
                    Text(Fmt.relative(collection.updatedAt)).frame(width: 80, alignment: .trailing).lineLimit(1)
                }
                .font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
            }
            .padding(.horizontal, 8).frame(height: 44)
            .background(focused || hovering ? W.muted : Color.clear)
            .rounded(W.radiusMd)
            .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct CollectionDetailPage: View {
    let collectionID: String
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @Environment(DialogState.self) private var dialogs
    @State private var store = CollectionDetailStore()

    var body: some View {
        if let error = store.error { ErrorStateView(message: error) { Task { await store.load(id: collectionID) } } }
        else if store.fresh, let d = store.detail {
            let c = d.collection
            PageColumn {
                WButton("Collections", icon: "arrowLeft", variant: .ghost, size: .sm, muted: true) { router.go(.collections) }.padding(.bottom, 16)
                HStack(alignment: .top, spacing: 12) {
                    Icon("folderOpen", size: 22).foregroundStyle(W.mutedForeground).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.name).font(W.font(24, 600)).tracking(-0.48)
                        if !c.description.isEmpty { Text(c.description).font(W.sm).foregroundStyle(W.mutedForeground) }
                        HStack(spacing: 8) {
                            WBadge("\(d.threads.count) thread\(d.threads.count == 1 ? "" : "s")", icon: "messagesSquare", variant: .secondary, muted: true)
                            WBadge("\(d.files.count) file\(d.files.count == 1 ? "" : "s")", icon: "paperclip", variant: .secondary, muted: true)
                            Text("updated \(Fmt.relative(c.updatedAt))").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
                        }
                        .padding(.top, 4)
                    }
                    Spacer()
                    WButton(icon: "moreHorizontal", variant: .ghost, size: .iconSm, muted: true, expanded: pops.isOpen("col-more"), help: "More") {
                        pops.toggle("col-more", side: .bottom, align: .end) {
                            PopCard(width: 192) {
                                MenuItem("Rename & describe", icon: "pencil") {
                                    dialogs.present("edit-collection", width: 448) {
                                        CollectionForm(title: "Edit collection", submit: "Save", initialName: c.name, initialDesc: c.description, descLabel: "Description", namePlaceholder: "", descPlaceholder: "", hint: nil) { name, desc in
                                            do { _ = try await APIClient.shared.patch("/api/collections/\(c.id)", body: ["name": name, "description": desc], as: MailCollection.self); await store.load(id: collectionID); dialogs.dismiss("edit-collection") }
                                            catch { Toasts.shared.error(error.localizedDescription) }
                                        } onCancel: { dialogs.dismiss("edit-collection") }
                                    }
                                }
                                MenuSeparator()
                                MenuItem("Delete collection", icon: "trash2") {
                                    dialogs.confirm(title: "Delete this collection?", description: "Threads and files stay where they are; only the grouping goes away.", action: "Delete") {
                                        Task {
                                            do { try await APIClient.shared.delete("/api/collections/\(c.id)"); router.go(.collections) }
                                            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .popAnchor("col-more")
                }
                .padding(.horizontal, 8).padding(.bottom, 24)

                SectionTitle("Threads", count: d.threads.count)
                ThreadListView(sections: [ListSection(threads: d.threads, emptyTitle: "Nothing in here yet.", emptyBody: "Add threads from any thread's More menu, or select a few and use the bulk bar.")], showBucket: true)
                if !d.threads.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(d.threads) { t in
                            Button { removeThread(t, from: c) } label: {
                                HStack(spacing: 4) { Text(t.displaySubject).lineLimit(1).frame(maxWidth: 260); Icon("x", size: 12) }
                                    .font(W.xs).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).frame(height: 20).overlay(Capsule().strokeBorder(W.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain).help("Remove from collection")
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 8)
                }
                SectionTitle("Files", count: d.files.count).padding(.top, 32)
                if d.files.isEmpty { Text("No attachments in these threads.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 12) }
                else { FileGrid(files: d.files, cursor: -1, rowSpacing: 12) }
            }
            .syncsWithMail { await store.load(id: collectionID) }
        } else {
            // `h-6 w-24 mb-6`, `h-8 w-1/2 mb-3`, `h-4 w-1/3 mb-8`, then two `h-10 w-full` rows.
            PageColumn {
                GeometryReader { g in
                    VStack(alignment: .leading, spacing: 0) {
                        SkeletonBlock(width: 96, height: 24).padding(.bottom, 24)
                        SkeletonBlock(width: g.size.width / 2, height: 32).padding(.bottom, 12)
                        SkeletonBlock(width: g.size.width / 3, height: 16).padding(.bottom, 32)
                        SkeletonBlock(height: 40).padding(.bottom, 4)
                        SkeletonBlock(height: 40)
                    }
                }
                .frame(height: 24 + 24 + 32 + 12 + 16 + 32 + 40 + 4 + 40)
            }
            .padding(.horizontal, 8)
            .task { await store.load(id: collectionID) }
        }
    }

    /// `removeThread`: a neutral `toast()` once the server agrees, an error toast otherwise.
    private func removeThread(_ t: ThreadSummary, from c: MailCollection) {
        Task {
            do {
                try await APIClient.shared.postIgnoringResult("/api/threads/bulk", body: ["thread_ids": [t.id], "action": "collections", "remove": [c.id]])
                Mail.invalidate()
                Toasts.shared.show("Removed “\(t.displaySubject)”")
                await store.load(id: collectionID)
            } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
}

// MARK: - Files

/// `grid-cols-2 sm:grid-cols-3 lg:grid-cols-4`, by the window's width.
private func fileColumns(for viewport: CGFloat) -> Int { viewport >= 1024 ? 4 : viewport >= 640 ? 3 : 2 }

/// `<a href={url} target="_blank">`: the browser opens or previews the file in a new tab. Here
/// the bytes land in a temporary file and the Finder's default app opens it.
@MainActor
func openAttachment(_ file: Attachment) {
    Task {
        do {
            let data = try await APIClient.shared.data(path: "/api/messages/\(file.messageID)/attachments/\(file.id)", query: file.accountID.map { ["account_id": $0] } ?? [:])
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heyflare-files/\(file.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = file.filename.isEmpty ? "attachment" : file.filename.replacingOccurrences(of: "/", with: "-")
            let url = dir.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? "Couldn't open that.") }
    }
}

struct FilesPage: View {
    @State private var store = FilesStore()
    @State private var cursor = -1
    @State private var viewport: CGFloat = 1200

    var body: some View {
        @Bindable var store = store
        let all = store.files
        let list = store.visible
        let columns = fileColumns(for: viewport)
        PageColumn {
            PageHeader(title: "Files", subtitle: "Every attachment anyone has ever sent you, in one place.") {
                if !all.isEmpty { Text("\(all.count) files · \(Fmt.size(store.totalBytes))").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground) }
            }
            .padding(.horizontal, -8)
            WToggleGroup(options: FileFilter.allCases.map { ToggleOption(id: $0.rawValue, label: $0.title) }, value: Binding(get: { store.filter.rawValue }, set: { store.filter = FileFilter(rawValue: $0) ?? .all }))
                .padding(.horizontal, 8).padding(.bottom, 16)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.refresh() } } }
            if store.loading {
                // Eight `aspect-[4/5]` tiles in the same responsive grid.
                GeometryReader { g in
                    let colW = (g.size.width - 16 - 12 * CGFloat(columns - 1)) / CGFloat(columns)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                        ForEach(0..<8, id: \.self) { _ in SkeletonBlock(height: colW * 1.25) }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: skeletonHeight(columns: columns))
            } else if list.isEmpty && store.error == nil {
                EmptyStateView(icon: "file", title: store.filter == .all ? "No files yet." : "No \(store.filter.title.lowercased()) here.", body: store.filter == .all ? "Attachments show up here as your mail syncs." : "Try another type, or clear the filter.")
            }
            FileGrid(files: list, cursor: cursor, columns: columns)
            LoadMore(hasMore: store.hasMore, loading: store.loadingMore) { Task { await store.loadMore() } }
        }
        .viewportWidth($viewport)
        .task { await store.firstLoad() }
        .itemCursorKeys(ids: list.map(\.id), cursor: $cursor) { i in openAttachment(list[i]) }
    }

    private func skeletonHeight(columns: Int) -> CGFloat {
        let colW = (768 - 16 - 12 * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = CGFloat((8 + columns - 1) / columns)
        return rows * colW * 1.25 + (rows - 1) * 12
    }
}

struct FileGrid: View {
    let files: [Attachment]
    var cursor: Int
    /// `gap-y-5` on the Files page, `gap-3` on a collection's.
    var rowSpacing: CGFloat = 20
    var columns: Int? = nil
    @State private var viewport: CGFloat = 1200

    var body: some View {
        let n = columns ?? fileColumns(for: viewport)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: n), alignment: .leading, spacing: rowSpacing) {
            ForEach(Array(files.enumerated()), id: \.element.id) { i, f in FileTile(file: f, focused: cursor == i).id(f.id) }
        }
        .padding(.horizontal, 8)
        .viewportWidth($viewport)
    }
}

struct FileTile: View {
    let file: Attachment
    var focused = false
    @Environment(Router.self) private var router
    @State private var hovering = false
    @State private var image: PlatformImage?

    private var kind: FileKind { FileKind.of(mimeType: file.mimeType, filename: file.filename) }
    private var ext: String { (file.filename as NSString).pathExtension.uppercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                W.muted
                if let image { Image(platformImage: image).resizable().scaledToFill() }
                else {
                    VStack(spacing: 6) {
                        Icon(kind.lucide, size: 24)
                        if !ext.isEmpty { Text(ext).font(W.font(11)).tracking(0.5) }
                    }
                    .foregroundStyle(W.mutedForeground)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .rounded(W.radiusMd)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { save() } label: { Icon("download", size: 14).foregroundStyle(W.mutedForeground).frame(width: 28, height: 28).background(W.background.opacity(0.9)).rounded(W.radiusMd) }
                        .buttonStyle(.plain).padding(6).help("Download")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { openAttachment(file) }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename.isEmpty ? "attachment" : file.filename).font(W.font(13, 500)).lineLimit(1).help(file.filename)
                Text("\(Fmt.size(file.size)) · \(Fmt.date(file.createdAt))").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).lineLimit(1)
                if file.from != nil || file.threadSubject != nil, let tid = file.threadID {
                    Button { router.go(.thread(tid, peek: false)) } label: {
                        HStack(spacing: 4) { Icon("messageSquare", size: 11); Text([file.from?.display, file.threadSubject].compactMap { $0 }.joined(separator: " · ")).lineLimit(1) }
                            .font(W.xs).foregroundStyle(W.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2).padding(.top, 8)
        }
        .overlay { if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.ring, lineWidth: 1) } }
        .onHover { hovering = $0 }
        .task {
            guard kind == .image else { return }
            if let data = try? await APIClient.shared.data(path: "/api/messages/\(file.messageID)/attachments/\(file.id)", query: file.accountID.map { ["account_id": $0] } ?? [:]) { image = PlatformImage(data: data) }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.filename
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task {
            do {
                let data = try await APIClient.shared.data(path: "/api/messages/\(file.messageID)/attachments/\(file.id)", query: file.accountID.map { ["account_id": $0] } ?? [:])
                try data.write(to: target, options: .atomic)
                Toasts.shared.show("Saved \(file.filename)")
            } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? "Couldn't download that.") }
        }
    }
}

// MARK: - Labels

struct LabelsPage: View {
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var store = LabelsStore()
    @State private var name = ""
    @State private var color = labelShades[0]
    @State private var cursor = -1
    @State private var creating = false

    var body: some View {
        let list = store.labels
        PageColumn {
            PageHeader(title: "Labels", subtitle: "Light-touch tags for cross-cutting stuff. Press b on any thread to add one.").padding(.horizontal, -8)
            HStack(spacing: 12) {
                ShadeButton(id: "new-label-shade", color: $color)
                WTextFieldPlain(placeholder: "New label…", text: $name).onSubmit { create() }
                WButton("Add", icon: "plus", variant: .ghost, size: .sm, muted: true) { create() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
            .padding(.horizontal, 8).frame(height: 40).background(W.muted40).rounded(W.radiusMd).padding(.bottom, 16)
            if let error = store.error { ErrorStateView(message: error) { Task { await store.load() } } }
            if !store.fresh { SkeletonRows(rows: 4, compact: true) }
            else if list.isEmpty && store.error == nil { EmptyStateView(icon: "tag", title: "No labels yet.", body: "Make one above.", compact: true) }
            if store.fresh {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, l in LabelRow(label: l, focused: cursor == i) { Task { await store.load() } }.id(l.id) }
            }
        }
        .task { await store.load() }
        .itemCursorKeys(ids: list.map(\.id), cursor: $cursor) { i in router.go(.label(list[i].id)) }
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !creating else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                _ = try await APIClient.shared.post("/api/labels", body: ["name": n, "color": color], as: MailLabel.self)
                name = ""; color = labelShades[(store.labels.count + 1) % labelShades.count]
                await store.load()
            } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
}

/// `Shades` behind a swatch button (`size-6 hover:bg-accent`). The picked shade carries a
/// check and a 2pt foreground outline set 1pt off its edge.
struct ShadeButton: View {
    let id: String
    @Binding var color: String
    @Environment(PopLayerState.self) private var pops
    @State private var hovering = false
    var body: some View {
        Button {
            pops.toggle(id, side: .bottom, align: .start) {
                PopCard(padding: 8) {
                    HStack(spacing: 6) {
                        ForEach(labelShades, id: \.self) { c in
                            Button { color = c; pops.closeAll() } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(colorFromHex(c))
                                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(W.foreground.opacity(0.15), lineWidth: 1)
                                    if color == c { Icon("check", size: 12, strokeWidth: 3).foregroundStyle(.white).blendMode(.difference) }
                                }
                                .frame(width: 24, height: 24)
                                .overlay { if color == c { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(W.foreground, lineWidth: 2).padding(-3) } }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(colorFromHex(color)).overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(W.foreground.opacity(0.15), lineWidth: 1)).frame(width: 14, height: 14)
                .frame(width: 24, height: 24).background(hovering ? W.accent : Color.clear).rounded(4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popAnchor(id)
        .onHover { hovering = $0 }
        .help("Shade")
    }
}

private struct LabelRow: View {
    let label: MailLabel
    var focused = false
    var onChanged: () -> Void
    @Environment(Router.self) private var router
    @Environment(DialogState.self) private var dialogs
    @State private var name = ""
    @FocusState private var labelFocused: Bool
    @State private var color = ""
    @State private var hovering = false
    @State private var threadsHover = false

    var body: some View {
        HStack(spacing: 12) {
            ShadeButton(id: "shade-\(label.id)", color: $color).onChange(of: color) { _, c in if !c.isEmpty, c != label.color { patch(["color": c]) } }
            TextField("Label name", text: $name).textFieldStyle(.plain).font(W.font(14, 500)).foregroundStyle(W.foreground).onSubmit { labelFocused = false }
                .focused($labelFocused).onChange(of: labelFocused) { was, now in if was && !now { commit() } }
                // Escape puts the saved name back and blurs; the blur commits nothing new.
                .onKeys(["Escape": { name = label.name; labelFocused = false }], enabled: labelFocused, priority: 10, whileTyping: true)
            Button { router.go(.label(label.id)) } label: { HStack(spacing: 4) { Text("Threads"); Icon("arrowRight", size: 12) }.font(W.s13).foregroundStyle(threadsHover ? W.foreground : W.mutedForeground) }.buttonStyle(.plain).onHover { threadsHover = $0 }
            WButton(icon: "trash2", variant: .ghost, size: .iconXs, muted: true, help: "Delete") {
                dialogs.confirm(title: "Delete “\(label.name)”?", description: "It comes off every thread. The threads themselves stay put.", action: "Delete label") {
                    Task {
                        do { try await APIClient.shared.delete("/api/labels/\(label.id)") } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
                        onChanged()
                    }
                }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8).frame(height: 40)
        .background(focused || hovering ? W.muted : Color.clear)
        .rounded(W.radiusMd)
        .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
        .onHover { hovering = $0 }
        .onAppear { name = label.name; color = label.color }
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { name = label.name; return }
        if n != label.name { patch(["name": n]) }
    }
    private func patch(_ body: [String: Any]) {
        Task { do { _ = try await APIClient.shared.patch("/api/labels/\(label.id)", body: body, as: MailLabel.self); onChanged() } catch { Toasts.shared.error(error.localizedDescription) } }
    }
}

struct LabelThreadsPage: View {
    let labelID: String
    @Environment(Router.self) private var router
    @State private var labels = LabelsStore()
    @State private var store = LabelThreadsStore()

    var body: some View {
        let label = labels.labels.first { $0.id == labelID }
        let n = store.threads.count
        PageColumn {
            PageHeader(title: label?.name ?? "Label", subtitle: n > 0 ? "\(n) \(n == 1 ? "thread" : "threads") with this label." : "A label.", titleIcon: "tag") {
                WButton("All labels", variant: .ghost, size: .sm, muted: true) { router.go(.labels) }
            }
            ThreadListView(sections: [ListSection(threads: store.threads, emptyTitle: "Nothing wears this label yet.", emptyBody: "Select a thread and press b to tag it.")], loading: !store.fresh, error: store.error, onRetry: { Task { await store.load(id: labelID) } }, showBucket: true, emptyIcon: "tag")
        }
        .task { async let a: () = labels.load(); async let b: () = store.load(id: labelID); _ = await (a, b) }
        .syncsWithMail { await store.load(id: labelID) }
    }
}

// MARK: - Drafts

struct DraftsPage: View {
    let scheduled: Bool
    @Environment(AppState.self) private var app
    @Environment(DialogState.self) private var dialogs
    @State private var drafts = DraftsStore()
    @State private var queue = ScheduledStore()
    @State private var cursor = -1

    private var list: [Draft] { scheduled ? queue.queued : drafts.unsent }
    private var fresh: Bool { scheduled ? queue.fresh : drafts.fresh }
    private var error: String? { scheduled ? queue.error : drafts.error }

    var body: some View {
        let list = list
        PageColumn {
            PageHeader(title: scheduled ? "Scheduled" : "Drafts", subtitle: scheduled ? "Going out later, automatically." : "Half-written thoughts, waiting.") {
                if !scheduled { WButton("New message", icon: "penSquare", variant: .ghost, size: .sm) { Compose.open() } }
            }
            if let error { ErrorStateView(message: error) { Task { await reload() } } }
            if !fresh { SkeletonRows(rows: 4) }
            else if list.isEmpty && error == nil {
                EmptyStateView(icon: scheduled ? "calendarClock" : "penSquare", title: scheduled ? "Nothing scheduled." : "No drafts.", body: scheduled ? "Use the arrow next to Send to pick a time." : "Press c to start one. We'll keep it here until you send it.") {
                    if !scheduled { WButton("Start writing", variant: .ghost, size: .sm) { Compose.open() } }
                }
            }
            if fresh {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, d in
                    DraftRow(draft: d, scheduled: scheduled, focused: cursor == i, onOpen: { open(d) },
                             onCancel: { Task { if let e = await queue.cancel(d) { Toasts.shared.error(e) } else { Mail.invalidate(); await reload() } } },
                             onDelete: { dialogs.confirm(title: "Delete this draft?", description: "It's gone for good — there's no undo for drafts.", cancel: "Keep it", action: "Delete") { Task { _ = scheduled ? await queue.delete(d) : await drafts.delete(d); await reload() } } })
                        .id(d.id)
                }
            }
        }
        .task { await reload() }
        .syncsWithMail { await reload() }
        .itemCursorKeys(ids: list.map(\.id), cursor: $cursor) { i in open(list[i]) }
    }

    private func reload() async { if scheduled { await queue.load() } else { await drafts.load() } }

    private func open(_ d: Draft) {
        Compose.open(ComposerInitial(draftID: d.id, accountID: d.accountID, threadID: d.threadID, replyToMessageID: d.replyToMessageID, to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, bodyHTML: d.bodyHTML, title: d.status == "draft" ? "Draft" : "Scheduled message"))
    }
}

private struct DraftRow: View {
    let draft: Draft
    let scheduled: Bool
    var focused = false
    var onOpen: () -> Void
    var onCancel: () -> Void
    var onDelete: () -> Void
    @Environment(AppState.self) private var app
    @State private var hovering = false

    private var preview: String {
        var s = draft.bodyHTML
        s = s.replacingOccurrences(of: #"<div class="hey-signature">[\s\S]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<div class="hey-quote">[\s\S]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return String(HTMLText.plain(from: s).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(120))
    }

    var body: some View {
        let people = draft.to.isEmpty ? draft.cc : draft.to
        HStack(spacing: 10) {
            ZStack {
                if people.count > 1 { WAvatarStack(people: people, size: 20, max: 2) } else if let p = people.first { WAvatar(p, size: 20) } else { Icon("penSquare", size: 14).foregroundStyle(W.mutedForeground) }
            }
            .frame(width: 20, height: 20)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if people.isEmpty { Text("No recipients yet").font(W.font(13, 500)).foregroundStyle(W.mutedForeground) }
                        else { Text(people.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", ")).font(W.font(13, 500)).lineLimit(1) }
                        if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: draft.accountID)).help(app.account(draft.accountID)?.email ?? "") }
                        if draft.status == "failed" { WBadge("Failed", variant: .outline, muted: true, small: true) }
                        if draft.status == "sending" { WBadge("Sending", variant: .outline, muted: true, small: true) }
                    }
                    // The subject keeps to `max-w-[60%]`; the snippet and any error take the rest.
                    CappedLeadLayout(fraction: 0.6, spacing: 6) {
                        Text(draft.subject.isEmpty ? "(no subject)" : draft.subject).font(W.s13).foregroundStyle(W.foreground80).lineLimit(1)
                        if !preview.isEmpty { Text("— \(preview)").font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1) }
                        if draft.status == "failed", let e = draft.error, !e.isEmpty { Text("· \(e)").font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hovering || focused {
                if draft.status == "scheduled" { WButton("Cancel", icon: "x", variant: .ghost, size: .xs, action: onCancel) }
                else { WButton(icon: "trash2", variant: .ghost, size: .iconXs, help: "Delete draft", action: onDelete) }
            } else if scheduled, let at = draft.sendAt {
                WBadge(Fmt.full(at), icon: "calendarClock", variant: .secondary, muted: true)
            } else {
                Text(Fmt.time(draft.updatedAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
            }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(focused || hovering ? W.muted : Color.clear)
        .rounded(W.radiusMd)
        .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
        .onHover { hovering = $0 }
    }
}
