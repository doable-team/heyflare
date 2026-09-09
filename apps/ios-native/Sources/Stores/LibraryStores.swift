import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// `GET /api/contacts/:id` — the person, merged across every account in scope, plus every
/// thread they appear in. Declared here because Contacts is the only screen that asks for it.
struct ContactDetailResponse: Codable, Sendable {
    var contact: Contact
    var threads: [ThreadSummary]

    enum CodingKeys: String, CodingKey { case contact, threads }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contact = try c.decode(Contact.self, forKey: .contact)
        threads = (try? c.decode([ThreadSummary].self, forKey: .threads)) ?? []
    }
}

/// `GET /api/labels/:id/threads` — every thread carrying one label.
struct LabelThreadsResponse: Codable, Sendable {
    var threads: [ThreadSummary]

    enum CodingKeys: String, CodingKey { case threads }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = (try? c.decode([ThreadSummary].self, forKey: .threads)) ?? []
    }
}

/// `GET /api/collections/:id` — the pile itself, the threads in it, and every attachment
/// hanging off those threads. Declared here because Collections is the only screen that
/// opens one.
struct CollectionDetailResponse: Codable, Sendable {
    var collection: MailCollection
    var threads: [ThreadSummary]
    var files: [Attachment]

    enum CodingKeys: String, CodingKey { case collection, threads, files }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode(MailCollection.self, forKey: .collection)
        threads = (try? c.decode([ThreadSummary].self, forKey: .threads)) ?? []
        files = (try? c.decode([Attachment].self, forKey: .files)) ?? []
    }
}

extension APIClient {
    func contact(_ id: String) async throws -> ContactDetailResponse {
        try await get("/api/contacts/\(id)", as: ContactDetailResponse.self)
    }

    /// `PATCH /api/contacts/:id` — answers with the *merged* contact rather than the row
    /// that was written, so a caller draws the state that settled and not the one it asked
    /// for. `scope` defaults to "all", which is what "this person" means once more than one
    /// mailbox has heard from them; "account" narrows the change to the mailbox in hand.
    @discardableResult
    func updateContact(_ id: String,
                       name: String? = nil,
                       notes: String? = nil,
                       screenStatus: ScreenStatus? = nil,
                       bundled: Bool? = nil,
                       scope: String = "all") async throws -> Contact {
        var body: [String: Any] = ["scope": scope]
        if let name { body["name"] = name }
        if let notes { body["notes"] = notes }
        if let screenStatus { body["screen_status"] = screenStatus.rawValue }
        if let bundled { body["bundled"] = bundled }
        return try await patch("/api/contacts/\(id)", body: body, as: Contact.self)
    }

    func labelThreads(_ id: String) async throws -> LabelThreadsResponse {
        try await get("/api/labels/\(id)/threads", as: LabelThreadsResponse.self)
    }

    func collection(_ id: String) async throws -> CollectionDetailResponse {
        try await get("/api/collections/\(id)", as: CollectionDetailResponse.self)
    }
}

@MainActor
@Observable
final class ContactsStore {
    var query = ""
    var contacts: [Contact] = []
    var loading = false
    var error: String?
    /// True once the first answer (or failure) has landed. The web has no cache, so it
    /// always shows the skeleton on first load; the Mac page keys its skeleton on this
    /// rather than on the list being empty, which the cached seed below makes it not.
    var fresh = false
    /// The query `contacts` answers. The web keys its cache on the query, so a fresh search
    /// term shows the skeleton until its own answer lands; this lets the page do the same.
    var answeredQuery = ""

    /// Not observed: a pending debounce is bookkeeping, and redrawing on it would
    /// re-run the very `onChange` that scheduled it.
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init() {
        // The list as it stood last time, so the screen opens on people rather than on a
        // spinner. The unfiltered request below still runs and replaces it.
        contacts = ContentCache.shared.value([Contact].self, for: .contacts) ?? []
    }

    func load() async {
        loading = true
        defer { loading = false }
        let searching = !query.isEmpty
        let asked = query
        do {
            contacts = try await APIClient.shared.contacts(query: asked)
            error = nil
            // Only the unfiltered list is cached. A result set for "ann" restored under a
            // blank search field would read as the whole address book being three people.
            if !searching { ContentCache.shared.store(contacts, for: .contacts) }
            fresh = true
            answeredQuery = asked
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            fresh = true
            answeredQuery = asked
        }
    }

