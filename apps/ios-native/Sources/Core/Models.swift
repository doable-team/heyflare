import Foundation

// Mirrors src/shared/types.ts. Every field the worker sends that the phone actually draws.
// Decoding is deliberately forgiving: the worker adds fields faster than the app ships,
// so unknown keys are ignored and absent ones fall back rather than failing the whole list.

// MARK: - Enumerations

enum Bucket: String, Codable, Hashable, CaseIterable, Sendable {
    case screener, imbox, feed
    case paperTrail = "paper_trail"
    case screenedOut = "screened_out"
    case trash

    var title: String {
        switch self {
        case .screener: return "Screener"
        case .imbox: return "Imbox"
        case .feed: return "The Feed"
        case .paperTrail: return "Paper Trail"
        case .screenedOut: return "Screened out"
        case .trash: return "Trash"
        }
    }
}

enum ScreenStatus: String, Codable, Hashable, Sendable {
    case pending, imbox, feed
    case paperTrail = "paper_trail"
    case screenedOut = "screened_out"

    var title: String {
        switch self {
        case .pending: return "Pending"
        case .imbox: return "Imbox"
        case .feed: return "The Feed"
        case .paperTrail: return "Paper Trail"
        case .screenedOut: return "Screened out"
        }
    }
}

/// Lists the worker exposes on `GET /api/threads?bucket=`, including the ones that are
/// not real buckets but saved views over them.
enum ThreadListKind: String, Hashable, Sendable {
    case feed
    case paperTrail = "paper_trail"
    case screenedOut = "screened_out"
    case trash
    case sent
    case everything
    case replyLater = "reply_later"
    case setAside = "set_aside"
    case bubbled
    /// Scheduled to return. The worker keeps this separate from `bubbled`,
    /// which is the ones that have already come back.
    case bubbleUp = "bubble_up"
    case screener

    /// Lists you look into before deciding, rather than sit down and read. Opening a
    /// thread from one of these must not consume its unread state.
    var previewsOnly: Bool {
        switch self {
        case .replyLater, .setAside, .bubbleUp, .bubbled, .screener: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .feed: return "The Feed"
        case .paperTrail: return "Paper Trail"
        case .screenedOut: return "Screened out"
        case .trash: return "Trash"
        case .sent: return "Sent"
        case .everything: return "Everything"
        case .replyLater: return "Reply Later"
        case .setAside: return "Set Aside"
        case .bubbled: return "Bubbled up"
        case .bubbleUp: return "Bubble Up"
        case .screener: return "Screener"
        }
    }
}

// MARK: - Primitives

struct Address: Codable, Hashable, Identifiable, Sendable {
    var email: String
    var name: String
    var avatarURL: String?

    var id: String { email }

    /// What a row shows: the display name when there is one, otherwise the local part.
    var display: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        if let at = email.firstIndex(of: "@") { return String(email[email.startIndex..<at]) }
        return email
    }

    var initials: String {
        let source = display
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        let letters = words.prefix(2).compactMap { $0.first }
        if letters.isEmpty { return "?" }
        return String(letters).uppercased()
    }

    enum CodingKeys: String, CodingKey {
        case email, name
        case avatarURL = "avatar_url"
    }

    init(email: String, name: String = "", avatarURL: String? = nil) {
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        avatarURL = try? c.decodeIfPresent(String.self, forKey: .avatarURL)
    }
}

struct MailLabel: Codable, Hashable, Identifiable, Sendable {
    var accountID: String?
    var id: String
    var name: String
    var color: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case id, name, color
    }
}

// MARK: - User & account

struct UserSettings: Codable, Hashable, Sendable {
    var theme: String?
    var defaultScreenTarget: String?
    var undoSendSeconds: Int?
    var showPreviews: Bool?
}

