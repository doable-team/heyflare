import SwiftUI
import AppKit

// `ThreadList.tsx` / `ThreadRow.tsx` / `BundleRow.tsx` / `BulkBar.tsx`.

enum QuickAction { case replyLater, setAside, bubbleUp, trash }

/// `senderLine`: the last sender, then the first names of the others, "+N".
func senderLine(_ t: ThreadSummary) -> String {
    let others = t.participants.filter { $0.email != t.lastFrom.email }
    let first = t.lastFrom.name.trimmingCharacters(in: .whitespaces).isEmpty ? t.lastFrom.email : t.lastFrom.name.trimmingCharacters(in: .whitespaces)
    if others.isEmpty { return first }
    let names = [first] + others.map { p in
        let n = p.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? String(p.email.split(separator: "@").first ?? "") : String(n.split(separator: " ").first ?? "")
    }
    return names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
}

/// Notion-dense thread row: 56pt two-line, or 44pt one-line (compact).
struct ThreadRowView: View {
    let thread: ThreadSummary
    var selected = false
    var focused = false
    var compact = false
    var showBucket = false
    var leaving = false
    var quickActions = true
    var onSelect: (String, Bool) -> Void = { _, _ in }
    var onQuick: ((String, QuickAction) -> Void)?

    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.searchTerms) private var terms
    @State private var hovering = false
    /// The text column's width, for the web's `max-w-[55%]` / `sm:max-w-[45%]` caps.
    @State private var textWidth: CGFloat = 0

    private var unread: Bool { thread.unread || !thread.seen }
    private var acctEmail: String? { app.accounts.count > 1 ? app.account(thread.accountID)?.email : nil }
    private var showQuick: Bool { quickActions && onQuick != nil }
    private var glyph: String? { app.accounts.count > 1 ? app.glyph(for: thread.accountID) : nil }
    private var stack: [Address]? {
        let me = (app.account(thread.accountID)?.email ?? "").lowercased()
        let others = thread.participants.filter { $0.email.lowercased() != me }
        guard others.count >= 2 else { return nil }
        return [thread.lastFrom] + others.filter { $0.email.lowercased() != thread.lastFrom.email.lowercased() }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // avatar ↔ checkbox
            ZStack {
                if !compact {
                    WAvatar(thread.lastFrom, size: 20).opacity(selected || (showQuick && hovering) ? 0 : 1)
                }
                if selected || hovering {
                    WCheckbox(checked: selected) { onSelect(thread.id, NSEvent.modifierFlags.contains(.shift)) }
                }
            }
            .frame(width: 20, height: 20)

            Button {
                router.go(.thread(thread.id, peek: false))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if compact {
                        HStack(spacing: 6) {
                            if unread { Circle().fill(W.foreground).frame(width: 6, height: 6) }
                            // `shrink-0 max-w-[55%]`
                            highlighted(thread.displaySubject, terms).font(W.font(13, unread ? 600 : 400)).foregroundStyle(unread ? W.foreground : W.mutedForeground).lineLimit(1).layoutPriority(1)
                                .frame(maxWidth: textWidth > 0 ? textWidth * 0.55 : nil, alignment: .leading)
                            if thread.messageCount > 1 { Text("\(thread.messageCount)").font(W.xs).monospacedDigit().foregroundStyle(W.tertiary) }
                            AccountGlyph(glyph: glyph, label: acctEmail)
                            if thread.bubbled { WBadge("Bubbled up", variant: .outline, muted: true, small: true) }
                            if showBucket && thread.bucket != .imbox { WBadge(thread.bucket.title, variant: .outline, muted: true, small: true) }
                            highlighted(senderLine(thread) + (thread.snippet.isEmpty ? "" : " — \(thread.snippet)"), terms).font(W.s13).foregroundStyle(unread ? W.foreground : W.tertiary).lineLimit(1)
                        }
                    } else {
                        HStack(spacing: 6) {
                            if unread { Circle().fill(W.foreground).frame(width: 6, height: 6) }
                            highlighted(thread.displaySubject, terms).font(W.font(13, unread ? 600 : 500)).webLine(13, weight: unread ? 600 : 500).foregroundStyle(unread ? W.foreground : W.foreground90).lineLimit(1)
                            if let stack { WAvatarStack(people: stack, size: 14, max: 6) }
                            if thread.messageCount > 1 { Text("\(thread.messageCount)").font(W.xs).monospacedDigit().foregroundStyle(W.tertiary) }
                            AccountGlyph(glyph: glyph, label: acctEmail)
                            if thread.bubbled { WBadge("Bubbled up", variant: .outline, muted: true, small: true) }
                            if showBucket && thread.bucket != .imbox { WBadge(thread.bucket.title, variant: .outline, muted: true, small: true) }
                        }
                        HStack(spacing: 6) {
                            // `shrink-0 sm:max-w-[45%]`
                            highlighted(senderLine(thread), terms).font(W.s13).webLine(13).foregroundStyle(unread ? W.foreground : W.mutedForeground).lineLimit(1).layoutPriority(1)
                                .frame(maxWidth: textWidth > 0 ? textWidth * 0.45 : nil, alignment: .leading)
                            if !thread.snippet.isEmpty {
                                highlighted("— \(thread.snippet)", terms).font(W.xs).webLine(12).foregroundStyle(unread ? W.foreground : W.mutedForeground).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(GeometryReader { g in Color.clear.onChange(of: g.size.width, initial: true) { _, w in textWidth = w } })

            // meta / quick actions
            ZStack(alignment: .trailing) {
                HStack(spacing: 8) {
                    if !compact {
                        ForEach(thread.labels.prefix(2)) { l in WBadge(l.name, variant: .outline, muted: true, small: true, paddingX: 6) }
                    }
                    if !thread.note.isEmpty { Icon("stickyNote", size: 13).help("Has a note") }
                    if thread.trackersBlocked > 0 { Icon("shieldCheck", size: 13).help("Blocked \(thread.trackersBlocked) spy tracker\(thread.trackersBlocked == 1 ? "" : "s")") }
                    if thread.hasAttachments { Icon("paperclip", size: 13) }
                    Text(Fmt.time(thread.lastMessageAt)).font(W.xs).webLine(12).monospacedDigit().foregroundStyle(unread ? W.foreground : W.mutedForeground).help(Fmt.full(thread.lastMessageAt))
                }
                .foregroundStyle(W.mutedForeground)
                .opacity(showQuick && hovering ? 0 : 1)
                if showQuick && hovering, let onQuick {
                    HStack(spacing: 2) {
                        if thread.bucket != .trash {
                            quick("clock", "Reply later", "l", active: thread.replyLater) { onQuick(thread.id, .replyLater) }
                            quick("bookmark", "Set aside", "a", active: thread.setAside) { onQuick(thread.id, .setAside) }
                            quick("arrowUpCircle", "Bubble up", "z", active: false) { onQuick(thread.id, .bubbleUp) }
                        }
                        quick("trash2", "Trash", "#", active: false) { onQuick(thread.id, .trash) }
                    }
                }
            }
            .frame(minWidth: showQuick && hovering ? 116 : 56, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        // `row-out`: the row fades, slides right and collapses (`max-height: 0`) together.
        .frame(height: leaving ? 0 : (compact ? 44 : 56))
        .clipped()
        .background(selected ? W.accent : (focused || hovering ? W.muted : Color.clear))
        .rounded(W.radiusMd)
        .overlay(alignment: .leading) {
            if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) }
        }
        .opacity(leaving ? 0 : 1)
        .offset(x: leaving ? 12 : 0)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .animation(.easeIn(duration: 0.12), value: leaving)
    }

    /// `Quick`: a ghost icon-xs button; while the action is on (`active`) it sits on `bg-accent`.
    private func quick(_ icon: String, _ label: String, _ kbd: String, active: Bool, action: @escaping () -> Void) -> some View {
        WButton(icon: icon, variant: .ghost, size: .iconXs, muted: !active, help: "\(label)  \(kbd)", action: action)
            .background(active ? W.accent : Color.clear)
            .rounded(W.radiusMd)
    }
}

/// One batch of mail from a bundled sender, in the same grammar as a thread row.
struct BundleRowView: View {
    let bundle: MailBundle
    var compact = false
    var focused = false
    var onSeen: ((MailBundle) -> Void)?

    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var hovering = false

    private var open: Bool { bundle.isOpen }

    var body: some View {
        HStack(spacing: 10) {
            BundleAvatar(email: bundle.email, name: bundle.name, src: bundle.avatarURL, size: 20)
            Button {
                router.go(.bundle(bundle.id))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if open { Circle().fill(W.foreground).frame(width: 6, height: 6) }
                        Text(bundle.name.isEmpty ? bundle.email : bundle.name).font(W.font(13, open ? 600 : 500)).foregroundStyle(open ? W.foreground : W.foreground90).lineLimit(1)
                        Icon("layers", size: 12).foregroundStyle(W.mutedForeground)
                        Text("\(bundle.messageCount) \(bundle.messageCount == 1 ? "message" : "messages")").font(W.xs).monospacedDigit().foregroundStyle(W.tertiary)
                        AccountGlyph(glyph: app.accounts.count > 1 ? app.glyph(for: bundle.accountID) : nil, label: app.account(bundle.accountID)?.email)
                        if compact {
                            Text(bundle.latest.displaySubject + (bundle.latest.snippet.isEmpty ? "" : " — \(bundle.latest.snippet)")).font(W.s13).foregroundStyle(W.foreground80).lineLimit(1)
                        }
                    }
                    if !compact {
                        HStack(spacing: 6) {
                            Text(bundle.latest.displaySubject).font(W.s13).foregroundStyle(open ? W.foreground : W.foreground80).lineLimit(1).layoutPriority(1)
                            if !bundle.latest.snippet.isEmpty { Text("— \(bundle.latest.snippet)").font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ZStack(alignment: .trailing) {
                Text(Fmt.time(bundle.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(open ? W.foreground : W.mutedForeground).opacity(hovering ? 0 : 1)
                if hovering {
                    HStack(spacing: 4) {
                        if open, let onSeen { WButton(icon: "check", variant: .ghost, size: .iconXs, muted: true, help: "Mark as seen") { onSeen(bundle) } }
                        WButton("Contact", variant: .ghost, size: .xs, muted: true) { router.go(.contact(bundle.contactID)) }
                    }
                }
            }
            .frame(minWidth: hovering ? 116 : 56, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: compact ? 44 : 56)
        .background(focused || hovering ? W.muted : Color.clear)
        .rounded(W.radiusMd)
        .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
        .onHover { hovering = $0 }
    }
}

/// A bundle at a glance: the sender's tile on two blank cards offset up-left.
struct BundleAvatar: View {
    let email: String
    var name = ""
    var src: String? = nil
    var size: CGFloat = 20
    var strong = false

    var body: some View {
        let off = max(2, (size * 0.12).rounded())
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(W.muted).overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(W.border, lineWidth: 1)).frame(width: size, height: size)
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(W.muted).overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(W.border, lineWidth: 1)).frame(width: size, height: size).offset(x: off, y: off)
            WAvatar(email: email, name: name, src: src, size: size, strong: strong).offset(x: off * 2, y: off * 2)
        }
        .frame(width: size + off * 2, height: size + off * 2, alignment: .topLeading)
    }
}

// MARK: - List

struct ListSection {
    var title: String? = nil
    var threads: [ThreadSummary]
    var bundles: [MailBundle] = []
    var emptyTitle: String? = nil
    var emptyBody: String? = nil
    var emptyView: AnyView? = nil
    var actions: AnyView? = nil
}

private enum ListItem: Identifiable {
    case thread(ThreadSummary)
    case bundle(MailBundle)
    var id: String { switch self { case .thread(let t): return t.id; case .bundle(let b): return "b:\(b.id)" } }
    var at: Double { switch self { case .thread(let t): return t.lastMessageAt; case .bundle(let b): return b.lastMessageAt } }
}

/// Selectable, keyboard-navigable list. Sections share one selection and cursor.
struct ThreadListView: View {
    var sections: [ListSection]
    var loading = false
    var error: String? = nil
    var onRetry: (() -> Void)? = nil
    var compact = false
    var groupByMonth = false
    var showBucket = false
    var emptyIcon: String? = nil
    var keysEnabled = true
    var quickActions = true
    var footer: AnyView? = nil
    /// Reacts to a change made through this list (so the page can drop rows optimistically).
    var onAct: ((_ ids: [String], _ action: ThreadAction, _ removes: Bool) -> Void)? = nil

    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @Environment(DialogState.self) private var dialogs
    @Environment(\.pageScrollProxy) private var pageScroll
    @State private var selected: Set<String> = []
    @State private var cursor = -1
    @State private var leaving: Set<String> = []
    @State private var lastClick: String?
    /// Where the bulk bar would sit unpinned (window coordinates), for `sticky top-11`.
    @State private var barTop: CGFloat = .infinity

    private var all: [ThreadSummary] { sections.flatMap(\.threads) }
    private var sectionItems: [[ListItem]] {
        sections.map { s in
            var items: [ListItem] = s.threads.map { .thread($0) } + s.bundles.map { .bundle($0) }
            if !s.bundles.isEmpty { items.sort { $0.at > $1.at } }
            return items
        }
    }
    private var items: [ListItem] { sectionItems.flatMap { $0 } }
    /// Where each section's rows start in the flat cursor order.
    private var sectionOffsets: [Int] {
        var out: [Int] = []
        var n = 0
        for rows in sectionItems { out.append(n); n += rows.count }
        return out
    }
    private var curThread: ThreadSummary? {
        guard cursor >= 0, cursor < items.count, case .thread(let t) = items[cursor] else { return nil }
        return t
    }
    private func targets() -> [String] { selected.isEmpty ? (curThread.map { [$0.id] } ?? []) : Array(selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error {
                ErrorStateView(message: error, retry: onRetry)
            } else if loading && all.isEmpty && sections.allSatisfy({ $0.bundles.isEmpty }) {
                SkeletonRows(compact: compact)
            } else {
                if !selected.isEmpty {
                    // `sticky top-11 z-20`: the page's scroll view lives in the shell, so the bar
                    // is pinned by measuring where it would be and offsetting it back under the
                    // 44pt top bar once it has scrolled past.
                    Color.clear.frame(height: 0)
                        .background(GeometryReader { g in
                            Color.clear.onChange(of: g.frame(in: .named("window")).minY, initial: true) { _, y in barTop = y }
                        })
                    BulkBar(selected: selected, threads: all, onClear: { selected = [] }) { action, msg, removes in
                        act(Array(selected), action, msg, removes: removes)
                    }
                    .offset(y: max(0, 44 - barTop))
                    .zIndex(1)
                }
                let offsets = sectionOffsets
                ForEach(Array(sections.enumerated()), id: \.offset) { si, s in
                    VStack(alignment: .leading, spacing: 0) {
                        if let title = s.title {
                            SectionTitle(title: title, count: s.threads.count + s.bundles.count) { if let a = s.actions { a } }
                        }
                        if s.threads.isEmpty && s.bundles.isEmpty {
                            if let e = s.emptyView { e }
                            else if let t = s.emptyTitle { EmptyStateView(icon: emptyIcon, title: t, body: s.emptyBody, compact: si > 0 || sections.count > 1) }
                            else { Text("Nothing here.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 12) }
                        } else {
                            let rows = sectionItems[si]
                            let base = offsets[si]
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                if groupByMonth {
                                    ForEach(monthGroups(rows), id: \.month) { g in
                                        Section {
                                            ForEach(Array(g.items.enumerated()), id: \.element.id) { j, item in row(item, at: base + g.offset + j) }
                                        } header: {
                                            Text(g.month).font(W.font(12, 500)).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).frame(height: 32).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading).background(W.background.opacity(0.95))
                                        }
                                    }
                                } else {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { j, item in row(item, at: base + j) }
                                }
                            }
                        }
                    }
                    .padding(.top, si > 0 ? 24 : 0)
                }
                if let footer { footer }
            }
        }
        .onKeys([
            "j": { step(1) }, "k": { step(-1) }, "ArrowDown": { step(1) }, "ArrowUp": { step(-1) },
            "x": { if let t = curThread { toggle(t.id, shift: false) } },
            "l": { act(targets(), .replyLater(true), "Added to Reply Later") },
            "a": { act(targets(), .setAside(true), "Set aside") },
            "z": { let ids = targets(); if !ids.isEmpty { bubble(ids) } },
            "#": { act(targets(), .move(.trash), "Moved to trash") },
            "u": { act(targets(), .markUnread, nil, removes: false) },
            "e": { act(targets(), .seen, "Done", removes: false) },
        ], enabled: keysEnabled && ui.region == .content)
        // `b` and `g` only mean something with a selection, so they bind only then.
        .onKeys(["b": { BulkBar.labelSelection(selected, all, pops: PopLayerState.shared) }, "g": { Task { await BulkBar.mergeSelection(selected, all) { selected = [] } } }],
                enabled: keysEnabled && ui.region == .content && !selected.isEmpty)
        // A bound key is a claimed key, so these only bind while they have something to
        // do: the Imbox's own `o` and a page's Escape get through otherwise.
        // With rows selected but nothing focused the web's `listRowActive()` still swallows
        // `o`, so the Imbox does not jump to Power Through under a selection.
        .onKeys(["Enter": { open() }, "o": { open() }], enabled: keysEnabled && ui.region == .content && ((cursor >= 0 && cursor < items.count) || !selected.isEmpty))
        .onKeys(["Escape": { selected = [] }], enabled: keysEnabled && ui.region == .content && !selected.isEmpty)
        .onChange(of: all.map(\.id)) { _, ids in
            selected = selected.filter { ids.contains($0) }
            if cursor >= items.count { cursor = items.count - 1 }
        }
    }

    private struct MonthGroup { let month: String; let offset: Int; let items: [ListItem] }
    private func monthGroups(_ rows: [ListItem]) -> [MonthGroup] {
        var out: [MonthGroup] = []
        var offset = 0
        for item in rows {
            let m = Fmt.monthKey(item.at)
            if let last = out.last, last.month == m {
                out[out.count - 1] = MonthGroup(month: m, offset: last.offset, items: last.items + [item])
            } else {
                out.append(MonthGroup(month: m, offset: offset, items: [item]))
            }
            offset += 1
        }
        return out
    }

    @ViewBuilder
    private func row(_ item: ListItem, at i: Int) -> some View {
        switch item {
        case .bundle(let b):
            BundleRowView(bundle: b, compact: compact, focused: i == cursor && ui.region == .content) { b in
                Task {
                    do { try await APIClient.shared.markBundleSeen(b.id); Mail.invalidate(); Toasts.shared.show("Marked \(b.name.isEmpty ? b.email : b.name) as seen") }
                    catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
                }
            }
            .id(item.id)
        case .thread(let t):
            ThreadRowView(thread: t, selected: selected.contains(t.id), focused: i == cursor && ui.region == .content, compact: compact, showBucket: showBucket, leaving: leaving.contains(t.id), quickActions: quickActions,
                          onSelect: { id, shift in toggle(id, shift: shift) },
                          onQuick: { id, q in quick(id, q) })
            .id(item.id)
        }
    }

    private func toggle(_ id: String, shift: Bool) {
        if shift, let last = lastClick, let a = all.firstIndex(where: { $0.id == last }), let b = all.firstIndex(where: { $0.id == id }) {
            for i in min(a, b)...max(a, b) { selected.insert(all[i].id) }
        } else if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        lastClick = id
    }

    private func open() {
        guard cursor >= 0, cursor < items.count else { return }
        switch items[cursor] {
        case .thread(let t): router.go(.thread(t.id, peek: false))
        case .bundle(let b): router.go(.bundle(b.id))
        }
    }

    private func step(_ delta: Int) {
        // An empty page scrolls instead, so the keys never feel dead (`useItemCursor`).
        guard !items.isEmpty else { PageScroll.by(CGFloat(delta) * 0.25); return }
        cursor = min(max(cursor + delta, 0), items.count - 1)
        // `scrollIntoView` on the web: the cursor moving is not enough on its own, since the
        // list sits inside the page's own ScrollView rather than owning one of its own.
        if items.indices.contains(cursor) {
            // `scrollIntoView({ block: "nearest" })`: the least movement that shows the row.
            withAnimation(nil) { pageScroll?.scrollTo(items[cursor].id, anchor: nil) }
        }
    }

    /// Animate rows out, then post.
    private func act(_ ids: [String], _ action: ThreadAction, _ msg: String?, removes: Bool = true) {
        guard !ids.isEmpty else { return }
        selected = []
        if removes {
            leaving.formUnion(ids)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                Mail.bulk(ids, action, toast: msg)
                onAct?(ids, action, true)
                leaving.subtract(ids)
            }
        } else {
            Mail.bulk(ids, action, toast: msg)
            onAct?(ids, action, false)
        }
    }

    private func quick(_ id: String, _ q: QuickAction) {
        guard let t = all.first(where: { $0.id == id }) else { return }
        switch q {
        case .replyLater: act([id], .replyLater(!t.replyLater), t.replyLater ? "Removed from Reply Later" : "Added to Reply Later", removes: !t.replyLater)
        case .setAside: act([id], .setAside(!t.setAside), t.setAside ? "Back in the Imbox" : "Set aside", removes: !t.setAside)
        case .bubbleUp: bubble([id])
        case .trash: act([id], .move(.trash), "Moved to trash")
        }
    }

    /// `<Modal size="sm">`: `sm:max-w-sm` (384), `p-4 gap-4`, a header of title + description
    /// (`gap-2`), and the close button at `top-2 right-2`.
    private func bubble(_ ids: [String]) {
        dialogs.present("bubble", width: 384) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bubble up").font(W.font(16, 500)).webLine(16, weight: 500).foregroundStyle(W.foreground)
                    Text("Out of sight until the moment you pick.").font(W.sm).foregroundStyle(W.mutedForeground)
                }
                DateTimePicker(embedded: true, onPick: { at in
                    dialogs.dismiss("bubble")
                    act(ids, .bubbleUp(at), "Will bubble up later")
                }, onCancel: { dialogs.dismiss("bubble") })
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                WButton(icon: "x", variant: .ghost, size: .iconSm, help: "Close") { dialogs.dismiss("bubble") }.padding(8)
            }
        }
    }
}

