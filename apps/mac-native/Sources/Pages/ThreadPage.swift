import SwiftUI
import AppKit

enum ReplyMode { case reply, replyAll, forward
    var label: String { switch self { case .reply: return "Reply"; case .replyAll: return "Reply all"; case .forward: return "Forward" } }
    var icon: String { switch self { case .reply: return "reply"; case .replyAll: return "replyAll"; case .forward: return "forward" } }
}

/// `replyInitial`: the composer prefill for a reply, reply-all or forward.
func replyInitial(_ thread: ThreadSummary, _ m: Message, _ mode: ReplyMode, myEmail: String?) -> ComposerInitial {
    let me = (myEmail ?? "").lowercased()
    let esc = HtmlBodyView.escape
    let body = m.htmlBody.isEmpty ? HTMLText.htmlBody(from: m.textBody) : m.htmlBody
    let quoted = "<div>On \(Fmt.full(m.date)), \(esc(m.from.name.isEmpty ? m.from.email : m.from.name)) &lt;\(esc(m.from.email))&gt; wrote:</div>\(body)"
    let subj = thread.originalSubject.isEmpty ? (thread.subject.isEmpty ? m.subject : thread.subject) : thread.originalSubject
    if mode == .forward {
        let header = "<div>---------- Forwarded message ----------<br>From: \(esc(m.from.name)) &lt;\(esc(m.from.email))&gt;<br>Date: \(Fmt.full(m.date))<br>Subject: \(esc(m.subject))<br>To: \(esc(m.to.map(\.email).joined(separator: ", ")))</div><br>"
        return ComposerInitial(accountID: thread.accountID, subject: subj.range(of: "^fwd?:", options: [.regularExpression, .caseInsensitive]) != nil ? subj : "Fwd: \(subj)", quotedHTML: header + body, title: "Forward")
    }
    var to: [Address] = m.isFromMe ? m.to : [m.from]
    var cc: [Address] = []
    if mode == .replyAll {
        let seen = Set(to.map(\.email))
        let extra = (m.to + m.cc).filter { $0.email.lowercased() != me && !seen.contains($0.email) }
        var dedup: [Address] = []
        for a in extra where !dedup.contains(where: { $0.email == a.email }) { dedup.append(a) }
        cc = dedup
    }
    to = to.filter { $0.email.lowercased() != me || m.isFromMe }
    return ComposerInitial(accountID: thread.accountID, threadID: thread.id, replyToMessageID: m.id, to: to, cc: cc,
                           subject: subj.range(of: "^re:", options: [.regularExpression, .caseInsensitive]) != nil ? subj : "Re: \(subj)", quotedHTML: quoted, title: mode == .replyAll ? "Reply all" : "Reply")
}

/// `Thread.tsx`.
struct ThreadPageView: View {
    let threadID: String
    var peek = false

    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @Environment(PopLayerState.self) private var pops
    @Environment(DialogState.self) private var dialogs
    @Environment(Toasts.self) private var toasts

    @State private var store = ThreadStore()
    @State private var msgCursor = -1
    @State private var reply: (mode: ReplyMode, message: Message, model: ComposerModel)?
    @State private var renaming = false
    @State private var subjectDraft = ""
    @State private var noteOpen = false
    @State private var noteDraft = ""
    @State private var hoverTitle = false
    @State private var seeded = false

    private var t: ThreadDetail? { store.detail }
    private var account: Account? { app.account(t?.summary.accountID) }
    private var lastIncoming: Message? { t.flatMap { d in d.messages.last { !$0.isFromMe } ?? d.messages.last } }

