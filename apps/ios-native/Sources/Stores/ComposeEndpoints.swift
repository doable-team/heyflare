import Foundation

// The worker routes the composer needs that `APIClient` did not already carry, plus the
// one piece of caching the autocomplete wants.
//
// They live here rather than in `Core/APIClient.swift` for the same reason `DraftsScreen`
// declares its own `deleteDraft`: every call site is inside this feature, so the endpoint
// sits next to the screen that is the authority on how it is used.

extension APIClient {
    /// `GET /api/contacts/suggest` — the ranked autocomplete the web client uses
    /// (`AddressInput.tsx:40-41`).
    ///
    /// `/api/contacts` is a plain substring scan over one table in whatever order the rows
    /// come back. `suggest` merges two sources instead: the people actually corresponded
    /// with, newest first, and the address book with prefix matches promoted, deduplicated
    /// by address and capped at ten. Same query, an answer that puts the right person first.
    func suggestContacts(query: String) async throws -> [Address] {
        try await get("/api/contacts/suggest", query: ["q": query], as: [Address].self)
    }

    /// `POST /api/drafts` → the stored draft. Its `id` is what later saves patch, which is
    /// the difference between autosaving a draft and littering the Drafts list with copies.
    func createDraft(_ body: [String: Any]) async throws -> Draft {
        try await post("/api/drafts", body: body, as: Draft.self)
    }

    /// `PATCH /api/drafts/:id`.
    func updateDraft(_ id: String, body: [String: Any]) async throws -> Draft {
        try await patch("/api/drafts/\(id)", body: body, as: Draft.self)
    }
}

// MARK: - Autocomplete

/// A short-lived memo of what `/api/contacts/suggest` answered, and the fallback to the
/// older endpoint when it answers with nothing.
///
/// The web client caches suggestions for a minute (`useSuggest`, `staleTime: 60_000`), and
/// on a phone that matters more than on a desktop: addressing a message means typing the
/// same prefix over and over as chips are added and removed, and every repeat would
/// otherwise be a request over a mobile radio. The cache is per-process and deliberately
/// small — contacts change slowly, but not so slowly that a stale answer should outlive
/// the composing session that asked for it.
@MainActor
enum ContactSuggestions {
    private struct Entry {
        let fetched: Date
        let addresses: [Address]
    }

    private static var entries: [String: Entry] = [:]
    private static let ttl: TimeInterval = 60
    /// Past this many distinct prefixes the whole memo goes rather than being aged one key
    /// at a time: it is a typing-session cache, and a session that long is already over.
    private static let capacity = 40

    static func lookup(_ raw: String) async -> [Address] {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        if let hit = entries[key], Date().timeIntervalSince(hit.fetched) < ttl {
            return hit.addresses
        }

        var found = (try? await APIClient.shared.suggestContacts(query: key)) ?? []
        if found.isEmpty {
            // A worker that predates `suggest`, or a genuinely empty answer: either way the
            // old endpoint is asked once before the field decides there is nobody to offer.
            found = ((try? await APIClient.shared.contacts(query: key)) ?? []).map(\.address)
        }

        if entries.count >= capacity { entries.removeAll() }
        entries[key] = Entry(fetched: Date(), addresses: found)
        return found
    }
}