struct User: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var email: String
    var name: String
    var disabled: Bool
    var settings: UserSettings
    var createdAt: Double
    var twoFactorEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case id, email, name, disabled, settings
        case createdAt = "created_at"
        case twoFactorEnabled = "two_factor_enabled"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        disabled = (try? c.decode(Bool.self, forKey: .disabled)) ?? false
        settings = (try? c.decode(UserSettings.self, forKey: .settings)) ?? UserSettings()
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        twoFactorEnabled = try? c.decodeIfPresent(Bool.self, forKey: .twoFactorEnabled)
    }
}

struct Account: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var email: String
    var displayName: String
    var provider: String
    var domainID: String?
    var initialSyncDone: Bool
    var initialSyncCount: Int
    var syncStatus: String
    var syncError: String?
    var lastSyncedAt: Double?
    var signature: String
    var avatarURL: String
    /// When contact photos were last pulled; nil until the account is reconnected with the
    /// People scope, which is what Settings prompts for.
    var photosSyncedAt: Double?

    var isDomain: Bool { provider == "domain" }

    enum CodingKeys: String, CodingKey {
        case id, email, provider, signature
        case displayName = "display_name"
        case domainID = "domain_id"
        case initialSyncDone = "initial_sync_done"
        case initialSyncCount = "initial_sync_count"
        case syncStatus = "sync_status"
        case syncError = "sync_error"
        case lastSyncedAt = "last_synced_at"
        case avatarURL = "avatar_url"
        case photosSyncedAt = "photos_synced_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        provider = (try? c.decode(String.self, forKey: .provider)) ?? "gmail"
        domainID = try? c.decodeIfPresent(String.self, forKey: .domainID)
        initialSyncDone = (try? c.decode(Bool.self, forKey: .initialSyncDone)) ?? true
        initialSyncCount = (try? c.decode(Int.self, forKey: .initialSyncCount)) ?? 0
        syncStatus = (try? c.decode(String.self, forKey: .syncStatus)) ?? "idle"
        syncError = try? c.decodeIfPresent(String.self, forKey: .syncError)
        lastSyncedAt = try? c.decodeIfPresent(Double.self, forKey: .lastSyncedAt)
        signature = (try? c.decode(String.self, forKey: .signature)) ?? ""
        avatarURL = (try? c.decode(String.self, forKey: .avatarURL)) ?? ""
        photosSyncedAt = try? c.decodeIfPresent(Double.self, forKey: .photosSyncedAt)
    }
}

// MARK: - Mail

struct Attachment: Codable, Hashable, Identifiable, Sendable {
    var accountID: String?
    var id: String
    var messageID: String
    var threadID: String?
    var filename: String
    var mimeType: String
    var size: Int
    var isInline: Bool
    var createdAt: Double
    var threadSubject: String?
    var from: Address?

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var received: Date { Date(timeIntervalSince1970: createdAt / 1000) }

    enum CodingKeys: String, CodingKey {
        case id, filename, size, from
        case accountID = "account_id"
        case messageID = "message_id"
        case threadID = "thread_id"
        case mimeType = "mime_type"
        case isInline = "is_inline"
        case createdAt = "created_at"
        case threadSubject = "thread_subject"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        messageID = (try? c.decode(String.self, forKey: .messageID)) ?? ""
        threadID = try? c.decodeIfPresent(String.self, forKey: .threadID)
        filename = (try? c.decode(String.self, forKey: .filename)) ?? "attachment"
        mimeType = (try? c.decode(String.self, forKey: .mimeType)) ?? "application/octet-stream"
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        isInline = (try? c.decode(Bool.self, forKey: .isInline)) ?? false
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        threadSubject = try? c.decodeIfPresent(String.self, forKey: .threadSubject)
        from = try? c.decodeIfPresent(Address.self, forKey: .from)
    }
}

struct Message: Codable, Hashable, Identifiable, Sendable {
    var accountID: String?
    var id: String
    var threadID: String
    var from: Address
    /// The Reply-To header, lowercased by the worker; empty when the sender set none.
    var replyTo: String
    var to: [Address]
    var cc: [Address]
    var bcc: [Address]
    var subject: String
    var date: Double
    var snippet: String
    var textBody: String
    var htmlBody: String
    var isFromMe: Bool
    var unread: Bool
    var hasAttachments: Bool
    var trackers: [String]
    var listUnsubscribe: String
    var attachments: [Attachment]

