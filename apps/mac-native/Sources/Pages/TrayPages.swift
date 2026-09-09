import SwiftUI
import AppKit

/// `ReplyLater.tsx`: Focus & Reply — one thread at a time.
struct ReplyLaterPage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @State private var imbox = ImboxStore()
    @State private var currentID: String?

    private var list: [ThreadSummary] { imbox.data.replyLater }
    private var index: Int { max(0, list.firstIndex { $0.id == currentID } ?? 0) }
    private var current: ThreadSummary? { list.indices.contains(index) ? list[index] : list.first }

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() } else {
            PageColumn(width: 672) {
                PageHeader(title: "Focus & Reply", subtitle: list.isEmpty ? "Just the things you said you'd reply to. One at a time." : "\(list.count) waiting on you. One at a time, nothing else in view.")
                if let error = imbox.error { ErrorStateView(message: error) { Task { await imbox.refresh() } } }
                else if imbox.loading && !imbox.loaded {
                    VStack(alignment: .leading, spacing: 16) { SkeletonBlock(width: 64); PctSkeleton(pct: 0.6, height: 24); PctSkeleton(pct: 0.35); SkeletonBlock(height: 128) }.padding(20).background(W.muted40).rounded(W.radiusMd)
                } else if list.isEmpty { EmptyStateView(icon: "clock", title: "Nothing waiting on you.", body: "Hit Reply Later on any thread and it stacks up here.") }
                if let current {
                    FocusCard(thread: current, index: index, total: list.count, onPrev: { go(-1) }, onNext: { go(1) }, onDone: { done(current) }).id(current.id)
                    if list.count > 1 {
                        VStack(alignment: .leading, spacing: 0) {
                            SectionTitle("Up next")
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                                UpNextRow(thread: t, number: i + 1, active: i == index) { currentID = t.id }
                            }
                        }
                        .padding(.top, 24)
                    }
                    HStack(spacing: 6) { Kbd("j"); Kbd("k"); Text("next / previous"); Text("·").padding(.horizontal, 4); Kbd("d"); Text("done"); Text("·").padding(.horizontal, 4); Kbd("↑"); Kbd("↓"); Text("scroll") }
                        .font(W.xs).foregroundStyle(W.mutedForeground).frame(maxWidth: .infinity).padding(.top, 32)
                }
            }
            .task { await imbox.load() }
            .syncsWithMail { await imbox.refresh() }
            .onChange(of: list.map(\.id)) { _, ids in if !ids.isEmpty, !ids.contains(currentID ?? "") { currentID = ids[min(index, ids.count - 1)] } }
            // The web binds `j`/`k` twice — `useCardScroll` scrolls the page and the page's own
            // keys advance — so both happen on one press.
            .onKeys(["j": { go(1); PageScroll.by(0.25) }, "k": { go(-1); PageScroll.by(-0.25) }, "]": { go(1) }, "[": { go(-1) }, "d": { if let c = current { done(c) } }], enabled: !list.isEmpty && ui.region == .content, priority: 1)
            .cardScrollKeys(enabled: ui.region == .content)
        }
    }

    private func go(_ d: Int) { let i = min(max(index + d, 0), list.count - 1); if list.indices.contains(i) { currentID = list[i].id } }
    private func done(_ t: ThreadSummary) {
        let next = list.indices.contains(index + 1) ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
        currentID = next?.id
        Mail.bulk([t.id], .replyLater(false), toast: "Done. Out of the pile.") { imbox.remove(t.id) }
    }
}

private struct FocusCard: View {
    let thread: ThreadSummary
    let index: Int
    let total: Int
    var onPrev: () -> Void
    var onNext: () -> Void
    var onDone: () -> Void

    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var store = ThreadStore()
    @State private var replying: ComposerModel?
    @State private var earlierHover = false

