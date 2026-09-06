import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

@MainActor
@Observable
final class SearchStore {
    private(set) var threads: [ThreadSummary] = []
    /// The text the results on screen belong to, which is not the text in the field while
    /// a keystroke is still settling.
    private(set) var query = ""
    private(set) var searching = false
    private(set) var loadingMore = false
    private(set) var error: String?

    private var nextPage: Int?

    var hasMore: Bool { nextPage != nil }
    var hasResults: Bool { !threads.isEmpty }

    func clear() {
        threads = []
        query = ""
        nextPage = nil
        error = nil
        searching = false
    }

    func run(_ text: String) async {
        searching = true
        defer { searching = false }
        do {
            let page = try await APIClient.shared.search(text, page: 0)
            threads = page.threads
            nextPage = page.nextPage
            query = text
            error = nil
        } catch is CancellationError {
            // Superseded by a later keystroke. The newer request owns the screen.
        } catch {
            threads = []
            nextPage = nil
            query = text
            self.error = ThreadActionRunner.describe(error)
        }
    }

    func loadMore() async {
        guard let page = nextPage, !loadingMore, !searching, !query.isEmpty else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let result = try await APIClient.shared.search(query, page: page)
            let known = Set(threads.map(\.id))
            threads.append(contentsOf: result.threads.filter { !known.contains($0.id) })
            nextPage = result.nextPage
        } catch {
            // A failed second page leaves the first one alone; the sentinel simply stops.
            nextPage = nil
        }
    }

    /// A result that has been acted on leaves, the same way it does in every other list.
    /// Results are a snapshot of a query, so a row that no longer answers it should not
    /// sit there claiming it does.
    func remove(_ id: String) -> Int? {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return nil }
        withAnimation(Theme.Motion.rowExit) { _ = threads.remove(at: index) }
        return index
    }

    func restore(_ thread: ThreadSummary, at index: Int) {
        guard !threads.contains(where: { $0.id == thread.id }) else { return }
        withAnimation(Theme.Motion.rowExit) { threads.insert(thread, at: min(index, threads.count)) }
    }

    /// Read state changes how a row reads without changing whether it matched.
    func update(_ id: String, _ edit: (inout ThreadSummary) -> Void) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        edit(&threads[index])
    }
}
