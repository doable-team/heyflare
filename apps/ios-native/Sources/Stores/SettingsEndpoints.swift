import Foundation

// The account-management, security and domain halves of the API. They were left to the
// web build on the reasoning that they are desk work; they are here now because a phone
// is where you are when Gmail stops syncing, when you want your second factor set up, or
// when a mailbox needs to exist before you can reply from it.

// MARK: - Shapes

/// One line of a mailbox's sync history, `GET /api/accounts/:id/logs`.
struct SyncLogRow: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var level: String
    var message: String
    var createdAt: Double

    var date: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    var isError: Bool { level == "error" }

    enum CodingKeys: String, CodingKey {
        case id, level, message
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        level = (try? c.decode(String.self, forKey: .level)) ?? "info"
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
    }
}

struct TwoFactorStatus: Codable, Sendable {
    var enabled: Bool
    var recoveryLeft: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case recoveryLeft = "recovery_left"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        recoveryLeft = (try? c.decode(Int.self, forKey: .recoveryLeft)) ?? 0
    }
}

/// `POST /api/me/2fa/setup`: the secret to type by hand and the URL a QR carries.
struct TwoFactorSetup: Codable, Identifiable, Sendable {
    var secret: String
    var otpauthURL: String

    var id: String { secret }

    enum CodingKeys: String, CodingKey {
        case secret
        case otpauthURL = "otpauth_url"
    }
}

struct RecoveryCodes: Codable, Sendable {
    var recoveryCodes: [String]

    enum CodingKeys: String, CodingKey {
        case recoveryCodes = "recovery_codes"
    }
}

struct DnsRecord: Codable, Hashable, Sendable {
    var type: String
    var name: String
    var content: String
    var priority: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        priority = try? c.decodeIfPresent(Int.self, forKey: .priority)
    }
}

/// A custom domain and the mailboxes on it, mirroring `Domain` in `src/shared/types.ts`.
struct MailDomain: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var status: String
    var routing: String
    var sending: String
    var catchAllAccountID: String?
    var error: String?
    var dns: [DnsRecord]
    var instructions: [String]
    var mailboxes: [Account]

    var isActive: Bool { status == "active" }

    var statusLabel: String {
        switch status {
        case "active": return "Active"
        case "error": return "Error"
        default: return "Pending"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, routing, sending, error, dns, instructions, mailboxes
        case catchAllAccountID = "catch_all_account_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "pending"
        routing = (try? c.decode(String.self, forKey: .routing)) ?? "unconfigured"
        sending = (try? c.decode(String.self, forKey: .sending)) ?? "none"
        catchAllAccountID = try? c.decodeIfPresent(String.self, forKey: .catchAllAccountID)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        dns = (try? c.decode([DnsRecord].self, forKey: .dns)) ?? []
        instructions = (try? c.decode([String].self, forKey: .instructions)) ?? []
        mailboxes = (try? c.decode([Account].self, forKey: .mailboxes)) ?? []
    }
}

private struct ConnectLink: Codable { var url: String }
private struct AccountSyncResult: Codable { var added: Int? }
private struct AccountReset: Codable {
    var syncError: String?
    enum CodingKeys: String, CodingKey { case syncError = "sync_error" }
}
private struct PhotoSync: Codable { var updated: Int? }

// MARK: - Calls

extension APIClient {
    // Mailboxes

    /// Mints the one-time link that starts Google's consent in a real browser. The state
    /// it carries identifies the session, so the browser needs no cookie of ours.
    func gmailConnectLink(loginHint: String? = nil) async throws -> URL {
        var body: [String: Any] = [:]
        if let loginHint, !loginHint.isEmpty { body["login_hint"] = loginHint }
        let link = try await post("/api/accounts/connect-link", body: body, as: ConnectLink.self, scoped: false)
        guard let url = URL(string: link.url) else { throw APIError.decoding("connect link") }
        return url
    }

    /// Answers how many threads the pull found, when the worker says.
    func syncNow(accountID: String) async throws -> Int? {
        try await post("/api/accounts/\(accountID)/sync", as: AccountSyncResult.self).added
    }

    /// "Start fresh": everything synced for the account goes, and syncing begins again
    /// from now. Answers the first sync's error, if it had one.
    func resetAccount(_ id: String) async throws -> String? {
        try await post("/api/accounts/\(id)/reset", as: AccountReset.self).syncError
    }

    func deleteAccount(_ id: String) async throws {
        try await delete("/api/accounts/\(id)")
    }

    func syncContactPhotos(accountID: String) async throws -> Int {
        try await post("/api/accounts/\(accountID)/sync-photos", as: PhotoSync.self).updated ?? 0
    }

    func accountLogs(_ id: String) async throws -> [SyncLogRow] {
        try await get("/api/accounts/\(id)/logs", as: [SyncLogRow].self)
    }

    // Security

    func changePassword(current: String, next: String) async throws {
        try await postIgnoringResult("/api/me/password", body: ["current": current, "next": next], scoped: false)
    }

    func twoFactorStatus() async throws -> TwoFactorStatus {
        try await get("/api/me/2fa", as: TwoFactorStatus.self, scoped: false)
    }

    func twoFactorSetup() async throws -> TwoFactorSetup {
        try await post("/api/me/2fa/setup", as: TwoFactorSetup.self, scoped: false)
    }

    func twoFactorEnable(code: String) async throws -> [String] {
        try await post("/api/me/2fa/enable", body: ["code": code], as: RecoveryCodes.self, scoped: false).recoveryCodes
    }

    func twoFactorRegenerate(code: String) async throws -> [String] {
        try await post("/api/me/2fa/recovery-codes", body: ["code": code], as: RecoveryCodes.self, scoped: false).recoveryCodes
    }

    func twoFactorDisable(password: String, code: String) async throws {
        var body: [String: Any] = ["password": password]
        if !code.isEmpty { body["code"] = code }
        try await postIgnoringResult("/api/me/2fa/disable", body: body, scoped: false)
    }

    // Domains

    func domains() async throws -> [MailDomain] {
        try await get("/api/domains", as: [MailDomain].self, scoped: false)
    }

    func verifyDomain(_ id: String) async throws -> MailDomain {
        try await post("/api/domains/\(id)/verify", as: MailDomain.self, scoped: false)
    }

    func createMailbox(domainID: String, localPart: String, displayName: String) async throws -> Account {
        try await post(
            "/api/domains/\(domainID)/mailboxes",
            body: ["local_part": localPart, "display_name": displayName],
            as: Account.self,
            scoped: false
        )
    }
}