    var sentAt: Date { Date(timeIntervalSince1970: date / 1000) }
    /// Attachments worth showing a chip for. Inline images belong to the body, not the tray.
    var visibleAttachments: [Attachment] { attachments.filter { !$0.isInline } }

    enum CodingKeys: String, CodingKey {
        case id, from, to, cc, bcc, subject, date, snippet, unread, trackers, attachments
        case accountID = "account_id"
        case threadID = "thread_id"
        case textBody = "text_body"
        case htmlBody = "html_body"
        case isFromMe = "is_from_me"
        case hasAttachments = "has_attachments"
        case listUnsubscribe = "list_unsubscribe"
        case replyTo = "reply_to"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        threadID = (try? c.decode(String.self, forKey: .threadID)) ?? ""
        from = (try? c.decode(Address.self, forKey: .from)) ?? Address(email: "")
        replyTo = (try? c.decode(String.self, forKey: .replyTo)) ?? ""
        to = (try? c.decode([Address].self, forKey: .to)) ?? []
        cc = (try? c.decode([Address].self, forKey: .cc)) ?? []
        bcc = (try? c.decode([Address].self, forKey: .bcc)) ?? []
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        date = (try? c.decode(Double.self, forKey: .date)) ?? 0
        snippet = (try? c.decode(String.self, forKey: .snippet)) ?? ""
        textBody = (try? c.decode(String.self, forKey: .textBody)) ?? ""
        htmlBody = (try? c.decode(String.self, forKey: .htmlBody)) ?? ""
        isFromMe = (try? c.decode(Bool.self, forKey: .isFromMe)) ?? false
        unread = (try? c.decode(Bool.self, forKey: .unread)) ?? false
        hasAttachments = (try? c.decode(Bool.self, forKey: .hasAttachments)) ?? false
        trackers = (try? c.decode([String].self, forKey: .trackers)) ?? []
        listUnsubscribe = (try? c.decode(String.self, forKey: .listUnsubscribe)) ?? ""
        attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
    }
}

struct ThreadSummary: Codable, Hashable, Identifiable, Sendable {
    var accountID: String?
    var id: String
    var subject: String
    var originalSubject: String
    var snippet: String
    var bucket: Bucket
    var seen: Bool
    var unread: Bool
    var replyLater: Bool
    var setAside: Bool
    var bubbleUpAt: Double?
    var bubbled: Bool
    var note: String
    var hasAttachments: Bool
    var trackersBlocked: Int
    var participants: [Address]
    var lastFrom: Address
    var messageCount: Int
    var firstMessageAt: Double
    var lastMessageAt: Double
    var labels: [MailLabel]
    var senderStatus: ScreenStatus?
    /// Only the Feed and Power Through send this along with the row.
    var latestMessage: Message?

    var lastDate: Date { Date(timeIntervalSince1970: lastMessageAt / 1000) }
    var displaySubject: String { subject.isEmpty ? "(no subject)" : subject }