    /// The web (`useContacts(q)`) asks on every keystroke, cancelling nothing — the newest
    /// answer wins. Here the previous request is cancelled so a slow early answer cannot
    /// land on top of a later one.
    func search() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in await self?.load() }
    }

    /// The worker searches server-side, so every keystroke would otherwise be a round trip.
    /// 250ms is long enough to swallow a burst of typing and short enough to feel live.
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }
}

@MainActor
@Observable
final class ContactDetailStore {
    var detail: ContactDetailResponse?
    var loading = true
    var error: String?
    /// True once the first answer (or failure) for this person has landed.
    var fresh = false
    /// True while a change is being written, so the controls can refuse a second tap.
    var saving = false

    func load(id: String) async {
        // A person's threads are keyed by their contact id, so reopening someone is
        // instant even though the list itself was fetched under a different scope.
        if detail == nil, let cached = ContentCache.shared.value(ContactDetailResponse.self, for: .contact(id)) {
            detail = cached
        }
        loading = detail == nil
        defer { loading = false }
        do {
            let fetched = try await APIClient.shared.contact(id)
            detail = fetched
            ContentCache.shared.store(fetched, for: .contact(id))
            error = nil
            fresh = true
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            fresh = true
        }
    }

    /// Writes one change and adopts whatever the worker says the person now looks like.
    ///
    /// Deliberately not optimistic. A screen decision fans out across every account that
    /// has heard from this person and can settle differently from what was asked — `mixed`
    /// is exactly that case — so drawing the request and correcting it afterwards would
    /// show a state that was never true. The controls disable for the moment it takes.
    /// Returns an error message, or nil when it stuck.
    func save(id: String,
              name: String? = nil,
              notes: String? = nil,
              screenStatus: ScreenStatus? = nil,
              bundled: Bool? = nil,
              scope: String = "all") async -> String? {
        guard !saving else { return nil }
        saving = true
        defer { saving = false }
        do {
            let updated = try await APIClient.shared.updateContact(
                id, name: name, notes: notes, screenStatus: screenStatus, bundled: bundled, scope: scope
            )
            if var detail { detail.contact = updated; self.detail = detail }
            if let detail { ContentCache.shared.store(detail, for: .contact(id)) }
            // The address book holds its own copy of this person. Correcting it in place
            // beats invalidating five hundred rows to fix one, and keeps Contacts from
            // drawing an answer the reader has just changed.
            if var cached = ContentCache.shared.value([Contact].self, for: .contacts),
               let index = cached.firstIndex(where: { $0.id == id }) {
                cached[index] = updated
                ContentCache.shared.store(cached, for: .contacts)
            }
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class ClipsStore {
    var clips: [Clip] = []
    var loading = true
    var error: String?
    /// True once the first answer (or failure) has landed (the Mac skeleton keys on it).
    var fresh = false

    /// Same shape in all four library stores below: seed from the cache so the list is
    /// already drawn when the screen appears, then let the request correct it.
    init() {
        clips = ContentCache.shared.value([Clip].self, for: .clips) ?? []
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            clips = try await APIClient.shared.clips()
            ContentCache.shared.store(clips, for: .clips)
            error = nil
            fresh = true
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            fresh = true
        }
    }
}

@MainActor
@Observable
final class CollectionsStore {
    var collections: [MailCollection] = []
    var loading = true
    var error: String?
    /// True once the first answer (or failure) has landed (the Mac skeleton keys on it).
    var fresh = false

    init() {
        collections = ContentCache.shared.value([MailCollection].self, for: .collections) ?? []
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            collections = try await APIClient.shared.collections()
            ContentCache.shared.store(collections, for: .collections)
            error = nil
            fresh = true
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            fresh = true
        }
    }
}

@MainActor
@Observable
final class CollectionDetailStore {
    var detail: CollectionDetailResponse?
    var loading = true
    var error: String?
    /// True once the first answer (or failure) has landed (the Mac skeleton keys on it).
    var fresh = false

    func load(id: String) async {
        loading = detail == nil
        defer { loading = false }
        do {
            detail = try await APIClient.shared.collection(id)
            error = nil
            fresh = true
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            fresh = true
        }
    }
}

@MainActor
@Observable
final class LabelsStore {
    var labels: [MailLabel] = []
    /// Thread totals per label id, filled in after the list lands.
    var counts: [String: Int] = [:]
    var loading = true
    var error: String?
    /// True once the first answer (or failure) has landed (the Mac skeleton keys on it).
    var fresh = false

