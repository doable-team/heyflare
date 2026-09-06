import SwiftUI

/// A row that reveals one action per side and commits when the drag passes the
/// threshold, the way Mail and Things behave.
///
/// Built by hand rather than with `List.swipeActions` because the list underneath is a
/// `LazyVStack` — that keeps row height free-form and scrolling cheap — and because the
/// spec asks for a specific reveal: a muted panel with icon and label, a haptic tick the
/// moment the drag crosses 96pt, and a commit that runs on release rather than on tap.
struct SwipeRow<Content: View>: View {
    struct Action {
        let icon: String
        let label: String
        /// `true` when performing the action leaves the row in the list — a swipe that only
        /// opens a confirmation dialog, say. Such a row must come back to rest instead of
        /// flying off, because nothing is going to remove it from under the finger.
        var resets: Bool = false
        let perform: () -> Void
    }

    var leading: Action?      // revealed by dragging right
    var trailing: Action?     // revealed by dragging left
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var armed = false
    @State private var committing = false
    @State private var dragging = false

    private let commit = Theme.Metrics.swipeCommit

    var body: some View {
        ZStack {
            revealPanel
            content()
                .background(Theme.Colors.background)
                // Not a SwiftUI `DragGesture`: see `HorizontalPan`. Every form of it stole
                // vertical scrolling from the list, and the plain `.gesture` form never
                // even engaged over the row's button, so a swipe landed as a tap.
                .background(HorizontalPan(onChange: moved(to:), onEnd: released(at:cancelled:)))
                .offset(x: offset)
        }
        .clipped()
        .animation(dragging ? nil : Theme.Motion.rowExit, value: offset)
        // Rows are recycled by the `LazyVStack` underneath, so a row that leaves mid-commit
        // must not hand its parked offset — or its `committing` flag, which blocks every
        // later swipe — to whatever content is next to use this identity.
        .onDisappear {
            offset = 0
            armed = false
            committing = false
            dragging = false
        }
    }

    // The panel behind the row. Only the side being dragged toward is drawn.
    @ViewBuilder
    private var revealPanel: some View {
        let showingLeading = offset > 0
        let action = showingLeading ? leading : trailing
        if let action {
            HStack {
                if !showingLeading { Spacer() }
                VStack(spacing: 4) {
                    Image(systemName: action.icon)
                        .font(.system(size: 17, weight: .medium))
                    Text(action.label)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.Colors.foreground)
                // Grows a touch at the threshold so the commit is visible as well as felt.
                .scaleEffect(armed ? 1.12 : 1.0)
                .animation(Theme.Motion.quick, value: armed)
                .frame(width: commit)
                if showingLeading { Spacer() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Colors.muted)
        }
    }

    private func moved(to translation: CGFloat) {
        guard !committing else { return }
        dragging = true
        var next = translation
        if next > 0 && leading == nil { next = 0 }
        if next < 0 && trailing == nil { next = 0 }
        // Past the threshold the row keeps moving, but at a third of the speed,
        // so the gesture has a floor without ever feeling stuck.
        if abs(next) > commit {
            let excess = abs(next) - commit
            next = (next < 0 ? -1 : 1) * (commit + excess / 3)
        }
        offset = next

        let nowArmed = abs(next) >= commit
        if nowArmed != armed {
            armed = nowArmed
            if nowArmed { Haptics.threshold() }
        }
    }

    private func released(at translation: CGFloat, cancelled: Bool) {
        dragging = false
        defer { armed = false }
        // `offset != 0` is the proof that this gesture actually moved the row rather than
        // being refused because no action was attached on that side.
        let past = abs(translation) >= commit
        let action = translation > 0 ? leading : trailing
        guard !cancelled, offset != 0, past, let action, !committing else {
            offset = 0
            return
        }
        committing = true

        if action.resets {
            // The action keeps the row: settle back at once, or the content parks 500pt
            // off-screen over a grey panel that cannot be tapped and cannot be swiped
            // away, because `committing` never clears.
            action.perform()
            offset = 0
            committing = false
            return
        }

        // Let the row finish leaving before the list drops it, so the
        // removal reads as one movement rather than a snap plus a delete.
        offset = translation > 0 ? 500 : -500
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            action.perform()
            // Safety net for the removal case: a row that survived anyway — because the
            // list refreshed underneath it, or because the action turned out to keep it —
            // settles back rather than staying bricked. By this point a row that really
            // was removed is long gone and this touches nothing.
            try? await Task.sleep(nanoseconds: 240_000_000)
            offset = 0
            committing = false
        }
    }
}