    enum CodingKeys: String, CodingKey {
        case id, subject, snippet, bucket, seen, unread, note, participants, labels, bubbled
        case accountID = "account_id"
        case originalSubject = "original_subject"
        case replyLater = "reply_later"
        case setAside = "set_aside"
        case bubbleUpAt = "bubble_up_at"
        case hasAttachments = "has_attachments"
        case trackersBlocked = "trackers_blocked"
        case lastFrom = "last_from"
        case messageCount = "message_count"
        case firstMessageAt = "first_message_at"
        case lastMessageAt = "last_message_at"
        case senderStatus = "sender_status"
        case latestMessage = "latest_message"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        originalSubject = (try? c.decode(String.self, forKey: .originalSubject)) ?? ""
        snippet = (try? c.decode(String.self, forKey: .snippet)) ?? ""
        bucket = (try? c.decode(Bucket.self, forKey: .bucket)) ?? .imbox
        seen = (try? c.decode(Bool.self, forKey: .seen)) ?? true
        unread = (try? c.decode(Bool.self, forKey: .unread)) ?? false
        replyLater = (try? c.decode(Bool.self, forKey: .replyLater)) ?? false
        setAside = (try? c.decode(Bool.self, forKey: .setAside)) ?? false
        bubbleUpAt = try? c.decodeIfPresent(Double.self, forKey: .bubbleUpAt)
        bubbled = (try? c.decode(Bool.self, forKey: .bubbled)) ?? false
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        hasAttachments = (try? c.decode(Bool.self, forKey: .hasAttachments)) ?? false
        trackersBlocked = (try? c.decode(Int.self, forKey: .trackersBlocked)) ?? 0
        participants = (try? c.decode([Address].self, forKey: .participants)) ?? []
        lastFrom = (try? c.decode(Address.self, forKey: .lastFrom)) ?? Address(email: "")
        messageCount = (try? c.decode(Int.self, forKey: .messageCount)) ?? 1
        firstMessageAt = (try? c.decode(Double.self, forKey: .firstMessageAt)) ?? 0
        lastMessageAt = (try? c.decode(Double.self, forKey: .lastMessageAt)) ?? 0
        labels = (try? c.decode([MailLabel].self, forKey: .labels)) ?? []
        senderStatus = try? c.decodeIfPresent(ScreenStatus.self, forKey: .senderStatus)
        latestMessage = try? c.decodeIfPresent(Message.self, forKey: .latestMessage)
    }
}

struct ThreadDetail: Codable, Hashable, Identifiable, Sendable {
    var summary: ThreadSummary
    var messages: [Message]
    var collections: [CollectionRef]
    var clips: [Clip]
    /// Threads folded into this one (`merged_threads`), for the "Includes merged: …" footnote.
    var mergedThreads: [MergedRef]
    var senderBundled: Bool

    var id: String { summary.id }

    struct CollectionRef: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var name: String
    }

    struct MergedRef: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var subject: String
    }

    enum CodingKeys: String, CodingKey {
        case messages, collections, clips
        case mergedThreads = "merged_threads"
        case senderBundled = "sender_bundled"
    }

    init(from decoder: Decoder) throws {
        summary = try ThreadSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = (try? c.decode([Message].self, forKey: .messages)) ?? []
        collections = (try? c.decode([CollectionRef].self, forKey: .collections)) ?? []
        clips = (try? c.decode([Clip].self, forKey: .clips)) ?? []
        mergedThreads = (try? c.decode([MergedRef].self, forKey: .mergedThreads)) ?? []
        senderBundled = (try? c.decode(Bool.self, forKey: .senderBundled)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(messages, forKey: .messages)
        try c.encode(collections, forKey: .collections)
        try c.encode(clips, forKey: .clips)
        try c.encode(mergedThreads, forKey: .mergedThreads)
        try c.encode(senderBundled, forKey: .senderBundled)
    }
}

// MARK: - People

struct Contact: Codable, Hashable, Identifiable, Sendable {
    var accountID: String?
    var id: String
    var email: String
    var name: String
    var screenStatus: ScreenStatus
    var screenedAt: Double?
    var firstSeenAt: Double
    var lastSeenAt: Double
    var messageCount: Int
    var notes: String
    var avatarURL: String
    var bundled: Bool
    var mixed: Bool?
    /// `MergedContact.accounts`: every mailbox this person has written to, with that
    /// mailbox's own decision about them.
    var accounts: [ContactAccount]

    var address: Address { Address(email: email, name: name, avatarURL: avatarURL) }

