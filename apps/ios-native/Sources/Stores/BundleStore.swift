import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// `GET /api/bundles/:id`. Mirrors `BundleDetail` in src/shared/types.ts.
///
/// This lives here rather than in Models.swift because the bundle screen is the only
/// caller; if a second one appears, it moves.
struct BundleDetail: Codable, Sendable {
    var bundle: MailBundle
    /// Each carries `latest_message`, which `ThreadSummary` already decodes.
    var threads: [ThreadSummary]

    enum CodingKeys: String, CodingKey { case bundle, threads }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundle = try c.decode(MailBundle.self, forKey: .bundle)
        threads = (try? c.decode([ThreadSummary].self, forKey: .threads)) ?? []
    }
}

extension APIClient {
    func bundle(_ id: String) async throws -> BundleDetail {
        try await get("/api/bundles/\(id)", as: BundleDetail.self)
    }

    /// Closing the batch. The next mail from this sender starts a fresh one.
    func markBundleSeen(_ id: String) async throws {
        try await postIgnoringResult("/api/bundles/\(id)/seen")
    }

    func markBundleUnseen(_ id: String) async throws {
        try await postIgnoringResult("/api/bundles/\(id)/unseen")
    }
}

@MainActor
@Observable
final class BundleStore {
    private(set) var detail: BundleDetail?
    private(set) var threads: [ThreadSummary] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var marking = false
    /// Flipped locally once the batch is closed, so the bar button settles without a reload.
    private(set) var closed = false

    private var started = false

    func firstLoad(_ id: String) async {
        guard !started else { return }
        started = true
        loading = true
        await load(id)
        loading = false
    }

    func refresh(_ id: String) async {
        started = true
        await load(id)
    }

    private func load(_ id: String) async {
        do {
            let result = try await APIClient.shared.bundle(id)
            detail = result
            threads = result.threads
            closed = !result.bundle.isOpen
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = ThreadActionRunner.describe(error)
        }
    }

    /// Answers whether it landed, so the screen can decide what to say.
    func markAllSeen(_ id: String) async -> Bool {
        guard !marking else { return false }
        marking = true
        defer { marking = false }
        do {
            try await APIClient.shared.markBundleSeen(id)
            closed = true
            return true
        } catch {
            self.error = ThreadActionRunner.describe(error)
            return false
        }
    }

    func remove(_ id: String) -> Int? {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return nil }
        withAnimation(Theme.Motion.rowExit) { _ = threads.remove(at: index) }
        return index
    }

    func restore(_ thread: ThreadSummary, at index: Int) {
        guard !threads.contains(where: { $0.id == thread.id }) else { return }
        withAnimation(Theme.Motion.rowExit) { threads.insert(thread, at: min(index, threads.count)) }
    }
}
