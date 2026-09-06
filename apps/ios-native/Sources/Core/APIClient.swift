import Foundation

// MARK: - Errors

enum APIError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case server(String, Int)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No server set. Add your heyflare address to sign in."
        case .unauthorized: return "Your session expired. Sign in again."
        case .server(let code, _): return APIError.friendly(code)
        case .transport(let m): return m
        case .decoding: return "The server sent something this app could not read."
        }
    }

    var isAuthFailure: Bool { self == .unauthorized }

    /// The worker answers with machine codes; these are the ones a person can act on.
    static func friendly(_ code: String) -> String {
        switch code {
        case "invalid_credentials": return "That email and password do not match."
        case "account_disabled": return "This account has been disabled."
        case "invalid_code": return "That code is not right."
        case "mfa_ticket_expired": return "That took too long. Sign in again."
        case "mfa_too_many_attempts": return "Too many attempts. Sign in again."
        case "no_recipients": return "Add someone to send this to."
        case "account_disconnected": return "That account is disconnected. Reconnect it in Settings."
        case "sending_not_configured": return "This domain cannot send mail yet."
        case "scheduled_send_no_attachments": return "Scheduled mail cannot carry attachments."
        case "send_failed": return "The server could not send that."
        case "invalid_email": return "That email address is not valid."
        case "password_too_short": return "Use at least 8 characters."
        case "setup_done": return "This server already has an owner."
        default: return code.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return String(f).uppercased() + dropFirst()
    }
}

// MARK: - Server configuration

/// Where this phone points, and which mailbox it is looking through.
/// Both survive relaunches; the session itself lives in the cookie store.
final class ServerConfig {
    static let shared = ServerConfig()

    private let serverKey = "hey.serverURL"
    private let scopeKey = "hey.accountId"
    private let defaults = UserDefaults.standard

    /// The unified scope, matching the web client's `X-Account-Id: all`.
    static let allAccounts = "all"

    var baseURL: URL? {
        get {
            guard let s = defaults.string(forKey: serverKey) else { return nil }
            return URL(string: s)
        }
        set {
            if let newValue { defaults.set(newValue.absoluteString, forKey: serverKey) }
            else { defaults.removeObject(forKey: serverKey) }
        }
    }

    var scope: String {
        get { defaults.string(forKey: scopeKey) ?? ServerConfig.allAccounts }
        set { defaults.set(newValue, forKey: scopeKey) }
    }

    /// Accepts what a person actually types: "mail.example.com", "https://mail.example.com/".
    /// Returns nil when there is no host to talk to.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }
}

// MARK: - Client