    /// Only the labels are cached, not their counts: the counts are a fan-out of one
    /// request per label and a stale number beside a name is worse than no number at all.
    init() {
        labels = ContentCache.shared.value([MailLabel].self, for: .labels) ?? []
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            labels = try await APIClient.shared.labels()
            ContentCache.shared.store(labels, for: .labels)
            error = nil
            fresh = true
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            fresh = true
            return
        }
        await loadCounts()
    }

    /// `GET /api/labels` does not carry a thread count, so the counts are a second pass:
    /// one request per label, in parallel, drawn as they arrive. Labels are hand-made and
    /// therefore few, which is what makes fan-out acceptable here and nowhere else.
    private func loadCounts() async {
        let ids = labels.map(\.id)
        await withTaskGroup(of: (String, Int?).self) { group in
            for id in ids {
                group.addTask {
                    let page = try? await APIClient.shared.labelThreads(id)
                    return (id, page?.threads.count)
                }
            }
            for await (id, count) in group {
                if let count { counts[id] = count }
            }
        }
    }
}

@MainActor
@Observable
final class LabelThreadsStore {
    var threads: [ThreadSummary] = []
    var loading = true
    var error: String?
    /// True once the first answer (or failure) has landed (the Mac skeleton keys on it).
    var fresh = false

    func load(id: String) async {
        // Seeded per label id, so reopening a label you have looked at is instant.
        if threads.isEmpty, let cached = ContentCache.shared.value([ThreadSummary].self, for: .labelThreads(id)) {
            threads = cached
        }
        loading = threads.isEmpty
        defer { loading = false }
        do {
            threads = try await APIClient.shared.labelThreads(id).threads
            ContentCache.shared.store(threads, for: .labelThreads(id))
            error = nil
            fresh = true
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            fresh = true
        }
    }
}

/// `GET /api/screener/screened-out` — every contact in scope whose screen status is
/// `screened_out`, most recently screened first.
struct ScreenedOutResponse: Codable, Sendable {
    var contacts: [Contact]

    enum CodingKeys: String, CodingKey { case contacts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contacts = (try? c.decode([Contact].self, forKey: .contacts)) ?? []
    }
}

extension APIClient {
    func screenedOut() async throws -> ScreenedOutResponse {
        try await get("/api/screener/screened-out", as: ScreenedOutResponse.self)
    }
}

@MainActor
@Observable
final class ScreenedOutStore {
    private(set) var contacts: [Contact] = []
    private(set) var loading = true
    private(set) var error: String?
    /// Contact ids with a decision in flight, so their row can refuse a second tap.
    private(set) var working: Set<String> = []

    init() {
        // There is no cache key of its own for this list, but there is one for the address
        // book — and `GET /api/contacts` carries everyone, screened out included. Filtering
        // last night's copy is a true subset of this list rather than a guess at it, so the
        // screen opens on faces and the request below corrects the set.
        contacts = (ContentCache.shared.value([Contact].self, for: .contacts) ?? [])
            .filter { $0.screenStatus == .screenedOut }
    }

    func load() async {
        loading = contacts.isEmpty
        defer { loading = false }
        do {
            contacts = try await APIClient.shared.screenedOut().contacts
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Lets one person back in. The row leaves only once the server has agreed — unlike the
    /// Screener, where the card is already flying and the network is catching up. Here there
    /// is no gesture in flight to honour, and a row that vanished and came back would read
    /// as the app having second thoughts about a decision the reader just made.
    func admit(_ contact: Contact, to status: ScreenStatus, scope: String) async -> String? {
        guard !working.contains(contact.id) else { return nil }
        working.insert(contact.id)
        defer { working.remove(contact.id) }
        do {
            let updated = try await APIClient.shared.updateContact(contact.id, screenStatus: status, scope: scope)
            withAnimation(Theme.Motion.rowExit) {
                contacts.removeAll { $0.id == contact.id }
            }
            // The address book cache holds this person with the status they no longer have.
            // Correcting it in place is cheaper than invalidating a list of five hundred
            // people, and stops Contacts from drawing a stale answer on its next open.
            if var cached = ContentCache.shared.value([Contact].self, for: .contacts),
               let index = cached.firstIndex(where: { $0.id == contact.id }) {
                cached[index] = updated
                ContentCache.shared.store(cached, for: .contacts)
            }
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Applied when a decision was made in the contact sheet rather than on the row.
    func reconcile(_ contact: Contact) {
        guard contact.screenStatus != .screenedOut else { return }
        withAnimation(Theme.Motion.rowExit) {
            contacts.removeAll { $0.id == contact.id }
        }
    }
}
