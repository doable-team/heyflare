import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// `DELETE /api/drafts/:id`. Declared here because this is the only screen that throws a
/// draft away — the composer only ever creates and patches them.
extension APIClient {
    func deleteDraft(_ id: String) async throws {
        try await delete("/api/drafts/\(id)")
    }
}

@MainActor
@Observable
final class DraftsStore {
    var drafts: [Draft] = []
    var loading = true
    var error: String?

    /// Half-written mail only. Anything queued, in flight or failed on the way out belongs
    /// to `ScheduledScreen`, which is the only place that can call it back — the same split
    /// the web makes between its Drafts and Scheduled pages. Before that screen existed
    /// this list carried the queue as well, and the only thing it could offer a scheduled
    /// message was Delete, which destroys mail somebody meant to send.
    var unsent: [Draft] { drafts.filter { $0.status == "draft" } }

    init() {
        // Unsent mail is the one list a reader opens expecting to find what they left.
        // Drawing last time's copy first means it is there before the request answers.
        // Cached whole, filtered on read, and shared with `ScheduledScreen`.
        drafts = ContentCache.shared.value([Draft].self, for: .drafts) ?? []
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            drafts = try await APIClient.shared.drafts()
            ContentCache.shared.store(drafts, for: .drafts)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Optimistic: the row has already swiped away, so putting it back on failure is the
    /// only honest thing to do, and the caller says so in a toast.
    func delete(_ draft: Draft) async -> String? {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return nil }
        withAnimation(Theme.Motion.rowExit) { _ = drafts.remove(at: index) }
        do {
            try await APIClient.shared.deleteDraft(draft.id)
            // The cache has to lose the draft too, or the next visit deals it straight
            // back and offers to delete something the server no longer has.
            ContentCache.shared.store(drafts, for: .drafts)
            return nil
        } catch {
            withAnimation(Theme.Motion.rowExit) { drafts.insert(draft, at: min(index, drafts.count)) }
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// `POST /api/send/cancel` — takes a scheduled draft off the queue and returns it to
/// being an ordinary draft, keeping every word of it. The worker refuses anything whose
/// status is not `scheduled`, which is why the button is only offered on those rows.
extension APIClient {
    func cancelScheduledSend(draftID: String) async throws {
        try await postIgnoringResult("/api/send/cancel", body: ["draft_id": draftID])
    }
}

@MainActor
@Observable
final class ScheduledStore {
    /// The whole draft list, because `GET /api/drafts` has no filter and because the cache
    /// entry this shares with `DraftsScreen` holds all of them. The screen shows a slice.
    private(set) var drafts: [Draft] = []
    private(set) var loading = true
    private(set) var error: String?

    /// Queued, in flight, or failed on the way out — the three states the web groups under
    /// "Scheduled". A failed send is still a message the sender believes is going out, so
    /// hiding it here would mean the only place it surfaces is the plain Drafts list, where
    /// nothing says it ever tried.
    private static let queuedStatuses: Set<String> = ["scheduled", "sending", "failed"]

    var queued: [Draft] {
        drafts
            .filter { Self.queuedStatuses.contains($0.status) }
            .sorted { ($0.sendAt ?? $0.updatedAt) < ($1.sendAt ?? $1.updatedAt) }
    }

    init() {
        // Shares `.drafts` with `DraftsScreen`: same endpoint, same payload, so the two
        // screens seed each other and neither opens on a spinner.
        drafts = ContentCache.shared.value([Draft].self, for: .drafts) ?? []
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            drafts = try await APIClient.shared.drafts()
            ContentCache.shared.store(drafts, for: .drafts)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Pulls one message back off the queue. The row leaves this screen because it is no
    /// longer scheduled — but the draft itself stays in the cached list with its new
    /// status, so Drafts finds it there rather than having to refetch to see it.
    func cancel(_ draft: Draft) async -> String? {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return nil }
        do {
            try await APIClient.shared.cancelScheduledSend(draftID: draft.id)
            withAnimation(Theme.Motion.rowExit) {
                drafts[index].status = "draft"
                drafts[index].sendAt = nil
            }
            ContentCache.shared.store(drafts, for: .drafts)
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Optimistic, like the Drafts list: the row is already gone, so putting it back on
    /// failure is the only honest thing to do and the caller says so in a toast.
    func delete(_ draft: Draft) async -> String? {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return nil }
        withAnimation(Theme.Motion.rowExit) { _ = drafts.remove(at: index) }
        do {
            try await APIClient.shared.deleteDraft(draft.id)
            ContentCache.shared.store(drafts, for: .drafts)
            return nil
        } catch {
            withAnimation(Theme.Motion.rowExit) { drafts.insert(draft, at: min(index, drafts.count)) }
            return (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