    var body: some View {
        Group {
            if let error = store.error, t == nil {
                ErrorStateView(message: error) { Task { await store.load(threadID, peek: peek) } }
            } else if let t {
                PageColumn(width: 672) {
                    content(t)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 128)
            } else {
                PageColumn(width: 672) {
                    SkeletonBlock(width: 64, height: 24).padding(.bottom, 24)
                    SkeletonBlock(width: 420, height: 28).padding(.bottom, 12)
                    SkeletonBlock(width: 200, height: 14).padding(.bottom, 32)
                    SkeletonBlock(height: 96).padding(.bottom, 12)
                    SkeletonBlock(height: 192)
                }
                .padding(.horizontal, 8)
            }
        }
        .task {
            await store.load(threadID, peek: peek)
            if !peek, store.detail != nil { Mail.invalidate() }
            seed()
        }
        .syncsWithMail { await store.load(threadID, peek: true); seed() }
        .onChange(of: store.detail?.id) { _, _ in seed() }
        .onAppear { publishDock() }
        .onChange(of: t?.summary) { _, _ in publishDock() }
        .onChange(of: reply?.message.id) { _, _ in publishDock() }
        .onDisappear { ui.dock = nil; ui.currentThread = nil }
        .onKeys([
            "ArrowDown": { moveMsg(1) }, "ArrowUp": { moveMsg(-1) }, "j": { moveMsg(1) }, "k": { moveMsg(-1) },
            "Enter": { toggleFocused() }, "o": { toggleFocused() },
            "r": { openReply(.reply) }, "f": { openReply(.forward) },
            "l": { toggleReplyLater() }, "a": { toggleSetAside() },
            "z": { pops.open("thread-bubble", side: .top, align: .center) { bubblePopover } },
            "u": { run(.markUnread, "Marked unread") },
            "n": { noteOpen = true },
            "#": { run(.move(.trash), "Moved to trash"); router.back() },
            "Escape": { if reply != nil { reply = nil } else { router.back() } },
        ], enabled: !renaming && !noteOpen && ui.region == .content)
    }

    private func seed() {
        guard let t, !seeded else { return }
        seeded = true
        if store.expanded.isEmpty {
            if let last = t.messages.last { store.expanded.insert(last.id) }
            for m in t.messages where m.unread { store.expanded.insert(m.id) }
        }
        noteDraft = t.summary.note
        ui.currentThread = .init(id: t.id, subject: t.summary.subject, from: t.summary.lastFrom.name.isEmpty ? t.summary.lastFrom.email : t.summary.lastFrom.name)
    }

