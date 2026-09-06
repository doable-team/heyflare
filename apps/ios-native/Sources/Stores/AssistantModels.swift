import Foundation

// The assistant's half of the API. `POST /api/ai/chat` answers with server-sent events
// rather than JSON, so the transport lives here beside the shapes it produces.

struct AiConversation: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var createdAt: Double
    var updatedAt: Double

    var displayTitle: String { title.isEmpty ? "Untitled" : title }
    var updated: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

/// One turn on screen. The worker stores Anthropic content blocks; the phone only needs
/// the text it should draw, plus the tool activity that explains a pause.
struct AiTurn: Identifiable, Hashable {
    enum Role: String { case user, assistant }

    let id: String
    var role: Role
    var text: String
    /// Tool calls made during this turn, in the order they started.
    var tools: [AiToolRun] = []
    /// Drafts the assistant wrote and left for you to send.
    var drafts: [AiDraftCard] = []
    var failed: String?
}

struct AiToolRun: Identifiable, Hashable {
    let id: String
    var name: String
    var summary: String
    var status: String      // running | done | error

    var isRunning: Bool { status == "running" }

    /// The tool names the worker emits are snake_case identifiers; this is what a
    /// person reads while they wait.
    var label: String {
        summary.isEmpty ? name.replacingOccurrences(of: "_", with: " ").capitalized : summary
    }
}

struct AiDraftCard: Codable, Hashable, Identifiable, Sendable {
    var draftID: String
    var accountID: String?
    var from: String
    var threadID: String?
    var to: [Address]
    var cc: [Address]
    var subject: String
    var bodyText: String

    var id: String { draftID }

    enum CodingKeys: String, CodingKey {
        case from, to, cc, subject
        case draftID = "draft_id"
        case accountID = "account_id"
        case threadID = "thread_id"
        case bodyText = "body_text"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        draftID = (try? c.decode(String.self, forKey: .draftID)) ?? UUID().uuidString
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        from = (try? c.decode(String.self, forKey: .from)) ?? ""
        threadID = try? c.decodeIfPresent(String.self, forKey: .threadID)
        to = (try? c.decode([Address].self, forKey: .to)) ?? []
        cc = (try? c.decode([Address].self, forKey: .cc)) ?? []
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        bodyText = (try? c.decode(String.self, forKey: .bodyText)) ?? ""
    }
}

struct AiConversationDetail: Sendable {
    var conversation: AiConversation
    var turns: [AiTurn]
}

/// One provider the worker knows how to talk to, from `GET /api/ai/settings`.
struct AiPreset: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var label: String
    var kind: String
    var baseURL: String
    var defaultModel: String
    var models: [String]
    var keyPlaceholder: String
    var keyURL: String?

    enum CodingKeys: String, CodingKey {
        case id, label, kind, models
        case baseURL = "base_url"
        case defaultModel = "default_model"
        case keyPlaceholder = "key_placeholder"
        case keyURL = "key_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? "custom"
        label = (try? c.decode(String.self, forKey: .label)) ?? id.capitalized
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "openai_compatible"
        baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? ""
        defaultModel = (try? c.decode(String.self, forKey: .defaultModel)) ?? ""
        models = (try? c.decode([String].self, forKey: .models)) ?? []
        keyPlaceholder = (try? c.decode(String.self, forKey: .keyPlaceholder)) ?? ""
        keyURL = try? c.decodeIfPresent(String.self, forKey: .keyURL)
    }
}

/// Whether the assistant is usable at all, and with which provider.
struct AiSettings: Codable, Sendable {
    var configured: Bool
    var preset: String
    var baseURL: String
    var keyHint: String
    var model: String
    var learn: Bool
    var autoSend: Bool
    var presets: [AiPreset]
    var lastLearnedAt: Double?
    var serverReady: Bool

    enum CodingKeys: String, CodingKey {
        case configured, preset, model, learn, presets
        case baseURL = "base_url"
        case keyHint = "key_hint"
        case autoSend = "auto_send"
        case lastLearnedAt = "last_learned_at"
        case serverReady = "server_ready"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = (try? c.decode(Bool.self, forKey: .configured)) ?? false
        preset = (try? c.decode(String.self, forKey: .preset)) ?? ""
        baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? ""
        keyHint = (try? c.decode(String.self, forKey: .keyHint)) ?? ""
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        learn = (try? c.decode(Bool.self, forKey: .learn)) ?? true
        autoSend = (try? c.decode(Bool.self, forKey: .autoSend)) ?? false
        presets = (try? c.decode([AiPreset].self, forKey: .presets)) ?? []
        lastLearnedAt = try? c.decodeIfPresent(Double.self, forKey: .lastLearnedAt)
        serverReady = (try? c.decode(Bool.self, forKey: .serverReady)) ?? false
    }
}

