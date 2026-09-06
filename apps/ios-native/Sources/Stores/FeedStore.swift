import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

extension ComposeIntent {
    /// A reply built from a `ThreadSummary` and its latest message.
    ///
    /// The existing `reply(to:in:me:all:)` needs a fully loaded `ThreadDetail`. The Feed,
    /// bundles and Power Through only ever hold a summary plus one message, and making
    /// them fetch the whole thread just to open the composer would cost a round trip for
    /// nothing — the reply-all recipients are the one thing lost, and the composer can
    /// add those.
    static func reply(to message: Message, inSummary thread: ThreadSummary) -> ComposeIntent {
        var recipients: [Address] = message.isFromMe ? message.to : [message.from]
        if recipients.isEmpty { recipients = [message.from] }

        let subject = thread.displaySubject.trimmingCharacters(in: .whitespaces)
        let prefixed = subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"

        let text = message.textBody.isEmpty ? HTMLText.plain(from: message.htmlBody) : message.textBody
        let quoted = "On \(RelativeTime.long(message.sentAt)), \(message.from.display) wrote:\n"
            + text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(200)
                .map { "> " + $0 }
                .joined(separator: "\n")

        return ComposeIntent(
            kind: .reply(threadID: thread.id, messageID: message.id, all: false),
            accountID: message.accountID ?? thread.accountID,
            to: recipients,
            subject: prefixed,
            quoted: quoted
        )
    }
}

/// Which half of the Feed is on screen.
///
/// The worker reads a single query parameter: `GET /api/feed` selects `bucket = 'feed'`
/// and, unless `?show=all` is passed, `seen = 0` as well. So "New" is the absence of the
/// parameter rather than a value of its own, and `all` is the only string the route
/// recognises — anything else falls back to New.
enum FeedFilter: String, CaseIterable, Hashable {
    case new
    case all

    var title: String { self == .new ? "New" : "All" }

    /// `nil` for New, so the default request stays byte-for-byte what it was.
    var parameter: String? { self == .all ? "all" : nil }
}

extension APIClient {
    /// The Feed, filtered. Kept here rather than in `APIClient.swift` because the Feed
    /// screen is the only caller of the variant.
    func feed(page: Int, show: FeedFilter) async throws -> ThreadPage {
        try await get("/api/feed", query: ["page": String(page), "show": show.parameter], as: ThreadPage.self)
    }
}

/// The Feed's paged list. Held by the view rather than the app because the Feed is one
/// tab out of five and its contents are worth throwing away when the tab is left.
@MainActor
@Observable
final class FeedStore {
    private(set) var threads: [ThreadSummary] = []
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var error: String?

    /// `0` before the first load, the worker's `next_page` after it, `nil` at the end.
    private var nextPage: Int? = 0
    private var started = false

    var hasMore: Bool { nextPage != nil && nextPage != 0 }

    init() {
        // Last time's first page, drawn on the first frame. The request below still runs
        // and replaces it; this only decides whether the Feed opens with cards or blank.
        threads = ContentCache.shared.value([ThreadSummary].self, for: .feed) ?? []
    }

    func firstLoad(_ show: FeedFilter) async {
        guard !started else { return }
        started = true
        // A spinner is only honest when there is nothing to look at.
        loading = threads.isEmpty
        await load(page: 0, replacing: true, show: show)
        loading = false
    }

    func refresh(_ show: FeedFilter) async {
        started = true
        await load(page: 0, replacing: true, show: show)
    }

    func loadMore(_ show: FeedFilter) async {
        guard let page = nextPage, page > 0, !loadingMore, !loading else { return }
        loadingMore = true
        await load(page: page, replacing: false, show: show)
        loadingMore = false
    }

    private func load(page: Int, replacing: Bool, show: FeedFilter) async {
        // An answer that lands after the scope has moved on is the other mailbox's Feed.
        let scope = ServerConfig.shared.scope
        do {
            let result = try await APIClient.shared.feed(page: page, show: show)
            guard scope == ServerConfig.shared.scope else { return }
            if replacing {
                threads = result.threads
                // Only page 0 of the default filter is ever cached. A cache that replays
                // page 5 into an empty list would open the Feed halfway down, on cards
                // whose beginning is missing; and storing an All page under the same key
                // would seed the New Feed with cards that have already been dealt with.
                if show == .new {
                    ContentCache.shared.store(result.threads, for: .feed)
                }
            } else {
                // The worker pages by position, so a thread arriving while you scroll can
                // shift a row into a page you already have. Dedupe rather than double it.
                let known = Set(threads.map(\.id))
                threads.append(contentsOf: result.threads.filter { !known.contains($0.id) })
            }
            nextPage = result.nextPage
            error = nil
        } catch is CancellationError {
            // Leaving the tab mid-request is not a failure.
        } catch {
            self.error = ThreadActionRunner.describe(error)
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

    /// Edits one row where it stands, for the actions the server does not take out of the
    /// Feed. Answers whether the row was there, so a caller can tell an edit from a no-op.
    @discardableResult
    func update(_ id: String, _ edit: (inout ThreadSummary) -> Void) -> Bool {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return false }
        edit(&threads[index])
        return true
    }
}
