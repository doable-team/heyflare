import SwiftUI

/// `useBulkAction` + `invalidateMail`: post the action, then tell every open page.
@MainActor
enum Mail {
    static weak var app: AppState?

    static func invalidate() { app?.didMutate() }

    static func bulk(_ ids: [String], _ action: ThreadAction, toast: String? = nil, onSuccess: (() -> Void)? = nil) {
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await APIClient.shared.bulk(ids, action)
                invalidate()
                if let toast { Toasts.shared.success(toast) }
                onSuccess?()
            } catch {
                Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
                // `onSettled: invalidateMail`: the row that left the list on the way out
                // comes back with the refetch.
                invalidate()
            }
        }
    }

    /// One thread, through `/actions`; the detail comes back for the page to adopt.
    @discardableResult
    static func act(_ id: String, _ action: ThreadAction, toast: String? = nil) async -> ThreadDetail? {
        do {
            let detail = try await APIClient.shared.act(id, action)
            invalidate()
            if let toast { Toasts.shared.show(toast) }
            return detail
        } catch {
            Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            return nil
        }
    }

    /// Actions the native `ThreadAction` enum does not carry (merge, collections, bundle).
    static func raw(_ id: String, _ body: [String: Any], toast: String? = nil) async -> Bool {
        do {
            try await APIClient.shared.postIgnoringResult("/api/threads/\(id)/actions", body: body)
            invalidate()
            if let toast { Toasts.shared.show(toast) }
            return true
        } catch {
            Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            return false
        }
    }

    static func rawBulk(_ ids: [String], _ body: [String: Any], toast: String? = nil) {
        Task {
            do {
                var b = body; b["thread_ids"] = ids
                try await APIClient.shared.postIgnoringResult("/api/threads/bulk", body: b)
                invalidate()
                if let toast { Toasts.shared.success(toast) }
            } catch {
                Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
                invalidate()
            }
        }
    }

    static func bucketName(_ b: Bucket) -> String { b.title }
}
