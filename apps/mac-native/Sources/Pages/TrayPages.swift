import SwiftUI

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
                    VStack(alignment: .leading, spacing: 16) { SkeletonBlock(width: 64); SkeletonBlock(width: 380, height: 24); SkeletonBlock(width: 220); SkeletonBlock(height: 128) }.padding(20).background(W.muted40).rounded(W.radiusMd)
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
            .onKeys(["j": { go(1) }, "k": { go(-1) }, "]": { go(1) }, "[": { go(-1) }, "d": { if let c = current { done(c) } }], enabled: !list.isEmpty && ui.region == .content)
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
                    if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: thread.accountID)) }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 20).padding(.top, 16)

            VStack(alignment: .leading, spacing: 12) {
                if store.loading && msgs.isEmpty { VStack(alignment: .leading, spacing: 12) { SkeletonBlock(width: 200); SkeletonBlock(); SkeletonBlock(width: 500); SkeletonBlock(width: 380) } }
                if let error = store.error { ErrorStateView(message: error) { Task { await store.load(thread.id, peek: true) } } }
                if let last {
                    if msgs.count > 1 {
                        Button { router.go(.thread(thread.id, peek: false)) } label: {
                            HStack(spacing: 4) { Text("\(msgs.count - 1) earlier message\(msgs.count - 1 == 1 ? "" : "s") in this thread"); Icon("arrowUpRight", size: 12) }.font(W.xs).foregroundStyle(W.mutedForeground)
                        }
                        .buttonStyle(.plain)
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
        .onKeys(["r": { startReply() }], enabled: replying == nil, priority: 1)
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
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("\(number)").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).frame(width: 16, alignment: .trailing)
                WAvatar(thread.lastFrom, size: 20)
                Text(thread.displaySubject).font(W.font(14, active ? 500 : 400)).lineLimit(1)
                Spacer()
                Text(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1).frame(maxWidth: 200, alignment: .trailing)
                Text(Fmt.time(thread.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
            }
            .padding(.horizontal, 8).frame(height: 40)
            .background(active || hovering ? W.accent : Color.clear)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) { ForEach(0..<3, id: \.self) { _ in VStack(alignment: .leading, spacing: 12) { SkeletonBlock(width: 140); SkeletonBlock(width: 220, height: 16); SkeletonBlock(); SkeletonBlock(width: 200) }.padding(16).background(W.muted40).rounded(W.radiusMd) } }
                } else if list.isEmpty { EmptyStateView(icon: "bookmark", title: "Nothing set aside.", body: "Press a on any thread to keep it handy here.") }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), alignment: .leading, spacing: 12) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                        SetAsideCard(thread: t, focused: cursor == i, leaving: leaving.contains(t.id)) { done(t) }
                    }
                }
            }
            .task { await imbox.load() }
            .syncsWithMail { await imbox.refresh() }
            .onKeys(["j": { cursor = min(cursor + 1, list.count - 1) }, "k": { cursor = max(cursor - 1, 0) }, "ArrowDown": { cursor = min(cursor + 1, list.count - 1) }, "ArrowUp": { cursor = max(cursor - 1, 0) },
                     "Enter": { if list.indices.contains(cursor) { router.go(.thread(list[cursor].id, peek: false)) } }, "o": { if list.indices.contains(cursor) { router.go(.thread(list[cursor].id, peek: false)) } }], enabled: ui.region == .content)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                WAvatar(thread.lastFrom, size: 20)
                Text(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name).font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1)
                Spacer()
                if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: thread.accountID)) }
                Text(Fmt.time(thread.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).help(Fmt.full(thread.lastMessageAt))
            }
            .padding(.horizontal, 16).padding(.top, 16)
            Button { router.go(.thread(thread.id, peek: false)) } label: {
                Text(thread.displaySubject).font(W.font(14, 600)).lineSpacing(2).lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
    }
}

