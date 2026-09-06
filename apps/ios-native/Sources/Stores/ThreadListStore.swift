import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// A row that has left a list, and the place it left, so a bulk undo can put a whole
/// selection back exactly where it was rather than at the top.
struct RemovedThread {
    let thread: ThreadSummary
    let index: Int
}

/// What putting a bulk action back looks like.
enum BulkUndo {
    /// The same inverse action for every thread — `reply_later off`, say.
    case action(ThreadAction)
    /// Every thread back to the bucket it came from. A selection can span buckets
    /// (Everything and Search both mix them), so this is grouped rather than one call.
    case buckets
}

/// `ThreadActionRunner`, for a selection instead of a row.
///
/// A separate type rather than a loop over the single-thread runner: one `POST
/// /api/threads/bulk` is one round trip and one toast, where fifty `act` calls would be
/// fifty requests and fifty toasts stacking on top of each other. The shape is otherwise
/// deliberately identical — rows leave first, the request follows, a failure puts them
/// all back, and the toast carries the inverse where there is one.
@MainActor
struct BulkActionRunner {
    let app: AppState
    let toasts: ToastCenter
    /// Drops the rows and answers where they were.
    let remove: (Set<String>) -> [RemovedThread]
    let restore: ([RemovedThread]) -> Void

    func run(_ threads: [ThreadSummary], _ action: ThreadAction, undo: BulkUndo?) {
        guard !threads.isEmpty else { return }
        let ids = threads.map(\.id)
        let removed = remove(Set(ids))
        Haptics.success()

        Task {
            do {
                try await APIClient.shared.bulk(ids, action)
                app.didMutate()

                var reverse: (@MainActor () async -> Void)?
                if let undo {
                    reverse = { @MainActor in
                        do {
                            switch undo {
                            case .action(let inverse):
                                try await APIClient.shared.bulk(ids, inverse)
                            case .buckets:
                                // One request per distinct origin bucket, not per thread.
                                for (bucket, group) in Dictionary(grouping: threads, by: { $0.bucket }) {
                                    try await APIClient.shared.bulk(group.map(\.id), .move(bucket))
                                }
                            }
                            restore(removed)
                            app.didMutate()
                        } catch {
                            toasts.error(ThreadActionRunner.describe(error))
                        }
                    }
                }
                toasts.show(Self.confirmation(action, count: ids.count), undo: reverse)
            } catch {
                restore(removed)
                toasts.error(ThreadActionRunner.describe(error))
            }
        }
    }

    /// The single-thread wording, with a count appended once there is more than one —
    /// "Moved to Trash" reads wrong when it was eleven of them.
    private static func confirmation(_ action: ThreadAction, count: Int) -> String {
        count == 1 ? action.confirmation : "\(action.confirmation) · \(count)"
    }
}

/// One month's worth of rows. Threads are grouped up front rather than on every body
/// evaluation, because the grouping only changes when the list does.
struct ThreadMonthGroup: Identifiable {
    let id: String
    let caption: String
    var threads: [ThreadSummary]
}

@MainActor
@Observable
final class ThreadListStore {
    private(set) var threads: [ThreadSummary] = []
    private(set) var groups: [ThreadMonthGroup] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var error: String?

    private var nextPage: Int? = 0
    private var started = false

    var hasMore: Bool { nextPage != nil && nextPage != 0 }
    /// Captions only earn their place once the list actually crosses a month boundary.
    var spansMonths: Bool { groups.count > 1 }

    private static let monthKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    /// The kind is taken here as well as on every call so the first page can be seeded
    /// during `init` — a list that only learned its kind in `.task` would already have
    /// drawn one empty frame by then, which is the flash this cache exists to remove.
    init(kind: ThreadListKind) {
        threads = ContentCache.shared.value([ThreadSummary].self, for: .list(kind)) ?? []
        regroup()
    }

    func firstLoad(_ kind: ThreadListKind) async {
        guard !started else { return }
        started = true
        loading = threads.isEmpty
        await load(kind, page: 0, replacing: true)
        loading = false
    }

    func refresh(_ kind: ThreadListKind) async {
        started = true
        await load(kind, page: 0, replacing: true)
    }

    func loadMore(_ kind: ThreadListKind) async {
        guard let page = nextPage, page > 0, !loadingMore, !loading else { return }
        loadingMore = true
        await load(kind, page: page, replacing: false)
        loadingMore = false
    }

    private func load(_ kind: ThreadListKind, page: Int, replacing: Bool) async {
        // The scope this request was made under; an answer that lands after a switch
        // belongs to the other mailbox and must not be drawn or cached as this one.
        let scope = ServerConfig.shared.scope
        do {
            let result = try await APIClient.shared.threads(kind, page: page)
            guard scope == ServerConfig.shared.scope else { return }
            if replacing {
                threads = result.threads
                // Page 0 only: a stored page 5 replayed into an empty list would open
                // this screen in the middle of a month nobody scrolled to.
                ContentCache.shared.store(result.threads, for: .list(kind))
            } else {
                // Paging is positional, so a thread that moved between requests can appear
                // twice. Identity wins over arrival order.
                let known = Set(threads.map(\.id))
                threads.append(contentsOf: result.threads.filter { !known.contains($0.id) })
            }
            nextPage = result.nextPage
            error = nil
        } catch is CancellationError {
            // A screen popped mid-request is not a failure.
        } catch {
            self.error = ThreadActionRunner.describe(error)
        }
        regroup()
    }

    func remove(_ id: String) -> Int? {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return nil }
        withAnimation(Theme.Motion.rowExit) {
            threads.remove(at: index)
            regroup()
        }
        return index
    }

    func restore(_ thread: ThreadSummary, at index: Int) {
        guard !threads.contains(where: { $0.id == thread.id }) else { return }
        withAnimation(Theme.Motion.rowExit) {
            threads.insert(thread, at: min(index, threads.count))
            regroup()
        }
    }

    /// The bulk counterpart. Positions are read before anything is dropped, because every
    /// removal shifts the ones after it and a second pass would record the wrong index.
    func removeMany(_ ids: Set<String>) -> [RemovedThread] {
        let taken = threads.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { RemovedThread(thread: $0.element, index: $0.offset) }
        guard !taken.isEmpty else { return [] }
        withAnimation(Theme.Motion.rowExit) {
            threads.removeAll { ids.contains($0.id) }
            regroup()
        }
        return taken
    }

    func restoreMany(_ removed: [RemovedThread]) {
        guard !removed.isEmpty else { return }
        withAnimation(Theme.Motion.rowExit) {
            // Ascending order: each insert re-establishes one position, and the rows after
            // it shift along as their own inserts follow. Descending would bury them.
            for item in removed.sorted(by: { $0.index < $1.index })
            where !threads.contains(where: { $0.id == item.thread.id }) {
                threads.insert(item.thread, at: min(item.index, threads.count))
            }
            regroup()
        }
    }

    /// Edits one row where it stands, for the actions that change how a row reads without
    /// moving it anywhere — read state, which none of these lists select on.
    func update(_ id: String, _ edit: (inout ThreadSummary) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        edit(&threads[index])
        regroup()
    }

    private func regroup() {
        var out: [ThreadMonthGroup] = []
        for thread in threads {
            let key = Self.monthKey.string(from: thread.lastDate)
            if out.last?.id == key {
                out[out.count - 1].threads.append(thread)
            } else {
                out.append(ThreadMonthGroup(id: key, caption: RelativeTime.monthCaption(thread.lastDate), threads: [thread]))
            }
        }
        groups = out
    }
}
