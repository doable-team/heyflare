import SwiftUI

// MARK: - Screen

struct ImboxView: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts

    @State private var store = ImboxStore()
    @State private var offset: CGFloat = 0
    @State private var showingScope = false
    @State private var showingTray: TrayKind?

    /// Selection is held as ids, not threads: a refresh replaces every row on the screen
    /// and a selection held by value would go stale under it.
    @State private var selection: Set<String> = []
    @State private var selecting = false
    /// When the long press opened selection mode, so the release that ends it is not
    /// also taken as a tap that unticks the row it just picked.
    @State private var selectionOpenedAt = Date.distantPast
    @State private var showingBubbleUp = false
    @State private var showingMove = false

    private enum TrayKind: Identifiable {
        case replyLater, setAside
        var id: Int { self == .replyLater ? 0 : 1 }
        var title: String { self == .replyLater ? "Reply Later" : "Set Aside" }
        var icon: String { self == .replyLater ? "arrowshape.turn.up.left" : "tray.and.arrow.down" }
    }

    /// The large title has scrolled away once the content has moved about its height.
    private var compactTitle: Bool { offset < -36 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                topBar

                RefreshableScroll(onRefresh: refresh, offset: $offset) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        LargeTitle(title: "Imbox", subtitle: app.scopeLabel) { showingScope = true }

                        if let error = store.error, !store.loaded {
                            InlineError(message: error) { Task { await store.refresh() } }
                        }

                        if store.data.screenerCount > 0 { screenerBanner }

                        newSection
                        seenSection

                        if store.loaded && store.data.isEmpty {
                            EmptyState(
                                icon: "tray",
                                message: app.accounts.isEmpty
                                    ? "No mailbox is connected yet. Connect one from the web app."
                                    : "Nothing new. The Imbox is clear."
                            )
                        }

                        // Clears the trays and the FAB.
                        Color.clear.frame(height: 96)
                    }
                }
                .overlay(alignment: .top) {
                    if store.loading {
                        ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 40)
                    }
                }

                // A sibling of the scroll view rather than an overlay: the list gives up
                // the height instead of hiding its last rows behind the bar.
                if selecting { actionBar }
            }

            // The piles and the compose button share one row: the piles read left, the
            // way the web build docks them, and the thumb still finds compose where it
            // expects it on the right. Both stand down while a selection is open — the
            // action bar is what the thumb is reaching for then.
            if !selecting {
                HStack(alignment: .bottom, spacing: 8) {
                    trays
                    Spacer(minLength: 8)
                    ComposeButton { nav.composing = .new(accountID: app.scopedAccount?.id) }
                }
            }
        }
        .screenBackground()
        .task { await store.load() }
        .onChange(of: app.scope) { _, _ in
            // The scope header changes the request, so the cached screen no longer
            // answers it. Without this the list kept showing the previous mailbox — and
            // a selection made in the old mailbox has nothing left to act on.
            endSelection()
            Task { await store.refresh() }
        }
        // Every other screen's actions reach this one through the bus: a thread read on
        // its own page, a reply sent, a decision in the Screener. Paused while a selection
        // is open so the rows are not swapped out under it; caught up the moment it ends.
        .syncsWithMail(enabled: !selecting) { await store.refresh() }
        .sheet(isPresented: $showingScope) { ScopeSheet() }
        .sheet(item: $showingTray) { tray in
            TraySheet(
                title: tray.title,
                threads: tray == .replyLater ? store.data.replyLater : store.data.setAside,
                onOpen: { id in showingTray = nil; nav.push(.thread(id)) }
            )
        }
        .confirmationDialog("Bubble up", isPresented: $showingBubbleUp, titleVisibility: .visible) { bubbleUpOptions }
        .confirmationDialog("Move to", isPresented: $showingMove, titleVisibility: .visible) { moveOptions }
    }

    // MARK: Chrome

    @ViewBuilder
    private var topBar: some View {
        if selecting {
            TopBar(title: "\(selected.count) selected", titleVisible: true) {
                barText("Cancel", label: "Cancel selection") { endSelection() }
            } trailing: {
                let all = allSelected
                barText(all ? "None" : "All", label: all ? "Deselect all" : "Select all") {
                    selection = all ? [] : Set(store.visibleThreads.map(\.id))
                    Haptics.select()
                }
            }
        } else {
            TopBar(title: "Imbox", titleVisible: compactTitle) {
                BarButton(icon: "magnifyingglass", label: "Search") { nav.push(.search) }
            } trailing: {
                BarButton(icon: "bolt", label: "Power through new") { nav.push(.powerThrough) }
            }
        }
    }

    /// A text button in the bar, sized to the same 44pt target the icon buttons use.
    private func barText(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.foreground)
            .frame(height: Theme.Metrics.minTouchTarget)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    /// The same five bulk actions the list screens dock, in the same order.
    private var actionBar: some View {
        HStack(spacing: 0) {
            barAction("clock", "Reply later") {
                bulk.run(selected, .replyLater(true), undo: .action(.replyLater(false)))
                endSelection()
            }
            barAction("tray.and.arrow.down", "Set aside") {
                bulk.run(selected, .setAside(true), undo: .action(.setAside(false)))
                endSelection()
            }
            barAction("arrow.up.circle", "Bubble up") { showingBubbleUp = true }
            barAction("folder", "Move") { showingMove = true }
            barAction("trash", "Trash") {
                bulk.run(selected, .move(.trash), undo: .buckets)
                endSelection()
            }
        }
        .frame(height: 56)
        .background(Theme.Colors.chrome)
        .background(.ultraThinMaterial)
        .hairline(.top)
        // Deselecting everything leaves the bar in place but inert, so it does not jump
        // away and back while a selection is being adjusted.
        .disabled(selected.isEmpty)
        .opacity(selected.isEmpty ? 0.4 : 1)
    }

    private func barAction(_ icon: String, _ label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(Theme.Colors.foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Sections

    private var screenerBanner: some View {
        Button {
            nav.select(.screener)
        } label: {
            HStack(spacing: 12) {
                AvatarStack(addresses: store.data.screenerSenders.map(\.address))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.data.screenerCount) \(store.data.screenerCount == 1 ? "person is" : "people are") waiting")
                        .font(Theme.Typography.bodyStrong)
                        .foregroundStyle(Theme.Colors.foreground)
                    Text("Decide once, for every account")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            .padding(14)
            .frame(minHeight: Theme.Metrics.minTouchTarget)
            .background(Theme.Colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var newSection: some View {
        let bundles = store.data.bundles.filter(\.isOpen)
        if !store.data.newThreads.isEmpty || !bundles.isEmpty {
            Section {
                ForEach(bundles) { bundle in
                    Button { nav.push(.bundle(bundle)) } label: {
                        BundleRow(bundle: bundle, glyph: app.glyph(for: bundle.accountID))
                    }
                    .buttonStyle(PressableRowStyle())
                    .hairline()
                }
                ForEach(store.data.newThreads) { thread in
                    row(thread)
                }
            } header: {
                SectionHeader(title: "New for you", trailing: "\(store.data.newThreads.count + bundles.count)")
                    .background(Theme.Colors.background)
            }
        }
    }

    @ViewBuilder
    private var seenSection: some View {
        // Bundles the reader has already been through still belong on the screen. The
        // worker returns them alongside the open ones, and their threads are excluded
        // from `seen_threads`, so dropping them here hid that sender's mail entirely.
        let seenBundles = store.data.bundles.filter { !$0.isOpen }
        if !store.data.seenThreads.isEmpty || !seenBundles.isEmpty {
            Section {
                ForEach(seenBundles) { bundle in
                    Button { nav.push(.bundle(bundle)) } label: {
                        BundleRow(bundle: bundle, glyph: app.glyph(for: bundle.accountID))
                    }
                    .buttonStyle(PressableRowStyle())
                    .hairline()
                }
                ForEach(store.data.seenThreads) { thread in
                    row(thread)
                }
            } header: {
                SectionHeader(title: "Previously seen")
                    .background(Theme.Colors.background)
            }
        }
    }

    private func row(_ thread: ThreadSummary) -> some View {
        let picked = selection.contains(thread.id)

        // Both swipes keep their row — ticking a box and turning read state over move a
        // thread nowhere — so each settles back on release instead of flying off, and
        // both stay attached while a selection is open.
        return SwipeRow(
            leading: .init(icon: "checkmark.circle", label: "Select", resets: true) {
                if selecting { toggle(thread) } else { beginSelection(with: thread) }
            },
            trailing: .init(
                icon: thread.unread ? "envelope.open" : "envelope",
                label: thread.unread ? "Read" : "Unread",
                resets: true
            ) {
                act(thread, thread.unread ? .markRead : .markUnread,
                    undo: thread.unread ? .markUnread : .markRead)
            }
        ) {
            Button {
                guard selecting else {
                    nav.push(.thread(thread.id))
                    return
                }
                // The press that opens selection mode is still a press: the button can
                // take its release as a tap and immediately untick the row the long
                // press just picked. Taps in the moment after it opened are that echo.
                guard Date().timeIntervalSince(selectionOpenedAt) > 0.5 else { return }
                toggle(thread)
            } label: {
                HStack(spacing: 0) {
                    if selecting { checkmark(picked) }
                    ThreadRow(thread: thread, glyph: app.glyph(for: thread.accountID), showsSnippet: app.showsPreviews)
                }
            }
            .buttonStyle(PressableRowStyle())
            .accessibilityAddTraits(picked ? .isSelected : [])
            .rowContextMenu(enabled: !selecting) { menu(for: thread) }
            // Fires before UIKit's own half-second press, so the context menu is off the
            // row by the time it would have presented. The menu carries "Select" too,
            // for the press where it wins the race.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35).onEnded { _ in beginSelection(with: thread) }
            )
        }
        .hairline()
    }

    private func checkmark(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(on ? Theme.Colors.foreground : Theme.Colors.border)
            .frame(width: 44, height: 44)
            .padding(.leading, 2)
            // The row already carries the `.isSelected` trait; a second announcement
            // would read the state twice.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func menu(for thread: ThreadSummary) -> some View {
        Button { beginSelection(with: thread) } label: {
            SwiftUI.Label("Select", systemImage: "checkmark.circle")
        }
        Divider()
        Button { act(thread, .replyLater(!thread.replyLater), undo: .replyLater(thread.replyLater)) } label: {
            SwiftUI.Label(thread.replyLater ? "Remove from Reply Later" : "Reply later",
                          systemImage: "arrowshape.turn.up.left")
        }
        Button { act(thread, .setAside(!thread.setAside), undo: .setAside(thread.setAside)) } label: {
            SwiftUI.Label(thread.setAside ? "Remove from Set Aside" : "Set aside", systemImage: "tray.and.arrow.down")
        }
        Button { act(thread, thread.unread ? .markRead : .markUnread, undo: thread.unread ? .markUnread : .markRead) } label: {
            SwiftUI.Label(thread.unread ? "Mark read" : "Mark unread", systemImage: "envelope")
        }
        Divider()
        Button { act(thread, .move(.feed), undo: .move(thread.bucket)) } label: {
            SwiftUI.Label("Move to The Feed", systemImage: "dot.radiowaves.up.forward")
        }
        Button { act(thread, .move(.paperTrail), undo: .move(thread.bucket)) } label: {
            SwiftUI.Label("Move to Paper Trail", systemImage: "doc.text")
        }
        Button(role: .destructive) { act(thread, .move(.trash), undo: .move(thread.bucket)) } label: {
            SwiftUI.Label("Trash", systemImage: "trash")
        }
    }

    // MARK: Trays

    @ViewBuilder
    private var trays: some View {
        let piles: [(TrayKind, [ThreadSummary])] = [
            (.replyLater, store.data.replyLater),
            (.setAside, store.data.setAside),
        ].filter { !$0.1.isEmpty }

        if !piles.isEmpty {
            HStack(spacing: 8) {
                ForEach(piles, id: \.0.id) { kind, threads in
                    Button { showingTray = kind } label: {
                        // No icon: the stack of faces already says what kind of thing
                        // this is, and two pills plus the compose button have to fit
                        // across a 375pt phone without the labels truncating.
                        HStack(spacing: 8) {
                            ThreadPile(threads: threads)
                            Text(kind.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .fixedSize(horizontal: true, vertical: false)
                            Text("\(threads.count)")
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.Colors.mutedForeground)
                        }
                        .foregroundStyle(Theme.Colors.foreground)
                        // A capsule needs more inset than a rectangle would: the curve
                        // eats into the corner, so 5pt read as the avatar touching it.
                        .padding(.leading, 8)
                        .padding(.trailing, 12)
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .background(Theme.Colors.background)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(kind.title), \(threads.count)")
                }
            }
            .padding(.leading, Theme.Metrics.hPadding)
            .padding(.bottom, 12)
        }
    }

    // MARK: Selection

    private var selected: [ThreadSummary] { store.threads(with: selection) }

    private var allSelected: Bool {
        let visible = store.visibleThreads
        return !visible.isEmpty && selection.count == visible.count
    }

    private func beginSelection(with thread: ThreadSummary) {
        guard !selecting else { return }
        Haptics.threshold()
        selectionOpenedAt = Date()
        withAnimation(Theme.Motion.quick) {
            selecting = true
            selection = [thread.id]
        }
    }

    private func toggle(_ thread: ThreadSummary) {
        Haptics.select()
        withAnimation(Theme.Motion.quick) {
            if selection.contains(thread.id) { selection.remove(thread.id) }
            else { selection.insert(thread.id) }
        }
    }

    private func endSelection() {
        withAnimation(Theme.Motion.quick) {
            selecting = false
            selection = []
        }
    }

    /// The Imbox answers in one request, so putting a bulk action back is a reload
    /// rather than a replay of where each row sat. `remove` hands back nothing for the
    /// same reason: there is no index worth remembering across five sections.
    private var bulk: BulkActionRunner {
        BulkActionRunner(
            app: app,
            toasts: toasts,
            remove: { ids in store.removeMany(ids); return [] },
            restore: { _ in Task { await store.refresh() } }
        )
    }

    @ViewBuilder
    private var bubbleUpOptions: some View {
        Button("In 3 hours") { bubbleUp(Date().addingTimeInterval(3 * 3600)) }
        if let evening = Self.laterToday(hour: 18) {
            Button("This evening") { bubbleUp(evening) }
        }
        Button("Tomorrow morning") { bubbleUp(Self.tomorrow(hour: 8)) }
        Button("Next week") { bubbleUp(Self.nextWeek()) }
        Button("Cancel", role: .cancel) {}
    }

    private func bubbleUp(_ date: Date) {
        bulk.run(selected, .bubbleUp(date), undo: .action(.bubbleUp(nil)))
        endSelection()
    }

    @ViewBuilder
    private var moveOptions: some View {
        Button("The Feed") { move(.feed) }
        Button("Paper Trail") { move(.paperTrail) }
        Button("Cancel", role: .cancel) {}
    }

    private func move(_ bucket: Bucket) {
        bulk.run(selected, .move(bucket), undo: .buckets)
        endSelection()
    }

    /// Today at `hour`, or `nil` when that moment has already gone by.
    private static func laterToday(hour: Int, now: Date = Date()) -> Date? {
        let cal = Calendar.current
        guard let today = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now), today > now else { return nil }
        return today
    }

    private static func tomorrow(hour: Int, now: Date = Date()) -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(24 * 3600)
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    private static func nextWeek(now: Date = Date()) -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 24 * 3600)
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: base) ?? base
    }

    // MARK: Behaviour

    private func refresh() async {
        // Refreshing while a selection is open would swap the rows out from under it.
        guard !selecting else { return }
        // Ask the mailboxes to pull before reading, so a manual refresh can actually
        // surface new mail rather than just redrawing what the cron last stored.
        await app.syncAll()
        await store.refresh()
        app.didMutate()
    }

    /// Runs an action optimistically, then offers its inverse as an Undo.
    private func act(_ thread: ThreadSummary, _ action: ThreadAction, undo: ThreadAction?) {
        // Read state changes the row; everything else moves the thread out of the Imbox.
        switch action {
        case .markRead, .seen:
            store.update(thread.id) { $0.unread = false; $0.seen = true }
        case .markUnread:
            store.update(thread.id) { $0.unread = true }
        default:
            store.remove(thread.id)
        }
        Haptics.select()
        Task {
            do {
                try await APIClient.shared.act(thread.id, action)
                app.didMutate()
                toasts.show(action.confirmation, undo: undo.map { inverse in
                    {
                        _ = try? await APIClient.shared.act(thread.id, inverse)
                        await store.refresh()
                        app.didMutate()
                    }
                })
            } catch {
                await store.refresh()
                toasts.error((error as? APIError)?.errorDescription ?? "That did not go through.")
            }
        }
    }
}

