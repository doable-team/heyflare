import Foundation

// The calendar's own wire types and its own transport.
//
// Two things forced this out of `Sources/Core`:
//
// 1. `Models.CalEvent` decodes what a month grid draws and no more — no RRULE, no attendees,
//    no reminders, no `series`. There is no `GET /api/calendar/events/:id`, so the only place
//    those fields ever arrive is the range payload, which means an editor cannot exist unless
//    the range is decoded into something richer. `CalEventFull` below is that superset.
// 2. `APIClient.patch` and `.delete` take no query string, and `?scope=this|following|all` is
//    the entire contract for editing one occurrence of a repeating event.
//
// Both would rather be fixed in `Core`; this file is the version of the fix that stays inside
// the calendar. The session cookie is `HTTPCookieStorage.shared`, which is the same jar
// `APIClient` writes to at sign-in, so nothing here has to know about auth.

// MARK: - Wire types

/// Who answered an invitation. `""` is "this event has no invitations at all".
enum CalRsvp: String, Codable, Sendable, CaseIterable {
    case none = ""
    case needsAction
    case accepted
    case declined
    case tentative

    /// The web client's wording, kept verbatim so the two clients say the same thing.
    var title: String {
        switch self {
        case .accepted: return "Yes"
        case .declined: return "No"
        case .tentative: return "Maybe"
        case .needsAction: return "No reply"
        case .none: return ""
        }
    }
}

struct CalAttendee: Codable, Hashable, Sendable {
    var email: String
    var name: String
    var rsvp: CalRsvp
    var optional: Bool
    var organizer: Bool

    enum CodingKeys: String, CodingKey { case email, name, rsvp, optional, organizer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        rsvp = (try? c.decode(CalRsvp.self, forKey: .rsvp)) ?? .none
        optional = (try? c.decode(Bool.self, forKey: .optional)) ?? false
        organizer = (try? c.decode(Bool.self, forKey: .organizer)) ?? false
    }
}

struct CalReminder: Codable, Hashable, Sendable, Identifiable {
    /// How long before the start it fires. Its own identity, so a list of them can be edited
    /// without two ten-minute reminders collapsing into one row.
    let id = UUID()
    var minutes: Int

    enum CodingKeys: String, CodingKey { case minutes }

    init(minutes: Int) { self.minutes = minutes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minutes = (try? c.decode(Int.self, forKey: .minutes)) ?? 0
    }

    /// Identity is per-row, but equality is the value: without this, re-reading the same event
    /// would produce fresh `id`s and make an unchanged event compare as changed.
    static func == (a: CalReminder, b: CalReminder) -> Bool { a.minutes == b.minutes }
    func hash(into hasher: inout Hasher) { hasher.combine(minutes) }
}