    private func publishDock() {
        guard let t, reply == nil else { ui.dock = nil; return }
        ui.dock = AnyView(actionBar(t))
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ t: ThreadDetail) -> some View {
        let s = t.summary
        let renamed = !s.subject.isEmpty && s.subject != s.originalSubject
        // Top row
        HStack(spacing: 8) {
            WButton("Back", icon: "arrowLeft", variant: .ghost, size: .sm, muted: true, kbd: "esc") { router.back() }.padding(.leading, -8)
            Spacer()
            HStack(spacing: 6) {
                if s.bucket != .imbox && s.bucket != .trash { WBadge(s.bucket.title, icon: bucketIcon(s.bucket), variant: .outline, muted: true) }
                if s.bucket == .trash { WBadge("Trash", icon: "trash2", variant: .outline, muted: true) }
                if s.replyLater { WBadge("Reply later", icon: "clock", variant: .secondary, muted: true) }
                if s.setAside { WBadge("Set aside", icon: "bookmark", variant: .secondary, muted: true) }
                if let at = s.bubbleUpAt { WBadge("Bubbles up \(Fmt.relative(at))", icon: "arrowUpCircle", variant: .secondary, muted: true) }
            }
        }
        .padding(.bottom, 16)

        // Title
        if renaming {
            VStack(alignment: .leading, spacing: 8) {
                TextField(s.originalSubject, text: $subjectDraft)
                    .textFieldStyle(.plain)
                    .font(W.font(24, 600)).tracking(-0.48).foregroundStyle(W.foreground)
                    .onSubmit { saveRename() }
                    .padding(.bottom, 4)
                    .edgeLine(.bottom, W.ring)
                HStack(spacing: 4) {
                    WButton("Save", icon: "check", size: .sm) { saveRename() }
                    WButton("Cancel", variant: .ghost, size: .sm) { renaming = false }
                    Text("Only you see this name.").font(W.xs).foregroundStyle(W.mutedForeground).padding(.leading, 8)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 4) {
                Text(s.subject.isEmpty ? "(no subject)" : s.subject)
                    .font(W.font(24, 600)).tracking(-0.48)
                    .foregroundStyle(s.subject.isEmpty ? W.tertiary : W.foreground)
                    .textSelection(.enabled)
                WButton(icon: "pencil", variant: .ghost, size: .iconXs, muted: true, help: "Rename subject") { subjectDraft = s.subject; renaming = true }
                    .opacity(hoverTitle ? 1 : 0).padding(.top, 4)
            }
            .onHover { hoverTitle = $0 }
        }
        if renamed && !renaming { Text("originally “\(s.originalSubject)”").font(W.xs).foregroundStyle(W.mutedForeground).padding(.top, 4) }

        // Meta row
        let me = (account?.email ?? "").lowercased()
        let others = s.participants.filter { $0.email.lowercased() != me }
        let names = (others.isEmpty ? s.participants : others).map { $0.name.trimmingCharacters(in: .whitespaces).isEmpty ? $0.email : $0.name.trimmingCharacters(in: .whitespaces) }
        HStack(spacing: 8) {
            WAvatarStack(people: s.participants, size: 20, max: 4)
            Text(names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")).font(W.s13).foregroundStyle(W.foreground80).lineLimit(1)
            Text("· \(s.messageCount) message\(s.messageCount == 1 ? "" : "s")").font(W.s13).monospacedDigit().foregroundStyle(W.mutedForeground)
            if app.accounts.count > 1, let account {
                HStack(spacing: 4) { AccountGlyph(glyph: app.glyph(for: account.id)); Text(account.email) }.font(W.xs).foregroundStyle(W.mutedForeground)
            }
            ForEach(s.labels) { l in Button { router.go(.label(l.id)) } label: { LabelChip(label: l) }.buttonStyle(.plain) }
            ForEach(t.collections) { c in Button { router.go(.collection(c.id)) } label: { WBadge(c.name, icon: "folderOpen", variant: .outline) }.buttonStyle(.plain) }
        }
        .padding(.top, 10)

        // Sticky note
        if !s.note.isEmpty || noteOpen {
            HStack(alignment: .top, spacing: 8) {
                Icon("pin", size: 13).foregroundStyle(W.mutedForeground).padding(.top, 4)
                if noteOpen {
                    VStack(alignment: .leading, spacing: 6) {
                        WTextArea(placeholder: "A private note, just for you.", text: $noteDraft, minHeight: 56, fontSize: 13)
                        HStack(spacing: 4) {
                            if !s.note.isEmpty { WButton("Remove note", variant: .ghost, size: .xs, muted: true) { run(.note(""), "Note removed"); noteOpen = false } }
                            Spacer()
                            WButton("Cancel", variant: .ghost, size: .xs) { noteOpen = false; noteDraft = s.note }
                            WButton("Save", size: .xs, kbd: "⌘↵") { saveNote() }
                        }
                    }
                } else {
                    Text(s.note).font(W.s13).lineSpacing(4).foregroundStyle(W.foreground).textSelection(.enabled)
                    Spacer()
                    Icon("pencil", size: 12).foregroundStyle(W.mutedForeground).padding(.top, 4)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(W.muted)
            .rounded(W.radiusMd)
            .padding(.top, 16)
            .contentShape(Rectangle())
            .onTapGesture { if !noteOpen { noteOpen = true } }
        }

        // Clips
        if !t.clips.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(t.clips) { c in
                    HStack(spacing: 4) {
                        Icon("scissors", size: 12).foregroundStyle(W.mutedForeground)
                        Text("“\(c.text)”").font(W.xs).lineLimit(1).frame(maxWidth: 288)
                        WButton(icon: "x", variant: .ghost, size: .iconXs, muted: true, help: "Delete clip") {
                            Task { try? await APIClient.shared.deleteClip(c.id); store.removeClip(c.id); toasts.show("Clip removed") }
                        }
                        .frame(width: 20, height: 20)
                    }
                    .padding(.leading, 8).padding(.trailing, 2).frame(height: 24)
                    .background(W.secondary).clipShape(Capsule())
                    .help(c.text)
                }
            }
            .padding(.top, 12)
        }

        // Summary
        switch store.summary {
        case .running: HStack(spacing: 8) { Icon("sparkles", size: 14); Text("Summarising…") }.font(W.s13).foregroundStyle(W.mutedForeground).padding(.top, 16)
        case .ready(let text): AiSummaryPanel(summary: text) { store.dismissSummary() }.padding(.top, 16)
        case .unconfigured: Text("Add your Anthropic API key in Settings → AI to summarise.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.top, 16)
        case .failed(let m): Text(m).font(W.s13).foregroundStyle(W.mutedForeground).padding(.top, 16)
        case .idle: EmptyView()
        }

        // Messages
        let allExpanded = store.expanded.count >= t.messages.count
        VStack(alignment: .leading, spacing: 0) {
            if t.messages.count > 2 {
                HStack { Spacer(); WButton(allExpanded ? "Collapse older" : "Expand all \(t.messages.count)", icon: "chevronsDownUp", variant: .ghost, size: .xs, muted: true) {
                    if allExpanded { store.expanded = Set([t.messages.last!.id]) } else { store.expanded = Set(t.messages.map(\.id)) }
                } }
            }
            ForEach(Array(t.messages.enumerated()), id: \.element.id) { i, m in
                MessageRow(message: m, expanded: store.expanded.contains(m.id), focused: i == msgCursor, isLast: i == t.messages.count - 1,
                           onToggle: { store.toggle(m.id) },
                           onReply: { mode in openReply(mode, m) },
                           onClip: { text in Task { if let c = try? await APIClient.shared.createClip(threadID: t.id, messageID: m.id, text: text) { store.addClip(c); toasts.show("Clip saved") } } },
                           onMarkUnread: { run(.markUnread, "Marked unread") })
                    .edgeLine(.bottom)
            }
        }
        .padding(.top, 20)

        // Reply box
        VStack(spacing: 0) {
            if let reply {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Icon(reply.mode.icon, size: 14).foregroundStyle(W.mutedForeground)
                        Text(reply.mode.label).font(W.font(13, 500))
                        if reply.mode != .forward {
                            Text("to \(reply.message.isFromMe ? reply.message.to.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", ") : (reply.message.from.name.isEmpty ? reply.message.from.email : reply.message.from.name))").font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1)
                        }
                        Spacer()
                        WButton(icon: "x", variant: .ghost, size: .iconXs, muted: true, help: "Close") { self.reply = nil }
                    }
                    .padding(.horizontal, 12).frame(height: 36).edgeLine(.bottom)
                    ComposerView(model: reply.model, inline: true)
                }
                .background(W.background)
                .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.border, lineWidth: 1))
                .rounded(W.radiusLg)
                .id("reply-\(reply.message.id)-\(reply.mode.label)")
            } else {
                ReplyPrompt(account: account, userName: app.user?.name ?? "", target: replyTarget) { openReply(.reply) }
            }
        }
        .padding(.top, 16)
    }

    private var replyTarget: String {
        guard let m = lastIncoming else { return "" }
        if m.isFromMe { return m.to.first.map { $0.name.isEmpty ? $0.email : $0.name } ?? "" }
        return m.from.name.isEmpty ? m.from.email : m.from.name
    }

    private func bucketIcon(_ b: Bucket) -> String? {
        switch b { case .imbox: return "inbox"; case .feed: return "rss"; case .paperTrail: return "scrollText"; default: return nil }
    }

    // MARK: Docked action bar

    private func actionBar(_ t: ThreadDetail) -> some View {
        let s = t.summary
        return HStack(spacing: 4) {
            ButtonGroup {
                WButton("Reply", icon: "reply", size: .sm) { openReply(.reply) }
                WButton("All", icon: "replyAll", variant: .outline, size: .sm, help: "Reply all") { openReply(.replyAll) }
                WButton("Forward", icon: "forward", variant: .outline, size: .sm, help: "Forward  f") { openReply(.forward) }
                WButton("Reply with AI", icon: "sparkles", variant: .outline, size: .sm, expanded: pops.isOpen("thread-ai")) {
                    pops.toggle("thread-ai", side: .top, align: .start) {
                        PopCard(width: 380, padding: 12) { AiReplyForm(threadID: t.id) { r in pops.closeAll(); openReply(.reply, lastIncoming, bodyHTML: r) } }
                    }
                }
                .popAnchor("thread-ai")
            }
            ButtonGroup {
                WButton("Reply later", icon: "clock", variant: .outline, size: .sm, expanded: s.replyLater, help: s.replyLater ? "Remove from Reply Later  l" : "Reply later  l") { toggleReplyLater() }
                WButton("Set aside", icon: "bookmark", variant: .outline, size: .sm, expanded: s.setAside, help: s.setAside ? "Remove from Set Aside  a" : "Set aside  a") { toggleSetAside() }
                WButton("Bubble up", icon: "arrowUpCircle", variant: .outline, size: .sm, expanded: s.bubbleUpAt != nil || pops.isOpen("thread-bubble"), help: "Bubble up  z") {
                    pops.toggle("thread-bubble", side: .top, align: .center) { bubblePopover }
                }
                .popAnchor("thread-bubble")
            }
            WButton("More", icon: "moreHorizontal", trailingIcon: "chevronDown", variant: .ghost, size: .sm, muted: true, expanded: pops.isOpen("thread-more")) {
                pops.toggle("thread-more", side: .top, align: .end) { moreMenu(t) }
            }
            .popAnchor("thread-more")
        }
        .padding(4)
        .fixedSize()
        .background(W.background.opacity(0.9))
        .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.border, lineWidth: 1))
        .rounded(W.radiusLg)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.bottom, 16)
    }

    private var bubblePopover: some View {
        PopCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Bubble up · out of sight until then").font(W.font(12, 500)).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).frame(height: 28)
                DateTimePicker(embedded: true) { at in pops.closeAll(); run(.bubbleUp(at), "Will bubble up \(Fmt.relative(at.timeIntervalSince1970 * 1000))") }
                if t?.summary.bubbleUpAt != nil {
                    WSeparator().padding(.vertical, 4)
                    WButton("Cancel bubble up", icon: "x", variant: .ghost, size: .sm, muted: true) { pops.closeAll(); run(.bubbleUp(nil), "Bubble up cancelled") }
                }
            }
        }
    }

    @ViewBuilder
    private func moreMenu(_ t: ThreadDetail) -> some View {
        let s = t.summary
        PopCard(width: 224) {
            MenuLabel("Move to")
            ForEach([Bucket.imbox, .feed, .paperTrail].filter { $0 != s.bucket }, id: \.self) { b in
                MenuItem(b.title, icon: bucketIcon(b)) { run(.move(b), "Moved to \(b.title)") }
            }
            MenuSeparator()
            MenuItem(store.summary == .running ? "Summarising…" : "Summarise with AI", icon: "sparkles", disabled: store.summary == .running) { Task { await store.summarise(t.id) } }
            MenuItem("Create event", icon: "calendarPlus") {
                Task {
                    if let draft = try? await CalendarAPI.eventDraft(threadID: t.id) { ui.pendingEvent = draft }
                    router.go(.calendar)
                }
            }
            MenuItem("Rename subject", icon: "pencil") { subjectDraft = s.subject; renaming = true }
            MenuItem(s.note.isEmpty ? "Stick a note on it" : "Edit note", icon: "stickyNote", shortcut: "n") { noteOpen = true }
            MenuItem("Labels", icon: "tag") {
                pops.open("thread-labels", side: .top, align: .end) {
                    PopCard(padding: 0) { LabelPicker(current: Set(s.labels.map(\.id)), onToggle: { id, on in run(.labels(add: on ? [id] : [], remove: on ? [] : [id]), nil) }, onClose: { pops.closeAll() }) }
                }
            }
            MenuItem("Collections", icon: "folderOpen") {
                pops.open("thread-collections", side: .top, align: .end) {
                    PopCard(padding: 0) { CollectionPicker(current: Set(t.collections.map(\.id)), onToggle: { id, on in Task { await Mail.raw(t.id, ["action": "collections", (on ? "add" : "remove"): [id]]); await store.load(t.id, peek: true) } }, onClose: { pops.closeAll() }) }
                }
            }
            MenuItem("Merge with…", icon: "gitMerge") {
                dialogs.present("merge", width: 448) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Merge into this thread").font(W.font(14, 600))
                            Text("Fold another conversation into this one. Their messages join this thread.").font(W.xs).foregroundStyle(W.mutedForeground)
                        }
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        ThreadPicker(exclude: [t.id]) { other in
                            dialogs.dismiss("merge")
                            Task { if await Mail.raw(t.id, ["action": "merge", "thread_ids": [other.id]], toast: "Merged “\(other.subject)”") { await store.load(t.id, peek: true) } }
                        }
                        .frame(width: 448)
                    }
                }
            }
            if s.bucket == .imbox || s.bucket == .paperTrail {
                MenuItem(t.senderBundled ? "Unbundle sender" : "Bundle up sender", icon: "layers") {
                    Task { if let d = try? await APIClient.shared.bundleSender(t.id, on: !t.senderBundled) { store.apply(d); Mail.invalidate(); toasts.show(t.senderBundled ? "Unbundled sender" : "Bundled up sender") } }
                }
            }
            MenuItem("Mark unread", icon: "mail", shortcut: "u") { run(.markUnread, "Marked unread") }
            MenuSeparator()
            if s.bucket != .trash { MenuItem("Trash", icon: "trash2", shortcut: "#") { run(.move(.trash), "Moved to trash"); router.back() } }
            MenuItem("Delete forever", icon: "trash2") {
                dialogs.confirm(title: "Delete this thread forever?", description: "It'll be removed here and trashed in \(account?.provider == "domain" ? "your mailbox" : "Gmail"). There's no undo.", action: "Delete forever") {
                    run(.delete, "Deleted"); router.go(.imbox)
                }
            }
        }
    }

    // MARK: Behaviour

    private func openReply(_ mode: ReplyMode, _ m: Message? = nil, bodyHTML: String? = nil) {
        guard let t, let msg = m ?? lastIncoming else { return }
        var initial = replyInitial(t.summary, msg, mode, myEmail: account?.email)
        if let bodyHTML { initial.bodyHTML = bodyHTML }
        let model = ComposerModel(initial: initial)
        model.onDone = { self.reply = nil }
        model.onCancel = { self.reply = nil }
        Compose.current = model
        reply = (mode, msg, model)
    }

    private func run(_ action: ThreadAction, _ msg: String?) {
        Task {
            if let d = await Mail.act(threadID, action, toast: msg) { store.apply(d) }
        }
    }

    private func toggleReplyLater() { guard let t else { return }; run(.replyLater(!t.summary.replyLater), t.summary.replyLater ? "Removed from Reply Later" : "Added to Reply Later") }
    private func toggleSetAside() { guard let t else { return }; run(.setAside(!t.summary.setAside), t.summary.setAside ? "Removed from Set Aside" : "Set aside") }

    private func saveRename() {
        guard let t else { return }
        let s = subjectDraft.trimmingCharacters(in: .whitespaces)
        run(.rename(s.isEmpty || s == t.summary.originalSubject ? nil : s), s.isEmpty ? "Name restored" : "Renamed")
        renaming = false
    }

    private func saveNote() { run(.note(noteDraft), "Note saved"); noteOpen = false }

    private func moveMsg(_ delta: Int) {
        guard let t, !t.messages.isEmpty else { return }
        msgCursor = msgCursor < 0 ? (delta > 0 ? 0 : t.messages.count - 1) : min(max(msgCursor + delta, 0), t.messages.count - 1)
    }

    private func toggleFocused() {
        guard let t, t.messages.indices.contains(msgCursor) else { return }
        store.toggle(t.messages[msgCursor].id)
    }
}