/// `POST /api/ai/settings/test`.
struct AiTestResult: Codable, Sendable {
    var ok: Bool
    var model: String?
    var reply: String?
    var error: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        reply = try? c.decodeIfPresent(String.self, forKey: .reply)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }

    enum CodingKeys: String, CodingKey { case ok, model, reply, error }
}

/// The five drawers the web sorts memory into, in the order it lists them.
enum AiMemoryKind: String, Codable, CaseIterable, Sendable {
    case profile, tone, fact, preference, contact

    var label: String {
        switch self {
        case .profile: return "About you"
        case .tone: return "How you write"
        case .fact: return "Facts"
        case .preference: return "Preferences"
        case .contact: return "People"
        }
    }
}

struct AiMemoryEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: AiMemoryKind
    var content: String
    /// `user`, `assistant` or `learned`.
    var source: String
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, content, source
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(AiMemoryKind.self, forKey: .kind)) ?? .fact
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? "user"
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

private struct LearnResult: Decodable {
    var changed: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        changed = (try? c.decode(Int.self, forKey: .changed)) ?? 0
    }
    enum CodingKeys: String, CodingKey { case changed }
}

// MARK: - Streaming

/// One server-sent event from `POST /api/ai/chat`.
enum AiEvent: Sendable {
    case start(conversationID: String)
    case text(String)
    case tool(id: String, name: String, status: String, summary: String)
    case draft(AiDraftCard)
    case sent(draftID: String, threadID: String)
    case done(conversationID: String)
    case failure(String)

    /// The worker sends `data: {json}` lines. Anything it does not recognise is skipped
    /// rather than treated as an error, so a newer worker cannot break an older app.
    static func decode(_ json: Data) -> AiEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "start":
            return .start(conversationID: obj["conversation_id"] as? String ?? "")
        case "text":
            return .text(obj["text"] as? String ?? "")
        case "tool":
            return .tool(
                id: obj["id"] as? String ?? UUID().uuidString,
                name: obj["name"] as? String ?? "",
                status: obj["status"] as? String ?? "running",
                summary: obj["summary"] as? String ?? ""
            )
        case "draft":
            guard let raw = obj["draft"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let card = try? JSONDecoder().decode(AiDraftCard.self, from: data) else { return nil }
            return .draft(card)
        case "sent":
            return .sent(draftID: obj["draft_id"] as? String ?? "", threadID: obj["thread_id"] as? String ?? "")
        case "done":
            return .done(conversationID: obj["conversation_id"] as? String ?? "")
        case "error":
            return .failure(obj["message"] as? String ?? "The assistant stopped.")
        default:
            return nil
        }
    }
}

extension APIClient {
    func aiSettings() async throws -> AiSettings {
        try await get("/api/ai/settings", as: AiSettings.self, scoped: false)
    }

    func aiConversations() async throws -> [AiConversation] {
        try await get("/api/ai/conversations", as: [AiConversation].self, scoped: false)
    }

    func aiConversation(_ id: String) async throws -> AiConversationDetail {
        let data = try await data(path: "/api/ai/conversations/\(id)")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let convRaw = obj["conversation"],
              let convData = try? JSONSerialization.data(withJSONObject: convRaw),
              let conversation = try? JSONDecoder().decode(AiConversation.self, from: convData) else {
            throw APIError.decoding("conversation")
        }
        let messages = obj["messages"] as? [[String: Any]] ?? []
        return AiConversationDetail(conversation: conversation, turns: messages.compactMap(Self.turn(from:)))
    }

    func deleteAiConversation(_ id: String) async throws {
        try await delete("/api/ai/conversations/\(id)", scoped: false)
    }

    func renameAiConversation(_ id: String, title: String) async throws {
        struct Ok: Decodable {}
        _ = try await patch("/api/ai/conversations/\(id)", body: ["title": title], as: Ok.self, scoped: false)
    }

    // Settings and memory

