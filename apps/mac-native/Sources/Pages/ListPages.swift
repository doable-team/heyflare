import SwiftUI

/// `PaperTrail.tsx`: dense rows grouped by month.
struct PaperTrailPage: View {
    @Environment(AppState.self) private var app
    @State private var store = ThreadListStore(kind: .paperTrail)

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() } else {
            PageColumn {
                // `threads.length`: the bundles are not counted.
                let n = store.threads.count
                let count = n > 0 ? "\(n)\(store.hasMore ? "+" : "") \(n == 1 && !store.hasMore ? "item" : "items"). " : ""
                PageHeader(title: "Paper Trail", subtitle: "\(count)Receipts, confirmations, and the rest of the paperwork.")
                ThreadListView(sections: [ListSection(threads: store.threads, bundles: store.bundles, emptyTitle: "No paperwork yet.", emptyBody: "Receipts and confirmations land here once you screen those senders into the Paper Trail.")],
                               loading: store.loading && store.threads.isEmpty, error: store.error, onRetry: { Task { await store.refresh(.paperTrail) } },
                               compact: true, groupByMonth: true, emptyIcon: "fileText",
                               footer: AnyView(LoadMore(hasMore: store.hasMore, loading: store.loadingMore) { Task { await store.loadMore(.paperTrail) } }),
                               onAct: { ids, _, removes in if removes { _ = store.removeMany(Set(ids)) } })
            }
            .task { await store.firstLoad(.paperTrail) }
            .syncsWithMail { await store.refresh(.paperTrail) }
        }
    }
}

/// `ListPage.tsx`: previously seen, trash, sent, everything.
struct ListPage: View {
    let kind: ThreadListKind
    let title: String
    var subtitle: String? = nil
    var showBucket = false
    var previouslySeen = false

    @Environment(AppState.self) private var app
    @State private var store: ThreadListStore
    @State private var imbox = ImboxStore()

    init(kind: ThreadListKind, title: String, subtitle: String? = nil, showBucket: Bool = false, previouslySeen: Bool = false) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.showBucket = showBucket; self.previouslySeen = previouslySeen
        _store = State(initialValue: ThreadListStore(kind: kind))
    }

    private var art: (icon: String, title: String, body: String) {
        if previouslySeen { return ("eye", "Nothing seen yet.", "Once you open something in the Imbox, it settles down here.") }
        switch kind {
        case .trash: return ("trash2", "Trash is empty.", "Nothing to take out.")
        case .sent: return ("send", "Nothing sent yet.", "Press c to write something.")
        default: return ("inbox", "Nothing here.", "Empty lists are underrated.")
        }
    }

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() } else {
            let threads = previouslySeen ? imbox.data.seenThreads : store.threads
            let loading = previouslySeen ? (imbox.loading && !imbox.loaded) : (store.loading && store.threads.isEmpty)
            let n = threads.count
            let count = n > 0 ? "\(n)\(!previouslySeen && store.hasMore ? "+" : "") \(n == 1 && !store.hasMore ? "thread" : "threads"). " : ""
            PageColumn {
                PageHeader(title: title, subtitle: "\(count)\(subtitle ?? "")".trimmingCharacters(in: .whitespaces))
                ThreadListView(sections: [ListSection(threads: threads, emptyTitle: art.title, emptyBody: art.body)],
                               loading: loading, error: previouslySeen ? imbox.error : store.error,
                               onRetry: { Task { if previouslySeen { await imbox.refresh() } else { await store.refresh(kind) } } },
                               showBucket: showBucket, emptyIcon: art.icon,
                               footer: previouslySeen ? nil : AnyView(LoadMore(hasMore: store.hasMore, loading: store.loadingMore) { Task { await store.loadMore(kind) } }),
                               onAct: { ids, _, removes in if removes { if previouslySeen { imbox.removeMany(Set(ids)) } else { _ = store.removeMany(Set(ids)) } } })
            }
            .task { if previouslySeen { await imbox.load() } else { await store.firstLoad(kind) } }
            .syncsWithMail { if previouslySeen { await imbox.refresh() } else { await store.refresh(kind) } }
        }
    }
}

/// `BubbleUp.tsx`: what is scheduled, soonest first.
struct BubbleUpPage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var store = ThreadListStore(kind: .bubbleUp)
    @State private var leaving: Set<String> = []
    @State private var cursor = -1

    private var list: [ThreadSummary] { store.threads.filter { $0.bubbleUpAt != nil }.sorted { ($0.bubbleUpAt ?? 0) < ($1.bubbleUpAt ?? 0) } }

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() } else {
            PageColumn {
                PageHeader(title: "Bubble Up", subtitle: list.isEmpty ? "Out of sight until the moment you picked. Then it pops back to the top of New for you." : "\(list.count) scheduled. Out of sight until the moment you picked.")
                if let error = store.error { ErrorStateView(message: error) { Task { await store.refresh(.bubbleUp) } } }
                else if store.loading && store.threads.isEmpty { SkeletonRows() }
                else if list.isEmpty { EmptyStateView(icon: "arrowUpCircle", title: "Nothing scheduled to bubble up.", body: "Pick a thread, press z, choose a time.") }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                    BubbleRow(thread: t, focused: cursor == i, leaving: leaving.contains(t.id)) { cancel(t) }
                        .id(t.id)
                }
            }
            .task { await store.firstLoad(.bubbleUp) }
            .syncsWithMail { await store.refresh(.bubbleUp) }
            .itemCursorKeys(ids: list.map(\.id), cursor: $cursor) { i in if list.indices.contains(i) { router.go(.thread(list[i].id, peek: false)) } }
        }
    }

    private func cancel(_ t: ThreadSummary) {
        leaving.insert(t.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            _ = store.remove(t.id)
            leaving.remove(t.id)
            Mail.bulk([t.id], .bubbleUp(nil), toast: "Back in the Imbox now")
        }
    }
}

