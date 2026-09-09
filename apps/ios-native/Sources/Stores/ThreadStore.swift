import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

@MainActor
@Observable
final class ThreadStore {
    private(set) var detail: ThreadDetail?
    private(set) var loading = false
    var error: String?
    /// Message ids the reader has expanded. The last message opens by itself.
    var expanded: Set<String> = []
    /// The AI summary panel. `.idle` means it has never been asked for and is not drawn.
    private(set) var summary: ThreadSummaryState = .idle

    /// `peek` reads the thread without marking it seen, which is what a preview from the
    /// Screener, Bubble Up or Reply Later needs: looking at something is not filing it.
    func load(_ id: String, peek: Bool = false) async {
        guard detail == nil else { return }
        // Draw the copy we already have, then correct it. Opening a thread twice should
        // never show a spinner the second time.
        if let cached = ContentCache.shared.value(ThreadDetail.self, for: .thread(id)) {
            detail = cached
            if let last = cached.messages.last { expanded.insert(last.id) }
        }
        loading = detail == nil
        defer { loading = false }
        do {
            let value = try await APIClient.shared.thread(id, peek: peek)
            detail = value
            ContentCache.shared.store(value, for: .thread(id))
            if let last = value.messages.last { expanded.insert(last.id) }
        } catch let e as APIError {
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fetches again without touching what is on screen until the answer is back. `load`
    /// returns early once a detail is held; this is for a change made elsewhere.
    func reload(_ id: String) async {
        guard let value = try? await APIClient.shared.thread(id, peek: true) else { return }
        detail = value
        ContentCache.shared.store(value, for: .thread(id))
    }

    func apply(_ value: ThreadDetail?) {
        guard let value else { return }
        detail = value
        ContentCache.shared.store(value, for: .thread(value.id))
    }

    func toggle(_ messageID: String) {
        if expanded.contains(messageID) { expanded.remove(messageID) } else { expanded.insert(messageID) }
    }

    // MARK: Clips

    /// Adds a saved clip to the thread in place. The clips endpoint answers with the clip
    /// rather than the thread, so re-fetching the whole thread to show one chip would be
    /// a second round trip for something already known.
    func addClip(_ clip: Clip) {
        guard var value = detail else { return }
        value.clips.append(clip)
        apply(value)
    }

    func removeClip(_ id: String) {
        guard var value = detail else { return }
        value.clips.removeAll { $0.id == id }
        apply(value)
    }

    // MARK: Summary

    /// `useThreadSummary`: one request; the worker's own error comes back as `.failed`,
    /// which the page reports the way the web does (a toast), with no settings call first.
    func summarise(_ id: String) async {
        summary = .running
        do {
            summary = .ready(try await APIClient.shared.aiSummary(threadID: id))
        } catch {
            summary = .failed((error as? APIError)?.errorDescription ?? "The assistant could not summarise this.")
        }
    }

    func dismissSummary() {
        summary = .idle
    }
}
