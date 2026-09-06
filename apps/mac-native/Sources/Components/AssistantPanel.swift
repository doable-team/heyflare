import SwiftUI

/// The closed state: a 40pt round button, bottom right.
struct AssistantFab: View {
    @Environment(UIState.self) private var ui
    @State private var hovering = false
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
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Assistant  ⌘J")
        .padding(16)
    }
}

/// `AssistantPanel`: the header with the conversation switcher, then the chat.
struct AssistantPanel: View {
    @Environment(UIState.self) private var ui
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var list = AssistantListStore()

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
                    .background(pops.isOpen("assistant-convs") ? W.muted : Color.clear)
                    .rounded(W.radiusMd)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popAnchor("assistant-convs")
                Spacer()
                WButton(icon: "squarePen", variant: .ghost, size: .iconSm, muted: true, help: "New chat") { ui.newChat() }
                WButton(icon: "x", variant: .ghost, size: .iconSm, muted: true, help: "Close  ⌘J") { ui.closeAssistant() }
            }
            .padding(.leading, 8).padding(.trailing, 6)
            .frame(height: 44)
            .edgeLine(.bottom)
            AssistantChat(conversationID: ui.assistantConversationID, configured: list.settings?.configured, autoSend: list.settings?.autoSend ?? false)
                .id(ui.assistantConversationID ?? "new")
        }
        .background(W.background)
        .task { await list.load() }
        .onAppear {
            if case .thread(let id, _) = router.route, let chip = ui.currentThread, chip.id == id { ui.addContext(chip) }
        }
        .onKeys(["Escape": { ui.closeAssistant() }], enabled: ui.region == .assistant, priority: 5)
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
                        MenuLabel(g.label)
                        ForEach(g.items) { c in
                            ConversationRow(conversation: c, current: c.id == ui.assistantConversationID, onPick: { pops.closeAll(); ui.assistantConversationID = c.id }, onDelete: {
                                Task {
                                    await list.delete(c.id)
                                    Toasts.shared.show("Deleted")
                                    if ui.assistantConversationID == c.id { ui.newChat() }
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
            if hovering {
                WButton(icon: "trash2", variant: .ghost, size: .iconSm, muted: true, help: "Delete conversation", action: onDelete)
            }
        }
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: 40)
        .background(hovering ? W.accent : Color.clear)
        .rounded(W.radiusMd)
        .onHover { hovering = $0 }
    }
}

/// `AssistantChat`: the transcript and the composer.
struct AssistantChat: View {
    let conversationID: String?
    var configured: Bool?
    var autoSend = false

    @Environment(UIState.self) private var ui
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var store: AssistantChatStore
    @State private var input = ""
    @FocusState private var focused: Bool

    init(conversationID: String?, configured: Bool? = nil, autoSend: Bool = false) {
        self.conversationID = conversationID
        self.configured = configured
        self.autoSend = autoSend
        _store = State(initialValue: AssistantChatStore(conversationID: conversationID))
    }

    private var notConfigured: Bool { configured == false }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if store.turns.isEmpty && !store.loading {
                            VStack(spacing: 8) {
                                Icon("sparkles", size: 24).foregroundStyle(W.mutedForeground).padding(.bottom, 4)
                                Text("What can I do for you?").font(W.font(16, 500)).foregroundStyle(W.foreground)
                                Text("I can read, search and organise your mail, screen senders, and write drafts for you to send.").font(W.sm).foregroundStyle(W.mutedForeground).multilineTextAlignment(.center)
                                if notConfigured {
                                    HStack(spacing: 4) {
                                        Button { router.go(.settings("ai")) } label: { Text("Add your Anthropic API key").font(W.sm).underline().foregroundStyle(W.foreground) }.buttonStyle(.plain)
                                        Text("to get started.").font(W.sm).foregroundStyle(W.foreground)
                                    }
                                    .padding(.top, 8)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                        }
                        ForEach(store.turns) { turn in turnView(turn).id(turn.id) }
                        if let error = store.error {
                            Text(error).font(W.s13).foregroundStyle(W.mutedForeground)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: store.turns.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: store.turns.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    if !ui.assistantContext.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(ui.assistantContext) { c in
                                HStack(spacing: 4) {
                                    Icon("paperclip", size: 12).foregroundStyle(W.mutedForeground)
                                    Text(c.subject.isEmpty ? "(no subject)" : c.subject).font(W.xs).lineLimit(1)
                                    Text("· \(c.from)").font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                                    Button { ui.assistantContext.removeAll { $0.id == c.id } } label: { Icon("x", size: 12).foregroundStyle(W.mutedForeground).frame(width: 16, height: 16) }.buttonStyle(.plain)
                                }
                                .padding(.leading, 8).padding(.trailing, 4).frame(height: 24).frame(maxWidth: 240)
                                .background(W.background).overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1)).rounded(W.radiusMd)
                            }
                        }
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        WButton(icon: "plus", variant: .ghost, size: .iconSm, muted: true, help: "Add a thread as context") {
                            if let chip = ui.currentThread, !ui.assistantContext.contains(where: { $0.id == chip.id }), case .thread = router.route { ui.addContext(chip); return }
                            pops.toggle("assistant-picker", side: .top, align: .start) {
                                PopCard(padding: 0) {
                                    ThreadPicker(placeholder: "Search a thread to attach…", hint: "Pick a thread to give the assistant as context.", exclude: ui.assistantContext.map(\.id)) { t in
                                        ui.addContext(.init(id: t.id, subject: t.subject, from: t.lastFrom.name.isEmpty ? t.lastFrom.email : t.lastFrom.name))
                                        pops.closeAll()
                                    }
                                }
                            }
                        }
                        .popAnchor("assistant-picker")
                        .disabled(notConfigured)
                        TextField(notConfigured ? "Add an API key in Settings → AI first" : "Ask about your mail, @ for context", text: $input, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(W.font(14))
                            .foregroundStyle(W.foreground)
                            .lineLimit(1...8)
                            .focused($focused)
                            .disabled(notConfigured)
                            .onSubmit { send() }
                            .onKeyPress(.leftArrow) { if input.isEmpty { ui.closeAssistant(); return .handled }; return .ignored }
                            .padding(.vertical, 6)
                        if store.streaming {
                            WButton(icon: "square", variant: .ghost, size: .iconSm, help: "Stop") { store.stop() }
                        } else {
                            WButton(icon: "arrowUp", size: .iconSm, help: "Send") { send() }
                                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || notConfigured)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(focused ? W.muted : W.muted60)
                .rounded(W.radiusXl)
                Text("Drafts are never sent without you\(autoSend ? ", unless you allowed it in Settings → AI" : ""). Enter to send, Shift+Enter for a new line.")
                    .font(W.font(11)).foregroundStyle(W.mutedForeground).padding(.horizontal, 4)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        }
        .task { await store.loadHistory() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
        .onChange(of: store.conversationID) { _, id in if let id, ui.assistantConversationID == nil { ui.assistantConversationID = id } }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.streaming, !notConfigured else { return }
        input = ""
        store.send(text, contextThreadIDs: ui.assistantContext.map(\.id))
    }

