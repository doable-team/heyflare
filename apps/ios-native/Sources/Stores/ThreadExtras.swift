import Foundation

// The thread screen's own slice of the API, kept here rather than in `APIClient.swift`
// so this feature can close its parity gaps without touching a file every other screen
// shares. Everything below is either an action the typed `ThreadAction` enum does not
// carry, or an endpoint only this screen calls.

// MARK: - Sender bundling

extension APIClient {
    /// Bundles (or unbundles) the thread's sender, the way the web client's More sheet does.
    ///
    /// `bundle` is a `POST /api/threads/:id/actions` action like any other — `{action, on}`,
    /// per `applyAction` in `src/worker/routes/mail.ts` — but it is missing from the shared
    /// `ThreadAction` enum, and that enum lives in a file this feature does not own. Calling
    /// the endpoint directly keeps the change local; when `ThreadAction` gains a `.bundle`
    /// case this can collapse into `act(_:_:)` and disappear.
    ///
    /// The route answers with the reloaded thread, exactly as the typed actions do, so the
    /// caller gets the same `ThreadDetail` back and `sender_bundled` flips in place.
    @discardableResult
    func bundleSender(_ threadID: String, on: Bool) async throws -> ThreadDetail {
        try await post("/api/threads/\(threadID)/actions", body: ["action": "bundle", "on": on], as: ThreadDetail.self)
    }
}

// MARK: - Clips

extension APIClient {
    /// Keeps a passage from a message. `message_id` is optional server-side, but sending it
    /// is what lets the Clips library point back at the message the words came from.
    func createClip(threadID: String, messageID: String?, text: String) async throws -> Clip {
        try await post(
            "/api/clips",
            body: ["thread_id": threadID, "message_id": messageID ?? NSNull(), "text": text],
            as: Clip.self
        )
    }

    func deleteClip(_ id: String) async throws {
        try await delete("/api/clips/\(id)")
    }
}

// MARK: - AI

/// The voice the drafted reply should be written in. `match` is the default and means
/// "sound like me", which is why it is labelled with a possessive rather than a style.
enum ThreadAiTone: String, CaseIterable, Identifiable, Sendable {
    case match, formal, friendly, brief

    var id: String { rawValue }

    var title: String {
        switch self {
        case .match: return "My tone"
        case .formal: return "Formal"
        case .friendly: return "Friendly"
        case .brief: return "Brief"
        }
    }
}

/// What `POST /api/ai/reply` hands back: a whole draft, not a stream.
struct ThreadAiReply: Decodable, Sendable {
    var bodyText: String
    var bodyHTML: String
    var subject: String?
    /// The message the model actually answered — the last one not from you. The composer
    /// quotes that message rather than whichever is last, so the reply threads correctly
    /// when your own sent mail is the tail of the conversation.
    var replyToMessageID: String?

    enum CodingKeys: String, CodingKey {
        case subject
        case bodyText = "body_text"
        case bodyHTML = "body_html"
        case replyToMessageID = "reply_to_message_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bodyText = (try? c.decode(String.self, forKey: .bodyText)) ?? ""
        bodyHTML = (try? c.decode(String.self, forKey: .bodyHTML)) ?? ""
        subject = try? c.decodeIfPresent(String.self, forKey: .subject)
        replyToMessageID = try? c.decodeIfPresent(String.self, forKey: .replyToMessageID)
    }
}

private struct ThreadAiSummaryResponse: Decodable {
    var summary: String
}

extension APIClient {
    /// Both AI calls are owner-wide, not account-scoped: the worker resolves the owning
    /// account from the thread row itself, which is why these go out unscoped like the
    /// assistant's own calls.
    func aiSummary(threadID: String) async throws -> String {
        try await post(
            "/api/ai/summarize",
            body: ["thread_id": threadID],
            as: ThreadAiSummaryResponse.self,
            scoped: false
        ).summary
    }

    func aiReply(threadID: String, brief: String, tone: ThreadAiTone) async throws -> ThreadAiReply {
        try await post(
            "/api/ai/reply",
            body: ["thread_id": threadID, "brief": brief, "tone": tone.rawValue],
            as: ThreadAiReply.self,
            scoped: false
        )
    }
}

// MARK: - Summary state

/// Where the AI summary panel is in its life. Modelled as one value rather than three
/// booleans so the panel cannot draw a spinner and a summary at the same time.
enum ThreadSummaryState: Equatable {
    /// Never asked for. The panel is not on screen at all.
    case idle
    case running
    case ready(String)
    /// No provider set up. Answered from `/api/ai/settings` before the request is made,
    /// so the person gets the explanation rather than the worker's raw error string.
    case unconfigured
    case failed(String)

    var isVisible: Bool { self != .idle }
}