    private var msgs: [Message] { store.detail?.messages ?? [] }
    private var last: Message? { msgs.last }
    private var lastIncoming: Message? { msgs.last { !$0.isFromMe } ?? last }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("\(index + 1) of \(total)").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
                    ZStack(alignment: .leading) { Capsule().fill(W.muted).frame(width: 96, height: 4); Capsule().fill(W.foreground).frame(width: 96 * CGFloat(index + 1) / CGFloat(max(total, 1)), height: 4) }
                    Text("Last message \(Fmt.time(thread.lastMessageAt))").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
                    Spacer()
                    WButton(icon: "chevronLeft", variant: .ghost, size: .iconSm, help: "Previous  k", action: onPrev).disabled(index == 0)
                    WButton(icon: "chevronRight", variant: .ghost, size: .iconSm, help: "Next  j", action: onNext).disabled(index >= total - 1)
                }
                .padding(.bottom, 12)
                Text(thread.displaySubject).font(W.font(24, 600)).tracking(-0.48).lineSpacing(2)
                HStack(spacing: 8) {
                    WAvatarStack(people: thread.participants.isEmpty ? [thread.lastFrom] : thread.participants, size: 18)
                    Text("\(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name)\(thread.participants.count > 1 ? " and \(thread.participants.count - 1) other\(thread.participants.count > 2 ? "s" : "")" : "")").font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1)
                    if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: thread.accountID), label: app.account(thread.accountID)?.email) }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 20).padding(.top, 16)

            VStack(alignment: .leading, spacing: 12) {
                if store.loading && msgs.isEmpty { VStack(alignment: .leading, spacing: 12) { PctSkeleton(pct: 0.4); PctSkeleton(); PctSkeleton(pct: 0.9); PctSkeleton(pct: 0.7) } }
                if let error = store.error { ErrorStateView(message: error) { Task { await store.load(thread.id, peek: true) } } }
                if let last {
                    if msgs.count > 1 {
                        Button { router.go(.thread(thread.id, peek: false)) } label: {
                            HStack(spacing: 4) { Text("\(msgs.count - 1) earlier message\(msgs.count - 1 == 1 ? "" : "s") in this thread"); Icon("arrowUpRight", size: 12) }
                                .font(W.xs).foregroundStyle(earlierHover ? W.foreground : W.mutedForeground)
                        }
                        .buttonStyle(.plain)
                        .onHover { earlierHover = $0 }
                    }
                    HStack(spacing: 10) {
                        WAvatar(last.from, size: 24)
                        Text(last.from.name.isEmpty ? last.from.email : last.from.name).font(W.font(14, 500)).lineLimit(1)
                        Text(Fmt.full(last.date)).font(W.xs).foregroundStyle(W.mutedForeground)
                    }
                    HtmlBodyView(html: last.htmlBody, text: last.textBody, trackers: last.trackers)
                }
            }
            .frame(minHeight: 140, alignment: .top)
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)

            if let replying, let detail = store.detail, lastIncoming != nil {
                ComposerView(model: replying, inline: true)
                    .background(W.background).rounded(W.radiusMd)
                    .padding(12)
                    .id(detail.id)
            } else {
                HStack(spacing: 4) {
                    WButton("Reply", icon: "reply", size: .sm) { startReply() }.disabled(lastIncoming == nil)
                    WButton("Open thread", icon: "arrowUpRight", variant: .ghost, size: .sm, muted: true) { router.go(.thread(thread.id, peek: false)) }
                    Spacer()
                    WButton("Skip", icon: "skipForward", variant: .ghost, size: .sm, muted: true, help: "Leave it in the pile, look at the next one  j", action: onNext).disabled(index >= total - 1)
                    WButton("Done", icon: "check", variant: .outline, size: .sm, help: "Remove from Reply Later  d", action: onDone)
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
        }
        .background(W.muted40)
        .rounded(W.radiusMd)
        .task(id: thread.id) { await store.load(thread.id, peek: true) }
    }

    private func startReply() {
        guard let detail = store.detail, let m = lastIncoming else { return }
        let model = ComposerModel(initial: replyInitial(detail.summary, m, .reply, myEmail: app.account(thread.accountID)?.email))
        model.onDone = { replying = nil; onDone() }
        model.onCancel = { replying = nil }
        Compose.current = model
        replying = model
    }
}

