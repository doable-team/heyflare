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
    /// Whether an AI provider is set up at all. Asked once, lazily, the first time an AI
    /// action runs — opening a thread should not cost a settings request for a feature
    /// most openings never touch.
    private var aiConfigured: Bool?

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

    func summarise(_ id: String) async {
        summary = .running
        if aiConfigured == nil {
            // A failed settings call is treated as "configured": the summarise request
            // below will produce the real error, and guessing "not set up" from a network
            // blip would send someone to Settings for nothing.
            aiConfigured = (try? await APIClient.shared.aiSettings())?.configured ?? true
        }
        guard aiConfigured == true else {
            summary = .unconfigured
            return
        }
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