/// The "Reply to X…" row under the messages.
struct ReplyPrompt: View {
    let account: Account?
    let userName: String
    let target: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                WAvatar(email: account?.email ?? "", name: account?.displayName.isEmpty == false ? account!.displayName : userName, src: account?.avatarURL, size: 20)
                Text("Reply to \(target.isEmpty ? "this thread" : target)…").font(W.s13).foregroundStyle(hovering ? W.foreground : W.mutedForeground).lineLimit(1)
                Spacer()
                Kbd("r")
            }
            .padding(.horizontal, 8).frame(height: 40)
            .background(hovering ? W.muted : Color.clear)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `MessageRow`: collapsed 56pt header, or the header with the body under it.
struct MessageRow: View {
    let message: Message
    let expanded: Bool
    var focused = false
    var isLast = false
    var onToggle: () -> Void
    var onReply: (ReplyMode) -> Void
    var onClip: (String) -> Void
    var onMarkUnread: () -> Void

    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @Environment(Toasts.self) private var toasts
    @State private var plain = false
    @State private var hovering = false

    private var files: [Attachment] { message.attachments.filter { !$0.isInline } }
    private var who: String { message.isFromMe ? "You" : (message.from.name.isEmpty ? message.from.email : message.from.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                WAvatar(message.from, size: 24, strong: message.unread).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if message.isFromMe {
                            Text("You").font(W.font(13, 600)).foregroundStyle(W.foreground)
                        } else {
                            Button { router.go(.contactEmail(message.from.email, account: message.accountID)) } label: {
                                Text(who).font(W.font(13, 600)).foregroundStyle(W.foreground).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(message.from.email).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                        if message.unread { Circle().fill(W.foreground).frame(width: 6, height: 6) }
                    }
                    Text(expanded ? recipients : message.snippet).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Button(action: onToggle) { Text(Fmt.time(message.date)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).padding(.horizontal, 8).frame(height: 24) }
                        .buttonStyle(.plain).help(Fmt.full(message.date))
                    if expanded {
                        WButton(icon: "reply", variant: .ghost, size: .iconXs, muted: true, help: "Reply  r") { onReply(.reply) }
                        WButton(icon: "moreHorizontal", variant: .ghost, size: .iconXs, muted: true, expanded: pops.isOpen("msg-\(message.id)"), help: "More") {
                            pops.toggle("msg-\(message.id)", side: .bottom, align: .end) {
                                PopCard(width: 192) {
                                    MenuItem("Reply", icon: "reply", shortcut: "r") { onReply(.reply) }
                                    MenuItem("Reply all", icon: "replyAll") { onReply(.replyAll) }
                                    MenuItem("Forward", icon: "forward", shortcut: "f") { onReply(.forward) }
                                    MenuSeparator()
                                    MenuItem("Mark unread", icon: "mail") { onMarkUnread() }
                                    MenuItem(plain ? "Rich text" : "Plain text", icon: "fileText") { plain.toggle() }
                                    if !isLast { MenuItem("Collapse", icon: "chevronsDownUp") { onToggle() } }
                                }
                            }
                        }
                        .popAnchor("msg-\(message.id)")
                    }
                }
                .padding(.top, -4)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !expanded { onToggle() } }

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    HtmlBodyView(html: message.htmlBody, text: message.textBody, trackers: message.trackers, plain: plain, onClip: onClip)
                    if !files.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) { Icon("paperclip", size: 12); Text("\(files.count) attachment\(files.count == 1 ? "" : "s")") }.font(W.xs).foregroundStyle(W.mutedForeground)
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                                ForEach(files) { a in
                                    AttachmentItemView(filename: a.filename, mimeType: a.mimeType, size: a.size, onDownload: { download(a) }, onOpen: { download(a) })
                                }
                            }
                        }
                        .padding(.top, 16)
                    }
                }
                .padding(.leading, 34)
                .padding(.top, 12)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, expanded && !focused ? 0 : 8)
        .background(!expanded && hovering ? W.muted : Color.clear)
        .overlay { if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.ring, lineWidth: 1) } }
        .rounded(W.radiusMd)
        .padding(.horizontal, expanded && !focused ? 0 : -8)
        .onHover { hovering = $0 }
    }

    private var recipients: String {
        let to = message.to.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", ")
        var s = "to \(to.isEmpty ? "—" : to)"
        if !message.cc.isEmpty { s += " · cc " + message.cc.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", ") }
        return s
    }

    private func download(_ a: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.filename
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task {
            do {
                let data = try await APIClient.shared.data(path: "/api/messages/\(a.messageID)/attachments/\(a.id)", query: a.accountID.map { ["account_id": $0] } ?? [:])
                try data.write(to: target, options: .atomic)
                toasts.show("Saved \(a.filename)")
            } catch { toasts.error((error as? APIError)?.errorDescription ?? "Couldn't download that.") }
        }
    }
}