private struct UpNextRow: View {
    let thread: ThreadSummary
    let number: Int
    var active = false
    var action: () -> Void
    @State private var hovering = false
    @State private var width: CGFloat = 0
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("\(number)").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).frame(width: 16, alignment: .trailing)
                WAvatar(thread.lastFrom, size: 20)
                Text(thread.displaySubject).font(W.font(14, active ? 500 : 400)).lineLimit(1)
                Spacer()
                // `max-w-[35%]` of the row.
                Text(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1).frame(maxWidth: width > 0 ? width * 0.35 : nil, alignment: .trailing)
                Text(Fmt.time(thread.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
            }
            .padding(.horizontal, 8).frame(height: 40)
            .background(active || hovering ? W.accent : Color.clear)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w } })
        .onHover { hovering = $0 }
    }
}

/// `SetAside.tsx`: cards on a board.
struct SetAsidePage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @State private var imbox = ImboxStore()
    @State private var leaving: Set<String> = []
    @State private var cursor = -1

    private var list: [ThreadSummary] { imbox.data.setAside }

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() } else {
            PageColumn(width: 1100) {
                PageHeader(title: "Set Aside", subtitle: list.isEmpty ? "Things you want close at hand. Confirmations, links, reference numbers." : "\(list.count) set aside. Things you want close at hand.")
                if let error = imbox.error { ErrorStateView(message: error) { Task { await imbox.refresh() } } }
                else if imbox.loading && !imbox.loaded {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 12) { PctSkeleton(pct: 0.5); PctSkeleton(pct: 0.8, height: 16); PctSkeleton(); PctSkeleton(pct: 0.7) }
                                .padding(16).background(W.muted40).rounded(W.radiusMd)
                        }
                    }
                } else if list.isEmpty { EmptyStateView(icon: "bookmark", title: "Nothing set aside.", body: "Press a on any thread to keep it handy here.") }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), alignment: .leading, spacing: 12) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                        SetAsideCard(thread: t, focused: cursor == i, leaving: leaving.contains(t.id)) { done(t) }
                            .id(t.id)
                    }
                }
            }
            .task { await imbox.load() }
            .syncsWithMail { await imbox.refresh() }
            .itemCursorKeys(ids: list.map(\.id), cursor: $cursor) { i in if list.indices.contains(i) { router.go(.thread(list[i].id, peek: false)) } }
        }
    }

    private func done(_ t: ThreadSummary) {
        leaving.insert(t.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            imbox.remove(t.id)
            leaving.remove(t.id)
            Mail.bulk([t.id], .setAside(false), toast: "Back in the Imbox")
        }
    }
}

private struct SetAsideCard: View {
    let thread: ThreadSummary
    var focused = false
    var leaving = false
    var onDone: () -> Void
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var subjectHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                WAvatar(thread.lastFrom, size: 20)
                Text(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name).font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1)
                Spacer()
                if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: thread.accountID), label: app.account(thread.accountID)?.email) }
                Text(Fmt.time(thread.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).help(Fmt.full(thread.lastMessageAt))
            }
            .padding(.horizontal, 16).padding(.top, 16)
            Button { router.go(.thread(thread.id, peek: false)) } label: {
                Text(thread.displaySubject).font(W.font(14, 600)).underline(subjectHover).lineSpacing(2).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { subjectHover = $0 }
            .padding(.horizontal, 16).padding(.top, 8)
            Text(thread.snippet).font(W.s13).foregroundStyle(W.mutedForeground).lineSpacing(4).lineLimit(3).padding(.horizontal, 16).padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
            if !thread.note.isEmpty {
                HStack(alignment: .top, spacing: 8) { Icon("stickyNote", size: 14).foregroundStyle(W.mutedForeground).padding(.top, 2); Text(thread.note).font(W.s13).lineLimit(2) }
                    .padding(.horizontal, 12).padding(.vertical, 8).background(W.background).rounded(W.radiusMd).padding(.horizontal, 16).padding(.top, 12)
            }
            HStack(spacing: 6) {
                if thread.hasAttachments { Icon("paperclip", size: 14).foregroundStyle(W.mutedForeground).help("Has attachments") }
                if thread.trackersBlocked > 0 { Icon("shieldCheck", size: 14).foregroundStyle(W.mutedForeground).help("Blocked \(thread.trackersBlocked) spy tracker\(thread.trackersBlocked == 1 ? "" : "s")") }
                ForEach(thread.labels.prefix(2)) { l in WBadge(l.name, variant: .outline, muted: true) }
                Spacer()
                WButton("Done", icon: "check", variant: .ghost, size: .sm, muted: true, help: "Back to the Imbox", action: onDone)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).padding(.top, 12)
        }
        .background(W.muted40)
        .overlay { if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.ring, lineWidth: 1) } }
        .rounded(W.radiusMd)
        .opacity(leaving ? 0 : 1)
        .animation(.easeOut(duration: 0.1), value: leaving)
    }
}

