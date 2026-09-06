import SwiftUI

// The one screen behind Paper Trail, Reply Later, Set Aside, Bubbled up, Sent,
// Everything, Trash and Screened out. They differ in copy and in nothing else, so they
// share an implementation rather than eight near-copies.

// MARK: - Swipe plumbing

/// A swipe action before it knows what it is attached to.
///
/// `SwipeRow.Action` is nested inside a generic, which makes `SwipeRow<A>.Action` and
/// `SwipeRow<B>.Action` different types — so an action cannot be built until the row's
/// content type is fixed. This carries the same three fields until then.
private struct RowSwipe {
    let icon: String
    let label: String
    /// Carried through to `SwipeRow.Action.resets`: true when the action leaves the row
    /// in the list, so it settles back instead of flying off.
    var resets: Bool = false
    let perform: () -> Void
}

/// Binds `RowSwipe` descriptors to a `SwipeRow` once `Content` is concrete.
private struct SwipeContainer<Content: View>: View {
    var leading: RowSwipe?
    var trailing: RowSwipe?
    @ViewBuilder var content: () -> Content

    var body: some View {
        SwipeRow(
            leading: leading.map { SwipeRow<Content>.Action(icon: $0.icon, label: $0.label, resets: $0.resets, perform: $0.perform) },
            trailing: trailing.map { SwipeRow<Content>.Action(icon: $0.icon, label: $0.label, resets: $0.resets, perform: $0.perform) },
            content: content
        )
    }
}

