import Foundation

/// What the composer was opened to do. Everything the sheet needs to prefill itself,
/// so any screen can start a reply without reaching into the composer's own state.
struct ComposeIntent: Identifiable, Hashable {
    enum Kind: Hashable {
        case new
        case reply(threadID: String, messageID: String, all: Bool)
        case forward(threadID: String, messageID: String)
    }

    let id = UUID()
    var kind: Kind = .new
    var accountID: String?
    /// Set when the composer was opened from a stored draft. Sending quotes this back to
    /// the worker so the draft is consumed rather than left behind as a duplicate — and,
    /// for a scheduled draft, so the queued send is replaced instead of racing it.
    var draftID: String?
    /// The time a scheduled draft was already set to go out, so reopening and sending it
    /// keeps the schedule instead of silently sending it now.
    var scheduledAt: Date?
    var to: [Address] = []
    var cc: [Address] = []
    var subject: String = ""
    /// Plain text; the composer wraps it in minimal HTML on send.
    var body: String = ""
    /// Text quoted under the reply, already flattened from the message being answered.
    var quoted: String = ""

    var title: String {
        switch kind {
        case .new: return "New message"
        case .reply: return "Reply"
        case .forward: return "Forward"
        }
    }

    var threadID: String? {
        switch kind {
        case .new: return nil
        case .reply(let t, _, _), .forward(let t, _): return t
        }
    }

    var replyToMessageID: String? {
        if case .reply(_, let m, _) = kind { return m }
        return nil
    }

    static func new(accountID: String?) -> ComposeIntent {
        ComposeIntent(kind: .new, accountID: accountID)
    }

    /// Builds a reply from a message: recipients, `Re:` subject and the quoted body.
    static func reply(to message: Message, in thread: ThreadDetail, me: [String], all: Bool) -> ComposeIntent {
        let mine = Set(me.map { $0.lowercased() })
        var recipients: [Address] = message.isFromMe ? message.to : [message.from]
        var carbon: [Address] = []
        if all {
            let extra = (message.to + message.cc).filter { !mine.contains($0.email.lowercased()) }
            let already = Set(recipients.map { $0.email.lowercased() })
            carbon = extra.filter { !already.contains($0.email.lowercased()) }
        }
        if recipients.isEmpty { recipients = [message.from] }

        return ComposeIntent(
            kind: .reply(threadID: thread.id, messageID: message.id, all: all),
            accountID: message.accountID ?? thread.summary.accountID,
            to: recipients,
            cc: carbon,
            subject: Self.prefixed("Re:", thread.summary.displaySubject),
            body: "",
            quoted: Self.quote(message)
        )
    }

    static func forward(_ message: Message, in thread: ThreadDetail) -> ComposeIntent {
        ComposeIntent(
            kind: .forward(threadID: thread.id, messageID: message.id),
            accountID: message.accountID ?? thread.summary.accountID,
            subject: Self.prefixed("Fwd:", thread.summary.displaySubject),
            quoted: Self.quote(message)
        )
    }

    /// Avoids "Re: Re: Re:".
    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) { return trimmed }
        return "\(prefix) \(trimmed)"
    }

    private static func quote(_ message: Message) -> String {
        let text = message.textBody.isEmpty ? HTMLText.plain(from: message.htmlBody) : message.textBody
        let header = "On \(RelativeTime.long(message.sentAt)), \(message.from.display) wrote:"
        let quoted = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(200)
            .map { "> " + $0 }
            .joined(separator: "\n")
        return header + "\n" + quoted
    }
}
