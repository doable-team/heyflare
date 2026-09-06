import Foundation

// The calendar's remaining half: what a day is called and what it looks like, the
// things that have to happen this week but at no particular hour, and the stopwatch.
// Ported from `WeekTasks.tsx`, the day header and the time-tracking hooks in `api.ts`.

// MARK: - Shapes

/// A "sometime this week" item. Anything unticked rolls into the next week rather than
/// being lost, which is what makes the list a standing promise.
struct FlexTask: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var weekStart: String
    var title: String
    var done: Bool
    var position: Int

    enum CodingKeys: String, CodingKey {
        case id, title, done, position
        case weekStart = "week_start"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        weekStart = (try? c.decode(String.self, forKey: .weekStart)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        position = (try? c.decode(Int.self, forKey: .position)) ?? 0
    }
}

struct TimeEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var eventID: String?
    var startedAt: Double
    var endedAt: Double?

    var start: Date { Date(timeIntervalSince1970: startedAt / 1000) }
    var end: Date? { endedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var isRunning: Bool { endedAt == nil }

    /// Seconds so far, live for a running entry.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case eventID = "event_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        eventID = try? c.decodeIfPresent(String.self, forKey: .eventID)
        startedAt = (try? c.decode(Double.self, forKey: .startedAt)) ?? 0
        endedAt = try? c.decodeIfPresent(Double.self, forKey: .endedAt)
    }
}

/// A stored day photo, `GET /api/calendar/covers`.
struct DayCover: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var url: String
    var name: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
    }
}

/// What `POST /api/calendar/events/from-thread` hands back: a prefilled event, not yet
/// saved, with the thread's people as guests.
struct EventDraft: Hashable, Identifiable, Sendable {
    var id: String { threadID }
    var title: String
    var description: String
    var attendees: [Address]
    var threadID: String
    var startsAt: Double
    var endsAt: Double

    /// The day the draft starts on, as a `yyyy-MM-dd` key in the calendar's own zone.
    var dayKey: String { CalDate.key(Date(timeIntervalSince1970: startsAt / 1000)) }
    var startMinutes: Int { CalDate.minutesOfDay(startsAt) }
    var endMinutes: Int { CalDate.minutesOfDay(endsAt) }
}

private struct EventDraftPayload: Decodable {
    var title: String
    var description: String
    var attendees: [Address]
    var threadID: String
    var startsAt: Double
    var endsAt: Double

    enum CodingKeys: String, CodingKey {
        case title, description, attendees
        case threadID = "thread_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        attendees = (try? c.decode([Address].self, forKey: .attendees)) ?? []
        threadID = (try? c.decode(String.self, forKey: .threadID)) ?? ""
        startsAt = (try? c.decode(Double.self, forKey: .startsAt)) ?? Date().timeIntervalSince1970 * 1000
        endsAt = (try? c.decode(Double.self, forKey: .endsAt)) ?? startsAt + 3_600_000
    }
}

private struct RollResult: Decodable {
    var tasks: [FlexTask]
    var moved: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = (try? c.decode([FlexTask].self, forKey: .tasks)) ?? []
        moved = (try? c.decode(Int.self, forKey: .moved)) ?? 0
    }

    enum CodingKeys: String, CodingKey { case tasks, moved }
}

// MARK: - Calls

extension CalendarAPI {
    // Days

    /// `PUT /api/calendar/days/:date`. Absent fields are left alone; an empty `coverURL`
    /// or a nil `coverID` takes the photo off.
    static func updateDay(_ date: String, label: String? = nil, coverID: String?? = nil, coverURL: String? = nil) async throws -> CalDay {
        var body: [String: Any] = [:]
        if let label { body["label"] = label }
        if let coverID { body["cover_id"] = coverID ?? NSNull() }
        if let coverURL { body["cover_url"] = coverURL }
        return try await send("PUT", "/api/calendar/days/\(date)", body: body, as: CalDay.self)
    }

    /// Raw image bytes up, one stored cover back. The caller downscales first.
    static func uploadCover(_ data: Data, mime: String, width: Int, height: Int, name: String) async throws -> DayCover {
        guard let base = ServerConfig.shared.baseURL else { throw APIError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent("/api/calendar/covers"))
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(String(width), forHTTPHeaderField: "X-Image-Width")
        req.setValue(String(height), forHTTPHeaderField: "X-Image-Height")
        req.setValue(name, forHTTPHeaderField: "X-Image-Name")
        return try decode(DayCover.self, from: try await run(req))
    }

    // Events from mail

    static func eventDraft(threadID: String) async throws -> EventDraft {
        let p = try await send("POST", "/api/calendar/events/from-thread", body: ["thread_id": threadID], as: EventDraftPayload.self)
        return EventDraft(title: p.title, description: p.description, attendees: p.attendees, threadID: p.threadID, startsAt: p.startsAt, endsAt: p.endsAt)
    }

    // Sometime this week

    static func flexTasks(week: String) async throws -> [FlexTask] {
        try await send("GET", "/api/calendar/flex-tasks", query: ["week": week], as: [FlexTask].self)
    }

    static func createFlexTask(title: String, week: String) async throws -> FlexTask {
        try await send("POST", "/api/calendar/flex-tasks", body: ["title": title, "week_start": week], as: FlexTask.self)
    }

    static func updateFlexTask(id: String, title: String? = nil, done: Bool? = nil) async throws -> FlexTask {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let done { body["done"] = done }
        return try await send("PATCH", "/api/calendar/flex-tasks/\(id)", body: body, as: FlexTask.self)
    }

    static func deleteFlexTask(id: String) async throws {
        struct Ok: Decodable {}
        _ = try await send("DELETE", "/api/calendar/flex-tasks/\(id)", as: Ok.self)
    }

    /// Pulls every unfinished task from earlier weeks into `week`. Answers the week's list
    /// and how many moved.
    static func rollFlexTasks(into week: String) async throws -> (tasks: [FlexTask], moved: Int) {
        let r = try await send("POST", "/api/calendar/flex-tasks/roll", body: ["week": week], as: RollResult.self)
        return (r.tasks, r.moved)
    }

    // Time

    static func timeEntries(from: String, to: String) async throws -> [TimeEntry] {
        try await send("GET", "/api/calendar/time", query: ["from": from, "to": to], as: [TimeEntry].self)
    }

    /// Starting one stops whatever was running: the worker keeps a single stopwatch.
    static func startTimer(title: String, eventID: String? = nil) async throws -> TimeEntry {
        var body: [String: Any] = ["title": title]
        if let eventID { body["event_id"] = eventID }
        return try await send("POST", "/api/calendar/time", body: body, as: TimeEntry.self)
    }

    static func stopTimer(id: String) async throws -> TimeEntry {
        try await send("POST", "/api/calendar/time/\(id)/stop", body: [:], as: TimeEntry.self)
    }

    static func updateTimeEntry(id: String, title: String) async throws -> TimeEntry {
        try await send("PATCH", "/api/calendar/time/\(id)", body: ["title": title], as: TimeEntry.self)
    }

    static func deleteTimeEntry(id: String) async throws {
        struct Ok: Decodable {}
        _ = try await send("DELETE", "/api/calendar/time/\(id)", as: Ok.self)
    }
}