/// The month divider. Pinned by the enclosing `LazyVStack`, so it needs its own opaque
/// ground or the rows would read through it while they pass underneath.
private struct MonthCaption: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Typography.caps)
            .tracking(0.6)
            .foregroundStyle(Theme.Colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(height: 28)
            .background(Theme.Colors.chrome)
            .background(.ultraThinMaterial)
            .hairline(.bottom)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Bulk actions

// MARK: - Store

// MARK: - Screen

struct ThreadListScreen: View {
    let kind: ThreadListKind

    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var store: ThreadListStore
    @State private var collapsed = false

    /// Selection lives as ids rather than as threads: a refresh replaces every value in
    /// the list, and a selection held by value would go stale under it.
    @State private var selection: Set<String> = []
    @State private var selecting = false
    /// When the long press opened selection mode. See the tap handler in `row(_:)`.
    @State private var selectionOpenedAt = Date.distantPast
    @State private var showingBubbleUp = false
    @State private var showingMove = false
    /// What a confirmation has been asked for before it is erased for good — one row from
    /// a context menu, or a whole selection from the bar. One request type rather than
    /// two flags, so there is one dialog and one code path behind it.
    @State private var erasing: EraseRequest?

    struct EraseRequest: Identifiable {
        let id = UUID()
        let threads: [ThreadSummary]
    }

    private static let space = "list.scroll"

    init(kind: ThreadListKind) {
        self.kind = kind
        _store = State(initialValue: ThreadListStore(kind: kind))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            // A ScrollView with a LazyVStack rather than a List: the rows carry the
            // hand-built `SwipeRow`, which a List's own swipe handling would fight, and
            // free row heights let a long subject wrap instead of truncating.
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ScrollOffsetProbe(space: Self.space)
                    LargeTitle(title: kind.title, subtitle: subtitle)
                    content
                }
            }
            .coordinateSpace(name: Self.space)
            .refreshable {
                // Pulling while a selection is open would swap the rows out from under it.
                guard !selecting else { return }
                await store.refresh(kind)
            }

            // A sibling of the scroll view rather than an overlay on it: the list gives up
            // the height instead of hiding its last rows behind the bar, and because the
            // whole screen is already inset by the tab bar and the home indicator, sitting
            // at the bottom of this stack is what "above the tab bar, clear of the safe
            // area" means here.
            if selecting { actionBar }
        }
        .screenBackground()
        .onPreferenceChange(ScrollOffsetKey.self) { [collapsed = $collapsed] offset in
            collapsed.wrappedValue = offset < -30
        }
        .task { await store.firstLoad(kind) }
        // Filing done elsewhere — on a thread's own page, in the Imbox, from the composer —
        // lands here the moment this list is looked at again. Paused while selecting.
        .syncsWithMail(enabled: !selecting) { await store.refresh(kind) }
        .confirmationDialog("Bubble up", isPresented: $showingBubbleUp, titleVisibility: .visible) { bubbleUpOptions }
        .confirmationDialog("Move to", isPresented: $showingMove, titleVisibility: .visible) { moveOptions }
        .confirmationDialog(
            eraseTitle,
            isPresented: Binding(get: { erasing != nil }, set: { if !$0 { erasing = nil } }),
            titleVisibility: .visible,
            presenting: erasing
        ) { request in
            // Named, not tinted, and confirmed. `delete` has no inverse, so the toast that
            // follows carries no Undo either — the confirmation is the only safety net
            // there is, which is why it is asked for even on a single row.
            Button("Delete permanently", role: .destructive) {
                bulk.run(request.threads, .delete, undo: nil)
                endSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This cannot be undone.")
        }
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
                    selection = all ? [] : Set(store.threads.map(\.id))
                    Haptics.select()
                }
            }
        } else {
            TopBar(title: kind.title, titleVisible: collapsed) {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                BarButton(icon: "magnifyingglass", label: "Search") { nav.push(.search) }
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

    /// The five bulk actions, in the order the web build docks them.
    private var actionBar: some View {
        HStack(spacing: 0) {
            // Reply Later and Set Aside invert on the list that already is that pile,
            // exactly as the swipes above them do — "Reply later" on the Reply Later
            // list would be a button that does nothing.
            barAction("clock", kind == .replyLater ? "Not later" : "Reply later") {
                let on = kind != .replyLater
                bulk.run(selected, .replyLater(on), undo: .action(.replyLater(!on)))
                endSelection()
            }
            barAction("tray.and.arrow.down", kind == .setAside ? "Put back" : "Set aside") {
                let on = kind != .setAside
                bulk.run(selected, .setAside(on), undo: .action(.setAside(!on)))
                endSelection()
            }
            barAction("arrow.up.circle", "Bubble up") { showingBubbleUp = true }
            barAction("folder", "Move") { showingMove = true }
            barAction("trash", kind == .trash ? "Delete" : "Trash") {
                if kind == .trash {
                    erasing = EraseRequest(threads: selected)
                } else {
                    bulk.run(selected, .move(.trash), undo: .buckets)
                    endSelection()
                }
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

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.threads.isEmpty {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.refresh(kind) }
            }
        } else if store.loading && store.threads.isEmpty {
            ProgressView()
                .tint(Theme.Colors.mutedForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if store.threads.isEmpty {
            EmptyState(icon: emptyIcon, message: emptyMessage)
        } else {
            ForEach(store.groups) { group in
                Section {
                    ForEach(group.threads) { thread in
                        row(thread)
                    }
                } header: {
                    if store.spansMonths {
                        MonthCaption(text: group.caption)
                    }
                }
            }

            if store.hasMore {
                ProgressView()
                    .tint(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .onAppear { Task { await store.loadMore(kind) } }
            }

            Color.clear.frame(height: 24)
        }
    }

    private func row(_ thread: ThreadSummary) -> some View {
        let picked = selection.contains(thread.id)

        // Both swipes survive selection mode. Each of them keeps its row — ticking a box
        // and turning read state over neither move a thread anywhere — so they settle
        // back on release rather than parking open over a grey strip, which is what made
        // the old filing swipes unsafe to leave attached here.
        return SwipeContainer(
            leading: leadingSwipe(thread),
            trailing: trailingSwipe(thread)
        ) {
            Button {
                guard selecting else {
                    // Trays are looked into, not read: peeking keeps a thread unread
                    // until it is actually dealt with, which is what the web does.
                    nav.push(kind.previewsOnly ? .peekThread(thread.id) : .thread(thread.id))
                    return
                }
                // The press that opens selection mode is still a press: the button can
                // take the release as a tap and immediately untick the row the long
                // press just picked. Taps in the moment after it opened are that echo.
                guard Date().timeIntervalSince(selectionOpenedAt) > 0.5 else { return }
                toggle(thread)
            } label: {
                HStack(spacing: 0) {
                    if selecting { checkmark(picked) }
                    ThreadRow(
                        thread: thread,
                        glyph: app.glyph(for: thread.accountID),
                        showsSnippet: app.showsPreviews && !isDense
                    )
                }
            }
            .buttonStyle(PressableRowStyle())
            .accessibilityAddTraits(picked ? .isSelected : [])
            .rowContextMenu(enabled: !selecting) { menu(for: thread) }
            // The long press that starts a selection is the same gesture iOS gives the
            // context menu, so the two cannot both own it. This one fires first (0.35s
            // against UIKit's half second) and flips `selecting`, which takes the context
            // menu off the row before it can present. `simultaneousGesture` rather than
            // `onLongPressGesture` so the row keeps its tap and the scroll view keeps its
            // pan. The menu also carries a "Select" entry, so the selection is reachable
            // even on the press where the menu wins the race.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35).onEnded { _ in beginSelection(with: thread) }
            )
        }
        .hairline(.bottom)
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

    // MARK: Context menu

    /// The Imbox's menu, adapted to the list it is standing in.
    ///
    /// Most of the adapting is free: the entries are written against the thread's own
    /// flags, so on the Reply Later list — where every row has `reply_later` set — the
    /// first entry already reads "Remove from Reply Later". Trash is the exception,
    /// because nothing there wants filing and its destructive entry is final.
    @ViewBuilder
    private func menu(for thread: ThreadSummary) -> some View {
        Button { beginSelection(with: thread) } label: {
            SwiftUI.Label("Select", systemImage: "checkmark.circle")
        }
        Divider()

        if kind == .trash {
            Button { runner.run(thread, .move(.imbox), undo: .move(.trash)) } label: {
                SwiftUI.Label("Restore to Imbox", systemImage: "tray")
            }
            Button { runner.run(thread, .move(.paperTrail), undo: .move(.trash)) } label: {
                SwiftUI.Label("Restore to Paper Trail", systemImage: "doc.text")
            }
            Divider()
            Button(role: .destructive) { erasing = EraseRequest(threads: [thread]) } label: {
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
            if thread.bubbleUpAt != nil {
                Button { runner.run(thread, .bubbleUp(nil), undo: nil) } label: {
                    SwiftUI.Label("Cancel bubble up", systemImage: "arrow.up.circle")
                }
            }
            Button { toggleRead(thread) } label: {
                SwiftUI.Label(thread.unread ? "Mark read" : "Mark unread", systemImage: "envelope")
            }
            Divider()
            ForEach(moveTargets(from: thread.bucket), id: \.self) { bucket in
                Button { runner.run(thread, .move(bucket), undo: .move(thread.bucket)) } label: {
                    SwiftUI.Label("Move to \(bucket.title)", systemImage: Self.icon(for: bucket))
                }
            }
            Button(role: .destructive) { runner.run(thread, .move(.trash), undo: .move(thread.bucket)) } label: {
                SwiftUI.Label("Trash", systemImage: "trash")
            }
        }
    }

    /// The three filing destinations, minus wherever the thread already is.
    private func moveTargets(from bucket: Bucket) -> [Bucket] {
        [.imbox, .feed, .paperTrail].filter { $0 != bucket }
    }

    private static func icon(for bucket: Bucket) -> String {
        switch bucket {
        case .imbox: return "tray"
        case .feed: return "dot.radiowaves.up.forward"
        case .paperTrail: return "doc.text"
        case .trash: return "trash"
        case .screener: return "shield"
        case .screenedOut: return "shield.slash"
        }
    }

    // MARK: Selection

    private var selected: [ThreadSummary] {
        store.threads.filter { selection.contains($0.id) }
    }

    private var eraseTitle: String {
        let count = erasing?.threads.count ?? 0
        return count == 1 ? "Delete this thread for good?" : "Delete \(count) threads for good?"
    }

    private var allSelected: Bool {
        !store.threads.isEmpty && selected.count == store.threads.count
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

    // MARK: Actions

    private var runner: ThreadActionRunner {
        ThreadActionRunner(
            app: app,
            toasts: toasts,
            remove: { store.remove($0) },
            restore: { store.restore($0, at: $1) }
        )
    }

    private var bulk: BulkActionRunner {
        BulkActionRunner(
            app: app,
            toasts: toasts,
            remove: { store.removeMany($0) },
            restore: { store.restoreMany($0) }
        )
    }

    /// Read state does not move a thread out of any of these lists, so the row is edited
    /// where it stands. Running it through the removing runner would make the thread
    /// vanish until the next refresh brought it straight back.
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

    @ViewBuilder
    private var bubbleUpOptions: some View {
        // The same presets the thread view offers, resolved against the current clock.
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
        Button("Imbox") { move(.imbox) }
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

    private static func nextWeek() -> Date {
        let cal = Calendar.current
        let base = cal.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return cal.date(bySettingHour: 8, minute: 0, second: 0, of: base) ?? base
    }

    /// Dragging right picks the row out. The same gesture on a list that is already
    /// selecting adds to the selection, so several rows can be gathered in one pass
    /// without lifting a finger to long-press each one.
    private func leadingSwipe(_ thread: ThreadSummary) -> RowSwipe? {
        RowSwipe(icon: "checkmark.circle", label: "Select", resets: true) {
            if selecting { toggle(thread) } else { beginSelection(with: thread) }
        }
    }

    /// Dragging left turns the row's read state over. Filing a thread — reply later,
    /// set aside, move, trash — is a selection away: swipe right, then the bar below.
    private func trailingSwipe(_ thread: ThreadSummary) -> RowSwipe? {
        RowSwipe(icon: thread.unread ? "envelope.open" : "envelope",
                 label: thread.unread ? "Read" : "Unread",
                 resets: true) {
            toggleRead(thread)
        }
    }

    // MARK: Copy

    /// Paper Trail is paperwork, not reading: dense rows, no snippet.
    private var isDense: Bool { kind == .paperTrail }

    private var subtitle: String? {
        switch kind {
        case .paperTrail: return "Receipts, confirmations, and the rest of the paperwork."
        case .replyLater: return "Threads you meant to answer."
        case .setAside: return "Things you want close at hand."
        case .bubbled: return "Back, at the moment you picked."
        case .bubbleUp: return "Waiting to come back."
        case .screenedOut: return "Senders you turned away."
        case .trash: return "Deleted mail, until the server clears it."
        case .feed, .sent, .everything, .screener: return nil
        }
    }

    private var emptyIcon: String {
        switch kind {
        case .feed: return "dot.radiowaves.up.forward"
        case .paperTrail: return "doc.text"
        case .screenedOut: return "shield.slash"
        case .trash: return "trash"
        case .sent: return "paperplane"
        case .everything: return "envelope"
        case .replyLater: return "clock"
        case .setAside: return "tray.and.arrow.down"
        case .bubbled: return "arrow.up.circle"
        case .bubbleUp: return "arrow.up.circle"
        case .screener: return "shield"
        }
    }

    private var emptyMessage: String {
        switch kind {
        case .feed: return "Your Feed is quiet."
        case .paperTrail: return "No paperwork yet. Receipts land here once you screen those senders into the Paper Trail."
        case .screenedOut: return "Nobody has been screened out."
        case .trash: return "Trash is empty."
        case .sent: return "Nothing sent yet."
        case .everything: return "Nothing here."
        case .replyLater: return "Nothing to reply to. Long-press a thread in the Imbox and choose Reply later to park it here."
        case .setAside: return "Nothing set aside. Long-press a thread in the Imbox and choose Set aside to keep it handy."
        case .bubbled: return "Nothing has bubbled up."
        case .bubbleUp: return "Nothing is waiting to come back. Bubble a thread up from its page."
        case .screener: return "The Screener is clear."
        }
    }
}

// MARK: - Shared row helpers

extension View {
    /// A context menu that can be taken off a row entirely.
    ///
    /// `.contextMenu` with an empty body still presents an empty sheet, and a `.disabled`
    /// menu still animates the row on press, so the only way to hand the long press back
    /// to selection mode is to not attach the modifier at all.
    @ViewBuilder
    func rowContextMenu<Menu: View>(enabled: Bool = true, @ViewBuilder menu: () -> Menu) -> some View {
        if enabled {
            contextMenu { menu() }
        } else {
            self
        }
    }
}