    @ViewBuilder
    private func turnView(_ turn: AiTurn) -> some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(turn.text).font(W.font(14)).foregroundStyle(W.foreground).lineSpacing(4)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(W.muted)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(turn.tools) { tool in
                    HStack(spacing: 8) {
                        if tool.isRunning { Spinner(size: 12) } else if tool.status == "error" { Icon("triangleAlert", size: 12) } else { Icon("check", size: 12) }
                        Text(tool.summary.isEmpty ? tool.label : tool.summary).font(W.xs).lineLimit(1)
                    }
                    .foregroundStyle(W.mutedForeground)
                }
                if !turn.text.isEmpty {
                    Prose(text: turn.text)
                } else if store.streaming && turn.failed == nil && turn.id == store.turns.last?.id {
                    HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().fill(W.mutedForeground.opacity(0.6)).frame(width: 6, height: 6) } }.frame(height: 24)
                }
                ForEach(turn.drafts) { d in DraftCardView(draft: d) }
                if let failed = turn.failed {
                    HStack(alignment: .top, spacing: 8) {
                        Icon("triangleAlert", size: 16).foregroundStyle(W.mutedForeground)
                        Text(failed).font(W.s13)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).background(W.muted60).rounded(W.radiusMd)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A draft the assistant wrote: open it in the composer, or send as is.
struct DraftCardView: View {
    let draft: AiDraftCard
    @State private var state: String = "idle"

    var body: some View {
        if state == "sent" {
            HStack(spacing: 8) { Icon("check", size: 14); Text("Sent “\(draft.subject.isEmpty ? "(no subject)" : draft.subject)”").lineLimit(1) }
                .font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 12).padding(.vertical, 8).background(W.muted50).rounded(W.radiusLg)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.subject.isEmpty ? "(no subject)" : draft.subject).font(W.font(13, 500))
                    Text("To \(draft.to.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", "))").font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                }
                Text(draft.bodyText).font(W.s13).lineLimit(6).lineSpacing(3)
                HStack(spacing: 6) {
                    WButton("Edit", icon: "penSquare", variant: .outline, size: .sm) {
                        Compose.open(ComposerInitial(draftID: draft.draftID, accountID: draft.accountID, threadID: draft.threadID, to: draft.to, cc: draft.cc, subject: draft.subject, bodyHTML: HTMLText.htmlBody(from: draft.bodyText), title: "Draft"))
                    }
                    WButton(state == "sending" ? "Sending…" : "Send", icon: "send", size: .sm) {
                        state = "sending"
                        Task {
                            do {
                                _ = try await APIClient.shared.send(["draft_id": draft.draftID, "account_id": draft.accountID as Any, "thread_id": draft.threadID as Any, "to": draft.to.map { ["email": $0.email, "name": $0.name] }, "cc": draft.cc.map { ["email": $0.email, "name": $0.name] }, "subject": draft.subject, "body_html": HTMLText.htmlBody(from: draft.bodyText)])
                                state = "sent"; Toasts.shared.show("Sent"); Mail.invalidate()
                            } catch { state = "idle"; Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
                        }
                    }
                    .disabled(state == "sending")
                }
            }
            .padding(12)
            .background(W.muted50)
            .rounded(W.radiusLg)
        }
    }
}

/// Tiny markdown: paragraphs, bullets, numbered lists, **bold**, `code`.
struct Prose: View {
    let text: String
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
                    .padding(.leading, 8)
                } else {
                    inline(b)
                }
            }
        }
        .font(W.font(14))
        .foregroundStyle(W.foreground)
    }

    private func inline(_ s: String) -> Text {
        var out = Text("")
        var rest = Substring(s)
        while !rest.isEmpty {
            if let r = rest.range(of: #"(\*\*[^*]+\*\*|`[^`]+`)"#, options: .regularExpression) {
                out = out + Text(String(rest[rest.startIndex..<r.lowerBound]))
                let token = rest[r]
                if token.hasPrefix("**") { out = out + Text(String(token.dropFirst(2).dropLast(2))).font(W.font(14, 600)) }
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