// MARK: - Power through new

private let powerCap: CGFloat = 560
private let powerOutMS: Double = 0.16

/// `PowerThrough.tsx`: HEY's "Power Through New" — the whole "New for you" queue stacked on one
/// page so you can act on each message in turn. Nothing is marked seen just by scrolling past
/// it; untouched mail stays new. The queue is a snapshot: it is not refetched under the cursor.
struct PowerThroughPage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @Environment(\.pageScrollProxy) private var pageScroll
    @State private var store = PowerThroughStore()
    @State private var cursor = -1
    @State private var leaving: Set<String> = []
    @State private var replyFor: String?
    @State private var replyModel: ComposerModel?
    @State private var markingAll = false
    @State private var backHover = false

    private var items: [ThreadSummary] { store.items }
    private var cur: ThreadSummary? { cursor >= 0 && cursor < items.count ? items[cursor] : nil }

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() }
        else if let error = store.error { ErrorStateView(message: error) { Task { await store.refresh() } } }
        else {
            PageColumn(width: 672) {
                // <header className="px-2 mb-4">
                VStack(alignment: .leading, spacing: 0) {
                    WButton("Back to Imbox", icon: "arrowLeft", variant: .ghost, size: .sm, muted: true, kbd: "esc") { router.go(.imbox) }.padding(.leading, -8)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Power through new").font(W.font(28, 700)).tracking(-0.56).webLine(28, 32, weight: 700).foregroundStyle(W.foreground)
                        if !items.isEmpty { SecondaryBadge(text: "\(items.count) to go") }
                    }
                    .padding(.top, 4)
                    Text("Act on each one and it leaves the stack. Anything you skip stays new.")
                        .font(W.s13).webLine(13).foregroundStyle(W.mutedForeground).padding(.top, 4)
                    HStack(spacing: 6) {
                        Kbd("j"); Kbd("k"); Text("move ·"); Kbd("r"); Text("reply ·"); Kbd("l"); Text("later ·"); Kbd("a"); Text("set aside ·"); Kbd("e"); Text("seen ·"); Kbd("#"); Text("trash ·"); Kbd("↵"); Text("open")
                    }
                    .font(W.xs).foregroundStyle(W.tertiary).padding(.top, 8)
                }
                .padding(.horizontal, 8).padding(.bottom, 16)

                if store.loading && items.isEmpty {
                    VStack(spacing: 16) { SkeletonBlock(height: 256); SkeletonBlock(height: 256) }
                }

                if !store.loading && items.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Nothing new. Go enjoy your day.").font(W.font(15)).webLine(15).foregroundStyle(W.foreground)
                        Button { router.go(.imbox) } label: {
                            Text("Back to the Imbox").font(W.s13).webLine(13).underline().foregroundStyle(backHover ? W.foreground : W.mutedForeground).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { backHover = $0 }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 40)
                }

                LazyVStack(spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                        PowerCard(thread: t, focused: cursor == i, replying: replyFor == t.id ? replyModel : nil,
                                  onLeave: { action, msg in leave(t, action, msg) },
                                  onReply: { startReply(t) },
                                  onCloseReply: { replyFor = nil; replyModel = nil },
                                  onUpdate: { edit in store.update(t.id, edit) })
                            .opacity(leaving.contains(t.id) ? 0 : 1)
                            .animation(.easeOut(duration: 0.15), value: leaving.contains(t.id))
                            .id(t.id)
                    }
                }

                if !items.isEmpty {
                    HStack(spacing: 12) {
                        WButton("Mark all as seen", icon: "check", variant: .outline) { markAll() }.disabled(markingAll)
                        WButton("Leave the rest", variant: .ghost) { router.go(.imbox) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            }
            .task { await store.firstLoad() }
            // `useItemCursor`: nothing focused until the first press; an empty page scrolls.
            .onKeys([
                "j": { step(1) }, "k": { step(-1) }, "ArrowDown": { step(1) }, "ArrowUp": { step(-1) },
                "Enter": { open() }, "o": { open() },
                "PageDown": { PageScroll.by(0.9) }, "PageUp": { PageScroll.by(-0.9) },
            ], enabled: ui.region == .content && replyFor == nil)
            .onKeys([
                "r": { if let c = cur { startReply(c) } },
                "l": { if let c = cur { leave(c, .replyLater(true), "Added to Reply Later") } },
                "a": { if let c = cur { leave(c, .setAside(true), "Set aside") } },
                "e": { if let c = cur { leave(c, .seen, "Marked seen") } },
                "#": { if let c = cur { leave(c, .move(.trash), "Moved to trash") } },
                "Escape": { router.go(.imbox) },
            ], enabled: replyFor == nil)
            .onChange(of: cursor) { _, c in
                guard c >= 0, items.indices.contains(c) else { return }
                withAnimation(nil) { pageScroll?.scrollTo(items[c].id, anchor: nil) }
            }
            .onChange(of: items.count) { _, n in if cursor >= n { cursor = n - 1 } }
        }
    }

    private func step(_ d: Int) {
        if items.isEmpty { PageScroll.by(CGFloat(d) * 0.25); return }
        cursor = min(max(cursor + d, 0), items.count - 1)
    }

    private func open() {
        guard let c = cur else { return }
        router.go(.thread(c.id, peek: false))
    }

    /// Fade the card out, run the action, then drop it from the stack.
    private func onGone(_ id: String, _ run: @escaping () -> Void) {
        leaving.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + powerOutMS) {
            run()
            _ = store.remove(id)
            leaving.remove(id)
            if replyFor == id { replyFor = nil; replyModel = nil }
        }
    }

    private func leave(_ t: ThreadSummary, _ action: ThreadAction, _ msg: String?) {
        onGone(t.id) { Mail.bulk([t.id], action, toast: msg) }
    }

    private func startReply(_ t: ThreadSummary) {
        guard let m = t.latestMessage else { return }
        let model = ComposerModel(initial: replyInitial(t, m, .reply, myEmail: app.account(t.accountID)?.email))
        model.onDone = { onGone(t.id) { Mail.bulk([t.id], .seen) } }
        model.onCancel = { replyFor = nil; replyModel = nil }
        Compose.current = model
        replyModel = model
        replyFor = t.id
    }

    private func markAll() {
        let ids = items.map(\.id)
        guard !ids.isEmpty, !markingAll else { return }
        markingAll = true
        Task {
            defer { markingAll = false }
            do {
                try await APIClient.shared.markSeen(ids)
                Mail.invalidate()
                Toasts.shared.show("Marked \(ids.count) as seen")
                router.go(.imbox)
            } catch {
                Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

private struct PowerCard: View {
    let thread: ThreadSummary
    var focused = false
    var replying: ComposerModel?
    var onLeave: (ThreadAction, String?) -> Void
    var onReply: () -> Void
    var onCloseReply: () -> Void
    var onUpdate: ((inout ThreadSummary) -> Void) -> Void

    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var expanded = false
    @State private var bodyHeight: CGFloat = 0
    @State private var subjectHover = false
    @State private var noteOpen = false
    @State private var note = ""
    @State private var collections: Set<String> = []

    private var menuID: String { "pt-more-\(thread.id)" }
    private var bubbleID: String { "pt-bubble-\(thread.id)" }

    var body: some View {
        let m = thread.latestMessage
        let acct = app.account(thread.accountID)
        VStack(alignment: .leading, spacing: 0) {
            // <header className="flex items-center gap-2.5 px-5 pt-5">
            HStack(spacing: 10) {
                WAvatar(thread.lastFrom, size: 20)
                Text(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name).font(W.font(14, 500)).lineLimit(1)
                if app.accounts.count > 1, let acct { AccountGlyph(glyph: app.glyph(for: acct.id), label: acct.email) }
                Text(thread.lastFrom.email).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                ForEach(thread.labels.prefix(2)) { l in
                    // `LabelChip small`: outline, font-normal, the label's colour as a dot.
                    WBadge(l.name, variant: .outline, muted: true, small: true, dot: colorFromHex(l.color), paddingX: 6)
                }
                Spacer()
                Text(Fmt.time(thread.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).help(Fmt.full(thread.lastMessageAt))
            }
            .padding(.horizontal, 20).padding(.top, 20)

            // <div className="px-5 pt-3">: the subject link, then "N messages" under it.
            VStack(alignment: .leading, spacing: 0) {
                Button { router.go(.thread(thread.id, peek: false)) } label: {
                    Text(thread.displaySubject).font(W.font(18, 600)).tracking(-0.18).webLine(18, 24.75, weight: 600).underline(subjectHover).foregroundStyle(W.foreground)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { subjectHover = $0 }
                if thread.messageCount > 1 {
                    Text("\(thread.messageCount) messages").font(W.xs).webLine(12).monospacedDigit().foregroundStyle(W.mutedForeground)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12)

            if !thread.note.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Icon("stickyNote", size: 14).foregroundStyle(W.mutedForeground).padding(.top, 2)
                    Text(thread.note).font(W.s13).webLine(13).foregroundStyle(W.foreground).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 8).background(W.background).rounded(W.radiusMd)
                .padding(.horizontal, 20).padding(.top, 12)
            }

            ZStack(alignment: .bottom) {
                Group { if let m { HtmlBodyView(html: m.htmlBody, text: m.textBody, trackers: m.trackers) } else { Text(thread.snippet).font(W.sm) } }
                    .background(GeometryReader { g in Color.clear.onChange(of: g.size.height, initial: true) { _, h in bodyHeight = h } })
                    .frame(maxHeight: expanded ? nil : powerCap, alignment: .top).clipped()
                if !expanded && bodyHeight > powerCap + 24 {
                    // `h-20 bg-gradient-to-t from-background via-background/70 to-transparent`
                    LinearGradient(colors: [W.background.opacity(0), W.background.opacity(0.7), W.background], startPoint: .top, endPoint: .bottom).frame(height: 80)
                        .overlay(alignment: .bottom) { WButton("Read more", trailingIcon: "chevronDown", variant: .outline, size: .sm) { expanded = true }.padding(.bottom, 8) }
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)

            if let replying, thread.latestMessage != nil {
                // <div className="px-3 pb-3"><div className="rounded-md ring-1 ring-border bg-background p-2">
                ComposerView(model: replying, inline: true)
                    .padding(8)
                    .background(W.background)
                    .border1(W.border, radius: W.radiusMd)
                    .rounded(W.radiusMd)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            } else {
                // <footer className="flex items-center gap-1 px-3 py-2 flex-wrap">
                HStack(spacing: 4) {
                    WButton("Reply", icon: "reply", size: .sm, action: onReply)
                    WButton("Reply later", icon: "clock", variant: .ghost, size: .sm, muted: true) { onLeave(.replyLater(true), "Added to Reply Later") }
                    WButton("Set aside", icon: "bookmark", variant: .ghost, size: .sm, muted: true) { onLeave(.setAside(true), "Set aside") }
                    WButton("Bubble up", icon: "arrowUpCircle", variant: .ghost, size: .sm, muted: true, expanded: pops.isOpen(bubbleID)) {
                        pops.toggle(bubbleID, side: .bottom, align: .start) {
                            PopCard(padding: 0) {
                                DateTimePicker(onPick: { at in pops.closeAll(); onLeave(.bubbleUp(at), "Will bubble up") }, onCancel: { pops.closeAll() })
                            }
                        }
                    }
                    .popAnchor(bubbleID)
                    Spacer()
                    WButton("Mark seen", icon: "check", variant: .ghost, size: .sm, muted: true) { onLeave(.seen, "Marked seen") }
                    WButton(icon: "moreHorizontal", variant: .ghost, size: .sm, muted: true, expanded: pops.isOpen(menuID)) {
                        pops.toggle(menuID, side: .bottom, align: .end) { moreMenu }
                    }
                    .popAnchor(menuID)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }

            if noteOpen {
                // <div className="px-5 pb-4">
                VStack(alignment: .leading, spacing: 0) {
                    WTextArea(placeholder: "A private note on this thread…", text: $note, minHeight: 64, fontSize: 13)
                    HStack(spacing: 8) {
                        WButton("Save note", size: .sm) { saveNote() }.keyboardShortcut(.return, modifiers: .command)
                        WButton("Cancel", variant: .ghost, size: .sm) { noteOpen = false }
                        HStack(spacing: 4) { Kbd("⌘"); Kbd("↵"); Text("to save") }.font(W.xs).foregroundStyle(W.mutedForeground)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
                .onKeys(["Escape": { noteOpen = false; note = thread.note }], enabled: noteOpen, priority: 20)
            }
        }
        .background(W.muted40)
        .overlay { if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.ring, lineWidth: 1) } }
        .rounded(W.radiusMd)
        .onAppear { note = thread.note }
        .onChange(of: thread.note) { _, n in note = n }
    }

    /// `<DropdownMenuContent align="end" className="w-52">`
    private var moreMenu: some View {
        PopCard(width: 208) {
            VStack(spacing: 0) {
                DropdownLabel("Move to")
                MenuItem("The Feed", icon: "rss") { onLeave(.move(.feed), "Moved to The Feed") }
                MenuItem("Paper Trail", icon: "fileText") { onLeave(.move(.paperTrail), "Moved to Paper Trail") }
                MenuSeparator()
                SubMenuItem(id: "pt-sub-labels-\(thread.id)", label: "Labels", icon: "tag") {
                    LabelMenuItems(current: Set(thread.labels.map(\.id))) { id, on in
                        Task {
                            if let d = await Mail.act(thread.id, .labels(add: on ? [id] : [], remove: on ? [] : [id])) {
                                onUpdate { $0.labels = d.summary.labels }
                            }
                        }
                    }
                }
                SubMenuItem(id: "pt-sub-collect-\(thread.id)", label: "Add to collection", icon: "folderOpen") {
                    CollectionMenuItems(current: collections) { id, on in
                        if on { collections.insert(id) } else { collections.remove(id) }
                        Task { _ = await Mail.raw(thread.id, ["action": "collections", (on ? "add" : "remove"): [id]]) }
                    }
                }
                MenuItem(thread.note.isEmpty ? "Add note" : "Edit note", icon: "stickyNote") { noteOpen.toggle() }
                MenuSeparator()
                MenuItem("Keep in Imbox", icon: "inbox") { onLeave(.move(.imbox), "Kept in the Imbox") }
                MenuItem("Trash", icon: "trash2") { onLeave(.move(.trash), "Moved to trash") }
            }
        }
    }

    private func saveNote() {
        let text = note
        noteOpen = false
        Task {
            if let d = await Mail.act(thread.id, .note(text), toast: "Note saved") {
                onUpdate { $0.note = d.summary.note }
            }
        }
    }
}

/// `DropdownMenuLabel`: px-1.5 py-1 text-xs font-medium muted.
private struct DropdownLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(W.font(12, 500)).webLine(12).foregroundStyle(W.mutedForeground)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
