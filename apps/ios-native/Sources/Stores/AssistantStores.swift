import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// The assistant tab: a list of conversations, and the chat itself.
///
/// It took the Feed's slot in the tab bar because it is a mid-task tool. The list is the
/// root so a past conversation is one tap away, and "New conversation" sits at the top
/// where the thumb already is.
@MainActor
@Observable
final class AssistantListStore {
    private(set) var conversations: [AiConversation] = []
    private(set) var settings: AiSettings?
    private(set) var loading = false
    private(set) var loaded = false
    var error: String?

    init() {
        // Past conversations, on the first frame. Settings are not cached alongside them:
        // whether the assistant is configured decides what the screen offers to do, and
        // that is not a claim worth making from a stale copy.
        conversations = ContentCache.shared.value([AiConversation].self, for: .aiConversations) ?? []
    }

    func load(force: Bool = false) async {
        if loaded && !force { return }
        await refresh()
    }

    func refresh() async {
        if !loaded { loading = true }
        defer { loading = false }
        // Settings decide whether the tab can do anything at all, so they load alongside.
        async let list = try? await APIClient.shared.aiConversations()
        async let config = try? await APIClient.shared.aiSettings()
        let (fetched, cfg) = await (list, config)
        if let fetched {
            conversations = fetched
            ContentCache.shared.store(fetched, for: .aiConversations)
            error = nil
        } else if !loaded {
            error = "Could not reach the assistant."
        }
        settings = cfg
        loaded = true
    }

    func delete(_ id: String) async {
        let previous = conversations
        conversations.removeAll { $0.id == id }
        do {
            try await APIClient.shared.deleteAiConversation(id)
            ContentCache.shared.store(conversations, for: .aiConversations)
        } catch {
            conversations = previous
        }
    }

    func rename(_ id: String, to title: String) async {
        guard let index = conversations.firstIndex(where: { $0.id == id }), conversations[index].title != title else { return }
        let previous = conversations[index].title
        conversations[index].title = title
        do {
            try await APIClient.shared.renameAiConversation(id, title: title)
            ContentCache.shared.store(conversations, for: .aiConversations)
        } catch {
            if let again = conversations.firstIndex(where: { $0.id == id }) { conversations[again].title = previous }
        }
    }
}

/// One conversation, streaming.
///
/// The worker answers `POST /api/ai/chat` with server-sent events, so the reply arrives a
/// token at a time. The store appends into the last turn in place rather than adding a
/// row per event, which keeps the list stable while text grows under the reader's eyes.
@MainActor
@Observable
final class AssistantChatStore {
    private(set) var turns: [AiTurn] = []
    private(set) var streaming = false
    private(set) var loading = false
    var conversationID: String?
    var error: String?

    private var stream: Task<Void, Never>?

    init(conversationID: String?) {
        self.conversationID = conversationID
    }

    func loadHistory() async {
        guard let id = conversationID, turns.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            turns = try await APIClient.shared.aiConversation(id).turns
        } catch is CancellationError {
            // Closed before the history arrived: nothing to say.
        } catch {
            // Swallowed, this read as a conversation that was empty, which is a different
            // and more alarming thing than one that could not be fetched.
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func send(_ text: String, contextThreadIDs: [String] = []) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !streaming else { return }

        turns.append(AiTurn(id: UUID().uuidString, role: .user, text: message))
        // The assistant's turn is created empty and filled by the stream, so the
        // "thinking" state and the answer are the same row rather than two.
        let replyID = UUID().uuidString
        turns.append(AiTurn(id: replyID, role: .assistant, text: ""))
        streaming = true
        error = nil

        let events = APIClient.shared.aiChat(message: message, conversationID: conversationID, contextThreadIDs: contextThreadIDs)
        stream = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { break }
                self.apply(event, to: replyID)
            }
            self?.streaming = false
        }
    }

    /// Stops the answer. Cancelling the task closes the connection, which trips the
    /// worker's own abort signal, so the model stops rather than finishing unseen.
    func stop() {
        stream?.cancel()
        stream = nil
        streaming = false
    }

    private func apply(_ event: AiEvent, to replyID: String) {
        guard let index = turns.firstIndex(where: { $0.id == replyID }) else { return }
        switch event {
        case .start(let id):
            if !id.isEmpty { conversationID = id }
        case .text(let chunk):
            turns[index].text += chunk
        case .tool(let id, let name, let status, let summary):
            if let existing = turns[index].tools.firstIndex(where: { $0.id == id }) {
                turns[index].tools[existing].status = status
                if !summary.isEmpty { turns[index].tools[existing].summary = summary }
            } else {
                turns[index].tools.append(AiToolRun(id: id, name: name, summary: summary, status: status))
            }
        case .draft(let card):
            turns[index].drafts.append(card)
        case .sent:
            // Autonomous sending is off unless the owner turned it on; when it is on the
            // draft card would be misleading, so it is dropped once the mail has gone.
            turns[index].drafts.removeAll()
        case .done(let id):
            if !id.isEmpty { conversationID = id }
            streaming = false
        case .failure(let message):
            turns[index].failed = message
            error = message
            streaming = false
        }
    }
}

@MainActor
@Observable
final class AiSettingsStore {
    private(set) var settings: AiSettings?
    private(set) var loading = false
    var error: String?

    func load() async {
        loading = settings == nil
        defer { loading = false }
        do {
            settings = try await APIClient.shared.aiSettings()
            error = nil
        } catch {
            guard !(error is CancellationError) else { return }
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func apply(_ patch: [String: Any]) async throws {
        try await APIClient.shared.updateAiSettings(patch)
        await load()
    }
}