    enum CodingKeys: String, CodingKey {
        case id, email, name, notes, bundled, mixed, accounts
        case accountID = "account_id"
        case screenStatus = "screen_status"
        case screenedAt = "screened_at"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case messageCount = "message_count"
        case avatarURL = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        screenStatus = (try? c.decode(ScreenStatus.self, forKey: .screenStatus)) ?? .pending
        screenedAt = try? c.decodeIfPresent(Double.self, forKey: .screenedAt)
        firstSeenAt = (try? c.decode(Double.self, forKey: .firstSeenAt)) ?? 0
        lastSeenAt = (try? c.decode(Double.self, forKey: .lastSeenAt)) ?? 0
        messageCount = (try? c.decode(Int.self, forKey: .messageCount)) ?? 0
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        avatarURL = (try? c.decode(String.self, forKey: .avatarURL)) ?? ""
        bundled = (try? c.decode(Bool.self, forKey: .bundled)) ?? false
        mixed = try? c.decodeIfPresent(Bool.self, forKey: .mixed)
        accounts = (try? c.decode([ContactAccount].self, forKey: .accounts)) ?? []
    }
}

/// One account's view of a person (`MergedContact.accounts[]`).
struct ContactAccount: Codable, Hashable, Sendable {
    var accountID: String
    var contactID: String
    var screenStatus: ScreenStatus
    var bundled: Bool

    enum CodingKeys: String, CodingKey {
        case bundled
        case accountID = "account_id"
        case contactID = "contact_id"
        case screenStatus = "screen_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = (try? c.decode(String.self, forKey: .accountID)) ?? ""
        contactID = (try? c.decode(String.self, forKey: .contactID)) ?? ""
        screenStatus = (try? c.decode(ScreenStatus.self, forKey: .screenStatus)) ?? .pending
        bundled = (try? c.decode(Bool.self, forKey: .bundled)) ?? false
    }
}

// MARK: - Bundles, clips, collections, drafts

struct MailBundle: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var contactID: String
    var accountID: String?
    var email: String
    var name: String
    var avatarURL: String
    var status: String
    var threadCount: Int
    var messageCount: Int
    var latest: ThreadSummary
    var lastMessageAt: Double

    var isOpen: Bool { status == "open" }
    var address: Address { Address(email: email, name: name, avatarURL: avatarURL) }
    var lastDate: Date { Date(timeIntervalSince1970: lastMessageAt / 1000) }

    enum CodingKeys: String, CodingKey {
        case id, email, name, status, latest
        case contactID = "contact_id"
        case accountID = "account_id"
        case avatarURL = "avatar_url"
        case threadCount = "thread_count"
        case messageCount = "message_count"
        case lastMessageAt = "last_message_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contactID = (try? c.decode(String.self, forKey: .contactID)) ?? ""
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        avatarURL = (try? c.decode(String.self, forKey: .avatarURL)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "seen"
        threadCount = (try? c.decode(Int.self, forKey: .threadCount)) ?? 0
        messageCount = (try? c.decode(Int.self, forKey: .messageCount)) ?? 0
        latest = try c.decode(ThreadSummary.self, forKey: .latest)
        lastMessageAt = (try? c.decode(Double.self, forKey: .lastMessageAt)) ?? 0
    }
}

struct Clip: Codable, Hashable, Identifiable, Sendable {
    var accountID: String?
    var id: String
    var threadID: String
    var messageID: String?
    var text: String
    var createdAt: Double
    var threadSubject: String?

    enum CodingKeys: String, CodingKey {
        case id, text
        case accountID = "account_id"
        case threadID = "thread_id"
        case messageID = "message_id"
        case createdAt = "created_at"
        case threadSubject = "thread_subject"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        threadID = (try? c.decode(String.self, forKey: .threadID)) ?? ""
        messageID = try? c.decodeIfPresent(String.self, forKey: .messageID)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        threadSubject = try? c.decodeIfPresent(String.self, forKey: .threadSubject)
    }
}