/// Sticky, borderless context bar shown while threads are selected.
struct BulkBar: View {
    let selected: Set<String>
    let threads: [ThreadSummary]
    var onClear: () -> Void
    var onAct: (ThreadAction, String?, Bool) -> Void

    @Environment(PopLayerState.self) private var pops
    @Environment(DialogState.self) private var dialogs
    @State private var busy = false

    private var sel: [ThreadSummary] { threads.filter { selected.contains($0.id) } }
    private var allRead: Bool { sel.allSatisfy { !$0.unread } }

    var body: some View {
        HStack(spacing: 2) {
            WButton(icon: "x", variant: .ghost, size: .iconSm, muted: true, help: "Clear selection  esc", action: onClear)
            Text("\(selected.count) selected").font(W.font(13, 500)).monospacedDigit().padding(.horizontal, 4)
            WSeparator(vertical: true).frame(height: 16).padding(.horizontal, 4)
            WButton(icon: allRead ? "mail" : "mailOpen", variant: .ghost, size: .iconSm, muted: true, help: allRead ? "Mark unread  u" : "Mark read  u") { onAct(allRead ? .markUnread : .markRead, nil, false) }
            WButton(icon: "clock", variant: .ghost, size: .iconSm, muted: true, help: "Reply later  l") { onAct(.replyLater(true), "Added to Reply Later", true) }
            WButton(icon: "bookmark", variant: .ghost, size: .iconSm, muted: true, help: "Set aside  a") { onAct(.setAside(true), "Set aside", true) }
            WButton(icon: "arrowUpCircle", variant: .ghost, size: .iconSm, muted: true, help: "Bubble up  z") {
                pops.toggle("bulk-bubble", side: .bottom, align: .start) {
                    // `PopoverContent className="w-auto p-0"` around the full picker: title row + Cancel.
                    PopCard(padding: 0) { DateTimePicker(onPick: { at in pops.closeAll(); onAct(.bubbleUp(at), "Will bubble up later", true) }, onCancel: { pops.closeAll() }) }
                }
            }
            .popAnchor("bulk-bubble")
            WSeparator(vertical: true).frame(height: 16).padding(.horizontal, 4)
            WButton("Move", icon: "moveRight", variant: .ghost, size: .sm, muted: true) {
                pops.toggle("bulk-move", side: .bottom, align: .start) {
                    PopCard(width: 176) {
                        MenuItem("Imbox", icon: "inbox") { onAct(.move(.imbox), "Moved to Imbox", true) }
                        MenuItem("The Feed", icon: "rss") { onAct(.move(.feed), "Moved to The Feed", true) }
                        MenuItem("Paper Trail", icon: "fileText") { onAct(.move(.paperTrail), "Moved to Paper Trail", true) }
                    }
                }
            }
            .popAnchor("bulk-move")
            WButton("Label", icon: "tag", variant: .ghost, size: .sm, muted: true) { Self.labelSelection(selected, threads, pops: pops) }
            .popAnchor("bulk-label")
            WButton("Collect", icon: "folderPlus", variant: .ghost, size: .sm, muted: true) {
                let ids = Array(selected)
                pops.toggle("bulk-collect", side: .bottom, align: .start) {
                    PopCard(padding: 0) { CollectionPicker(current: [], onToggle: { id, on in Mail.rawBulk(ids, ["action": "collections", (on ? "add" : "remove"): [id]]) }, onClose: { pops.closeAll() }) }
                }
            }
            .popAnchor("bulk-collect")
            if selected.count >= 2 {
                Button {
                    guard !busy else { return }
                    busy = true
                    Task { defer { busy = false }; await Self.mergeSelection(selected, threads, onClear: onClear) }
                } label: {
                    HStack(spacing: 4) {
                        if busy { Spinner(size: 14) } else { Icon("gitMerge", size: 14) }
                        Text("Merge")
                    }
                }
                .buttonStyle(.web(.ghost, .sm, muted: true))
                .disabled(busy)
                .help("Merge")
            }
            Spacer()
            WButton(icon: "trash2", variant: .ghost, size: .iconSm, muted: true, help: "Trash  #") { onAct(.move(.trash), "Moved to trash", true) }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        // `bg-background/90 backdrop-blur`
        .background { Rectangle().fill(.ultraThinMaterial) }
        .background(W.background.opacity(0.9))
        .edgeLine(.bottom)
        .padding(.horizontal, -8)
        .padding(.bottom, 4)
    }
}

extension BulkBar {
    /// The label picker over the selection, from the bar's button or the `b` key.
    static func labelSelection(_ selected: Set<String>, _ threads: [ThreadSummary], pops: PopLayerState) {
        let sel = threads.filter { selected.contains($0.id) }
        let ids = Array(selected)
        let common = Set(sel.first.map { first in first.labels.map(\.id).filter { id in sel.allSatisfy { $0.labels.contains { $0.id == id } } } } ?? [])
        pops.toggle("bulk-label", side: .bottom, align: .start) {
            PopCard(padding: 0) { LabelPicker(current: common, onToggle: { id, on in Mail.bulk(ids, .labels(add: on ? [id] : [], remove: on ? [] : [id])) }, onClose: { pops.closeAll() }) }
        }
    }