/// One occurrence, with every field the editor needs. Decoding stays forgiving in the same way
/// `Models.swift` is: the worker grows fields faster than the app ships.
struct CalEventFull: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var eventID: String
    /// Set when `id` addresses one occurrence of a master (`<row>@<YYYY-MM-DD>`).
    var occurrenceDate: String?
    var calendarID: String
    var calendarName: String
    /// The calendar's colour, the one place colour enters the UI; empty means the default fill.
    var calendarColor: String
    var source: String
    var writable: Bool
    var kind: String
    var title: String
    var description: String
    var location: String
    var emoji: String
    var allDay: Bool
    var startsAt: Double
    var endsAt: Double
    var startDate: String?
    var endDate: String?
    var timezone: String
    var rrule: String?
    var recurring: Bool
    /// A repeating event Google already expanded into one row per occurrence. It repeats, but
    /// carries no RRULE to narrow an edit down with — so a delete can reach the whole series
    /// while a save only ever means this one occurrence. Mirrors `CalEvent.series` in
    /// `src/shared/types.ts`, and `EventEditor` is the only thing that reads it.
    var series: Bool
    var status: String
    var busy: Bool
    var countdown: Bool
    var circled: Bool
    var attendees: [CalAttendee]
    var rsvp: CalRsvp
    var conferenceURL: String
    var url: String
    var reminders: [CalReminder]
    var threadID: String?
    var done: Bool
    var createdAt: Double
    var updatedAt: Double

    var start: Date { Date(timeIntervalSince1970: startsAt / 1000) }
    var end: Date { Date(timeIntervalSince1970: endsAt / 1000) }
    var isCancelled: Bool { status == "cancelled" }
    var isTentative: Bool { status == "tentative" }
    var isTodo: Bool { kind == "todo" }
    var isDeclined: Bool { rsvp == .declined }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, description, location, emoji, status, recurring, done, writable
        case source, timezone, rrule, series, busy, countdown, circled, attendees, rsvp, url, reminders
        case eventID = "event_id"
        case occurrenceDate = "occurrence_date"
        case calendarID = "calendar_id"
        case calendarName = "calendar_name"
        case calendarColor = "calendar_color"
        case allDay = "all_day"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case startDate = "start_date"
        case endDate = "end_date"
        case conferenceURL = "conference_url"
        case threadID = "thread_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventID = (try? c.decode(String.self, forKey: .eventID)) ?? id
        occurrenceDate = try? c.decodeIfPresent(String.self, forKey: .occurrenceDate)
        calendarID = (try? c.decode(String.self, forKey: .calendarID)) ?? ""
        calendarName = (try? c.decode(String.self, forKey: .calendarName)) ?? ""
        calendarColor = (try? c.decode(String.self, forKey: .calendarColor)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? "local"
        writable = (try? c.decode(Bool.self, forKey: .writable)) ?? false
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "event"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        location = (try? c.decode(String.self, forKey: .location)) ?? ""
        emoji = (try? c.decode(String.self, forKey: .emoji)) ?? ""
        allDay = (try? c.decode(Bool.self, forKey: .allDay)) ?? false
        startsAt = (try? c.decode(Double.self, forKey: .startsAt)) ?? 0
        endsAt = (try? c.decode(Double.self, forKey: .endsAt)) ?? 0
        startDate = try? c.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try? c.decodeIfPresent(String.self, forKey: .endDate)
        timezone = (try? c.decode(String.self, forKey: .timezone)) ?? ""
        rrule = try? c.decodeIfPresent(String.self, forKey: .rrule)
        recurring = (try? c.decode(Bool.self, forKey: .recurring)) ?? false
        series = (try? c.decode(Bool.self, forKey: .series)) ?? false
        status = (try? c.decode(String.self, forKey: .status)) ?? "confirmed"
        busy = (try? c.decode(Bool.self, forKey: .busy)) ?? true
        countdown = (try? c.decode(Bool.self, forKey: .countdown)) ?? false
        circled = (try? c.decode(Bool.self, forKey: .circled)) ?? false
        attendees = (try? c.decode([CalAttendee].self, forKey: .attendees)) ?? []
        rsvp = (try? c.decode(CalRsvp.self, forKey: .rsvp)) ?? .none
        conferenceURL = (try? c.decode(String.self, forKey: .conferenceURL)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        reminders = (try? c.decode([CalReminder].self, forKey: .reminders)) ?? []
        threadID = try? c.decodeIfPresent(String.self, forKey: .threadID)
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? 0
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

/// A habit and its ticks over the requested window.
///
/// Named `CalHabit` rather than `Habit` deliberately: the shared model this was supposed to
/// extend does not exist in `Sources/Core/Models.swift`, and a bare `Habit` here would collide
/// with it the moment somebody adds it there.
struct CalHabit: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var icon: String
    /// The owner's chosen colour, decoded and then deliberately never drawn — see `HabitsScreen`.
    var color: String
    /// Weekdays the habit is expected on, `0 = Sunday`, matching `Date`'s weekday index minus one.
    var days: [Int]
    var position: Int
    var archived: Bool
    /// `YYYY-MM-DD` values inside the requested window.
    var completions: [String]
    var streak: Int

    /// An empty list means every day, which is how the web reads it too.
    var expectedDays: [Int] { days.isEmpty ? [0, 1, 2, 3, 4, 5, 6] : days }

    enum CodingKeys: String, CodingKey { case id, name, icon, color, days, position, archived, completions, streak }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        icon = (try? c.decode(String.self, forKey: .icon)) ?? ""
        color = (try? c.decode(String.self, forKey: .color)) ?? ""
        days = (try? c.decode([Int].self, forKey: .days)) ?? []
        position = (try? c.decode(Int.self, forKey: .position)) ?? 0
        archived = (try? c.decode(Bool.self, forKey: .archived)) ?? false
        completions = (try? c.decode([String].self, forKey: .completions)) ?? []
        streak = (try? c.decode(Int.self, forKey: .streak)) ?? 0
    }
}

