import SwiftUI
import Observation

/// One counter every mail screen watches.
///
/// Each screen owns its store, and a pushed screen cannot reach the store the tab root
/// made — so without a shared signal, reading a thread (which the worker marks seen) or
/// filing it from its own page left the Imbox behind it drawing the old row until the
/// next pull-to-refresh. This is the phone's equivalent of the web client's
/// `invalidateMail`: anything that changes mail on the server bumps the revision, and
/// every list decides for itself what to refetch.
///
/// A singleton rather than a value on `AppState` because the send queue, which can fire
/// minutes after the composer closed, holds no `AppState` and has to be able to say that
/// a message went out.
@MainActor
@Observable
final class MailBus {
    static let shared = MailBus()

    private(set) var revision = 0

    func changed() { revision &+= 1 }
}

extension View {
    /// Refreshes this screen whenever mail changes somewhere else in the app.
    ///
    /// The refresh runs when the revision moves while the screen is showing, and on the
    /// way back onto the screen when it moved while it was covered — which is the pop
    /// back from a thread, or a switch back to this tab. The first appearance only takes
    /// note of the revision: the screen's own `.task` does the first load, and a second
    /// request on the same frame would be waste.
    ///
    /// `enabled` is for the moments a refresh would pull the rows out from under
    /// something — a selection being gathered. A change that arrives while disabled is
    /// caught up the moment it is enabled again, not lost.
    func syncsWithMail(enabled: Bool = true, _ refresh: @escaping @MainActor () async -> Void) -> some View {
        modifier(MailSync(enabled: enabled, refresh: refresh))
    }
}

private struct MailSync: ViewModifier {
    let enabled: Bool
    let refresh: @MainActor () async -> Void

    /// The revision this screen last drew. `nil` until the first appearance.
    @State private var seen: Int?
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                visible = true
                let current = MailBus.shared.revision
                guard let seen else {
                    self.seen = current
                    return
                }
                if seen != current { catchUp(to: current) }
            }
            .onDisappear { visible = false }
            .onChange(of: MailBus.shared.revision) { _, current in
                guard visible else { return }
                catchUp(to: current)
            }
            .onChange(of: enabled) { _, on in
                guard on, visible, let seen, seen != MailBus.shared.revision else { return }
                catchUp(to: MailBus.shared.revision)
            }
    }

    private func catchUp(to current: Int) {
        guard enabled else { return }
        seen = current
        Task { await refresh() }
    }
}