    /// Merges the selection into its newest thread, from the bar's button or the `g` key.
    static func mergeSelection(_ selected: Set<String>, _ threads: [ThreadSummary], onClear: @escaping () -> Void) async {
        let sorted = threads.filter { selected.contains($0.id) }.sorted { $0.lastMessageAt > $1.lastMessageAt }
        guard sorted.count >= 2, let target = sorted.first else { return }
        if await Mail.raw(target.id, ["action": "merge", "thread_ids": sorted.dropFirst().map(\.id)]) {
            Toasts.shared.success("Merged \(sorted.count) threads")
            onClear()
        }
    }
}

/// `LoadMore`: appears at the end of a paged list.
struct LoadMore: View {
    let hasMore: Bool
    let loading: Bool
    let onMore: () -> Void
    var body: some View {
        if hasMore || loading {
            HStack {
                Spacer()
                if loading {
                    HStack(spacing: 8) { Spinner(size: 14); Text("Loading more…") }.font(W.s13).foregroundStyle(W.mutedForeground)
                } else {
                    WButton("Load more", variant: .ghost, size: .sm, action: onMore)
                }
                Spacer()
            }
            .padding(.vertical, 24)
            // The web's IntersectionObserver: the next page is asked for when the footer is
            // near the window, and asked again once that page has landed if it still is.
            .background(GeometryReader { g in
                Color.clear
                    .onChange(of: g.frame(in: .named("window")).minY, initial: true) { _, y in top = y; nudge() }
            })
            .onChange(of: loading) { _, l in if !l { nudge() } }
        }
    }