/// A day's own row: its label, and whether anything was written in the journal that day.
/// Cover art is deliberately not read — day photos are out of scope for this client.
struct CalDay: Codable, Hashable, Sendable {
    var date: String
    var label: String
    var hasJournal: Bool
    /// Present on the journal index and on `GET /journal/:date`; nil in a range payload.
    var excerpt: String?
    var journalHTML: String?
    /// The day's photo, if one was set: a stored cover's URL or an external one.
    var coverURL: String
    var coverID: String?
    /// A CSS object-position such as "50% 30%"; the phone honours the vertical half.
    var coverPosition: String

    /// The photo as something `CachedImage` can load: stored covers are relative paths.
    var coverImageURL: URL? {
        guard !coverURL.isEmpty else { return nil }
        if coverURL.hasPrefix("/") { return ServerConfig.shared.baseURL?.appendingPathComponent(coverURL) }
        return URL(string: coverURL)
    }

    enum CodingKeys: String, CodingKey {
        case date, label, excerpt
        case hasJournal = "has_journal"
        case journalHTML = "journal_html"
        case coverURL = "cover_url"
        case coverID = "cover_id"
        case coverPosition = "cover_position"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decode(String.self, forKey: .date)) ?? ""
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        hasJournal = (try? c.decode(Bool.self, forKey: .hasJournal)) ?? false
        excerpt = try? c.decodeIfPresent(String.self, forKey: .excerpt)
        journalHTML = try? c.decodeIfPresent(String.self, forKey: .journalHTML)
        coverURL = (try? c.decode(String.self, forKey: .coverURL)) ?? ""
        coverID = try? c.decodeIfPresent(String.self, forKey: .coverID)
        coverPosition = (try? c.decode(String.self, forKey: .coverPosition)) ?? ""
    }
}

/// One writable (or at least visible) calendar, for the editor's picker.
struct CalSource: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var accountID: String?
    var accountEmail: String?
    var name: String
    var source: String   // local | google | ics
    var url: String?
    var color: String
    var visible: Bool
    var writable: Bool
    var isDefault: Bool
    var lastSyncedAt: Double?
    var syncError: String?
    var eventCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, source, url, color, visible, writable
        case accountID = "account_id"
        case accountEmail = "account_email"
        case isDefault = "is_default"
        case lastSyncedAt = "last_synced_at"
        case syncError = "sync_error"
        case eventCount = "event_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try? c.decode(String.self, forKey: .accountID)
        accountEmail = try? c.decode(String.self, forKey: .accountEmail)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? "local"
        url = try? c.decode(String.self, forKey: .url)
        color = (try? c.decode(String.self, forKey: .color)) ?? "#111111"
        visible = (try? c.decode(Bool.self, forKey: .visible)) ?? true
        writable = (try? c.decode(Bool.self, forKey: .writable)) ?? false
        isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        lastSyncedAt = try? c.decode(Double.self, forKey: .lastSyncedAt)
        syncError = try? c.decode(String.self, forKey: .syncError)
        eventCount = try? c.decode(Int.self, forKey: .eventCount)
    }
}

