import SwiftUI

// The Feed, plus the card pieces the bundle and power-through screens reuse.
//
// DESIGN.md §8 asks for "cards full-bleed with the message body; sticky per-card footer
// actions". Everything below that is shared — the message body, the card, the collapsing
// large title, the optimistic action-with-undo — lives here rather than in a fourth file
// so there is exactly one implementation of each.

// MARK: - Compose

// MARK: - Feed filter

// MARK: - Store

// MARK: - Screen

struct FeedView: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL

    @State private var store = FeedStore()
    @State private var collapsed = false
    @State private var show: FeedFilter = .new
    @State private var unsubscribing: UnsubscribeRequest?

    /// One pending unsubscribe, held while the reader confirms it.
    struct UnsubscribeRequest: Identifiable {
        /// The thread it came from, which is unique on screen.
        let id: String
        let sender: String
        let url: URL

        /// A mailto: target opens the mail composer rather than a web page, and the
        /// button should say which of the two is about to happen.
        var isMail: Bool { url.scheme?.lowercased() == "mailto" }
    }

    private static let space = "feed.scroll"

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "The Feed", titleVisible: collapsed) {
                // The Feed is reached from More now rather than from a tab, so it needs
                // a way back the way every other pushed screen has one.
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                filterToggle
                BarButton(icon: "magnifyingglass", label: "Search") { nav.push(.search) }
            }

            // The cards need the viewport's height to place their sticky footers, and this
            // is the cheapest place to learn it.
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ScrollOffsetProbe(space: Self.space)
                        LargeTitle(title: "The Feed", subtitle: "Newsletters and long reads. Scroll, don't sort.")
                        content(viewportHeight: geo.size.height)
                    }
                }
                .coordinateSpace(name: Self.space)
                .refreshable { await store.refresh(show) }
            }
        }
        .screenBackground()
        // The binding is captured instead of `self` so the callback holds nothing that
        // outlives the update — the whole view, environment included, would otherwise be
        // retained by an escaping closure.
        .onPreferenceChange(ScrollOffsetKey.self) { [collapsed = $collapsed] offset in
            collapsed.wrappedValue = offset < -30
        }
        .task { await store.firstLoad(show) }
        .syncsWithMail { await store.refresh(show) }
        .onChange(of: show) { _, next in
            // The filter is part of the request, so the cards on screen no longer answer
            // it. They stay up until the new ones land rather than blanking the screen.
            Task { await store.refresh(next) }
        }
        .confirmationDialog(
            unsubscribing.map { "Unsubscribe from \($0.sender)?" } ?? "Unsubscribe",
            isPresented: Binding(get: { unsubscribing != nil }, set: { if !$0 { unsubscribing = nil } }),
            titleVisibility: .visible,
            presenting: unsubscribing
        ) { request in
            // Confirmed rather than immediate, and handed straight to the system: leaving
            // the app is not something the app can take back, so there is no Undo to
            // offer and the reader has to mean it.
            Button(request.isMail ? "Email the sender" : "Open unsubscribe page") {
                openURL(request.url)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.isMail
                 ? "This opens a message to the sender's unsubscribe address. It cannot be undone from here."
                 : "This opens the sender's page outside heyflare. It cannot be undone from here.")
        }
    }

    /// New / All, the way the web build offers it beside the title. Two segments rather
    /// than a system `Picker`, which would bring its own tint with it.
    private var filterToggle: some View {
        HStack(spacing: 0) {
            ForEach(FeedFilter.allCases, id: \.self) { filter in
                let on = show == filter
                Button {
                    guard !on else { return }
                    Haptics.select()
                    show = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 13, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.Colors.background : Theme.Colors.mutedForeground)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(on ? Theme.Colors.foreground : Color.clear, in: Capsule())
                        // The pill reads at 30pt; the target around it is the full 44.
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filter == .new ? "Show new only" : "Show everything")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .background(alignment: .center) {
            Capsule().fill(Theme.Colors.muted).frame(height: 30)
        }
    }

    @ViewBuilder
    private func content(viewportHeight: CGFloat) -> some View {
        if let error = store.error, store.threads.isEmpty {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.refresh(show) }
            }
        } else if store.loading && store.threads.isEmpty {
            ProgressView()
                .tint(Theme.Colors.mutedForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if store.threads.isEmpty {
            EmptyState(
                icon: "dot.radiowaves.up.forward",
                message: show == .new
                    ? "Nothing new in your Feed. Switch to All to see what you have already been through."
                    : "Your Feed is quiet. Screen a newsletter into The Feed and it shows up here, fully opened."
            )
        } else {
            ForEach(store.threads) { thread in
                card(thread, viewportHeight: viewportHeight)
            }

            if store.hasMore {
                ProgressView()
                    .tint(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .onAppear { Task { await store.loadMore(show) } }
            }

            Color.clear.frame(height: 28)
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
            // Seven actions where there were four, so every one of them is icon-only and
            // takes an equal share of the width. Written labels would push the row past
            // a 360pt screen; the names still reach VoiceOver through `CardAction`.
            HStack(spacing: 0) {
                CardAction(icon: "checkmark", label: "Done", fills: true) {
                    done(thread)
                }
                CardAction(icon: "arrowshape.turn.up.left", label: "Reply", fills: true) {
                    reply(to: thread)
                }
                // Set Aside flags the card; it does not file it away. See `flag(_:_:)`.
                CardAction(icon: thread.setAside ? "tray.and.arrow.up" : "tray.and.arrow.down",
                           label: thread.setAside ? "Remove from Set Aside" : "Set aside",
                           fills: true) {
                    flag(thread, .setAside(!thread.setAside))
                }
                CardAction(icon: "tray", label: "Move to Imbox", fills: true) {
                    runner.run(thread, .move(.imbox), undo: .move(thread.bucket))
                }
                CardAction(icon: "doc.text", label: "Move to Paper Trail", fills: true) {
                    runner.run(thread, .move(.paperTrail), undo: .move(thread.bucket))
                }
                if let request = unsubscribeRequest(for: thread) {
                    CardAction(icon: "bell.slash", label: "Unsubscribe", fills: true) {
                        unsubscribing = request
                    }
                }
                CardAction(icon: "trash", label: "Trash", fills: true) {
                    runner.run(thread, .move(.trash), undo: .move(thread.bucket))
                }
            }
            .padding(.horizontal, 4)
            .hairline(.top)
        }
    }

    /// Move and Trash go through the shared runner, because they really do take the thread
    /// out of the Feed: `GET /api/feed` selects on `bucket = 'feed'`, so a moved card is
    /// gone from the next page as well as from this screen.
    private var runner: ThreadActionRunner {
        ThreadActionRunner(
            app: app,
            toasts: toasts,
            remove: { store.remove($0) },
            restore: { store.restore($0, at: $1) }
        )
    }

    /// Done — the control that empties the Feed. It is `seen`, which is exactly what the
    /// default filter selects against, so on New the card leaves and on All it stays.
    ///
    /// Written out rather than handed to `ThreadActionRunner` for two reasons: the runner
    /// always removes the row, which is wrong under All, and it would toast the action's
    /// own wording ("Marked read") rather than the word on the button.
    private func done(_ thread: ThreadSummary) {
        let leaves = show == .new
        var index: Int?
        if leaves {
            index = store.remove(thread.id)
        } else {
            withAnimation(Theme.Motion.quick) {
                _ = store.update(thread.id) { $0.seen = true; $0.unread = false }
            }
        }
        Haptics.success()

        func putBack() {
            if leaves {
                if let index { store.restore(thread, at: index) }
            } else {
                withAnimation(Theme.Motion.quick) {
                    _ = store.update(thread.id) { $0.seen = false; $0.unread = true }
                }
            }
        }

        Task { @MainActor in
            do {
                try await APIClient.shared.act(thread.id, .seen)
                app.didMutate()
                // `mark_unread` is the server's inverse of `seen`: it clears the flag the
                // Feed selects on, so the card comes back where it was.
                toasts.show("Done", undo: { @MainActor in
                    do {
                        try await APIClient.shared.act(thread.id, .markUnread)
                        putBack()
                        app.didMutate()
                    } catch {
                        toasts.error(ThreadActionRunner.describe(error))
                    }
                })
            } catch {
                putBack()
                toasts.error(ThreadActionRunner.describe(error))
            }
        }
    }

    /// Reply Later and Set Aside, applied to the card in place instead of removing it.
    ///
    /// The Feed's query is `bucket = 'feed' AND visible AND seen = 0` — it does not exclude
    /// `set_aside` or `reply_later`. Sliding the card off screen would therefore promise
    /// something the server never did: the next pull to refresh brings it straight back,
    /// which reads as the action having failed. Flagging it where it stands is what actually
    /// happened, and the toast still carries the undo.
    @MainActor
    private func flag(_ thread: ThreadSummary, _ action: ThreadAction) {
        let undo: ThreadAction
        switch action {
        case .setAside(let on): undo = .setAside(!on)
        case .replyLater(let on): undo = .replyLater(!on)
        default: return
        }

        func apply(_ change: ThreadAction) {
            store.update(thread.id) { row in
                switch change {
                case .setAside(let on): row.setAside = on
                case .replyLater(let on): row.replyLater = on
                default: break
                }
            }
        }

        withAnimation(Theme.Motion.quick) { apply(action) }
        Haptics.success()

        Task { @MainActor in
            do {
                try await APIClient.shared.act(thread.id, action)
                app.didMutate()
                toasts.show(action.confirmation, undo: { @MainActor in
                    do {
                        try await APIClient.shared.act(thread.id, undo)
                        withAnimation(Theme.Motion.quick) { apply(undo) }
                        app.didMutate()
                    } catch {
                        toasts.error(ThreadActionRunner.describe(error))
                    }
                })
            } catch {
                // The optimistic flag was a guess about the server; put it back.
                withAnimation(Theme.Motion.quick) { apply(undo) }
                toasts.error(ThreadActionRunner.describe(error))
            }
        }
    }

    private func reply(to thread: ThreadSummary) {
        // Without the message there is nothing to quote, so hand the reader the thread
        // instead of an empty composer.
        guard let message = thread.latestMessage else {
            nav.push(.thread(thread.id))
            return
        }
        nav.composing = .reply(to: message, inSummary: thread)
    }

    /// The unsubscribe target this card offers, or `nil` when the sender gave none — in
    /// which case the action is not drawn at all rather than drawn and dead.
    private func unsubscribeRequest(for thread: ThreadSummary) -> UnsubscribeRequest? {
        guard let header = thread.latestMessage?.listUnsubscribe,
              let url = Self.unsubscribeTarget(header) else { return nil }
        return UnsubscribeRequest(id: thread.id, sender: thread.lastFrom.display, url: url)
    }

    /// `List-Unsubscribe` carries a comma-separated list of angle-bracketed targets:
    /// a mailto:, an https:, or both. Parsed the way the thread view parses it, and for
    /// the same reason — the web target is a page a person can read before committing,
    /// where the mail target sends something on their behalf.
    private static func unsubscribeTarget(_ header: String) -> URL? {
        let candidates = header
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
            .filter { !$0.isEmpty }
        guard let target = candidates.first(where: { $0.lowercased().hasPrefix("https://") }) ?? candidates.first
        else { return nil }
        return URL(string: target)
    }
}
