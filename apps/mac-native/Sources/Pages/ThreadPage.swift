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
    // `reply.ts`: a Reply-To header names where the answer goes; the name stays the sender's.
    let replyTarget = m.replyTo.isEmpty ? m.from : Address(email: m.replyTo.lowercased(), name: m.from.name)
    var to: [Address] = m.isFromMe ? m.to : [replyTarget]
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

/// A key the web catches in one element's own `onKeyDown` (⌘↵ in the note, Enter in the AI
/// brief): taken before the menu bar or the text view sees it, only while `enabled`.
struct LocalKeyMonitor: ViewModifier {
    let enabled: Bool
    let matches: (NSEvent) -> Bool
    let action: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { update() }
            .onChange(of: enabled) { _, _ in update() }
            .onDisappear { remove() }
    }

    private func update() {
        remove()
        guard enabled else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if matches(event) { action(); return nil }
            return event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension View {
    func onLocalKey(enabled: Bool, matches: @escaping (NSEvent) -> Bool, action: @escaping () -> Void) -> some View {
        modifier(LocalKeyMonitor(enabled: enabled, matches: matches, action: action))
    }
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
    @Environment(\.pageScrollProxy) private var pageScroll

    @State private var store = ThreadStore()
    @State private var msgCursor = -1
    @State private var reply: (mode: ReplyMode, message: Message, model: ComposerModel)?
    @State private var renaming = false
    @State private var subjectDraft = ""
    @State private var noteOpen = false
    @State private var noteDraft = ""
    @State private var hoverTitle = false
    @State private var hoverNote = false
    @State private var creatingEvent = false
    @State private var seeded = false
    @FocusState private var renameFocused: Bool
    @FocusState private var noteFocused: Bool

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
        .syncsWithMail { await store.reload(threadID); seed() }
        .onChange(of: store.detail?.id) { _, _ in seed() }
        .onAppear { publishDock() }
        .onChange(of: t?.summary) { _, _ in publishDock() }
        .onChange(of: reply?.message.id) { _, _ in publishDock() }
        .onChange(of: ui.assistantOpen) { _, _ in publishDock() }
        .onDisappear { ui.clearDock(owner: "thread"); ui.currentThread = nil }
        // `useThreadSummary`: a failure is a toast, not a panel.
        .onChange(of: store.summary) { _, s in
            switch s {
            case .failed(let m): toasts.error(m); store.dismissSummary()
            case .unconfigured: toasts.error("Add your Anthropic API key in Settings → AI to summarise."); store.dismissSummary()
            default: break
            }
        }
        .onKeys([
            "ArrowDown": { moveMsg(1) }, "ArrowUp": { moveMsg(-1) }, "j": { moveMsg(1) }, "k": { moveMsg(-1) },
            "Enter": { toggleFocused() }, "o": { toggleFocused() },
            "r": { openReply(.reply) }, "f": { openReply(.forward) },
            "l": { toggleReplyLater() }, "a": { toggleSetAside() },
            "z": { pops.open("thread-bubble", side: .top, align: .center) { bubblePopover } },
            "u": { run(.markUnread, "Marked unread") },
            "n": { noteOpen = true },
            "#": { run(.move(.trash), "Moved to trash"); router.back() },
            "Escape": { if reply != nil { closeReply() } else { router.back() } },
        ], enabled: !renaming && !noteOpen && ui.region == .content)
        .cardScrollKeys(arrows: false, enabled: !renaming && !noteOpen && ui.region == .content)
        // Escape backs out of a rename or a note (and puts the note's text back), as the web's inputs do.
        .onKeys(["Escape": { renaming = false; if noteOpen { noteOpen = false; noteDraft = t?.summary.note ?? "" } }], enabled: renaming || noteOpen, priority: 10, whileTyping: true)
        // ⌘↵ in the note saves the note — and never reaches the composer's Send.
        .onLocalKey(enabled: noteOpen && noteFocused, matches: { e in (e.keyCode == 36 || e.keyCode == 76) && e.modifierFlags.contains(.command) }) { saveNote() }
        .onChange(of: renaming) { _, on in if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { renameFocused = true } } }
        .onChange(of: noteOpen) { _, on in if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { noteFocused = true } } }
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
        guard let t, reply == nil else { ui.clearDock(owner: "thread"); return }
        ui.setDock(AnyView(actionBar(t, compact: ui.assistantOpen)), owner: "thread")
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
                if s.bucket != .imbox && s.bucket != .trash { badge(s.bucket.title, icon: bucketIcon(s.bucket), variant: .outline, color: W.mutedForeground) }
                if s.bucket == .trash { badge("Trash", icon: "trash2", variant: .outline, color: W.mutedForeground) }
                if s.replyLater { badge("Reply later", icon: "clock", variant: .secondary, color: W.foreground) }
                if s.setAside { badge("Set aside", icon: "bookmark", variant: .secondary, color: W.foreground) }
                if let at = s.bubbleUpAt { badge("Bubbles up \(Fmt.relative(at))", icon: "arrowUpCircle", variant: .secondary, color: W.foreground) }
            }
        }
        .padding(.bottom, 16)

        // Title
        if renaming {
            VStack(alignment: .leading, spacing: 8) {
                TextField(s.originalSubject, text: $subjectDraft)
                    .textFieldStyle(.plain)
                    .font(W.font(24, 600)).tracking(-0.48).foregroundStyle(W.foreground)
                    .focused($renameFocused)
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
                HStack(spacing: 4) { AccountGlyph(glyph: app.glyph(for: account.id), label: account.email); Text(account.email) }.font(W.xs).foregroundStyle(W.mutedForeground)
            }
            ForEach(s.labels) { l in Button { router.go(.label(l.id)) } label: { LabelChip(label: l) }.buttonStyle(.plain) }
            ForEach(t.collections) { c in Button { router.go(.collection(c.id)) } label: { badge(c.name, icon: "folderOpen", variant: .outline, color: W.foreground90) }.buttonStyle(.plain) }
        }
        .padding(.top, 10)

        // Sticky note
        if !s.note.isEmpty || noteOpen {
            HStack(alignment: .top, spacing: 8) {
                Icon("pin", size: 13).foregroundStyle(W.mutedForeground).padding(.top, 4)
                if noteOpen {
                    VStack(alignment: .leading, spacing: 6) {
                        NoteEditor(text: $noteDraft, focused: $noteFocused)
                        HStack(spacing: 4) {
                            if !s.note.isEmpty { WButton("Remove note", variant: .ghost, size: .xs, muted: true) { run(.note(""), "Note removed"); noteOpen = false } }
                            Spacer()
                            WButton("Cancel", variant: .ghost, size: .xs) { noteOpen = false; noteDraft = s.note }
                            WButton("Save", size: .xs, kbd: "⌘↵") { saveNote() }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Text(s.note).font(W.s13).lineSpacing(4).foregroundStyle(W.foreground).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Icon("pencil", size: 12).foregroundStyle(W.mutedForeground).padding(.top, 4).opacity(hoverNote ? 1 : 0)
                    }
                    .onHover { hoverNote = $0 }
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
        case .ready(let text): AiSummaryPanel(summary: text) { store.dismissSummary() }.padding(.top, 16).padding(.bottom, 16)
        default: EmptyView()
        }

        // Messages
        let allExpanded = store.expanded.count >= t.messages.count
        VStack(alignment: .leading, spacing: 0) {
            if t.messages.count > 2 {
                HStack { Spacer(); WButton(allExpanded ? "Collapse older" : "Expand all \(t.messages.count)", icon: "chevronsDownUp", variant: .ghost, size: .xs, muted: true) {
                    if allExpanded { store.expanded = Set([t.messages.last!.id]) } else { store.expanded = Set(t.messages.map(\.id)) }
                } }
            }
            // `divide-y`: a line between rows, none after the last.
            ForEach(Array(t.messages.enumerated()), id: \.element.id) { i, m in
                MessageRow(message: m, expanded: store.expanded.contains(m.id), focused: i == msgCursor, isLast: i == t.messages.count - 1,
                           onToggle: { store.toggle(m.id) },
                           onReply: { mode in openReply(mode, m) },
                           onClip: { text in Task { if let c = try? await APIClient.shared.createClip(threadID: t.id, messageID: m.id, text: text) { store.addClip(c); toasts.show("Clip saved") } } },
                           onMarkUnread: { run(.markUnread, "Marked unread") })
                    .edgeLine(.bottom, i < t.messages.count - 1 ? W.border : Color.clear)
                    .id("msg-\(i)")
            }
            if !t.mergedThreads.isEmpty {
                HStack(spacing: 6) {
                    Icon("gitMerge", size: 12)
                    Text("Includes merged: \(t.mergedThreads.map(\.subject).joined(separator: ", "))")
                }
                .font(W.xs).foregroundStyle(W.mutedForeground)
                .padding(.top, 8)
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
                        WButton(icon: "x", variant: .ghost, size: .iconXs, muted: true, help: "Close") { closeReply() }
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
        .id("reply-box")
    }

    /// `Badge` with the thread's own classes: `font-normal`, and the colour the row asks for.
    private func badge(_ text: String, icon: String?, variant: WBadgeVariant, color: Color) -> some View {
        HStack(spacing: 4) {
            if let icon { Icon(icon, size: 12) }
            Text(text).lineLimit(1)
        }
        .font(W.font(12, 400))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(variant == .secondary ? W.secondary : Color.clear)
        .overlay { if variant == .outline { Capsule().strokeBorder(W.border, lineWidth: 1) } }
        .clipShape(Capsule())
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

    /// `compact`: with the assistant panel open the labels go and the icons stay (`data-compact-bar`).
    private func actionBar(_ t: ThreadDetail, compact: Bool) -> some View {
        let s = t.summary
        func label(_ text: String) -> String? { compact ? nil : text }
        return HStack(spacing: 4) {
            ButtonGroup {
                WButton("Reply", icon: "reply", size: .sm) { openReply(.reply) }
                WButton(label("All"), icon: "replyAll", variant: .outline, size: .sm, help: "Reply all") { openReply(.replyAll) }
                WButton(label("Forward"), icon: "forward", variant: .outline, size: .sm, help: "Forward  f") { openReply(.forward) }
                WButton(label("Reply with AI"), icon: "sparkles", variant: .outline, size: .sm, expanded: pops.isOpen("thread-ai"), help: "Reply with AI") {
                    pops.toggle("thread-ai", side: .top, align: .start) {
                        PopCard(width: 380, padding: 12) { AiReplyForm(threadID: t.id) { r in pops.closeAll(); openReply(.reply, lastIncoming, bodyHTML: r) } }
                    }
                }
                .popAnchor("thread-ai")
            }
            ButtonGroup {
                WButton(label("Reply later"), icon: "clock", variant: .outline, size: .sm, expanded: s.replyLater, help: s.replyLater ? "Remove from Reply Later  l" : "Reply later  l") { toggleReplyLater() }
                WButton(label("Set aside"), icon: "bookmark", variant: .outline, size: .sm, expanded: s.setAside, help: s.setAside ? "Remove from Set Aside  a" : "Set aside  a") { toggleSetAside() }
                WButton(label("Bubble up"), icon: "arrowUpCircle", variant: .outline, size: .sm, expanded: s.bubbleUpAt != nil || pops.isOpen("thread-bubble"), help: "Bubble up  z") {
                    pops.toggle("thread-bubble", side: .top, align: .center) { bubblePopover }
                }
                .popAnchor("thread-bubble")
            }
            WButton(label("More"), icon: "moreHorizontal", trailingIcon: "chevronDown", variant: .ghost, size: .sm, muted: true, expanded: pops.isOpen("thread-more"), help: "More") {
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
                    // `w-full justify-start`.
                    Button { pops.closeAll(); run(.bubbleUp(nil), "Bubble up cancelled") } label: {
                        HStack(spacing: 4) {
                            Icon("x", size: 14)
                            Text("Cancel bubble up")
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.web(.ghost, .sm, muted: true))
                }
            }
        }
    }

    private func closeSubmenus() {
        pops.close("thread-labels")
        pops.close("thread-collections")
    }

    @ViewBuilder
    private func moreMenu(_ t: ThreadDetail) -> some View {
        let s = t.summary
        let mailbox = (account?.provider == "domain" || account?.provider == "imap") ? "your mailbox" : (account?.provider == "outlook" ? "Outlook" : "Gmail")
        PopCard(width: 224) {
            MenuLabel("Move to")
            ForEach([Bucket.imbox, .feed, .paperTrail].filter { $0 != s.bucket }, id: \.self) { b in
                MenuItem(b.title, icon: bucketIcon(b)) { run(.move(b), "Moved to \(b.title)") }.onHover { if $0 { closeSubmenus() } }
            }
            MenuSeparator()
            MenuItem(store.summary == .running ? "Summarising…" : "Summarise with AI", icon: "sparkles", disabled: store.summary == .running) { Task { await store.summarise(t.id) } }.onHover { if $0 { closeSubmenus() } }
            // A failed prefill stays here; the calendar only opens with a draft to show.
            MenuItem("Create event", icon: "calendarPlus", disabled: creatingEvent) {
                creatingEvent = true
                Task {
                    defer { creatingEvent = false }
                    if let draft = try? await CalendarAPI.eventDraft(threadID: t.id) {
                        ui.pendingEvent = draft
                        router.go(.calendar(nil))
                    }
                }
            }
            .onHover { if $0 { closeSubmenus() } }
            MenuItem("Rename subject", icon: "pencil") { subjectDraft = s.subject; renaming = true }.onHover { if $0 { closeSubmenus() } }
            MenuItem(s.note.isEmpty ? "Stick a note on it" : "Edit note", icon: "stickyNote", shortcut: "n") { noteOpen = true }.onHover { if $0 { closeSubmenus() } }
            SubMenuItem(id: "thread-labels", label: "Labels", icon: "tag") {
                LabelMenuItems(current: Set(s.labels.map(\.id)), onToggle: { id, on in run(.labels(add: on ? [id] : [], remove: on ? [] : [id]), nil) }, onManage: { router.go(.labels) })
            }
            .onHover { if $0 { pops.close("thread-collections") } }
            SubMenuItem(id: "thread-collections", label: "Collections", icon: "folderOpen") {
                CollectionMenuItems(current: Set(t.collections.map(\.id)), onToggle: { id, on in Task { await Mail.raw(t.id, ["action": "collections", (on ? "add" : "remove"): [id]]); await store.reload(t.id) } }, onManage: { router.go(.collections) })
            }
            .onHover { if $0 { pops.close("thread-labels") } }
            MenuItem("Merge with…", icon: "gitMerge") {
                dialogs.present("merge", width: 448) {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Merge into this thread").font(W.font(14, 600)).webLine(14, 14, weight: 600)
                            Text("Fold another conversation into this one. Their messages join this thread.").font(W.xs).foregroundStyle(W.mutedForeground)
                        }
                        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        ThreadPicker(exclude: [t.id], inDialog: true) { other in
                            dialogs.dismiss("merge")
                            Task { if await Mail.raw(t.id, ["action": "merge", "thread_ids": [other.id]], toast: "Merged “\(other.subject)”") { await store.reload(t.id) } }
                        }
                    }
                }
            }
            .onHover { if $0 { closeSubmenus() } }
            if s.bucket == .imbox || s.bucket == .paperTrail {
                MenuItem(t.senderBundled ? "Unbundle sender" : "Bundle up sender", icon: "layers") {
                    Task { if let d = try? await APIClient.shared.bundleSender(t.id, on: !t.senderBundled) { store.apply(d); Mail.invalidate(); toasts.show(t.senderBundled ? "Unbundled sender" : "Bundled up sender") } }
                }
                .onHover { if $0 { closeSubmenus() } }
            }
            MenuItem("Mark unread", icon: "mail", shortcut: "u") { run(.markUnread, "Marked unread") }.onHover { if $0 { closeSubmenus() } }
            MenuSeparator()
            if s.bucket != .trash { MenuItem("Trash", icon: "trash2", shortcut: "#") { run(.move(.trash), "Moved to trash"); router.back() }.onHover { if $0 { closeSubmenus() } } }
            MenuItem("Delete forever", icon: "trash2") {
                dialogs.confirm(title: "Delete this thread forever?", description: "It'll be removed here and trashed in \(mailbox). There's no undo.", action: "Delete forever") {
                    run(.delete, "Deleted"); router.go(.imbox)
                }
            }
            .onHover { if $0 { closeSubmenus() } }
        }
    }

    // MARK: Behaviour

    private func openReply(_ mode: ReplyMode, _ m: Message? = nil, bodyHTML: String? = nil) {
        guard let t, let msg = m ?? lastIncoming else { return }
        var initial = replyInitial(t.summary, msg, mode, myEmail: account?.email)
        if let bodyHTML { initial.bodyHTML = bodyHTML }
        let model = ComposerModel(initial: initial)
        model.onDone = { closeReply() }
        model.onCancel = { closeReply() }
        Compose.current = model
        reply = (mode, msg, model)
        // `scrollIntoView({ behavior: "smooth", block: "nearest" })` once the box is on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.easeOut(duration: 0.25)) { pageScroll?.scrollTo("reply-box", anchor: nil) }
        }
    }

    /// `setReply(null)`: the box just goes; nothing is saved on the way out.
    private func closeReply() {
        reply = nil
        Compose.current = nil
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
        let next = msgCursor < 0 ? (delta > 0 ? 0 : t.messages.count - 1) : min(max(msgCursor + delta, 0), t.messages.count - 1)
        msgCursor = next
        // `scrollIntoView({ block: "nearest" })`.
        DispatchQueue.main.async { withAnimation(nil) { pageScroll?.scrollTo("msg-\(next)", anchor: nil) } }
    }

    private func toggleFocused() {
        guard let t, t.messages.indices.contains(msgCursor) else { return }
        store.toggle(t.messages[msgCursor].id)
    }
}

/// The note's `Textarea`: borderless and transparent, `p-0 min-h-14 text-[13px]`.
private struct NoteEditor: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("A private note, just for you.").font(W.s13).foregroundStyle(W.mutedForeground).allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .textEditorStyle(.plain)
                .font(W.s13)
                .lineSpacing(3)
                .foregroundStyle(W.foreground)
                .scrollContentBackground(.hidden)
                .focused(focused)
                .padding(.horizontal, -5)
        }
        .frame(minHeight: 56, alignment: .topLeading)
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
    @State private var hoverName = false

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
                                Text(who).font(W.font(13, 600)).underline(hoverName).foregroundStyle(W.foreground).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .onHover { hoverName = $0 }
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
                                    AttachmentItemView(filename: a.filename, mimeType: a.mimeType, size: a.size, thumbnailURL: a.isImage ? url(for: a) : nil, onDownload: { download(a) }, onOpen: { open(a) })
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

    private func url(for a: Attachment) -> URL? {
        APIClient.shared.attachmentURL(messageID: a.messageID, attachmentID: a.id, accountID: a.accountID)
    }

    private func fetch(_ a: Attachment) async throws -> Data {
        try await APIClient.shared.data(path: "/api/messages/\(a.messageID)/attachments/\(a.id)", query: a.accountID.map { ["account": $0] } ?? [:])
    }

    /// The item is a link that opens the file: fetched to a temporary file, then handed to the
    /// system, the way a browser tab would show it.
    private func open(_ a: Attachment) {
        Task {
            do {
                let data = try await fetch(a)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heyflare-attachments/\(a.id)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(a.filename.isEmpty ? "attachment" : a.filename)
                try data.write(to: file, options: .atomic)
                NSWorkspace.shared.open(file)
            } catch { toasts.error((error as? APIError)?.errorDescription ?? "Couldn't open that.") }
        }
    }

    private func download(_ a: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.filename
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task {
            do {
                let data = try await fetch(a)
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

/// `AiReplyForm`: a brief and a tone, then a draft comes back into the reply box. Enter
/// submits (Shift-Enter for a new line); the button shows a spinner while it writes.
struct AiReplyForm: View {
    let threadID: String
    var onResult: (String) -> Void
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var brief = ""
    @State private var tone = "match"
    @State private var pending = false
    @State private var settings = AiSettingsStore()
    @FocusState private var focused: Bool

    private var canGo: Bool { !brief.trimmingCharacters(in: .whitespaces).isEmpty && !pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if settings.settings?.configured == false {
                HStack(spacing: 4) {
                    Button { pops.closeAll(); router.go(.settings("ai")) } label: { Text("Add your Anthropic API key").underline() }.buttonStyle(.plain)
                    Text("in Settings → AI to write replies with AI.")
                }
                .font(W.s13).foregroundStyle(W.mutedForeground)
            } else {
                // `rows={3} rounded-md bg-muted/60 focus:bg-muted px-3 py-2 text-[14px] leading-6`
                ZStack(alignment: .topLeading) {
                    if brief.isEmpty {
                        Text("What do you want to say? e.g. “Yes, Tuesday at 3 works — ask them to send the agenda.”")
                            .font(W.sm).lineSpacing(24 - Geist.naturalLine(size: 14)).foregroundStyle(W.mutedForeground)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $brief)
                        .textEditorStyle(.plain)
                        .font(W.sm)
                        .lineSpacing(24 - Geist.naturalLine(size: 14))
                        .foregroundStyle(W.foreground)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(.horizontal, 7).padding(.vertical, 8)
                }
                .frame(height: 88)
                .background(focused ? W.muted : W.muted60)
                .rounded(W.radiusMd)
                HStack(spacing: 8) {
                    WToggleGroup(options: [ToggleOption(id: "match", label: "My tone"), ToggleOption(id: "formal", label: "Formal"), ToggleOption(id: "friendly", label: "Friendly"), ToggleOption(id: "brief", label: "Brief")], value: $tone, outline: true, fontSize: 12)
                    Spacer()
                    Button { go() } label: {
                        HStack(spacing: 4) {
                            if pending { Spinner(size: 14) } else { Icon("sparkles", size: 14) }
                            Text("Write reply")
                        }
                    }
                    .buttonStyle(.web(.default, .sm))
                    .disabled(!canGo)
                }
                Text("Reads the whole thread and what I know about how you write. You review before sending.").font(W.font(11)).foregroundStyle(W.mutedForeground)
            }
        }
        .task { await settings.load() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
        .onLocalKey(enabled: focused, matches: { e in (e.keyCode == 36 || e.keyCode == 76) && !e.modifierFlags.contains(.shift) && !e.modifierFlags.contains(.command) }) { go() }
    }

    private func go() {
        guard canGo else { return }
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