/// `PowerThrough.tsx`: the new pile, one card after another.
struct PowerThroughPage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @Environment(PopLayerState.self) private var pops
    @State private var store = PowerThroughStore()
    @State private var cursor = 0
    @State private var leaving: Set<String> = []
    @State private var replying: [String: ComposerModel] = [:]

    private var items: [ThreadSummary] { store.items }
    private var current: ThreadSummary? { items.indices.contains(cursor) ? items[cursor] : nil }

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() } else {
            PageColumn(width: 672) {
                HStack {
                    WButton("Back to the Imbox", icon: "arrowLeft", variant: .ghost, size: .sm, muted: true, kbd: "esc") { router.go(.imbox) }.padding(.leading, -8)
                    Spacer()
                    if !items.isEmpty { Text("\(cursor + 1) of \(items.count)").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground) }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
                PageHeader(title: "Power through new", subtitle: items.isEmpty ? "Everything new, one at a time." : "\(items.count) new. Reply, file or drop each one, then it's out of your way.") {
                    if !items.isEmpty { WButton("Mark all seen", icon: "check", variant: .outline, size: .sm) { Task { if await store.markAllSeen() { Mail.invalidate(); router.go(.imbox) } } } }
                }
                if let error = store.error { ErrorStateView(message: error) { Task { await store.refresh() } } }
                else if store.loading && items.isEmpty { FeedSkeleton() }
                else if items.isEmpty { EmptyStateView(icon: "zap", title: "Nothing new to power through.", body: "Go enjoy your day.") { WButton("Back to the Imbox", variant: .ghost, size: .sm) { router.go(.imbox) } } }
                LazyVStack(spacing: 16) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                        PowerCard(thread: t, focused: i == cursor, leaving: leaving.contains(t.id), replying: replying[t.id],
                                  onFocus: { cursor = i }, onReply: { startReply(t) }, onAct: { action, msg in act(t, action, msg) })
                            .id(t.id)
                    }
                }
            }
            .task { await store.firstLoad() }
            .onKeys([
                "j": { cursor = min(cursor + 1, max(items.count - 1, 0)) }, "k": { cursor = max(cursor - 1, 0) },
                "ArrowDown": { cursor = min(cursor + 1, max(items.count - 1, 0)) }, "ArrowUp": { cursor = max(cursor - 1, 0) },
                "Enter": { if let c = current { router.go(.thread(c.id, peek: false)) } },
                "r": { if let c = current { startReply(c) } },
                "l": { if let c = current { act(c, .replyLater(true), "Added to Reply Later") } },
                "a": { if let c = current { act(c, .setAside(true), "Set aside") } },
                "e": { if let c = current { act(c, .seen, "Marked seen") } },
                "#": { if let c = current { act(c, .move(.trash), "Moved to trash") } },
                "Escape": { router.go(.imbox) },
            ], enabled: ui.region == .content && replying.isEmpty)
        }
    }

    private func act(_ t: ThreadSummary, _ action: ThreadAction, _ msg: String) {
        leaving.insert(t.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            _ = store.remove(t.id)
            if cursor >= store.items.count { cursor = max(store.items.count - 1, 0) }
            leaving.remove(t.id)
            Mail.bulk([t.id], action, toast: msg)
        }
    }

    private func startReply(_ t: ThreadSummary) {
        guard let m = t.latestMessage else { router.go(.thread(t.id, peek: false)); return }
        let model = ComposerModel(initial: replyInitial(t, m, .reply, myEmail: app.account(t.accountID)?.email))
        model.onDone = { replying[t.id] = nil; act(t, .seen, "Replied") }
        model.onCancel = { replying[t.id] = nil }
        Compose.current = model
        replying[t.id] = model
    }
}

private struct PowerCard: View {
    let thread: ThreadSummary
    var focused = false
    var leaving = false
    var replying: ComposerModel?
    var onFocus: () -> Void
    var onReply: () -> Void
    var onAct: (ThreadAction, String) -> Void

    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var expanded = false
    @State private var bodyHeight: CGFloat = 0
    private let cap: CGFloat = 560

