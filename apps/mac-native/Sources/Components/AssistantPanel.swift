import SwiftUI
import AppKit

/// The closed state: a 40pt round button, bottom right (`active:scale-95 transition-transform`).
struct AssistantFab: View {
    @Environment(UIState.self) private var ui
    @State private var hovering = false
    @State private var pressed = false
    var body: some View {
        Button { ui.openAssistant() } label: {
            Icon("sparkles", size: 18)
                .foregroundStyle(W.primaryForeground)
                .frame(width: 40, height: 40)
                .background(W.foreground.opacity(hovering ? 0.9 : 1))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(pressed: $pressed))
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.easeOut(duration: 0.15), value: pressed)
        .onHover { hovering = $0 }
        .webTooltip("Assistant", kbd: "⌘J", side: .left)
        .padding(16)
    }
}

private struct PressScaleStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, p in pressed = p }
    }
}

/// `AssistantPanel`: the header with the conversation switcher, then the chat.
struct AssistantPanel: View {
    @Environment(UIState.self) private var ui
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var list = AssistantListStore()
    /// Changes only when a person picks another conversation or starts a new chat — not when
    /// the server names a fresh one, which would throw away the stream in progress.
    @State private var chatKey = 0
    /// `openedFrom`: the thread attached when the panel opened on its page, once per id.
    @State private var openedFrom: String?
    /// `useBundle`: the bundle page's latest thread, fetched while the panel is showing.
    @State private var bundleChip: UIState.ContextChip?
    @State private var titleHover = false

