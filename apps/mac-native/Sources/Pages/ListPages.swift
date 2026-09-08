import SwiftUI

/// `PaperTrail.tsx`: dense rows grouped by month.
struct PaperTrailPage: View {
    @Environment(AppState.self) private var app
    @State private var store = ThreadListStore(kind: .paperTrail)

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() } else {
            PageColumn {
                let n = store.threads.count + store.bundles.count
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
                }
            }
            .task { await store.firstLoad(.bubbleUp) }
            .syncsWithMail { await store.refresh(.bubbleUp) }
            .onKeys(["j": { cursor = min(cursor + 1, list.count - 1) }, "k": { cursor = max(cursor - 1, 0) }, "ArrowDown": { cursor = min(cursor + 1, list.count - 1) }, "ArrowUp": { cursor = max(cursor - 1, 0) },
                     "Enter": { if list.indices.contains(cursor) { router.go(.thread(list[cursor].id, peek: false)) } }, "o": { if list.indices.contains(cursor) { router.go(.thread(list[cursor].id, peek: false)) } }])
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
                    if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: thread.accountID)) }
                    Text("\(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name)\(thread.snippet.isEmpty ? "" : " — \(thread.snippet)")").font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            WBadge(Fmt.relative(thread.bubbleUpAt ?? 0), icon: "arrowUpCircle", variant: .secondary, muted: true).help(Fmt.full(thread.bubbleUpAt ?? 0))
            WButton(icon: "x", variant: .ghost, size: .iconSm, muted: true, help: "Cancel · back to the Imbox now", action: onCancel).opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(focused ? W.muted : (hovering ? W.accent : Color.clear))
        .rounded(W.radiusMd)
        .overlay(alignment: .leading) { if focused { Capsule().fill(W.foreground).frame(width: 2).padding(.vertical, 8) } }
        .opacity(leaving ? 0 : 1)
        .onHover { hovering = $0 }
    }
}

/// `Search.tsx`.
struct SearchPage: View {
    let query: String
    @Environment(Router.self) private var router
    @State private var text = ""
    @State private var store = SearchStore()

    var body: some View {
        let n = store.threads.count
        PageColumn {
            PageHeader(title: "Search", subtitle: !query.isEmpty && !store.searching ? "\(n)\(store.hasMore ? "+" : "") \(n == 1 ? "result" : "results") for “\(query)”" : "Subjects, names, and what they said.")
            HStack(spacing: 8) {
                Icon("search", size: 16).foregroundStyle(W.mutedForeground)
                WTextFieldPlain(placeholder: "Search subjects, people, and message text…", text: $text, autofocus: true, fontSize: 16)
                    .onSubmit { router.replace(.search(text.trimmingCharacters(in: .whitespaces))) }
                if !text.isEmpty { WButton(icon: "x", variant: .ghost, size: .iconXs, muted: true, help: "Clear") { text = ""; router.replace(.search("")) } }
                Kbd("↵")
            }
            .padding(.horizontal, 12).frame(height: 44).background(W.muted).rounded(W.radiusMd)
            .padding(.horizontal, 8).padding(.bottom, 24)
            if query.isEmpty {
                HStack(spacing: 6) { Text("Tip:"); Kbd("⌘K"); Text("searches from anywhere.") }.font(W.s13).foregroundStyle(W.mutedForeground).frame(maxWidth: .infinity).padding(.top, 16)
            } else {
                ThreadListView(sections: [ListSection(threads: store.threads, emptyTitle: "No matches.", emptyBody: "Try fewer words, or just a name.")],
                               loading: store.searching && store.threads.isEmpty, error: store.error, onRetry: { Task { await store.run(query) } },
                               showBucket: true, emptyIcon: "search",
                               footer: AnyView(LoadMore(hasMore: store.hasMore, loading: store.loadingMore) { Task { await store.loadMore() } }),
                               onAct: { ids, _, removes in if removes { for id in ids { _ = store.remove(id) } } })
            }
        }
        .onAppear { text = query }
        .task(id: query) { if !query.isEmpty { await store.run(query) } }
        .onKeys(["Enter": { router.replace(.search(text.trimmingCharacters(in: .whitespaces))) }], priority: -2)
    }
}