private struct BubbleRow: View {
    let thread: ThreadSummary
    var focused = false
    var leaving = false
    var onCancel: () -> Void
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            WAvatar(thread.lastFrom, size: 20)
            Button { router.go(.thread(thread.id, peek: true)) } label: {
                HStack(spacing: 8) {
                    Text(thread.displaySubject).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                    if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: thread.accountID), label: app.account(thread.accountID)?.email) }
                    Text("\(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name)\(thread.snippet.isEmpty ? "" : " — \(thread.snippet)")").font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // `Badge variant="secondary" className="font-normal tnum"`: foreground, not muted.
            SecondaryBadge(text: Fmt.relative(thread.bubbleUpAt ?? 0), icon: "arrowUpCircle").help(Fmt.full(thread.bubbleUpAt ?? 0))
            WButton(icon: "x", variant: .ghost, size: .iconSm, muted: true, help: "Cancel · back to the Imbox now", action: onCancel).opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(focused ? W.muted : (hovering ? W.accent : Color.clear))
        .rounded(W.radiusMd)
        .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
        .opacity(leaving ? 0 : 1)
        .animation(.easeOut(duration: 0.1), value: leaving)
        .onHover { hovering = $0 }
    }
}

/// `Search.tsx`.
struct SearchPage: View {
    let query: String
    @Environment(Router.self) private var router
    @State private var text = ""
    @State private var store = SearchStore()
    @FocusState private var focused: Bool

    /// The words the results are highlighted for: lower-cased, split on whitespace, two
    /// characters or longer.
    private var words: [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count > 1 }
    }

    var body: some View {
        let n = store.threads.count
        PageColumn {
            PageHeader(title: "Search", subtitle: !query.isEmpty && !store.searching ? "\(n)\(store.hasMore ? "+" : "") \(n == 1 ? "result" : "results") for “\(query)”" : "Subjects, names, and what they said.")
            HStack(spacing: 8) {
                Icon("search", size: 16).foregroundStyle(W.mutedForeground)
                TextField("Search subjects, people, and message text…", text: $text)
                    .textFieldStyle(.plain)
                    .font(W.font(16))
                    .foregroundStyle(W.foreground)
                    .focused($focused)
                    .onSubmit { router.replace(.search(text.trimmingCharacters(in: .whitespaces))) }
                if !text.isEmpty { WButton(icon: "x", variant: .ghost, size: .iconXs, muted: true, help: "Clear") { text = ""; router.replace(.search("")); focused = true } }
                Kbd("↵")
            }
            .padding(.horizontal, 12).frame(height: 44).background(W.muted)
            // `focus:ring-1 focus:ring-border`
            .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(focused ? W.border : Color.clear, lineWidth: 1))
            .rounded(W.radiusMd)
            .padding(.horizontal, 8).padding(.bottom, 24)
            if query.isEmpty {
                HStack(spacing: 6) { Text("Tip:"); Kbd("⌘K"); Text("searches from anywhere.") }.font(W.s13).foregroundStyle(W.mutedForeground).frame(maxWidth: .infinity).padding(.top, 16)
            } else {
                ThreadListView(sections: [ListSection(threads: store.threads, emptyTitle: "No matches.", emptyBody: "Try fewer words, or just a name.")],
                               loading: store.searching && store.threads.isEmpty, error: store.error, onRetry: { Task { await store.run(query) } },
                               showBucket: true, emptyIcon: "search",
                               footer: AnyView(LoadMore(hasMore: store.hasMore, loading: store.loadingMore) { Task { await store.loadMore() } }),
                               onAct: { ids, _, removes in if removes { for id in ids { _ = store.remove(id) } } })
                    .environment(\.searchTerms, words)
            }
        }
        .onAppear { text = query; DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
        // `useEffect(() => setText(q), [q])`: the field follows the route.
        .onChange(of: query) { _, q in text = q }
        .task(id: query) { if !query.isEmpty { await store.run(query) } }
    }
}

// MARK: - Shared list-page pieces

/// `<Skeleton className="h-3 w-[70%]" />`: a bar sized to its container.
struct PctSkeleton: View {
    var pct: CGFloat = 1
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { g in SkeletonBlock(width: g.size.width * pct, height: height) }
            .frame(height: height)
    }
}

/// `Badge variant="secondary" className="font-normal"`: the wash with the page's own text
/// colour (`text-secondary-foreground`), unlike `WBadge(muted:)` which goes muted.
struct SecondaryBadge: View {
    let text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Icon(icon, size: 12) }
            Text(text).lineLimit(1).monospacedDigit()
        }
        .font(W.font(12, 400))
        .foregroundStyle(W.foreground)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(W.secondary)
        .clipShape(Capsule())
    }
}