/// One Google account, as the settings page groups calendars by it (`google_accounts` in
/// `GET /api/calendar/sources`).
struct CalGoogleAccount: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var email: String
    var calendar: Bool
    var mail: Bool
    var calendarCount: Int
    var syncError: String?
    var calendarError: String?

    enum CodingKeys: String, CodingKey {
        case id, email, calendar, mail
        case calendarCount = "calendar_count"
        case syncError = "sync_error"
        case calendarError = "calendar_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        calendar = (try? c.decode(Bool.self, forKey: .calendar)) ?? false
        mail = (try? c.decode(Bool.self, forKey: .mail)) ?? false
        calendarCount = (try? c.decode(Int.self, forKey: .calendarCount)) ?? 0
        syncError = try? c.decode(String.self, forKey: .syncError)
        calendarError = try? c.decode(String.self, forKey: .calendarError)
    }
}

/// The owner's calendar preferences, set in the browser and until now ignored on the phone.
///
/// There is no editor for these anywhere in this app and there should not be: they are desk
/// work. This client only reads them and obeys.
struct CalPrefs: Codable, Hashable, Sendable {
    var timezone: String
    /// `0 = Sunday`. `Calendar.firstWeekday` is 1-based, so it is `weekStart + 1` there.
    var weekStart: Int
    var nightStart: Int
    var nightEnd: Int
    var collapseNight: Bool
    /// `"12"` or `"24"`.
    var timeFormat: String
    var showDeclined: Bool
    /// `days | week | year` — which of `CalendarPage`'s three tabs opens by default.
    var defaultView: String

    /// What the app assumes before `/settings` has answered: the device's own conventions.
    /// `weekStart` of -1 means "not yet known", which is how `calendar` tells the difference
    /// between an owner who chose Sunday and an owner whose preferences have not landed.
    static let deviceDefaults = CalPrefs(
        timezone: TimeZone.current.identifier,
        weekStart: -1,
        nightStart: 22,
        nightEnd: 6,
        collapseNight: true,
        timeFormat: "",
        showDeclined: false
    )

    init(timezone: String, weekStart: Int, nightStart: Int, nightEnd: Int, collapseNight: Bool, timeFormat: String, showDeclined: Bool, defaultView: String = "week") {
        self.timezone = timezone
        self.weekStart = weekStart
        self.nightStart = nightStart
        self.nightEnd = nightEnd
        self.collapseNight = collapseNight
        self.timeFormat = timeFormat
        self.showDeclined = showDeclined
        self.defaultView = defaultView
    }

    enum CodingKeys: String, CodingKey {
        case timezone
        case weekStart = "week_start"
        case nightStart = "night_start"
        case nightEnd = "night_end"
        case collapseNight = "collapse_night"
        case timeFormat = "time_format"
        case showDeclined = "show_declined"
        case defaultView = "default_view"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timezone = (try? c.decode(String.self, forKey: .timezone)) ?? TimeZone.current.identifier
        // A server that has never been told wins over the device only when it names a real day.
        weekStart = (try? c.decode(Int.self, forKey: .weekStart)) ?? -1
        nightStart = (try? c.decode(Int.self, forKey: .nightStart)) ?? 22
        nightEnd = (try? c.decode(Int.self, forKey: .nightEnd)) ?? 6
        collapseNight = (try? c.decode(Bool.self, forKey: .collapseNight)) ?? true
        timeFormat = (try? c.decode(String.self, forKey: .timeFormat)) ?? ""
        showDeclined = (try? c.decode(Bool.self, forKey: .showDeclined)) ?? false
        defaultView = (try? c.decode(String.self, forKey: .defaultView)) ?? "week"
    }
}

/// The range payload, as much of it as this client draws.
struct CalRange: Codable, Sendable {
    var events: [CalEventFull]
    var habits: [CalHabit]
    var days: [CalDay]

