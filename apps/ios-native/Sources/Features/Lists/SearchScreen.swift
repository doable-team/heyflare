import SwiftUI

// Search: a field in the top bar and nothing else, because the results are the screen.

// MARK: - Store

// MARK: - Screen

struct SearchScreen: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var store = SearchStore()
    @State private var text = ""
    @State private var erasing: ThreadSummary?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The field takes the whole bar: there is no title worth the width here, and
            // `TopBar`'s leading slot expands into the space the spacer would have used.
            TopBar(title: "Search", titleVisible: false) {
                HStack(spacing: 4) {
                    BarButton(icon: "chevron.left", label: "Back") { dismiss() }
                    field
                }
                .frame(maxWidth: .infinity)
            } trailing: {
                if !text.isEmpty {
                    BarButton(icon: "xmark.circle.fill", label: "Clear search") {
                        text = ""
                        focused = true
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    content
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .screenBackground()
        .onAppear { focused = true }
        // Results are threads like any other list: one filed from its page on top of this
        // screen should be gone from the results when the page is popped.
        .syncsWithMail {
            let current = store.query
            if !current.isEmpty { await store.run(current) }
        }
        // `task(id:)` cancels the previous run whenever the text changes, so the sleep
        // below is the debounce: only the last keystroke of a burst survives it.
        .task(id: text) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                store.clear()
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await store.run(trimmed)
        }
        .confirmationDialog(
            "Delete this thread for good?",
            isPresented: Binding(get: { erasing != nil }, set: { if !$0 { erasing = nil } }),
            titleVisibility: .visible,
            presenting: erasing
        ) { thread in
            Button("Delete permanently", role: .destructive) {
                // No inverse exists for `delete`, so nothing is offered as an Undo. The
                // confirmation is the whole safety net.
                runner.run(thread, .delete, undo: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Colors.mutedForeground)
                .accessibilityHidden(true)

            TextField("Search mail", text: $text)
                .font(Theme.Typography.large)
                .foregroundStyle(Theme.Colors.foreground)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .accessibilityLabel("Search mail")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.muted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if typed.isEmpty {
            EmptyState(icon: "magnifyingglass", message: "Search subjects, people and message text.")
        } else if let error = store.error {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.run(typed) }
            }
        } else if store.searching && !store.hasResults {
            ProgressView()
                .tint(Theme.Colors.mutedForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if !store.hasResults {
            // Only claim there are no matches once a search for this text has landed.
            if store.query == typed {
                EmptyState(icon: "magnifyingglass", message: "No matches. Try fewer words, or a name.")
            } else {
                Color.clear.frame(height: 1)
            }
        } else {
            ForEach(store.threads) { thread in
                row(thread)
            }

            if store.hasMore {
                ProgressView()
                    .tint(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .onAppear { Task { await store.loadMore() } }
            }

            Color.clear.frame(height: 24)
        }
    }

    private func row(_ thread: ThreadSummary) -> some View {
        Button {
            nav.push(.thread(thread.id))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ThreadRow(thread: thread, glyph: app.glyph(for: thread.accountID))
                bucketCaption(thread.bucket)
            }
        }
        .buttonStyle(PressableRowStyle())
        .contextMenu { menu(for: thread) }
        .hairline(.bottom)
    }

    /// Which pile the hit was found in.
    ///
    /// Search is the one list that spans every bucket, so a result without this reads as
    /// though it were in the Imbox. The web build hides the caption for Imbox hits; this
    /// one shows it for all of them, because a caption that disappears on the commonest
    /// case cannot be told apart from a caption that failed to render.
    private func bucketCaption(_ bucket: Bucket) -> some View {
        Text(bucket.title.uppercased())
            .font(Theme.Typography.caps)
            .tracking(0.6)
            .foregroundStyle(Theme.Colors.mutedForeground)
            // Lined up with the row's text column rather than the screen edge: avatar,
            // plus the gap `ThreadRow` puts after it.
            .padding(.leading, Theme.Metrics.hPadding + Theme.Metrics.avatar + 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("In \(bucket.title)")
    }

    /// The Imbox's menu, adapted to whichever bucket this particular hit came out of.
    @ViewBuilder
    private func menu(for thread: ThreadSummary) -> some View {
        if thread.bucket == .trash {
            Button { runner.run(thread, .move(.imbox), undo: .move(.trash)) } label: {
                SwiftUI.Label("Restore to Imbox", systemImage: "tray")
            }
            Button { runner.run(thread, .move(.paperTrail), undo: .move(.trash)) } label: {
                SwiftUI.Label("Restore to Paper Trail", systemImage: "doc.text")
            }
            Divider()
            Button(role: .destructive) { erasing = thread } label: {
                SwiftUI.Label("Delete permanently", systemImage: "trash")
            }
        } else {
            Button { runner.run(thread, .replyLater(!thread.replyLater), undo: .replyLater(thread.replyLater)) } label: {
                SwiftUI.Label(thread.replyLater ? "Remove from Reply Later" : "Reply later",
                              systemImage: "arrowshape.turn.up.left")
            }
            Button { runner.run(thread, .setAside(!thread.setAside), undo: .setAside(thread.setAside)) } label: {
                SwiftUI.Label(thread.setAside ? "Remove from Set Aside" : "Set aside", systemImage: "tray.and.arrow.down")
            }
            Button { toggleRead(thread) } label: {
                SwiftUI.Label(thread.unread ? "Mark read" : "Mark unread", systemImage: "envelope")
            }
            Divider()
            if thread.bucket != .imbox {
                Button { runner.run(thread, .move(.imbox), undo: .move(thread.bucket)) } label: {
                    SwiftUI.Label("Move to Imbox", systemImage: "tray")
                }
            }
            if thread.bucket != .feed {
                Button { runner.run(thread, .move(.feed), undo: .move(thread.bucket)) } label: {
                    SwiftUI.Label("Move to The Feed", systemImage: "dot.radiowaves.up.forward")
                }
            }
            if thread.bucket != .paperTrail {
                Button { runner.run(thread, .move(.paperTrail), undo: .move(thread.bucket)) } label: {
                    SwiftUI.Label("Move to Paper Trail", systemImage: "doc.text")
                }
            }
            Button(role: .destructive) { runner.run(thread, .move(.trash), undo: .move(thread.bucket)) } label: {
                SwiftUI.Label("Trash", systemImage: "trash")
            }
        }
    }

    // MARK: Actions

    private var runner: ThreadActionRunner {
        ThreadActionRunner(
            app: app,
            toasts: toasts,
            remove: { store.remove($0) },
            restore: { store.restore($0, at: $1) }
        )
    }

    /// Marking a result read does not stop it matching, so the row stays where it is.
    private func toggleRead(_ thread: ThreadSummary) {
        let makeUnread = !thread.unread
        let action: ThreadAction = makeUnread ? .markUnread : .markRead
        store.update(thread.id) { row in
            row.unread = makeUnread
            if !makeUnread { row.seen = true }
        }
        Haptics.select()

        Task {
            do {
                try await APIClient.shared.act(thread.id, action)
                app.didMutate()
                toasts.show(action.confirmation)
            } catch {
                store.update(thread.id) { $0.unread = !makeUnread }
                toasts.error(ThreadActionRunner.describe(error))
            }
        }
    }
}