/// One shared client. `URLSession` owns the cookie jar, so the HttpOnly `hey_session`
/// cookie the worker sets is replayed on every later call without the app ever reading it.
actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder = JSONDecoder()

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        // Deliberately not waiting for connectivity: every screen can draw from cache, so
        // a prompt failure that leaves the last known content on screen beats a request
        // that hangs until the radio comes back.
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)
    }

    // MARK: Request building

    private func request(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil, scoped: Bool = true) throws -> URLRequest {
        guard let base = ServerConfig.shared.baseURL else { throw APIError.notConfigured }
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.transport("Bad URL")
        }
        let items = query.compactMap { key, value -> URLQueryItem? in
            guard let value, !value.isEmpty else { return nil }
            return URLQueryItem(name: key, value: value)
        }
        if !items.isEmpty { comps.queryItems = items }
        guard let url = comps.url else { throw APIError.transport("Bad URL") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if scoped { req.setValue(ServerConfig.shared.scope, forHTTPHeaderField: "X-Account-Id") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func run(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.transport(Self.describe(error))
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("No response") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                // The worker answers anonymous /api/me with 200 and a null user, so a 401
                // here really is an expired or missing session.
                if let code = Self.errorCode(data), code != "unauthorized" {
                    throw APIError.server(code, http.statusCode)
                }
                throw APIError.unauthorized
            }
            throw APIError.server(Self.errorCode(data) ?? "http_\(http.statusCode)", http.statusCode)
        }
        return data
    }

    private static func errorCode(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["error"] as? String
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "No internet connection."
        case .timedOut: return "The server took too long to answer."
        case .cannotFindHost, .cannotConnectToHost: return "Could not reach that server."
        case .secureConnectionFailed, .serverCertificateUntrusted: return "That server's certificate was refused."
        default: return error.localizedDescription
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    // MARK: Verbs

    func get<T: Decodable>(_ path: String, query: [String: String?] = [:], as type: T.Type, scoped: Bool = true) async throws -> T {
        let data = try await run(try request("GET", path, query: query, scoped: scoped))
        return try decode(T.self, from: data)
    }

    @discardableResult
    func post<T: Decodable>(_ path: String, body: [String: Any] = [:], as type: T.Type, scoped: Bool = true) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let data = try await run(try request("POST", path, body: payload, scoped: scoped))
        return try decode(T.self, from: data)
    }

    func postIgnoringResult(_ path: String, body: [String: Any] = [:], scoped: Bool = true) async throws {
        let payload = try JSONSerialization.data(withJSONObject: body)
        _ = try await run(try request("POST", path, body: payload, scoped: scoped))
    }

    @discardableResult
    func patch<T: Decodable>(_ path: String, body: [String: Any] = [:], as type: T.Type, scoped: Bool = true) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let data = try await run(try request("PATCH", path, body: payload, scoped: scoped))
        return try decode(T.self, from: data)
    }

    @discardableResult
    func put<T: Decodable>(_ path: String, body: [String: Any] = [:], as type: T.Type, scoped: Bool = true) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let data = try await run(try request("PUT", path, body: payload, scoped: scoped))
        return try decode(T.self, from: data)
    }

    func delete(_ path: String, scoped: Bool = true) async throws {
        _ = try await run(try request("DELETE", path, scoped: scoped))
    }

    /// Raw bytes, for attachments and remote images that need the session cookie.
    func data(path: String, query: [String: String?] = [:]) async throws -> Data {
        try await run(try request("GET", path, query: query))
    }

    /// Clears the cookie jar. Called on sign-out and when a server is swapped.
    func clearCookies() {
        guard let jar = session.configuration.httpCookieStorage else { return }
        jar.cookies?.forEach { jar.deleteCookie($0) }
    }
}

// MARK: - Endpoints

/// Every call the phone makes, in one place, so a worker change lands here and nowhere else.
extension APIClient {
    // Auth
    func me() async throws -> MeResponse { try await get("/api/me", as: MeResponse.self, scoped: false) }

    func login(email: String, password: String) async throws -> LoginResponse {
        try await post("/auth/login", body: ["email": email, "password": password], as: LoginResponse.self, scoped: false)
    }

    func loginTwoFactor(ticket: String, code: String) async throws -> LoginResponse {
        try await post("/auth/login/2fa", body: ["ticket": ticket, "code": code], as: LoginResponse.self, scoped: false)
    }

    func logout() async throws {
        try await postIgnoringResult("/auth/logout", scoped: false)
        clearCookies()
    }

    // Mail
    func counts() async throws -> Counts { try await get("/api/counts", as: Counts.self) }
    func imbox() async throws -> ImboxResponse { try await get("/api/imbox", as: ImboxResponse.self) }

    func threads(_ kind: ThreadListKind, page: Int = 0, query: String = "", label: String? = nil) async throws -> ThreadPage {
        try await get("/api/threads", query: [
            "bucket": kind.rawValue,
            "page": String(page),
            "q": query.isEmpty ? nil : query,
            "label": label,
        ], as: ThreadPage.self)
    }

    func feed(page: Int = 0) async throws -> ThreadPage {
        try await get("/api/feed", query: ["page": String(page)], as: ThreadPage.self)
    }

    func search(_ q: String, page: Int = 0) async throws -> ThreadPage {
        try await get("/api/search", query: ["q": q, "page": String(page)], as: ThreadPage.self)
    }

    func thread(_ id: String, peek: Bool = false) async throws -> ThreadDetail {
        try await get("/api/threads/\(id)", query: peek ? ["peek": "1"] : [:], as: ThreadDetail.self)
    }

    @discardableResult
    func act(_ id: String, _ action: ThreadAction) async throws -> ThreadDetail? {
        var body = action.payload
        body["action"] = action.name
        // `delete` answers {ok, deleted} rather than a thread, so it is not decoded as one.
        if case .delete = action {
            try await postIgnoringResult("/api/threads/\(id)/actions", body: body)
            return nil
        }
        return try await post("/api/threads/\(id)/actions", body: body, as: ThreadDetail.self)
    }

