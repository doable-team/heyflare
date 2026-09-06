import SwiftUI

struct AssistantView: View {
    @Environment(AppState.self) private var app
    @Environment(ToastCenter.self) private var toasts

    @State private var store = AssistantListStore()
    @State private var offset: CGFloat = 0
    @State private var open: AssistantChatTarget?
    @State private var pendingDelete: AiConversation?
    @State private var renaming: AiConversation?
    @State private var renameDraft = ""

    private var compactTitle: Bool { offset < -36 }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Assistant", titleVisible: compactTitle) {
                EmptyView()
            } trailing: {
                BarButton(icon: "square.and.pencil", label: "New conversation") {
                    open = AssistantChatTarget(conversationID: nil)
                }
            }

            RefreshableScroll(onRefresh: { await store.refresh() }, offset: $offset) {
                LazyVStack(spacing: 0) {
                    LargeTitle(title: "Assistant", subtitle: subtitle)

                    if let error = store.error, !store.loaded {
                        InlineError(message: error) { Task { await store.refresh() } }
                    }

                    if store.settings?.configured == false {
                        notConfigured
                    }

                    startRow

                    if !store.conversations.isEmpty {
                        SectionHeader(title: "Recent")
                        ForEach(store.conversations) { conversation in
                            SwipeRow(
                                trailing: .init(icon: "trash", label: "Delete", resets: true) {
                                    pendingDelete = conversation
                                }
                            ) {
                                Button {
                                    open = AssistantChatTarget(conversationID: conversation.id)
                                } label: {
                                    row(conversation)
                                }
                                .buttonStyle(PressableRowStyle())
                                .contextMenu {
                                    Button {
                                        renameDraft = conversation.title
                                        renaming = conversation
                                    } label: {
                                        SwiftUI.Label("Rename", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        pendingDelete = conversation
                                    } label: {
                                        SwiftUI.Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .hairline()
                        }
                    } else if store.loaded && store.settings?.configured != false {
                        EmptyState(icon: "sparkles", message: "No conversations yet. Ask the assistant anything about your mail.")
                    }

                    Color.clear.frame(height: 40)
                }
            }
        }
        .screenBackground()
        .task { await store.load() }
        .fullScreenCover(item: $open) { target in
            AssistantChatView(conversationID: target.conversationID) {
                Task { await store.refresh() }
            }
        }
        // An alert rather than a sheet: a title is one short line, and the system alert
        // brings its own keyboard, Cancel and Save.
        .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameDraft)
            Button("Save") {
                if let conversation = renaming {
                    Task { await store.rename(conversation.id, to: renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let conversation = pendingDelete {
                    Task { await store.delete(conversation.id) }
                }
                pendingDelete = nil
            }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        }
    }

    private var subtitle: String {
        guard let settings = store.settings, settings.configured else { return "" }
        return settings.model.isEmpty ? settings.preset.capitalized : settings.model
    }

    private var startRow: some View {
        Button {
            open = AssistantChatTarget(conversationID: nil)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New conversation")
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Colors.foreground)
                    Text("Ask about your mail, or have something written.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.Colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .padding(.horizontal, Theme.Metrics.hPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The keys live encrypted on the Worker and are only enterable there, so this
    /// explains where to go rather than pretending the phone can fix it.
    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No provider yet")
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Colors.foreground)
            Text("Add a model provider and key in the web app under Settings, AI. Keys are stored encrypted on your Worker, so they cannot be entered here.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 8)
    }

    private func row(_ conversation: AiConversation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Colors.mutedForeground)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)
                Text(RelativeTime.short(conversation.updated))
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.mutedForeground)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .frame(height: 60)
        .contentShape(Rectangle())
    }
}

/// Identifies which conversation the chat sheet should open, including "a new one".
struct AssistantChatTarget: Identifiable, Hashable {
    let id = UUID()
    let conversationID: String?
}
