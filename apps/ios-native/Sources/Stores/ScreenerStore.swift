import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// The queue, plus the destination chosen per card.
///
/// The chosen destination lives here rather than in the card so it survives the card being
/// re-created by a list diff, and so an Undo can put an entry back without losing the
/// selection the user had already made on it.
@MainActor
@Observable
final class ScreenerStore {
    private(set) var entries: [ScreenerEntry] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?

    /// contact id → destination, only for cards the user actually touched.
    private var chosen: [String: ScreenStatus] = [:]
    private var task: Task<Void, Never>?

    init() {
        // The queue as it stood last time, on the first frame. The request still goes out.
        entries = ContentCache.shared.value([ScreenerEntry].self, for: .screener) ?? []
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        await load()
    }

    func load(force: Bool = false) async {
        if force { task?.cancel() } else if let task { await task.value; return }
        // The scope the request was made under: an answer arriving after a switch is the
        // other mailbox's queue, and must not be drawn or cached as this one.
        let scope = ServerConfig.shared.scope
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.loading = true
            defer { self.loading = false }
            do {
                let response = try await APIClient.shared.screener()
                guard !Task.isCancelled, scope == ServerConfig.shared.scope else { return }
                self.entries = response.senders
                ContentCache.shared.store(response.senders, for: .screener)
                self.error = nil
                self.loaded = true
                // Drop selections for senders who are no longer in the queue.
                let live = Set(response.senders.map(\.id))
                self.chosen = self.chosen.filter { live.contains($0.key) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
                self.loaded = true
            }
        }
        self.task = task
        await task.value
        if self.task == task { self.task = nil }
    }

    /// The server's suggestion is the default, except that a bare "imbox" suggestion defers
    /// to the owner's own preference — the web client does the same.
    func target(for entry: ScreenerEntry, defaultTarget: ScreenStatus?) -> ScreenStatus {
        if let picked = chosen[entry.id] { return picked }
        if entry.suggestion == .imbox, let defaultTarget { return defaultTarget }
        switch entry.suggestion {
        case .feed, .paperTrail, .imbox: return entry.suggestion
        default: return .imbox
        }
    }

    func setTarget(_ status: ScreenStatus, for entry: ScreenerEntry) {
        guard chosen[entry.id] != status else { return }
        chosen[entry.id] = status
        Haptics.select()
    }

    func index(of id: String) -> Int? { entries.firstIndex { $0.id == id } }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    func insert(_ entry: ScreenerEntry, at index: Int) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.insert(entry, at: min(max(index, 0), entries.count))
    }

    /// Writes the queue as it now stands back to the cache.
    ///
    /// A decision has to reach the cache as well as the array. Removing the card from
    /// `entries` alone leaves the decided sender in the stored copy, so the next time the
    /// Screener opens they are dealt again — a person already judged, asking to be judged
    /// twice. Called once the server has agreed the decision stuck.
    func persist() {
        ContentCache.shared.store(entries, for: .screener)
    }
}