    enum CodingKeys: String, CodingKey { case events, habits, days }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = (try? c.decode([CalEventFull].self, forKey: .events)) ?? []
        habits = (try? c.decode([CalHabit].self, forKey: .habits)) ?? []
        days = (try? c.decode([CalDay].self, forKey: .days)) ?? []
    }
}

private struct CalSourcesResponse: Decodable {
    var calendars: [CalSource]
    var googleAccounts: [CalGoogleAccount]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calendars = (try? c.decode([CalSource].self, forKey: .calendars)) ?? []
        googleAccounts = (try? c.decode([CalGoogleAccount].self, forKey: .googleAccounts)) ?? []
    }

    enum CodingKeys: String, CodingKey { case calendars; case googleAccounts = "google_accounts" }
}

// MARK: - How far a write reaches

/// The answer to "this event / this and following / all events", as the worker spells it.
enum EventScope: String, Sendable, CaseIterable {
    case this, following, all

    /// `EventSheet.tsx:978-1009`, word for word — the two clients must not describe the same
    /// three buttons differently.
    var title: String {
        switch self {
        case .this: return "This event"
        case .following: return "This and following events"
        case .all: return "All events"
        }
    }
}

// MARK: - What a write sends

/// The body of a create or a patch.
///
/// Every field is optional and only the ones that are set are sent, because the worker's
/// `readEventInput` leaves absent fields alone. That is load-bearing: this editor does not show
/// guests, and omitting `attendees` is the only way to save a title change without silently
/// uninviting everybody.
struct EventInput {
    var calendarID: String?
    var title: String?
    var description: String?
    var location: String?
    var emoji: String?
    var allDay: Bool?
    var startsAt: Double?
    var endsAt: Double?
    /// `.some(nil)` clears the field; `nil` leaves it alone. Timed events must clear both.
    var startDate: String??
    var endDate: String??
    var timezone: String?
    var rrule: String??
    var conferenceURL: String?
    var url: String?
    var reminders: [Int]?
    /// `{email, name}` rows. Sent only by a draft made from mail.
    var attendees: [[String: Any]]?

    var payload: [String: Any] {
        var body: [String: Any] = [:]
        if let attendees { body["attendees"] = attendees }
        if let calendarID { body["calendar_id"] = calendarID }
        if let title { body["title"] = title }
        if let description { body["description"] = description }
        if let location { body["location"] = location }
        if let emoji { body["emoji"] = emoji }
        if let allDay { body["all_day"] = allDay }
        if let startsAt { body["starts_at"] = startsAt }
        if let endsAt { body["ends_at"] = endsAt }
        if let startDate { body["start_date"] = startDate ?? NSNull() }
        if let endDate { body["end_date"] = endDate ?? NSNull() }
        if let timezone { body["timezone"] = timezone }
        if let rrule { body["rrule"] = rrule ?? NSNull() }
        if let conferenceURL { body["conference_url"] = conferenceURL }
        if let url { body["url"] = url }
        if let reminders { body["reminders"] = reminders.map { ["minutes": $0] } }
        return body
    }
}

// MARK: - Transport

enum CalendarAPI {
    /// A session of its own, pointed at the cookie jar `APIClient` fills at sign-in. Nothing
    /// here reads the cookie; `URLSession` replays it because the storage is shared.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private static let decoder = JSONDecoder()