    private var title: String {
        if let id = ui.assistantConversationID { return list.conversations.first { $0.id == id }?.displayTitle ?? "Untitled" }
        return "New chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    pops.toggle("assistant-convs", side: .bottom, align: .start) { conversationsMenu }
                } label: {
                    HStack(spacing: 4) {
                        Text(title).font(W.font(13, 500)).foregroundStyle(W.foreground).lineLimit(1)
                        Icon("chevronDown", size: 14).foregroundStyle(W.mutedForeground)
                    }
                    .padding(.horizontal, 8).frame(height: 32).frame(maxWidth: 260)
                    .background(pops.isOpen("assistant-convs") || titleHover ? W.muted : Color.clear)
                    .rounded(W.radiusMd)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { titleHover = $0 }
                .popAnchor("assistant-convs")
                Spacer()
                WButton(icon: "squarePen", variant: .ghost, size: .iconSm, muted: true) { ui.newChat(); chatKey += 1 }
                    .webTooltip("New chat")
                WButton(icon: "x", variant: .ghost, size: .iconSm, muted: true) { ui.closeAssistant() }
                    .webTooltip("Close", kbd: "⌘J")
            }
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: 44)
            .edgeLine(.bottom)
            AssistantChat(conversationID: ui.assistantConversationID, configured: list.settings?.configured, autoSend: list.settings?.autoSend ?? false, onAddContext: addContext, onFinished: { Task { await list.refresh() } })
                .id(chatKey)
        }
        .background(W.background)
        .overlay(alignment: .leading) { if ui.assistantDocked { AssistantResizeHandle() } }
        .task { await list.load() }
        // A chat started here gets its id from the stream; the switcher must learn about it.
        .onChange(of: ui.assistantConversationID) { _, id in if id != nil { Task { await list.refresh() } } }
        .onChange(of: pops.isOpen("assistant-convs")) { _, open in if open { Task { await list.refresh() } } }
        .onAppear { attachCurrent() }
        // `AssistantPanel.tsx`: the thread on screen rides along whenever it changes while
        // the panel is open, including when it finishes loading after the panel did.
        .onChange(of: ui.currentThread?.id) { _, _ in attachCurrent() }
        .onChange(of: bundleChip?.id) { _, _ in attachCurrent() }
        .task(id: router.route) {
            bundleChip = nil
            guard case .bundle(let id) = router.route else { return }
            if let latest = (try? await APIClient.shared.bundle(id))?.bundle.latest {
                bundleChip = .init(id: latest.id, subject: latest.subject, from: latest.lastFrom.name.isEmpty ? latest.lastFrom.email : latest.lastFrom.name)
            }
        }
    }

    /// `useCurrentThreadChip`: the thread page's thread, or a bundle page's latest.
    private var current: UIState.ContextChip? {
        switch router.route {
        case .thread(let id, _): return ui.currentThread.flatMap { $0.id == id ? $0 : nil }
        case .bundle: return bundleChip
        default: return nil
        }
    }

    private func attachCurrent() {
        guard let current, openedFrom != current.id else { return }
        openedFrom = current.id
        ui.addContext(current)
    }

    /// `onAddContext`: the page's thread when it is not attached yet, else the picker.
    private func addContext() {
        if let current, !ui.assistantContext.contains(where: { $0.id == current.id }) { ui.addContext(current); return }
        pops.open("assistant-picker", side: .top, align: .start) {
            PopCard(width: 360, padding: 0) {
                ThreadPicker(placeholder: "Search a thread to attach…", hint: "Pick a thread to give the assistant as context.", exclude: ui.assistantContext.map(\.id)) { t in
                    ui.addContext(.init(id: t.id, subject: t.subject, from: t.lastFrom.name.isEmpty ? t.lastFrom.email : t.lastFrom.name))
                    pops.closeAll()
                }
            }
        }
    }

    @ViewBuilder
    private var conversationsMenu: some View {
        PopCard(width: 340) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if list.conversations.isEmpty { Text("No conversations yet.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 12) }
                    let groups = grouped(list.conversations)
                    ForEach(Array(groups.enumerated()), id: \.offset) { gi, g in
                        if gi > 0 { MenuSeparator() }
                        // `DropdownMenuLabel text-[12px] font-medium px-2 py-1.5`.
                        Text(g.label).font(W.font(12, 500)).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 6)
                        ForEach(g.items) { c in
                            ConversationRow(conversation: c, current: c.id == ui.assistantConversationID, onPick: { pops.closeAll(); if ui.assistantConversationID != c.id { ui.assistantConversationID = c.id; ui.assistantContext = []; chatKey += 1 } }, onDelete: {
                                Task {
                                    await list.delete(c.id)
                                    Toasts.shared.show("Deleted")
                                    if ui.assistantConversationID == c.id { ui.newChat(); chatKey += 1 }
                                }
                            })
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func grouped(_ list: [AiConversation]) -> [(label: String, items: [AiConversation])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let week = cal.date(byAdding: .day, value: -7, to: today)!
        var groups: [String: [AiConversation]] = ["Today": [], "Yesterday": [], "Previous 7 days": [], "Older": []]
        for c in list {
            let d = c.updated
            let key = d >= today ? "Today" : d >= yesterday ? "Yesterday" : d >= week ? "Previous 7 days" : "Older"
            groups[key, default: []].append(c)
        }
        return ["Today", "Yesterday", "Previous 7 days", "Older"].compactMap { k in groups[k]!.isEmpty ? nil : (k, groups[k]!) }
    }
}

/// `AssistantPanel.tsx`: drag the left edge to resize (320–720), double-click resets to 400.
private struct AssistantResizeHandle: View {
    @Environment(UIState.self) private var ui
    @State private var hovering = false
    @State private var dragging = false
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(hovering || dragging ? W.border : Color.clear)
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .offset(x: -3)
            .contentShape(Rectangle())
            .onHover { over in
                hovering = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("window"))
                    .onChanged { v in
                        if startWidth == nil { startWidth = ui.assistantWidth; dragging = true }
                        ui.assistantWidth = UIState.clampAssistantWidth((startWidth ?? 400) - v.translation.width)
                    }
                    .onEnded { _ in startWidth = nil; dragging = false }
            )
            .onTapGesture(count: 2) { ui.assistantWidth = 400 }
            .help("Drag to resize · double-click to reset")
    }
}

private struct ConversationRow: View {
    let conversation: AiConversation
    let current: Bool
    var onPick: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPick) {
                HStack(spacing: 8) {
                    Text(conversation.displayTitle).font(W.s13).foregroundStyle(W.foreground).lineLimit(1)
                    Spacer()
                    if current { Icon("check", size: 14).foregroundStyle(W.mutedForeground) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            DeleteConversationButton(action: onDelete).opacity(hovering ? 1 : 0)
        }
        .padding(.leading, 6).padding(.trailing, 4)
        .frame(height: 40)
        .background(hovering ? W.accent : Color.clear)
        .rounded(W.radiusMd)
        .onHover { hovering = $0 }
    }
}

/// `size-7 rounded-md text-muted-foreground hover:bg-background hover:text-foreground`.
private struct DeleteConversationButton: View {
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Icon("trash2", size: 14)
                .foregroundStyle(hovering ? W.foreground : W.mutedForeground)
                .frame(width: 28, height: 28)
                .background(hovering ? W.background : Color.clear)
                .rounded(W.radiusMd)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `AssistantChat`: the transcript and the composer.
struct AssistantChat: View {
    let conversationID: String?
    var configured: Bool?
    var autoSend = false
    var onAddContext: () -> Void = {}
    var onFinished: () -> Void = {}

    static let suggestions = ["What's new for me today?", "Anything waiting in the Screener?", "Summarise my unread mail", "Draft a reply to the latest email from …"]

    @Environment(UIState.self) private var ui
    @Environment(Router.self) private var router
    @State private var store: AssistantChatStore
    @State private var input = ""
    @State private var focused = false
    @State private var focusRequest = 0
    @State private var inputHeight: CGFloat = 24
    /// The chips that rode along with the message in flight; removed once the reply lands.
    @State private var inFlight: [String] = []

    init(conversationID: String?, configured: Bool? = nil, autoSend: Bool = false, onAddContext: @escaping () -> Void = {}, onFinished: @escaping () -> Void = {}) {
        self.conversationID = conversationID
        self.configured = configured
        self.autoSend = autoSend
        self.onAddContext = onAddContext
        self.onFinished = onFinished
        _store = State(initialValue: AssistantChatStore(conversationID: conversationID))
    }

    private var notConfigured: Bool { configured == false }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if store.turns.isEmpty && !store.loading {
                            // `pt-6 pb-6 text-center`, with the margins the web sets on each line.
                            VStack(spacing: 0) {
                                Icon("sparkles", size: 24).foregroundStyle(W.mutedForeground)
                                Text("What can I do for you?").font(W.font(15, 500)).webLine(15, 22.5, weight: 500).foregroundStyle(W.foreground)
                                    .padding(.top, 12)
                                Text("I can read, search and organise your mail, screen senders, and write drafts for you to send.").font(W.s13).webLine(13, 19.5).foregroundStyle(W.mutedForeground).multilineTextAlignment(.center)
                                    .padding(.top, 4)
                                if notConfigured {
                                    HStack(spacing: 4) {
                                        Button { router.go(.settings("ai")) } label: { Text("Add your Anthropic API key").font(W.s13).webLine(13, 19.5).underline().foregroundStyle(W.foreground) }.buttonStyle(.plain)
                                        Text("to get started.").font(W.s13).webLine(13, 19.5).foregroundStyle(W.foreground)
                                    }
                                    .padding(.top, 16)
                                } else {
                                    // `mt-5 flex flex-wrap justify-center gap-2`.
                                    WrapLayout(spacing: 8, alignment: .center) {
                                        ForEach(Self.suggestions, id: \.self) { s in
                                            SuggestionChip(text: s) { input = s; focusRequest += 1 }
                                        }
                                    }
                                    .padding(.top, 20)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                            .padding(.bottom, 24)
                        }
                        // `py-4 space-y-5`.
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(store.turns) { turn in turnView(turn).id(turn.id) }
                            Color.clear.frame(height: 0).id("bottom")
                        }
                        .padding(.vertical, 16)
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: store.turns.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.turns.last?.tools.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.turns.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }

            // `shrink-0 pt-2 px-4 pb-3`.
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if !ui.assistantContext.isEmpty {
                        WrapLayout(spacing: 4) {
                            ForEach(ui.assistantContext) { c in
                                HStack(spacing: 4) {
                                    Icon("paperclip", size: 12).foregroundStyle(W.mutedForeground)
                                    Text(c.subject.isEmpty ? "(no subject)" : c.subject).font(W.xs).foregroundStyle(W.foreground).lineLimit(1)
                                    Text("· \(c.from)").font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                                    RemoveChipButton { ui.assistantContext.removeAll { $0.id == c.id } }
                                }
                                .padding(.leading, 8).padding(.trailing, 4).frame(height: 24).frame(maxWidth: 240)
                                .background(W.background).overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1)).rounded(W.radiusMd)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        WButton(icon: "plus", variant: .ghost, size: .iconSm, muted: true, action: onAddContext)
                            .popAnchor("assistant-picker")
                            .disabled(notConfigured)
                        AssistantInput(
                            text: $input,
                            placeholder: notConfigured ? "Add an API key in Settings → AI first" : "Ask about your mail, @ for context",
                            disabled: notConfigured,
                            focusRequest: focusRequest,
                            onSubmit: { send() },
                            onLeftWhenEmpty: { ui.closeAssistant() },
                            onAt: onAddContext,
                            onFocusChange: { focused = $0 },
                            height: $inputHeight
                        )
                        .frame(height: inputHeight)
                        .padding(.vertical, 2)
                        if store.streaming {
                            WButton(icon: "square", variant: .ghost, size: .iconSm) { store.stop() }
                        } else {
                            WButton(icon: "arrowUp", size: .iconSm) { send() }
                                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notConfigured)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(focused ? W.muted : W.muted60)
                .rounded(W.radiusXl)
                Text("Drafts are never sent without you\(autoSend ? ", unless you allowed it in Settings → AI" : ""). Enter to send, Shift+Enter for a new line.")
                    .font(W.font(11)).webLine(11, 16.5).foregroundStyle(W.mutedForeground).padding(.horizontal, 4).padding(.top, 6)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        }
        .task { await store.loadHistory() }
        .onAppear { focusRequest += 1 }
        .onChange(of: ui.assistantFocusRequest) { _, _ in focusRequest += 1 }
        // The web has no "assistant" region: list keys work with the panel open whenever
        // nobody is typing into it. Focus leaving the field hands the keys back to the page.
        .onChange(of: focused) { _, f in if f { ui.region = .assistant } else if ui.region == .assistant { ui.region = .content } }
        .onChange(of: store.conversationID) { _, id in if let id, ui.assistantConversationID == nil { ui.assistantConversationID = id } }
        // `AssistantChat.tsx` after the stream: the chips are spent, the conversation list and
        // every mail query behind the panel are refetched.
        .onChange(of: store.streaming) { was, now in
            guard was, !now else { return }
            let ids = inFlight
            inFlight = []
            ui.assistantContext.removeAll { ids.contains($0.id) }
            onFinished()
            Mail.invalidate()
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.streaming, !notConfigured else { return }
        input = ""
        // `AssistantChat.tsx`: at most three threads ride along.
        let ctx = Array(ui.assistantContext.prefix(3))
        inFlight = ctx.map(\.id)
        store.send(text, contextThreadIDs: ctx.map(\.id), context: ctx.map { AiContextRef(id: $0.id, subject: $0.subject, from: $0.from) })
    }

    @ViewBuilder
    private func turnView(_ turn: AiTurn) -> some View {
        if turn.role == .user {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    if !turn.context.isEmpty {
                        WrapLayout(spacing: 4, alignment: .trailing) {
                            ForEach(turn.context) { c in
                                ContextLinkChip(chip: c) { router.go(.thread(c.id, peek: false)) }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    Text(turn.text).font(W.font(14)).webLine(14, 24).foregroundStyle(W.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(W.muted)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous))
                }
                .containerRelativeFrame(.horizontal, alignment: .trailing) { w, _ in w * 0.85 }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !turn.tools.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(turn.tools) { tool in
                            HStack(spacing: 8) {
                                if tool.isRunning { Spinner(size: 12) } else if tool.status == "error" { Icon("triangleAlert", size: 12) } else { Icon("check", size: 12) }
                                Text(tool.label).font(W.xs).lineLimit(1)
                            }
                            .foregroundStyle(W.mutedForeground)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.bottom, 4)
                }
                if !turn.text.isEmpty {
                    Prose(text: turn.text)
                } else if store.streaming && turn.failed == nil && turn.id == store.turns.last?.id {
                    ThinkingDots()
                }
                ForEach(turn.drafts) { d in DraftCardView(draft: d, sentThreadID: turn.sent[d.id]) }
                if let failed = turn.failed {
                    HStack(alignment: .top, spacing: 8) {
                        Icon("triangleAlert", size: 16).foregroundStyle(W.mutedForeground).padding(.top, 2)
                        errorText(failed)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).background(W.muted60).rounded(W.radiusMd)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerRelativeFrame(.horizontal, alignment: .leading) { w, _ in w * 0.92 }
        }
    }

    /// The error line, with "· Settings → AI" when the message is about an API key.
    @ViewBuilder
    private func errorText(_ message: String) -> some View {
        if message.range(of: "API key", options: .caseInsensitive) != nil {
            HStack(spacing: 0) {
                Text(message + " · ").font(W.s13).webLine(13)
                Button { router.go(.settings("ai")) } label: { Text("Settings → AI").font(W.s13).webLine(13).underline().foregroundStyle(W.foreground) }.buttonStyle(.plain)
            }
            .foregroundStyle(W.foreground)
        } else {
            Text(message).font(W.s13).webLine(13).foregroundStyle(W.foreground)
        }
    }
}

/// `rounded-full bg-muted/60 hover:bg-muted px-3 h-8 text-[13px] text-foreground/80`.
private struct SuggestionChip: View {
    let text: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(text).font(W.s13).foregroundStyle(W.foreground80)
                .padding(.horizontal, 12).frame(height: 32)
                .background(hovering ? W.muted : W.muted60)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The paperclip link above a sent message: `rounded-md bg-muted/60 px-2 h-6 text-[12px]`.
private struct ContextLinkChip: View {
    let chip: AiContextRef
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Icon("paperclip", size: 12)
                Text(chip.subject.isEmpty ? "(no subject)" : chip.subject).font(W.xs).lineLimit(1)
            }
            .foregroundStyle(W.mutedForeground)
            .padding(.horizontal, 8).frame(height: 24).frame(maxWidth: 220)
            .background(W.muted60).rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// `size-4 rounded-sm text-muted-foreground hover:text-foreground hover:bg-muted`.
private struct RemoveChipButton: View {
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Icon("x", size: 12).foregroundStyle(hovering ? W.foreground : W.mutedForeground)
                .frame(width: 16, height: 16)
                .background(hovering ? W.muted : Color.clear)
                .rounded(W.radiusSm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `ThinkingDots`: three 6pt dots pulsing (`animate-pulse`, 160 ms apart).
private struct ThinkingDots: View {
    @State private var dim = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(W.mutedForeground.opacity(0.6)).frame(width: 6, height: 6)
                    .opacity(dim ? 0.5 : 1)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true).delay(Double(i) * 0.16), value: dim)
            }
        }
        .frame(height: 24)
        .onAppear { dim = true }
    }
}

/// Drafts sent from a card in this session (the web's `sentDrafts`), so a card never
/// offers to send mail that already went out.
@MainActor
@Observable
final class SentDrafts {
    static let shared = SentDrafts()
    private(set) var sent: [String: String?] = [:]
    func mark(_ draftID: String, threadID: String? = nil) { sent[draftID] = threadID }
    func thread(for draftID: String) -> String?? { sent[draftID] }
}

/// `DraftCard`: a draft the assistant wrote — send it as is, or open it in the composer.
struct DraftCardView: View {
    let draft: AiDraftCard
    var sentThreadID: String?
    @Environment(Router.self) private var router
    @State private var state: String = "idle"
    @State private var threadID: String?
    @State private var openHover = false

    private var toNames: String { draft.to.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", ") }

    var body: some View {
        Group {
            if state == "sent" || sentThreadID != nil || SentDrafts.shared.sent[draft.id] != nil {
                // Collapsed: the mail is gone, so the card stops offering to send it.
                HStack(spacing: 8) {
                    Icon("check", size: 14)
                    (Text("Sent to \(toNames) · ") + Text(draft.subject).foregroundStyle(W.foreground80)).font(W.s13).lineLimit(1)
                    if let id = threadID ?? sentThreadID ?? (SentDrafts.shared.sent[draft.id] ?? nil) {
                        Spacer(minLength: 0)
                        Button { router.go(.thread(id, peek: false)) } label: {
                            Text("Open").font(W.s13).underline().foregroundStyle(openHover ? W.foreground : W.mutedForeground)
                        }
                        .buttonStyle(.plain)
                        .onHover { openHover = $0 }
                    }
                }
                .foregroundStyle(W.mutedForeground)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(W.muted50).rounded(W.radiusLg)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Icon("penSquare", size: 14)
                        Text("Draft · from \(draft.from) · to \(toNames)\(draft.cc.isEmpty ? "" : " · cc \(draft.cc.map(\.email).joined(separator: ", "))")").font(W.s13).lineLimit(1)
                    }
                    .foregroundStyle(W.mutedForeground)
                    .padding(.bottom, 4)
                    Text(draft.subject).font(W.font(13, 500)).webLine(13, 19.5, weight: 500).foregroundStyle(W.foreground).padding(.bottom, 4)
                    ScrollView {
                        Prose(text: draft.bodyText, size: 13, lineHeight: 20, color: W.foreground90)
                    }
                    .scrollIndicators(.automatic)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: 224)
                    HStack(spacing: 8) {
                        Button {
                            state = "sending"
                            Task {
                                do {
                                    let r = try await APIClient.shared.send(["draft_id": draft.draftID, "account_id": draft.accountID as Any, "thread_id": draft.threadID as Any, "to": draft.to.map { ["email": $0.email, "name": $0.name] }, "cc": draft.cc.map { ["email": $0.email, "name": $0.name] }, "subject": draft.subject, "body_html": HTMLText.htmlBody(from: draft.bodyText)])
                                    threadID = r.threadID
                                    state = "sent"
                                    Toasts.shared.show("Sent")
                                    SentDrafts.shared.mark(draft.id, threadID: r.threadID)
                                    Mail.invalidate()
                                } catch { state = "idle"; Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if state == "sending" { Spinner(size: 14) } else { Icon("send", size: 14) }
                                Text("Send")
                            }
                        }
                        .buttonStyle(.web(.default, .sm))
                        .disabled(state == "sending")
                        WButton("Open in composer", variant: .ghost, size: .sm) {
                            Compose.open(ComposerInitial(draftID: draft.draftID, accountID: draft.accountID, threadID: draft.threadID, to: draft.to, cc: draft.cc, subject: draft.subject, bodyHTML: HTMLText.htmlBody(from: draft.bodyText)))
                        }
                    }
                    .padding(.top, 12)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(W.muted50)
                .rounded(W.radiusLg)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Tiny markdown: paragraphs, bullets, numbered lists, **bold**, `code`.
/// `text-[14px] leading-6 space-y-2` unless told otherwise.
struct Prose: View {
    let text: String
    var size: CGFloat = 14
    var lineHeight: CGFloat = 24
    var color: Color = W.foreground

    var body: some View {
        let blocks = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                let lines = b.components(separatedBy: "\n")
                if lines.allSatisfy({ $0.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) != nil }) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                            HStack(alignment: .top, spacing: 8) { Text("•").foregroundStyle(W.mutedForeground); inline(l.replacingOccurrences(of: #"^\s*[-*]\s+"#, with: "", options: .regularExpression)) }
                        }
                    }
                    .padding(.leading, 8)
                } else if lines.allSatisfy({ $0.range(of: #"^\s*\d+[.)]\s+"#, options: .regularExpression) != nil }) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            HStack(alignment: .top, spacing: 8) { Text("\(i + 1).").foregroundStyle(W.mutedForeground).monospacedDigit(); inline(l.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)) }
                        }
                    }
                    .padding(.leading, 12)
                } else {
                    inline(b)
                }
            }
        }
        .font(W.font(size))
        .foregroundStyle(color)
        .webLine(size, lineHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ s: String) -> Text {
        var out = Text("")
        var rest = Substring(s)
        while !rest.isEmpty {
            if let r = rest.range(of: #"(\*\*[^*]+\*\*|`[^`]+`)"#, options: .regularExpression) {
                out = out + Text(String(rest[rest.startIndex..<r.lowerBound]))
                let token = rest[r]
                if token.hasPrefix("**") { out = out + Text(String(token.dropFirst(2).dropLast(2))).font(W.font(size, 600)) }
                else { out = out + Text(String(token.dropFirst().dropLast())).font(W.mono(12)) }
                rest = rest[r.upperBound...]
            } else {
                out = out + Text(String(rest))
                break
            }
        }
        return out
    }
}

// MARK: - The input

/// The assistant's textarea: Enter sends, Shift+Enter breaks the line, ← from an empty box
/// leaves, "@" at a word start opens the thread picker, and the box grows with its text up
/// to 160pt before it scrolls (`INPUT_MAX_PX`).
struct AssistantInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var disabled: Bool
    var focusRequest: Int
    var onSubmit: () -> Void
    var onLeftWhenEmpty: () -> Void
    var onAt: () -> Void
    var onFocusChange: (Bool) -> Void
    /// The box's height, measured from its text (one line up to `maxHeight`).
    @Binding var height: CGFloat

    private static let lineHeight: CGFloat = 24
    private static let maxHeight: CGFloat = 160

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = InputTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.font = Geist.nsFont(size: 14, weight: 400)
        tv.textColor = NSColor(W.foreground)
        tv.insertionPointColor = NSColor(W.foreground)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = Self.lineHeight
        style.maximumLineHeight = Self.lineHeight
        tv.defaultParagraphStyle = style
        tv.typingAttributes = [.font: tv.font!, .foregroundColor: tv.textColor!, .paragraphStyle: style]
        tv.placeholder = placeholder
        tv.onSubmit = onSubmit
        tv.onLeftWhenEmpty = onLeftWhenEmpty

        let sv = NSScrollView()
        sv.documentView = tv
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.verticalScrollElasticity = .none
        context.coordinator.textView = tv
        context.coordinator.scrollView = sv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        let co = context.coordinator
        co.parent = self
        tv.placeholder = placeholder
        tv.onSubmit = onSubmit
        tv.onLeftWhenEmpty = onLeftWhenEmpty
        tv.isEditable = !disabled
        tv.isSelectable = !disabled
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            co.lastText = text
            tv.needsDisplay = true
        }
        if focusRequest != co.focusRequest {
            co.focusRequest = focusRequest
            if !disabled {
                DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
            }
        }
        co.remeasure()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AssistantInput
        weak var textView: InputTextView?
        weak var scrollView: NSScrollView?
        var focusRequest = 0
        var lastText = ""

        init(_ parent: AssistantInput) { self.parent = parent }

        func remeasure() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = max(AssistantInput.lineHeight, ceil(lm.usedRect(for: tc).height))
            let h = min(used, AssistantInput.maxHeight)
            if h != parent.height {
                DispatchQueue.main.async { [weak self] in self?.parent.height = h }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let v = tv.string
            let previous = lastText
            lastText = v
            parent.text = v
            tv.needsDisplay = true
            remeasure()
            // "@" opens the thread picker only when it starts a word — otherwise you could
            // never type an email address. The character is always kept.
            let body = v.dropLast()
            let startsWord = v.count == 1 || body.last?.isWhitespace == true
            if v.hasSuffix("@"), !previous.hasSuffix("@"), startsWord { parent.onAt() }
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }
    }

    final class InputTextView: NSTextView {
        var placeholder = ""
        var onSubmit: () -> Void = {}
        var onLeftWhenEmpty: () -> Void = {}

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty, !placeholder.isEmpty {
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = 24; style.maximumLineHeight = 24
                let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(W.mutedForeground), .paragraphStyle: style]
                (placeholder as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attrs)
            }
        }

        override func keyDown(with event: NSEvent) {
            // Enter sends; Shift+Enter breaks the line (`onKeyDown` in AssistantChat.tsx).
            if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
                if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil); return }
                onSubmit()
                return
            }
            // ← from an empty box leaves the assistant.
            if event.keyCode == 123, string.isEmpty, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                window?.makeFirstResponder(nil)
                onLeftWhenEmpty()
                return
            }
            super.keyDown(with: event)
        }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { needsDisplay = true }
            return ok
        }
    }
}

/// `flex-wrap` with `justify-start` / `justify-center` / `justify-end`.
struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var alignment: HorizontalAlignment = .leading

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.init(width: width, height: nil))
            if x + size.width > width, x > 0 { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let all = rows(subviews, width: width)
        let height = all.reduce(CGFloat(0)) { $0 + ($1.map(\.1.height).max() ?? 0) } + CGFloat(max(0, all.count - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.1.width } + CGFloat(max(0, row.count - 1)) * spacing
            var x: CGFloat
            switch alignment {
            case .center: x = bounds.minX + (bounds.width - rowWidth) / 2
            case .trailing: x = bounds.maxX - rowWidth
            default: x = bounds.minX
            }
            let rowHeight = row.map(\.1.height).max() ?? 0
            for (i, size) in row {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: .init(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