    var body: some View {
        let m = thread.latestMessage
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                WAvatar(thread.lastFrom, size: 20)
                Text(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name).font(W.font(14, 500)).lineLimit(1)
                if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: thread.accountID)) }
                Text(thread.lastFrom.email).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                Spacer()
                if thread.messageCount > 1 { Text("\(thread.messageCount) messages").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground) }
                Text(Fmt.time(thread.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).help(Fmt.full(thread.lastMessageAt))
            }
            .padding(.horizontal, 20).padding(.top, 20)
            Button { router.go(.thread(thread.id, peek: false)) } label: {
                Text(thread.displaySubject).font(W.font(20, 600)).tracking(-0.2).lineSpacing(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.top, 12)
            if !thread.note.isEmpty {
                HStack(alignment: .top, spacing: 8) { Icon("stickyNote", size: 14).foregroundStyle(W.mutedForeground); Text(thread.note).font(W.s13) }
                    .padding(.horizontal, 12).padding(.vertical, 8).background(W.background).rounded(W.radiusMd).padding(.horizontal, 20).padding(.top, 12)
            }
            ZStack(alignment: .bottom) {
                Group { if let m { HtmlBodyView(html: m.htmlBody, text: m.textBody, trackers: m.trackers) } else { Text(thread.snippet).font(W.sm) } }
                    .background(GeometryReader { g in Color.clear.onChange(of: g.size.height, initial: true) { _, h in bodyHeight = h } })
                    .frame(maxHeight: expanded ? nil : cap, alignment: .top).clipped()
                if !expanded && bodyHeight > cap + 24 {
                    LinearGradient(colors: [W.background.opacity(0), W.background.opacity(0.8), W.background], startPoint: .top, endPoint: .bottom).frame(height: 96)
                        .overlay(alignment: .bottom) { WButton("Read more", trailingIcon: "chevronDown", variant: .outline, size: .sm) { expanded = true }.padding(.bottom, 8) }
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)

            if let replying {
                ComposerView(model: replying, inline: true).background(W.background).rounded(W.radiusMd).padding(12)
            } else {
                HStack(spacing: 4) {
                    WButton("Reply", icon: "reply", size: .sm, help: "Reply  r", action: onReply)
                    WButton("Open", icon: "arrowUpRight", variant: .ghost, size: .sm, muted: true, help: "Open the full thread  ↵") { router.go(.thread(thread.id, peek: false)) }
                    Spacer()
                    WButton("Reply later", icon: "clock", variant: .ghost, size: .sm, muted: true, help: "Reply later  l") { onAct(.replyLater(true), "Added to Reply Later") }
                    WButton("Set aside", icon: "bookmark", variant: .ghost, size: .sm, muted: true, help: "Set aside  a") { onAct(.setAside(true), "Set aside") }
                    WButton(icon: "arrowUpCircle", variant: .ghost, size: .iconSm, muted: true, help: "Bubble up") {
                        pops.toggle("pt-bubble-\(thread.id)", side: .top, align: .end) { PopCard { DateTimePicker(embedded: true) { at in pops.closeAll(); onAct(.bubbleUp(at), "Will bubble up \(Fmt.relative(at.timeIntervalSince1970 * 1000))") } } }
                    }
                    .popAnchor("pt-bubble-\(thread.id)")
                    WButton("Done", icon: "check", variant: .outline, size: .sm, help: "Mark seen  e") { onAct(.seen, "Marked seen") }
                    WButton(icon: "trash2", variant: .ghost, size: .iconSm, muted: true, help: "Trash  #") { onAct(.move(.trash), "Moved to trash") }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .background(W.muted40)
        .overlay { if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.ring, lineWidth: 1) } }
        .rounded(W.radiusMd)
        .opacity(leaving ? 0 : 1)
        .onHover { if $0 { onFocus() } }
    }
}
