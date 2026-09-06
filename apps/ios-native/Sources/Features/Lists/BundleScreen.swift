import SwiftUI

// A bundle is one sender's batch of mail collapsed into a single row in the Imbox or the
// Paper Trail. Opening it should read like the Feed — every thread already expanded, in
// one pass — rather than like a folder you then have to walk.

// MARK: - Model

// MARK: - Store

// MARK: - Screen

struct BundleScreen: View {
    /// The row that was tapped. It carries enough to draw the header immediately, so the
    /// screen has a title and a face before the request comes back.
    let bundle: MailBundle

    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var store = BundleStore()
    @State private var collapsed = false

    private static let space = "bundle.scroll"

    private var current: MailBundle { store.detail?.bundle ?? bundle }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: current.address.display, titleVisible: collapsed) {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                if !store.closed {
                    BarButton(icon: "checkmark.circle", label: "Mark all seen") { markAllSeen() }
                }
            }

            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ScrollOffsetProbe(space: Self.space)
                        header
                        content(viewportHeight: geo.size.height)
                    }
                }
                .coordinateSpace(name: Self.space)
                .refreshable { await store.refresh(bundle.id) }
            }
        }
        .screenBackground()
        .onPreferenceChange(ScrollOffsetKey.self) { [collapsed = $collapsed] offset in
            collapsed.wrappedValue = offset < -30
        }
        .task { await store.firstLoad(bundle.id) }
        .syncsWithMail { await store.refresh(bundle.id) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AvatarView(address: current.address, size: 40, emphasised: current.isOpen)

            VStack(alignment: .leading, spacing: 2) {
                Text(current.address.display)
                    .font(Theme.Typography.section)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)
                Text(counts)
                    .font(Theme.Typography.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var counts: String {
        let messages = current.messageCount
        let threads = current.threadCount
        return "\(messages) \(messages == 1 ? "message" : "messages") · \(threads) \(threads == 1 ? "thread" : "threads")"
    }

    @ViewBuilder
    private func content(viewportHeight: CGFloat) -> some View {
        if let error = store.error, store.threads.isEmpty {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.refresh(bundle.id) }
            }
        } else if store.loading && store.threads.isEmpty {
            ProgressView()
                .tint(Theme.Colors.mutedForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if store.threads.isEmpty {
            EmptyState(icon: "square.stack", message: "This batch is empty.")
        } else {
            ForEach(store.threads) { thread in
                card(thread, viewportHeight: viewportHeight)
            }

            if !store.closed {
                Button {
                    markAllSeen()
                } label: {
                    if store.marking {
                        ProgressView().tint(Theme.Colors.foreground)
                    } else {
                        Text("Mark all seen")
                    }
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(store.marking)
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.vertical, 20)
            } else {
                Color.clear.frame(height: 24)
            }
        }
    }

    private func card(_ thread: ThreadSummary, viewportHeight: CGFloat) -> some View {
        FeedCard(
            thread: thread,
            glyph: app.glyph(for: thread.accountID),
            scrollSpace: Self.space,
            viewportHeight: viewportHeight,
            onOpen: { nav.push(.thread(thread.id)) },
            onLink: { openURL($0) }
        ) {
            HStack(spacing: 0) {
                CardAction(icon: "arrowshape.turn.up.left", label: "Reply", showsLabel: true) {
                    reply(to: thread)
                }
                Spacer(minLength: 0)
                CardAction(icon: "tray.and.arrow.down", label: "Set aside") {
                    runner.run(thread, .setAside(true), undo: .setAside(false))
                }
                CardAction(icon: "trash", label: "Trash") {
                    runner.run(thread, .move(.trash), undo: .move(thread.bucket))
                }
            }
            .padding(.horizontal, 8)
            .hairline(.top)
        }
    }

    private var runner: ThreadActionRunner {
        ThreadActionRunner(
            app: app,
            toasts: toasts,
            remove: { store.remove($0) },
            restore: { store.restore($0, at: $1) }
        )
    }

    private func reply(to thread: ThreadSummary) {
        guard let message = thread.latestMessage else {
            nav.push(.thread(thread.id))
            return
        }
        nav.composing = .reply(to: message, inSummary: thread)
    }

    /// Marking seen closes the batch rather than touching individual threads, which is why
    /// this is a bundle endpoint and not a bulk thread action.
    private func markAllSeen() {
        Task {
            if await store.markAllSeen(bundle.id) {
                Haptics.success()
                app.didMutate()
                toasts.show("Marked as seen")
            } else if let error = store.error {
                toasts.error(error)
            }
        }
    }
}
