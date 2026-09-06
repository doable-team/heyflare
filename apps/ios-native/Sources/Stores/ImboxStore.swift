import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// Everything the Imbox draws, in one place. `GET /api/imbox` answers with the whole
/// screen in a single round trip, so there is one request and one loading state rather
/// than five sections each racing on their own.
@MainActor
@Observable
final class ImboxStore {
    private(set) var data: ImboxResponse
    private(set) var loading = false
    private(set) var loaded = false
    var error: String?

    private var inFlight: Task<Void, Never>?

    init() {
        // Last time's Imbox, on the first frame. The request still goes out below; this
        // only decides whether the screen opens with rows or with a spinner.
        data = ContentCache.shared.value(ImboxResponse.self, for: .imbox) ?? .empty
    }

    /// True when something is on screen already, cached or fetched.
    private var hasContent: Bool { !data.isEmpty }

    func load(force: Bool = false) async {
        if loaded && !force && hasContent { return }
        await refresh()
    }

    func refresh() async {
        inFlight?.cancel()
        // A spinner is only honest when there is nothing to look at.
        if !loaded && !hasContent { loading = true }
        // The scope the request was made under. An answer that lands after the scope has
        // moved on belongs to the other mailbox, and was both drawn and cached as this one.
        let scope = ServerConfig.shared.scope
        let task = Task {
            defer { loading = false }
            do {
                let next = try await APIClient.shared.imbox()
                guard !Task.isCancelled, scope == ServerConfig.shared.scope else { return }
                data = next
                ContentCache.shared.store(next, for: .imbox)
                error = nil
                loaded = true
            } catch is CancellationError {
                return
            } catch let e as APIError {
                // Keep whatever is already on screen; a failed refresh should not
                // empty the Imbox out from under someone.
                error = e.errorDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
        inFlight = task
        await task.value
    }

    /// Updates one thread in place, for actions that change how a row reads without
    /// moving it anywhere. `mark_read` and `mark_unread` do not change the bucket
    /// server-side, so removing the row would make it vanish until the next refresh.
    func update(_ id: String, _ transform: (inout ThreadSummary) -> Void) {
        for path in [\ImboxResponse.newThreads, \.seenThreads, \.replyLater, \.setAside] {
            guard let index = data[keyPath: path].firstIndex(where: { $0.id == id }) else { continue }
            transform(&data[keyPath: path][index])
        }
    }

    /// Takes a thread out of every section it might be sitting in, so an action reads
    /// as immediate. The server is the authority; this is just the optimistic half.
    func remove(_ id: String) {
        withAnimation(Theme.Motion.rowExit) {
            data.newThreads.removeAll { $0.id == id }
            data.seenThreads.removeAll { $0.id == id }
            data.replyLater.removeAll { $0.id == id }
            data.setAside.removeAll { $0.id == id }
        }
    }

    /// The same, for a whole selection, in one animation rather than one per row.
    func removeMany(_ ids: Set<String>) {
        withAnimation(Theme.Motion.rowExit) {
            data.newThreads.removeAll { ids.contains($0.id) }
            data.seenThreads.removeAll { ids.contains($0.id) }
            data.replyLater.removeAll { ids.contains($0.id) }
            data.setAside.removeAll { ids.contains($0.id) }
        }
    }

    /// Every thread in a selection, wherever in the screen it is sitting.
    func threads(with ids: Set<String>) -> [ThreadSummary] {
        (data.newThreads + data.seenThreads).filter { ids.contains($0.id) }
    }

    /// The rows a selection can reach: the two lists the Imbox actually draws. The trays
    /// are pills, not rows, so nothing in them can be ticked.
    var visibleThreads: [ThreadSummary] { data.newThreads + data.seenThreads }
}

extension ImboxResponse {
    var isEmpty: Bool {
        newThreads.isEmpty && seenThreads.isEmpty && bundles.isEmpty
            && replyLater.isEmpty && setAside.isEmpty && screenerCount == 0
    }
}