/// `AiSummaryPanel`.
struct AiSummaryPanel: View {
    let summary: String
    var onClose: () -> Void
    @State private var open = true
    var body: some View {
        let lines = summary.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Icon("sparkles", size: 14).foregroundStyle(W.mutedForeground)
                    Text("Summary").font(W.font(13, 500))
                    Spacer()
                    Icon(open ? "chevronUp" : "chevronDown", size: 14).foregroundStyle(W.mutedForeground)
                }
                .frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .top, spacing: 8) { Text("•").foregroundStyle(W.mutedForeground); Text(l.replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)) }
                            .font(W.s13).lineSpacing(3)
                    }
                }
                .padding(.leading, 8)
                Button("Hide", action: onClose).buttonStyle(.plain).font(W.font(11)).foregroundStyle(W.mutedForeground).padding(.top, 8)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(W.muted50)
        .rounded(W.radiusLg)
    }
}

/// `AiReplyForm`: a brief and a tone, then a draft comes back into the reply box.
struct AiReplyForm: View {
    let threadID: String
    var onResult: (String) -> Void
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var brief = ""
    @State private var tone = "match"
    @State private var pending = false
    @State private var settings = AiSettingsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if settings.settings?.configured == false {
                HStack(spacing: 4) {
                    Button { pops.closeAll(); router.go(.settings("ai")) } label: { Text("Add your Anthropic API key").underline() }.buttonStyle(.plain)
                    Text("in Settings → AI to write replies with AI.")
                }
                .font(W.s13).foregroundStyle(W.mutedForeground)
            } else {
                WTextArea(placeholder: "What do you want to say? e.g. “Yes, Tuesday at 3 works — ask them to send the agenda.”", text: $brief, minHeight: 72)
                HStack(spacing: 8) {
                    WToggleGroup(options: [ToggleOption(id: "match", label: "My tone"), ToggleOption(id: "formal", label: "Formal"), ToggleOption(id: "friendly", label: "Friendly"), ToggleOption(id: "brief", label: "Brief")], value: $tone, outline: true, fontSize: 12)
                    Spacer()
                    WButton(pending ? "Writing…" : "Write reply", icon: "sparkles", size: .sm) { go() }.disabled(brief.trimmingCharacters(in: .whitespaces).isEmpty || pending)
                }
                Text("Reads the whole thread and what I know about how you write. You review before sending.").font(W.font(11)).foregroundStyle(W.mutedForeground)
            }
        }
        .task { await settings.load() }
    }

    private func go() {
        pending = true
        Task {
            defer { pending = false }
            do {
                let r = try await APIClient.shared.aiReply(threadID: threadID, brief: brief.trimmingCharacters(in: .whitespaces), tone: ThreadAiTone(rawValue: tone) ?? .match)
                onResult(r.bodyHTML)
            } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
}