    @Environment(UIState.self) private var ui
    @State private var top: CGFloat = .infinity
    private func nudge() {
        // `rootMargin: "400px"`
        if hasMore && !loading && top < ui.viewportHeight + 400 { onMore() }
    }
}

// MARK: - Search highlighting

private struct SearchTermsKey: EnvironmentKey { static let defaultValue: [String] = [] }
extension EnvironmentValues {
    /// The Search page's query words: every row under it marks its matches.
    var searchTerms: [String] {
        get { self[SearchTermsKey.self] }
        set { self[SearchTermsKey.self] = newValue }
    }
}

/// `::highlight(hey-search){background:var(--accent);text-decoration:underline}`: each
/// occurrence of each word, case-insensitively, on an accent wash and underlined.
func highlighted(_ string: String, _ words: [String]) -> Text {
    guard !words.isEmpty else { return Text(string) }
    var a = AttributedString(string)
    for w in words where !w.isEmpty {
        var from = string.startIndex
        while from < string.endIndex, let r = string.range(of: w, options: .caseInsensitive, range: from..<string.endIndex) {
            if let ar = Range(r, in: a) {
                a[ar].backgroundColor = W.accent
                a[ar].underlineStyle = .single
            }
            from = r.upperBound
        }
    }
    return Text(a)
}
