import SwiftUI

// MARK: - Optimistic actions

/// Runs one thread action the way every list in this app runs it: the row leaves first,
/// the request follows, and the toast carries the inverse action so an accident costs one
/// tap to undo. A failed request puts the row back where it was.
///
/// A struct rather than a method on each screen because the Feed, the lists, bundles and
/// Power Through all behave identically here; only where the row lives differs, which is
/// what the two closures supply.
@MainActor
struct ThreadActionRunner {
    let app: AppState
    let toasts: ToastCenter
    /// Drops the row and answers where it was, so an undo can put it back in place.
    let remove: (String) -> Int?
    let restore: (ThreadSummary, Int) -> Void

    func run(_ thread: ThreadSummary, _ action: ThreadAction, undo: ThreadAction?) {
        // A missing row is not a cancelled action. A pull-to-refresh can replace the list
        // during the swipe's 160ms commit delay, and bailing here dropped the user's tap
        // silently: nothing reached the server, no toast said so. The request and the toast
        // are what the user asked for, so they go ahead regardless; only the restore has to
        // be skipped, because without an index there is no place to put the row back.
        let index = remove(thread.id)
        Haptics.success()

        Task {
            do {
                try await APIClient.shared.act(thread.id, action)
                app.didMutate()

                var reverse: (@MainActor () async -> Void)?
                if let undo {
                    reverse = { @MainActor in
                        do {
                            try await APIClient.shared.act(thread.id, undo)
                            if let index { restore(thread, index) }
                            app.didMutate()
                        } catch {
                            toasts.error(Self.describe(error))
                        }
                    }
                }
                toasts.show(action.confirmation, undo: reverse)
            } catch {
                if let index { restore(thread, index) }
                toasts.error(Self.describe(error))
            }
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}