    /// `PUT /api/ai/settings` merges: send only the keys that change. `api_key` as
    /// `NSNull` removes the stored key.
    func updateAiSettings(_ patch: [String: Any]) async throws {
        struct Ok: Decodable {}
        _ = try await put("/api/ai/settings", body: patch, as: Ok.self, scoped: false)
    }

    /// A failed test comes back as a 400 whose `error` is the provider's own words, so the
    /// thrown `APIError.server` code is the message to show.
    func testAiSettings() async throws -> AiTestResult {
        try await post("/api/ai/settings/test", as: AiTestResult.self, scoped: false)
    }

    func aiMemory() async throws -> [AiMemoryEntry] {
        try await get("/api/ai/memory", as: [AiMemoryEntry].self, scoped: false)
    }

    func addAiMemory(kind: AiMemoryKind, content: String) async throws -> AiMemoryEntry {
        try await post("/api/ai/memory", body: ["kind": kind.rawValue, "content": content], as: AiMemoryEntry.self, scoped: false)
    }

    func updateAiMemory(_ id: String, content: String) async throws -> AiMemoryEntry {
        try await patch("/api/ai/memory/\(id)", body: ["content": content], as: AiMemoryEntry.self, scoped: false)
    }

    func deleteAiMemory(_ id: String) async throws {
        try await delete("/api/ai/memory/\(id)", scoped: false)
    }

    func clearAiMemory() async throws {
        try await delete("/api/ai/memory", scoped: false)
    }

    /// Runs the learner now rather than waiting for the cron. Answers how many memories changed.
    func aiLearnNow() async throws -> Int {
        try await post("/api/ai/learn", as: LearnResult.self, scoped: false).changed
    }

    /// Flattens one stored message into the text the phone draws.
    ///
    /// The worker persists Anthropic content blocks, so a single assistant message can be
    /// a mix of prose, `tool_use` and `tool_result`. Only the text blocks are rendered;
    /// tool blocks become the small activity lines, because replaying a tool's raw JSON
    /// into the transcript would be noise.
    private static func turn(from message: [String: Any]) -> AiTurn? {
        guard let id = message["id"] as? String,
              let roleRaw = message["role"] as? String,
              let role = AiTurn.Role(rawValue: roleRaw) else { return nil }

        var text = ""
        var tools: [AiToolRun] = []

        if let plain = message["content"] as? String {
            text = plain
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    // Context blocks are prefixed by the worker and are not the person's words.
                    let value = block["text"] as? String ?? ""
                    if value.hasPrefix("[[context thread=") { continue }
                    text += (text.isEmpty ? "" : "\n\n") + value
                case "tool_use":
                    tools.append(AiToolRun(
                        id: block["id"] as? String ?? UUID().uuidString,
                        name: block["name"] as? String ?? "",
                        summary: "",
                        status: "done"
                    ))
                default:
                    continue
                }
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !tools.isEmpty else { return nil }
        return AiTurn(id: id, role: role, text: trimmed, tools: tools)
    }

    /// Opens the chat stream and yields events as they arrive.
    ///
    /// `URLSession.bytes(for:)` gives a line sequence, which is exactly the shape of a
    /// server-sent event stream, so there is no buffering to get wrong here. Cancelling
    /// the surrounding task closes the connection, and the worker's own abort signal
    /// stops the model mid-answer.
    nonisolated func aiChat(message: String, conversationID: String?, contextThreadIDs: [String]) -> AsyncStream<AiEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    guard let base = ServerConfig.shared.baseURL else {
                        continuation.yield(.failure(APIError.notConfigured.errorDescription ?? "No server"))
                        continuation.finish()
                        return
                    }
                    var request = URLRequest(url: base.appendingPathComponent("/api/ai/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // The model can think for a long time before the first byte.
                    request.timeoutInterval = 180
                    var body: [String: Any] = ["message": message]
                    if let conversationID, !conversationID.isEmpty { body["conversation_id"] = conversationID }
                    if !contextThreadIDs.isEmpty { body["context_thread_ids"] = contextThreadIDs }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.yield(.failure(http.statusCode == 400
                            ? "The assistant is not set up yet. Add a provider key in the web app under Settings, AI."
                            : "The assistant could not be reached."))
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8), let event = AiEvent.decode(data) else { continue }
                        continuation.yield(event)
                        if case .done = event { break }
                    }
                } catch is CancellationError {
                    // Nothing to say: the person navigated away or stopped the answer.
                } catch {
                    continuation.yield(.failure((error as? APIError)?.errorDescription ?? error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