    func bulk(_ ids: [String], _ action: ThreadAction) async throws {
        var body = action.payload
        body["action"] = action.name
        body["thread_ids"] = ids
        try await postIgnoringResult("/api/threads/bulk", body: body)
    }

    // Screener
    func screener() async throws -> ScreenerResponse { try await get("/api/screener", as: ScreenerResponse.self) }

    func decide(contactID: String, decision: ScreenStatus, scope: String = "all") async throws {
        try await postIgnoringResult("/api/screener/decide", body: [
            "contact_id": contactID, "decision": decision.rawValue, "scope": scope,
        ])
    }

    // People
    func contacts(query: String = "") async throws -> [Contact] {
        try await get("/api/contacts", query: ["q": query.isEmpty ? nil : query], as: [Contact].self)
    }

    // Compose
    func send(_ payload: [String: Any]) async throws -> SendResponse {
        try await post("/api/send", body: payload, as: SendResponse.self)
    }

    func drafts() async throws -> [Draft] { try await get("/api/drafts", as: [Draft].self) }

    // Accounts
    func accounts() async throws -> [Account] { try await get("/api/accounts", as: [Account].self) }

    func sync(accountID: String) async throws {
        try await postIgnoringResult("/api/accounts/\(accountID)/sync")
    }

    // Organisation
    func labels() async throws -> [MailLabel] { try await get("/api/labels", as: [MailLabel].self) }
    func collections() async throws -> [MailCollection] { try await get("/api/collections", as: [MailCollection].self) }
    func clips() async throws -> [Clip] { try await get("/api/clips", as: [Clip].self) }

    // Power through
    func powerThrough() async throws -> PowerThroughResponse {
        try await get("/api/power-through", as: PowerThroughResponse.self)
    }

    func markSeen(_ ids: [String]) async throws {
        try await postIgnoringResult("/api/power-through/seen", body: ["thread_ids": ids])
    }


    /// Absolute URL for an attachment, carrying the scope as a query param because
    /// image and link loads cannot set headers.
    nonisolated func attachmentURL(messageID: String, attachmentID: String, accountID: String?) -> URL? {
        guard let base = ServerConfig.shared.baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("/api/messages/\(messageID)/attachments/\(attachmentID)"), resolvingAgainstBaseURL: false)
        if let accountID { comps?.queryItems = [URLQueryItem(name: "account", value: accountID)] }
        return comps?.url
    }
}

// MARK: - Thread actions

/// The `POST /api/threads/:id/actions` vocabulary, typed so a caller cannot
/// invent an action name or forget a parameter.
enum ThreadAction: Equatable {
    case markUnread
    case markRead
    case seen
    case replyLater(Bool)
    case setAside(Bool)
    case bubbleUp(Date?)
    case move(Bucket)
    case rename(String?)
    case note(String)
    case labels(add: [String], remove: [String])
    case delete

    var name: String {
        switch self {
        case .markUnread: return "mark_unread"
        case .markRead: return "mark_read"
        case .seen: return "seen"
        case .replyLater: return "reply_later"
        case .setAside: return "set_aside"
        case .bubbleUp: return "bubble_up"
        case .move: return "move"
        case .rename: return "rename"
        case .note: return "note"
        case .labels: return "labels"
        case .delete: return "delete"
        }
    }

    var payload: [String: Any] {
        switch self {
        case .replyLater(let on), .setAside(let on):
            return ["on": on]
        case .bubbleUp(let date):
            return ["at": date.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull()]
        case .move(let bucket):
            return ["bucket": bucket.rawValue]
        case .rename(let subject):
            return ["subject": subject ?? NSNull()]
        case .note(let text):
            return ["note": text]
        case .labels(let add, let remove):
            return ["add": add, "remove": remove]
        default:
            return [:]
        }
    }

    /// What the toast says once it lands.
    var confirmation: String {
        switch self {
        case .markUnread: return "Marked unread"
        case .markRead, .seen: return "Marked read"
        case .replyLater(let on): return on ? "Reply Later" : "Removed from Reply Later"
        case .setAside(let on): return on ? "Set aside" : "Removed from Set Aside"
        case .bubbleUp(let d): return d == nil ? "Bubble up cancelled" : "Bubbling up later"
        case .move(let b): return "Moved to \(b.title)"
        case .rename: return "Renamed"
        case .note: return "Note saved"
        case .labels: return "Labels updated"
        case .delete: return "Deleted"
        }
    }
}