struct MailCollection: Codable, Hashable, Identifiable, Sendable {
    var accountID: String?
    var id: String
    var name: String
    var description: String
    var threadCount: Int
    var fileCount: Int
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case accountID = "account_id"
        case threadCount = "thread_count"
        case fileCount = "file_count"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        threadCount = (try? c.decode(Int.self, forKey: .threadCount)) ?? 0
        fileCount = (try? c.decode(Int.self, forKey: .fileCount)) ?? 0
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

struct Draft: Codable, Hashable, Identifiable, Sendable {
    var accountID: String?
    var id: String
    var threadID: String?
    var replyToMessageID: String?
    var to: [Address]
    var cc: [Address]
    var bcc: [Address]
    var subject: String
    var bodyHTML: String
    var sendAt: Double?
    var status: String
    /// Why the last send attempt failed, when `status` is "failed".
    var error: String?
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, to, cc, bcc, subject, status, error
        case accountID = "account_id"
        case threadID = "thread_id"
        case replyToMessageID = "reply_to_message_id"
        case bodyHTML = "body_html"
        case sendAt = "send_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        threadID = try? c.decodeIfPresent(String.self, forKey: .threadID)
        replyToMessageID = try? c.decodeIfPresent(String.self, forKey: .replyToMessageID)
        to = (try? c.decode([Address].self, forKey: .to)) ?? []
        cc = (try? c.decode([Address].self, forKey: .cc)) ?? []
        bcc = (try? c.decode([Address].self, forKey: .bcc)) ?? []
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        bodyHTML = (try? c.decode(String.self, forKey: .bodyHTML)) ?? ""
        sendAt = try? c.decodeIfPresent(Double.self, forKey: .sendAt)
        status = (try? c.decode(String.self, forKey: .status)) ?? "draft"
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

// MARK: - Responses

struct MeResponse: Codable, Sendable {
    var user: User?
    var accounts: [Account]
    var googleConfigured: Bool?
    var microsoftConfigured: Bool?
    /// A server with no owner yet: the first sign-in creates one (`/auth/setup`).
    var setupRequired: Bool

    enum CodingKeys: String, CodingKey {
        case user, accounts
        case googleConfigured = "google_configured"
        case microsoftConfigured = "microsoft_configured"
        case setupRequired = "setup_required"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try? c.decodeIfPresent(User.self, forKey: .user)
        accounts = (try? c.decode([Account].self, forKey: .accounts)) ?? []
        googleConfigured = try? c.decodeIfPresent(Bool.self, forKey: .googleConfigured)
        microsoftConfigured = try? c.decodeIfPresent(Bool.self, forKey: .microsoftConfigured)
        setupRequired = (try? c.decode(Bool.self, forKey: .setupRequired)) ?? false
    }
}

struct Counts: Codable, Hashable, Sendable {
    var screener: Int
    var imboxNew: Int
    var feedNew: Int
    var paperTrailNew: Int
    var replyLater: Int
    var setAside: Int

    static let zero = Counts()

    init() {
        screener = 0; imboxNew = 0; feedNew = 0; paperTrailNew = 0; replyLater = 0; setAside = 0
    }

    enum CodingKeys: String, CodingKey {
        case screener
        case imboxNew = "imbox_new"
        case feedNew = "feed_new"
        case paperTrailNew = "paper_trail_new"
        case replyLater = "reply_later"
        case setAside = "set_aside"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screener = (try? c.decode(Int.self, forKey: .screener)) ?? 0
        imboxNew = (try? c.decode(Int.self, forKey: .imboxNew)) ?? 0
        feedNew = (try? c.decode(Int.self, forKey: .feedNew)) ?? 0
        paperTrailNew = (try? c.decode(Int.self, forKey: .paperTrailNew)) ?? 0
        replyLater = (try? c.decode(Int.self, forKey: .replyLater)) ?? 0
        setAside = (try? c.decode(Int.self, forKey: .setAside)) ?? 0
    }
}

struct ScreenerSender: Codable, Hashable, Identifiable, Sendable {
    var accountID: String?
    var threadCount: Int
    var email: String
    var name: String
    var avatarURL: String

    var id: String { email }
    var address: Address { Address(email: email, name: name, avatarURL: avatarURL) }

