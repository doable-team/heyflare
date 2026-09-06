import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

@MainActor
@Observable
final class PowerThroughStore {
    private(set) var items: [ThreadSummary] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var marking = false

    private var started = false

    func firstLoad() async {
        guard !started else { return }
        started = true
        loading = true
        await load()
        loading = false
    }

    func refresh() async {
        started = true
        await load()
    }

    private func load() async {
        do {
            items = try await APIClient.shared.powerThrough().items
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = ThreadActionRunner.describe(error)
        }
    }

    func remove(_ id: String) -> Int? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        withAnimation(Theme.Motion.rowExit) { _ = items.remove(at: index) }
        return index
    }

    func restore(_ thread: ThreadSummary, at index: Int) {
        guard !items.contains(where: { $0.id == thread.id }) else { return }
        withAnimation(Theme.Motion.rowExit) { items.insert(thread, at: min(index, items.count)) }
    }

    /// Answers whether it landed, and what was marked, so the screen can say so.
    func markAllSeen() async -> Bool {
        guard !marking, !items.isEmpty else { return false }
        marking = true
        defer { marking = false }
        do {
            try await APIClient.shared.markSeen(items.map(\.id))
            return true
        } catch {
            self.error = ThreadActionRunner.describe(error)
            return false
        }
    }
}