    /// Calendar routes are owner-wide, so no `X-Account-Id` goes out: which mailbox the app is
    /// scoped to has nothing to do with whose calendar this is.
    private static func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) throws -> URLRequest {
        guard let base = ServerConfig.shared.baseURL else { throw APIError.notConfigured }
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.transport("Bad URL")
        }
        if !query.isEmpty {
            comps.queryItems = query.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError.transport("Bad URL") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// The same status handling `APIClient.run` does, including the machine-code vocabulary, so
    /// a calendar failure reads like every other failure in the app.
    static func run(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.transport(error.localizedDescription)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("No response") }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = (object ?? nil)?["error"] as? String
            if http.statusCode == 401 || http.statusCode == 403, code == nil || code == "unauthorized" {
                throw APIError.unauthorized
            }
            throw APIError.server(code ?? "http_\(http.statusCode)", http.statusCode)
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    static func send<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil, as type: T.Type) async throws -> T {
        try decode(T.self, from: try await run(try request(method, path, query: query, body: body)))
    }

    // MARK: Reading

    static func range(from: String, to: String) async throws -> CalRange {
        try await send("GET", "/api/calendar/events", query: ["from": from, "to": to], as: CalRange.self)
    }

    static func settings() async throws -> CalPrefs {
        try await send("GET", "/api/calendar/settings", as: CalPrefs.self)
    }

    /// The calendar picker's list. `/sources` also carries account plumbing this app has no
    /// screen for; only the calendars are read.
    static func sources() async throws -> [CalSource] {
        try await send("GET", "/api/calendar/sources", as: CalSourcesResponse.self).calendars
    }

    /// The Mac's Settings screen edits this list, so it reads the account grouping the phone
    /// does not.
    static func sourcesFull() async throws -> (calendars: [CalSource], accounts: [CalGoogleAccount]) {
        let r = try await send("GET", "/api/calendar/sources", as: CalSourcesResponse.self)
        return (r.calendars, r.googleAccounts)
    }

    /// Pull first, then re-read: without this a refresh only re-fetches whatever the last cron
    /// run left behind.
    static func syncSources() async throws {
        _ = try await run(try request("POST", "/api/calendar/sources/sync", body: [:]))
    }

    /// A `nil` field is left as it was; only what is passed changes.
    @discardableResult
    static func updateSource(id: String, name: String? = nil, color: String? = nil, visible: Bool? = nil, isDefault: Bool? = nil) async throws -> CalSource {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let color { body["color"] = color }
        if let visible { body["visible"] = visible }
        if let isDefault { body["is_default"] = isDefault }
        return try await send("PATCH", "/api/calendar/sources/\(id)", body: body, as: CalSource.self)
    }

    /// The settings page's "Remove": for a Google calendar, gone for good rather than back on
    /// the next sync (the worker tombstones it).
    static func removeSource(id: String) async throws {
        _ = try await run(try request("DELETE", "/api/calendar/sources/\(id)"))
    }

    static func createSource(name: String, color: String) async throws -> CalSource {
        try await send("POST", "/api/calendar/sources", body: ["name": name, "color": color], as: CalSource.self)
    }

    private struct SyncOneResponse: Decodable { var ok: Bool; var changed: Int; var error: String? }

    static func syncSource(id: String) async throws -> (changed: Int, error: String?) {
        let r = try await send("POST", "/api/calendar/sources/\(id)/sync", body: [:], as: SyncOneResponse.self)
        return (r.changed, r.error)
    }

    /// The web's `Section title="Calendar preferences"` — desk work on the phone, but the Mac is
    /// a desk, so this is the one client besides the browser that lets someone change it.
    static func applySettings(_ patch: [String: Any]) async throws -> CalPrefs {
        try await send("PUT", "/api/calendar/settings", body: patch, as: CalPrefs.self)
    }

    // MARK: Events

    static func createEvent(_ input: EventInput) async throws -> CalEventFull {
        try await send("POST", "/api/calendar/events", body: input.payload, as: CalEventFull.self)
    }

    /// `scope` is omitted for a one-off; the worker then defaults to "all" for a master and
    /// "this" for an addressed occurrence, which is the behaviour the web relies on too.
    static func updateEvent(id: String, scope: EventScope?, input: EventInput) async throws -> CalEventFull {
        try await send("PATCH", "/api/calendar/events/\(id)",
                       query: scope.map { ["scope": $0.rawValue] } ?? [:],
                       body: input.payload,
                       as: CalEventFull.self)
    }

    static func deleteEvent(id: String, scope: EventScope?) async throws {
        _ = try await run(try request("DELETE", "/api/calendar/events/\(id)", query: scope.map { ["scope": $0.rawValue] } ?? [:]))
    }

    static func duplicateEvent(id: String) async throws -> CalEventFull {
        try await send("POST", "/api/calendar/events/\(id)/duplicate", body: [:], as: CalEventFull.self)
    }

    static func rsvp(id: String, _ answer: CalRsvp) async throws -> CalEventFull {
        try await send("POST", "/api/calendar/events/\(id)/rsvp", body: ["rsvp": answer.rawValue], as: CalEventFull.self)
    }

    /// `date` names which occurrence of a repeating todo is being ticked; a one-off sends none.
    static func setDone(id: String, done: Bool, date: String?) async throws -> CalEventFull {
        var body: [String: Any] = ["done": done]
        if let date, !date.isEmpty { body["date"] = date }
        return try await send("POST", "/api/calendar/events/\(id)/done", body: body, as: CalEventFull.self)
    }

    /// The event as an `.ics`, written to a temp file so it can be handed to a share sheet.
    /// It is fetched rather than linked because the download needs the session cookie, which a
    /// plain `UIApplication.open` would not carry.
    static func exportICS(id: String, title: String) async throws -> URL {
        let data = try await run(try request("GET", "/api/calendar/events/\(id).ics"))
        let safe = title.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        let name = (safe.isEmpty ? "event" : String(safe.prefix(60))) + ".ics"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Habits

    static func habits(from: String, to: String) async throws -> [CalHabit] {
        try await send("GET", "/api/calendar/habits", query: ["from": from, "to": to], as: [CalHabit].self)
    }

    static func createHabit(name: String, icon: String, days: [Int], color: String = "#111111") async throws -> CalHabit {
        // A colour is required by the worker (`HEX` is validated); the phone never draws one
        // and sends a neutral value, the Mac sends the shade the person picked.
        try await send("POST", "/api/calendar/habits",
                       body: ["name": name, "icon": icon, "color": color, "days": days],
                       as: CalHabit.self)
    }

    static func updateHabit(id: String, name: String? = nil, icon: String? = nil, days: [Int]? = nil, color: String? = nil) async throws -> CalHabit {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let icon { body["icon"] = icon }
        if let days { body["days"] = days }
        if let color { body["color"] = color }
        return try await send("PATCH", "/api/calendar/habits/\(id)", body: body, as: CalHabit.self)
    }

    static func deleteHabit(id: String) async throws {
        _ = try await run(try request("DELETE", "/api/calendar/habits/\(id)"))
    }

    /// Returns the habit with its streak already recomputed, so the row can just be swapped in.
    /// `from`/`to` name the window whose ticks come back — the grid's own twelve weeks.
    static func toggleHabit(id: String, date: String, from: String, to: String) async throws -> CalHabit {
        try await send("POST", "/api/calendar/habits/\(id)/toggle",
                       query: ["from": from, "to": to],
                       body: ["date": date],
                       as: CalHabit.self)
    }

    // MARK: Journal

    static func journalIndex() async throws -> [CalDay] {
        try await send("GET", "/api/calendar/journal", as: [CalDay].self)
    }

    static func journal(date: String) async throws -> CalDay {
        try await send("GET", "/api/calendar/journal/\(date)", as: CalDay.self)
    }

    static func saveJournal(date: String, html: String) async throws -> CalDay {
        try await send("PUT", "/api/calendar/journal/\(date)", body: ["journal_html": html], as: CalDay.self)
    }
}

// MARK: - Change notice

/// One counter every calendar screen watches.
///
/// The month grid, the day screen and the editor each hold their own `CalendarStore`, because a
/// pushed screen cannot reach the one the tab root made. Without a shared signal, deleting an
/// event on the day screen would leave the month behind it still drawing that event until the
/// next cold load. A bumped revision is enough: each screen decides for itself what to refetch.
@MainActor
@Observable
final class CalendarBus {
    static let shared = CalendarBus()

    private(set) var revision = 0

    func changed() { revision &+= 1 }
}