    enum CodingKeys: String, CodingKey {
        case email, name
        case accountID = "account_id"
        case threadCount = "thread_count"
        case avatarURL = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try? c.decodeIfPresent(String.self, forKey: .accountID)
        threadCount = (try? c.decode(Int.self, forKey: .threadCount)) ?? 0
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        avatarURL = (try? c.decode(String.self, forKey: .avatarURL)) ?? ""
    }
}

struct ImboxResponse: Codable, Sendable {
    var newThreads: [ThreadSummary]
    var seenThreads: [ThreadSummary]
    var replyLater: [ThreadSummary]
    var setAside: [ThreadSummary]
    var screenerCount: Int
    var screenerSenders: [ScreenerSender]
    var bundles: [MailBundle]

    static let empty = ImboxResponse()

    init() {
        newThreads = []; seenThreads = []; replyLater = []; setAside = []
        screenerCount = 0; screenerSenders = []; bundles = []
    }

    enum CodingKeys: String, CodingKey {
        case bundles
        case newThreads = "new_threads"
        case seenThreads = "seen_threads"
        case replyLater = "reply_later"
        case setAside = "set_aside"
        case screenerCount = "screener_count"
        case screenerSenders = "screener_senders"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        newThreads = (try? c.decode([ThreadSummary].self, forKey: .newThreads)) ?? []
        seenThreads = (try? c.decode([ThreadSummary].self, forKey: .seenThreads)) ?? []
        replyLater = (try? c.decode([ThreadSummary].self, forKey: .replyLater)) ?? []
        setAside = (try? c.decode([ThreadSummary].self, forKey: .setAside)) ?? []
        screenerCount = (try? c.decode(Int.self, forKey: .screenerCount)) ?? 0
        screenerSenders = (try? c.decode([ScreenerSender].self, forKey: .screenerSenders)) ?? []
        bundles = (try? c.decode([MailBundle].self, forKey: .bundles)) ?? []
    }
}

struct ThreadPage: Codable, Sendable {
    var threads: [ThreadSummary]
    /// Paper Trail only, page 0: the bundled senders' threads come as bundles instead of rows.
    var bundles: [MailBundle]
    var nextPage: Int?

    enum CodingKeys: String, CodingKey {
        case threads, bundles
        case nextPage = "next_page"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = (try? c.decode([ThreadSummary].self, forKey: .threads)) ?? []
        bundles = (try? c.decode([MailBundle].self, forKey: .bundles)) ?? []
        nextPage = try? c.decodeIfPresent(Int.self, forKey: .nextPage)
    }
}

struct ScreenerEntry: Codable, Identifiable, Sendable {
    var contact: Contact
    var threads: [ThreadSummary]
    var suggestion: ScreenStatus

    var id: String { contact.id }

    enum CodingKeys: String, CodingKey { case contact, threads, suggestion }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contact = try c.decode(Contact.self, forKey: .contact)
        threads = (try? c.decode([ThreadSummary].self, forKey: .threads)) ?? []
        suggestion = (try? c.decode(ScreenStatus.self, forKey: .suggestion)) ?? .imbox
    }
}

struct ScreenerResponse: Codable, Sendable {
    var senders: [ScreenerEntry]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        senders = (try? c.decode([ScreenerEntry].self, forKey: .senders)) ?? []
    }

    enum CodingKeys: String, CodingKey { case senders }
}

struct LoginResponse: Codable, Sendable {
    var user: User?
    var mfaRequired: Bool?
    var ticket: String?

    enum CodingKeys: String, CodingKey {
        case user, ticket
        case mfaRequired = "mfa_required"
    }
}

struct SendResponse: Codable, Sendable {
    var ok: Bool?
    var threadID: String?
    var messageID: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case threadID = "thread_id"
        case messageID = "message_id"
    }
}

struct PowerThroughResponse: Codable, Sendable {
    var items: [ThreadSummary]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decode([ThreadSummary].self, forKey: .items)) ?? []
    }

    enum CodingKeys: String, CodingKey { case items }
}

// MARK: - Calendar

/// The calendar's own wire types live in `Features/Calendar/CalendarAPI.swift`. They decode
/// the same endpoint as the rest of this file's models but carry recurrence, attendees and
/// reminders too, which the editor needs and a month grid does not.
