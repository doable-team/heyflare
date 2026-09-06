import SwiftUI

// "Power through new": everything unseen in the Imbox, one thread to a screen, one
// decision per swipe. The point of the screen is that a decision is a deliberate act —
// scrolling past something does not file it, and nothing is marked seen until the reader
// says so at the end.

// MARK: - Store

// MARK: - Screen

struct PowerThroughView: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var store = PowerThroughStore()
    /// Which page is showing. Drives both the pager and the "3 of 12" count.
    @State private var current: String?
    @State private var moveTarget: ThreadSummary?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: progress) {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                if !store.items.isEmpty {
                    BarButton(icon: "checkmark.circle", label: "Mark all as seen") { markAll() }
                }
            }

            content
        }
        .screenBackground()
        .task {
            await store.firstLoad()
            if current == nil { current = store.items.first?.id }
        }
        .confirmationDialog(
            "Move to",
            isPresented: Binding(get: { moveTarget != nil }, set: { if !$0 { moveTarget = nil } }),
            titleVisibility: .visible,
            presenting: moveTarget
        ) { thread in
            Button("Imbox") { runner.run(thread, .move(.imbox), undo: .move(thread.bucket)) }
            Button("The Feed") { runner.run(thread, .move(.feed), undo: .move(thread.bucket)) }
            Button("Paper Trail") { runner.run(thread, .move(.paperTrail), undo: .move(thread.bucket)) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.items.isEmpty {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.refresh() }
            }
        } else if store.loading && store.items.isEmpty {
            ProgressView()
                .tint(Theme.Colors.mutedForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.items.isEmpty {
            EmptyState(
                icon: "checkmark",
                message: "Nothing new. Go enjoy your day. Anything you skipped is still in the Imbox.",
                actionTitle: "Back to the Imbox"
            ) {
                dismiss()
            }
            .frame(maxHeight: .infinity)
        } else {
            pager
        }
    }

    /// A paging scroll view rather than a rotated `TabView`: paging is native to the
    /// vertical axis in iOS 17, and a rotated tab view would turn every page upside down
    /// for VoiceOver's reading order.
    private var pager: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(store.items) { thread in
                    page(thread)
                        .containerRelativeFrame(.vertical)
                        .id(thread.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
    }

    // MARK: One page

    private func page(_ thread: ThreadSummary) -> some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                header(thread)

                Button {
                    nav.push(.thread(thread.id))
                } label: {
                    Text(thread.displaySubject)
                        .font(Theme.Typography.compactTitle)
                        .foregroundStyle(Theme.Colors.foreground)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Metrics.hPadding)
                        .padding(.top, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the thread")

                // The page cannot scroll — the outer view owns the gesture — so the body
                // is cut to whatever is left after the header and the actions, and the
                // rest is reached by opening the thread.
                messageBody(thread, cap: max(160, geo.size.height - 260))
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.top, 10)

                Spacer(minLength: 0)

                actions(thread)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    private func header(_ thread: ThreadSummary) -> some View {
        HStack(spacing: 10) {
            AvatarView(address: thread.lastFrom, size: Theme.Metrics.smallAvatar, emphasised: !thread.seen)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(thread.lastFrom.display)
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Colors.foreground)
                        .lineLimit(1)
                    if let glyph = app.glyph(for: thread.accountID) {
                        Text(glyph)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                }
                Text(thread.lastFrom.email)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(RelativeTime.short(thread.lastDate))
                .font(Theme.Typography.micro)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.mutedForeground)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 14)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func messageBody(_ thread: ThreadSummary, cap: CGFloat) -> some View {
        if let message = thread.latestMessage {
            MessageBody(message: message, cap: cap, expandable: false) { openURL($0) }
        } else {
            Text(thread.snippet)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions(_ thread: ThreadSummary) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                CardAction(icon: "arrowshape.turn.up.left", label: "Reply", showsLabel: true) {
                    reply(to: thread)
                }
                Spacer(minLength: 0)
                CardAction(icon: "clock", label: "Reply later") {
                    runner.run(thread, .replyLater(true), undo: .replyLater(false))
                }
                CardAction(icon: "tray.and.arrow.down", label: "Set aside") {
                    runner.run(thread, .setAside(true), undo: .setAside(false))
                }
                CardAction(icon: "folder", label: "Move") {
                    moveTarget = thread
                }
                CardAction(icon: "trash", label: "Trash") {
                    runner.run(thread, .move(.trash), undo: .move(thread.bucket))
                }
            }

            if isLast(thread) {
                Button {
                    markAll()
                } label: {
                    if store.marking {
                        ProgressView().tint(Theme.Colors.background)
                    } else {
                        Text("Mark all as seen")
                    }
                }
                .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
                .disabled(store.marking)
            } else {
                Button("Next") { next() }
                    .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .hairline(.top)
    }

    // MARK: Progress and movement

    private var index: Int? {
        guard let current else { return nil }
        return store.items.firstIndex { $0.id == current }
    }

    private var progress: String {
        guard !store.items.isEmpty else { return "Power through" }
        return "\((index ?? 0) + 1) of \(store.items.count)"
    }

    private func isLast(_ thread: ThreadSummary) -> Bool {
        store.items.last?.id == thread.id
    }

    private func next() {
        guard let index, index + 1 < store.items.count else { return }
        withAnimation(Theme.Motion.navigation) { current = store.items[index + 1].id }
    }

    /// When a card leaves, the page that slid into its place becomes the current one, so
    /// the counter and the "last card" test stay honest.
    private func advance(past index: Int) {
        guard !store.items.isEmpty else {
            current = nil
            return
        }
        current = store.items[min(index, store.items.count - 1)].id
    }

    // MARK: Actions

    private var runner: ThreadActionRunner {
        ThreadActionRunner(
            app: app,
            toasts: toasts,
            remove: { id in
                let index = store.remove(id)
                if let index { advance(past: index) }
                return index
            },
            restore: { thread, index in
                store.restore(thread, at: index)
                current = thread.id
            }
        )
    }

    private func reply(to thread: ThreadSummary) {
        guard let message = thread.latestMessage else {
            nav.push(.thread(thread.id))
            return
        }
        nav.composing = .reply(to: message, inSummary: thread)
    }

    /// The only thing on this screen that marks anything seen. Scrolling does not.
    private func markAll() {
        let count = store.items.count
        Task {
            if await store.markAllSeen() {
                Haptics.success()
                app.didMutate()
                toasts.show("Marked \(count) as seen")
                dismiss()
            } else if let error = store.error {
                toasts.error(error)
            }
        }
    }
}
