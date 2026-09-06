import SwiftUI

struct AssistantChatView: View {
    let conversationID: String?
    var onClose: () -> Void

    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var store: AssistantChatStore
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    init(conversationID: String?, onClose: @escaping () -> Void) {
        self.conversationID = conversationID
        self.onClose = onClose
        _store = State(initialValue: AssistantChatStore(conversationID: conversationID))
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Assistant") {
                Button("Done") {
                    store.stop()
                    onClose()
                    dismiss()
                }
                .font(Theme.Typography.bodyMedium)
                .foregroundStyle(Theme.Colors.foreground)
                .frame(height: Theme.Metrics.minTouchTarget)
                .padding(.horizontal, 8)
            } trailing: {
                EmptyView()
            }

            transcript
            composer
        }
        .screenBackground()
        .task { await store.loadHistory() }
        .onDisappear { store.stop() }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.turns.isEmpty && !store.loading {
                        suggestions
                    }
                    ForEach(store.turns) { turn in
                        TurnView(turn: turn, streaming: store.streaming && turn.id == store.turns.last?.id) { draft in
                            openDraft(draft)
                        }
                        .id(turn.id)
                    }
                    // Anchors the auto-scroll so a growing answer keeps its tail in view.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.turns.last?.text) { _, _ in
                withAnimation(Theme.Motion.quick) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.turns.count) { _, _ in
                withAnimation(Theme.Motion.quick) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Openers taken from the product's own description of what the assistant is for.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(Theme.Typography.caps)
                .tracking(0.6)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .padding(.bottom, 2)
            ForEach([
                "What's new for me today?",
                "Anything waiting in the Screener?",
                "Find the invoice from Stripe",
                "Summarise my unread mail",
            ], id: \.self) { prompt in
                Button {
                    input = prompt
                    inputFocused = true
                } label: {
                    HStack {
                        Text(prompt)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.foreground)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                            .strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                Text(error)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask anything", text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .font(Theme.Typography.body)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.Colors.muted)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    if store.streaming {
                        store.stop()
                    } else {
                        store.send(input)
                        input = ""
                    }
                } label: {
                    Image(systemName: store.streaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Colors.background)
                        .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                        .background(Theme.Colors.foreground.opacity(canSend ? 1 : 0.35))
                        .clipShape(Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel(store.streaming ? "Stop" : "Send")
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.vertical, 10)
        }
        .background(Theme.Colors.chrome)
        .background(.ultraThinMaterial)
        .hairline(.top)
    }

    private var canSend: Bool {
        store.streaming || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The assistant writes, you decide: a draft opens in the composer rather than going out.
    private func openDraft(_ card: AiDraftCard) {
        var intent = ComposeIntent(kind: .new, accountID: card.accountID)
        if let threadID = card.threadID {
            intent.kind = .reply(threadID: threadID, messageID: "", all: false)
        }
        intent.to = card.to
        intent.cc = card.cc
        intent.subject = card.subject
        intent.body = card.bodyText
        intent.draftID = card.draftID
        onClose()
        dismiss()
        nav.composing = intent
    }
}

// MARK: - One turn

private struct TurnView: View {
    let turn: AiTurn
    let streaming: Bool
    let onDraft: (AiDraftCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turn.role == .user {
                Text(turn.text)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.background)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.Colors.foreground)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                if !turn.tools.isEmpty { tools }

                if !turn.text.isEmpty {
                    Text(turn.text)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if streaming && turn.tools.isEmpty {
                    ThinkingDots()
                }

                ForEach(turn.drafts) { draft in
                    draftCard(draft)
                }

                if let failed = turn.failed {
                    Text(failed)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
    }

    /// What the assistant is doing while it is quiet. Without this a tool call reads as
    /// the app having hung.
    private var tools: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(turn.tools) { tool in
                HStack(spacing: 6) {
                    Image(systemName: tool.isRunning ? "circle.dotted" : (tool.status == "error" ? "exclamationmark.circle" : "checkmark.circle"))
                        .font(.system(size: 11))
                    Text(tool.label)
                        .font(Theme.Typography.micro)
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.Colors.mutedForeground)
            }
        }
    }

    private func draftCard(_ draft: AiDraftCard) -> some View {
        Button { onDraft(draft) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Draft ready")
                    .font(Theme.Typography.caps)
                    .tracking(0.6)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)
                Text("To " + draft.to.map(\.display).joined(separator: ", "))
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
                Text(draft.bodyText)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(3)
                    .padding(.top, 2)
                Text("Open in composer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.foreground)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Three dots that breathe, so a pause reads as thinking rather than as a stall.
private struct ThinkingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.Colors.mutedForeground)
                    .frame(width: 6, height: 6)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(index) * 0.6)))
            }
        }
        .frame(height: 20)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
        .accessibilityLabel("Thinking")
    }
}
