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

/// One provider's OAuth client, `GET /api/oauth` (`OAuthCredentialStatus` in api.ts).
struct OAuthCredentialStatus: Codable, Hashable, Identifiable, Sendable {
    var provider: String
    var configured: Bool
    /// Which credentials are in use right now: `env`, `db` or `none`.
    var source: String
    /// A Worker secret exists for this provider, whether or not it is the one in use.
    var envAvailable: Bool
    /// Stored credentials are deliberately overriding a Worker secret.
    var overriding: Bool
    var clientID: String
    var secretHint: String

    var id: String { provider }

    enum CodingKeys: String, CodingKey {
        case provider, configured, source, overriding
        case envAvailable = "env_available"
        case clientID = "client_id"
        case secretHint = "secret_hint"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
        configured = (try? c.decode(Bool.self, forKey: .configured)) ?? false
        source = (try? c.decode(String.self, forKey: .source)) ?? "none"
        envAvailable = (try? c.decode(Bool.self, forKey: .envAvailable)) ?? false
        overriding = (try? c.decode(Bool.self, forKey: .overriding)) ?? false
        clientID = (try? c.decode(String.self, forKey: .clientID)) ?? ""
        secretHint = (try? c.decode(String.self, forKey: .secretHint)) ?? ""
    }
}

/// An IMAP mailbox's servers, `GET /api/accounts/:id/imap`. The password never comes back.
struct ImapServerSettings: Codable, Sendable {
    var imapHost: String
    var imapPort: Int
    var smtpHost: String
    var smtpPort: Int

    enum CodingKeys: String, CodingKey {
        case imapHost = "imap_host"
        case imapPort = "imap_port"
        case smtpHost = "smtp_host"
        case smtpPort = "smtp_port"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imapHost = (try? c.decode(String.self, forKey: .imapHost)) ?? ""
        imapPort = (try? c.decode(Int.self, forKey: .imapPort)) ?? 993
        smtpHost = (try? c.decode(String.self, forKey: .smtpHost)) ?? ""
        smtpPort = (try? c.decode(Int.self, forKey: .smtpPort)) ?? 465
    }
}

/// `POST /api/domains` answered 409 `mx_in_use`: the domain's mail goes to these hosts today,
/// and adding it has to be confirmed as a takeover (the web's `DomainMxError`).
struct DomainMxInUse: Error {
    let mx: [String]
}

private struct ConnectLink: Codable { var url: String }
private struct ImapAccountResponse: Codable { var account: Account }
private struct ImapTestResponse: Codable { var ok: Bool; var error: String? }
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
    func gmailConnectLink(loginHint: String? = nil, provider: String = "google") async throws -> URL {
        var body: [String: Any] = ["provider": provider]
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

    /// The web always sends `code`, even empty; the worker rejects the empty one.
    func twoFactorDisable(password: String, code: String) async throws {
        try await postIgnoringResult("/api/me/2fa/disable", body: ["password": password, "code": code], scoped: false)
    }

    // Domains

    func domains() async throws -> [MailDomain] {
        try await get("/api/domains", as: [MailDomain].self, scoped: false)
    }

    func verifyDomain(_ id: String) async throws -> MailDomain {
        try await post("/api/domains/\(id)/verify", as: MailDomain.self, scoped: false)
    }

    /// `catch_all` makes the new mailbox the domain's catch-all as well; the web ticks it by
    /// default for a domain's first mailbox.
    func createMailbox(domainID: String, localPart: String, displayName: String, catchAll: Bool = false) async throws -> Account {
        try await post(
            "/api/domains/\(domainID)/mailboxes",
            body: ["local_part": localPart, "display_name": displayName, "catch_all": catchAll],
            as: Account.self,
            scoped: false
        )
    }

    /// Adds a domain. A 409 `mx_in_use` is thrown as `DomainMxInUse` carrying the hosts, so the
    /// takeover notice can list them; every other failure is the usual `APIError`.
    func createDomain(name: String, confirm: Bool?) async throws -> MailDomain {
        var body: [String: Any] = ["name": name]
        if let confirm { body["confirm"] = confirm }
        let (status, json) = try await postRaw("/api/domains", body: body, scoped: false)
        let code = json?["error"] as? String
        if status == 409, code == "mx_in_use" { throw DomainMxInUse(mx: (json?["mx"] as? [String]) ?? []) }
        guard (200..<300).contains(status) else { throw APIError.server(code ?? "http_\(status)", status) }
        let data = try JSONSerialization.data(withJSONObject: json ?? [:])
        do { return try JSONDecoder().decode(MailDomain.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    /// `PATCH /api/domains/:id`: where mail to unknown addresses goes. `nil` turns it off.
    func setDomainCatchAll(_ domainID: String, accountID: String?) async throws -> MailDomain {
        try await patch("/api/domains/\(domainID)", body: ["catch_all_account_id": accountID ?? NSNull()], as: MailDomain.self, scoped: false)
    }

    // IMAP mailboxes

    /// `POST /api/accounts/imap`: the worker checks both servers before it saves anything, so
    /// a failure here is the provider's own words and the caller shows them.
    func createImapAccount(_ body: [String: Any]) async throws -> Account {
        try await post("/api/accounts/imap", body: body, as: ImapAccountResponse.self, scoped: false).account
    }

    func imapSettings(accountID: String) async throws -> ImapServerSettings {
        try await get("/api/accounts/\(accountID)/imap", as: ImapServerSettings.self, scoped: false)
    }

    func updateImapAccount(_ accountID: String, _ body: [String: Any]) async throws -> Account {
        try await patch("/api/accounts/\(accountID)/imap", body: body, as: ImapAccountResponse.self, scoped: false).account
    }

    /// Logs in to both servers with what is stored. Answers the provider's error when one refuses.
    func testImapAccount(_ accountID: String) async throws -> (ok: Bool, error: String?) {
        let r = try await post("/api/accounts/\(accountID)/imap/test", as: ImapTestResponse.self, scoped: false)
        return (r.ok, r.error)
    }

    // Provider credentials

    func oauthCredentials() async throws -> [OAuthCredentialStatus] {
        try await get("/api/oauth", as: [OAuthCredentialStatus].self, scoped: false)
    }

    /// `PUT /api/oauth/:provider`. `clientSecret` as `.some(nil)` removes the stored secret;
    /// `overrideEnv: false` hands the provider back to the Worker secret.
    func saveOAuthCredential(provider: String, clientID: String? = nil, clientSecret: String?? = nil, overrideEnv: Bool? = nil) async throws -> OAuthCredentialStatus {
        var body: [String: Any] = [:]
        if let clientID { body["client_id"] = clientID }
        if let clientSecret { body["client_secret"] = clientSecret ?? NSNull() }
        if let overrideEnv { body["override_env"] = overrideEnv }
        return try await put("/api/oauth/\(provider)", body: body, as: OAuthCredentialStatus.self, scoped: false)
    }
}