// MARK: - Supporting views

struct InlineError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
            Text(message)
                .font(Theme.Typography.small)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Theme.Colors.foreground)
        .padding(12)
        .background(Theme.Colors.muted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 8)
    }
}

/// The account scope picker, opened by tapping the Imbox subtitle.
struct ScopeSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
            Text("Inbox scope")
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Colors.foreground)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 0) {
                    scopeRow(
                        glyph: "◇",
                        label: "All accounts",
                        hint: app.accounts.count > 1 ? "\(app.accounts.count)" : nil,
                        checked: app.scope == ServerConfig.allAccounts
                    ) {
                        app.setScope(ServerConfig.allAccounts); dismiss()
                    }

                    ForEach(Array(app.accounts.enumerated()), id: \.element.id) { index, account in
                        scopeRow(
                            glyph: Theme.glyph(forAccountIndex: index),
                            label: account.email,
                            hint: account.syncStatus == "disconnected" ? "Disconnected" : nil,
                            checked: app.scope == account.id
                        ) {
                            app.setScope(account.id); dismiss()
                        }
                    }
                }
            }
        }
        .padding(.bottom, 12)
        .screenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private func scopeRow(glyph: String, label: String, hint: String?, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(glyph)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                Text(label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let hint {
                    Text(hint)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                }
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.foreground)
                }
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
    }
}

struct SheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(Theme.Colors.border)
            .frame(width: 36, height: 5)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .accessibilityHidden(true)
    }
}

/// A tray opened from the Imbox: the same rows, in a sheet.
struct TraySheet: View {
    let title: String
    let threads: [ThreadSummary]
    let onOpen: (String) -> Void

    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()
            Text(title)
                .font(Theme.Typography.bodyStrong)
                .foregroundStyle(Theme.Colors.foreground)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(threads) { thread in
                        Button { onOpen(thread.id) } label: {
                            ThreadRow(thread: thread, glyph: app.glyph(for: thread.accountID), showsSnippet: app.showsPreviews)
                        }
                        .buttonStyle(PressableRowStyle())
                        .hairline()
                    }
                }
            }
        }
        .screenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
