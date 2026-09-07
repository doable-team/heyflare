import SwiftUI
import AppKit

/// `Imbox.tsx`.
struct ImboxPage: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @State private var store = ImboxStore()

    private var newCount: Int { store.data.newThreads.count + store.data.bundles.filter(\.isOpen).count }

    var body: some View {
        if app.accounts.isEmpty {
            ConnectGmailCard()
        } else {
            PageColumn {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Imbox").font(W.font(28, 700)).webLine(28, weight: 700).tracking(-0.56).foregroundStyle(W.foreground)
                    HStack(spacing: 12) {
                        Text(scopeLabel).font(W.xs).webLine(12).foregroundStyle(W.mutedForeground)
                        SyncPill()
                    }
                    .frame(minHeight: 20)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)

                if store.data.screenerCount > 0 {
                    ScreenerBanner(count: store.data.screenerCount, senders: store.data.screenerSenders)
                        .padding(.bottom, 20)
                }

                ThreadListView(
                    sections: [
                        ListSection(title: "New for you", threads: store.data.newThreads, bundles: store.data.bundles.filter(\.isOpen),
                                    emptyView: AnyView(
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Nothing new. Go enjoy your day.").font(W.font(14)).webLine(14, 21).foregroundStyle(W.foreground)
                                            Text("Mail from people you've screened in shows up here.").font(W.s13).webLine(13, 19.5).foregroundStyle(W.mutedForeground)
                                        }
                                        .padding(.horizontal, 8).padding(.top, 8)
                                        .frame(maxWidth: .infinity, minHeight: ui.viewportHeight * 0.2, alignment: .topLeading)
                                    ),
                                    actions: newCount > 0 ? AnyView(WButton("Power through new", icon: "zap", variant: .ghost, size: .sm, muted: true, kbd: "o") { router.go(.powerThrough) }) : nil),
                        ListSection(title: "Previously seen", threads: store.data.seenThreads, bundles: store.data.bundles.filter { !$0.isOpen }, emptyTitle: "Nothing here yet.", emptyBody: "Once you open something, it settles down here."),
                    ],
                    loading: store.loading && !store.loaded,
                    error: store.error,
                    onRetry: { Task { await store.load(force: true) } },
                    onAct: { ids, _, removes in if removes { store.removeMany(Set(ids)) } }
                )
            }
            .task { await store.load() }
            .syncsWithMail { await store.refresh() }
            .onKeys(["o": { if newCount > 0 { router.go(.powerThrough) } }], enabled: ui.region == .content, priority: -1)
            .onAppear { ui.setDock(AnyView(Piles(replyLater: store.data.replyLater, setAside: store.data.setAside)), owner: "imbox") }
            .onChange(of: store.data.replyLater.map(\.id) + store.data.setAside.map(\.id)) { _, _ in
                ui.setDock(AnyView(Piles(replyLater: store.data.replyLater, setAside: store.data.setAside)), owner: "imbox")
            }
            .onDisappear { ui.clearDock(owner: "imbox") }
        }
    }

    private var scopeLabel: String {
        if app.accounts.count > 1 { return app.scope == ServerConfig.allAccounts ? "All accounts" : (app.scopedAccount?.email ?? "") }
        return app.scopedAccount?.email ?? app.accounts.first?.email ?? ""
    }
}

/// "N new senders are waiting in the Screener".
struct ScreenerBanner: View {
    let count: Int
    let senders: [ScreenerSender]
    @Environment(Router.self) private var router
    @State private var hovering = false

    private var line: String {
        let names = senders.prefix(3).map { $0.name.isEmpty ? $0.email : $0.name }
        let rest = count - names.count
        if names.isEmpty { return "" }
        if rest <= 0 { return names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last! }
        return names.joined(separator: ", ") + " and \(rest) more"
    }

    var body: some View {
        Button { router.go(.screener) } label: {
            HStack(spacing: 12) {
                HStack(spacing: -6) {
                    ForEach(Array(senders.prefix(5).enumerated()), id: \.offset) { _, p in
                        WAvatar(p.address, size: 24).padding(2).background(W.background).rounded(4)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Icon("shield", size: 13).foregroundStyle(W.mutedForeground)
                        Text("\(count)").monospacedDigit() + Text(" new \(count == 1 ? "sender is" : "senders are") waiting in the Screener")
                    }
                    .font(W.font(13, 500)).foregroundStyle(W.foreground)
                    Text(line).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 4) { Text("Screen them"); Icon("chevronRight", size: 14) }.font(W.s13).foregroundStyle(hovering ? W.foreground : W.mutedForeground)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(hovering ? W.muted : W.muted40)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `SyncPill`: only while a sync is running or broken.
struct SyncPill: View {
    @Environment(AppState.self) private var app
    @State private var syncing = false

    var body: some View {
        let targets = app.scope == ServerConfig.allAccounts ? app.accounts : (app.scopedAccount.map { [$0] } ?? [])
        let busy = targets.filter { !$0.initialSyncDone || $0.syncStatus == "syncing" }
        let broken = targets.filter { $0.syncStatus == "error" || $0.syncStatus == "disconnected" }
        if let a = broken.first ?? busy.first {
            let error = !broken.isEmpty
            HStack(spacing: 8) {
                if error { Icon("refreshCw", size: 13) } else { Spinner(size: 13) }
                if error {
                    Text("Sync problem\(targets.count > 1 ? " (\(a.email))" : ""): \(a.syncError ?? "unknown").")
                } else {
                    Text("Syncing\(targets.count > 1 ? " \(a.email)" : "")\(a.lastSyncedAt.map { " · \(Fmt.relative($0))" } ?? "")")
                }
                WButton("Sync now", variant: .ghost, size: .xs, muted: true) {
                    syncing = true
                    Task { defer { syncing = false }; _ = try? await APIClient.shared.syncNow(accountID: a.id); await app.refreshAccounts(); Mail.invalidate() }
                }
                .disabled(syncing)
            }
            .font(W.xs).foregroundStyle(W.mutedForeground)
        }
    }
}

/// `ConnectGmailCard`: the empty first run.
struct ConnectGmailCard: View {
    @Environment(AppState.self) private var app
    @Environment(Toasts.self) private var toasts
    var body: some View {
        VStack(spacing: 12) {
            Icon("mail", size: 20).foregroundStyle(W.mutedForeground).frame(width: 40, height: 40).background(W.muted).rounded(W.radiusLg)
            Text("Connect your Gmail\(app.user?.name.isEmpty == false ? ", \(app.user!.name.split(separator: " ").first ?? "")" : "")").font(W.font(18, 600)).foregroundStyle(W.foreground)
            Text("Nobody reaches your Imbox until you say so. First-time senders wait in the Screener; newsletters go to The Feed; receipts to the Paper Trail. Nothing from the past is imported — heyflare starts from the moment you connect and checks Gmail every couple of minutes.")
                .font(W.sm).foregroundStyle(W.mutedForeground).multilineTextAlignment(.center).frame(maxWidth: 448)
            WButton("Connect Gmail", trailingIcon: "arrowRight") { GoogleConnect.start(toasts: toasts) }.padding(.top, 8)
            Text("Tokens stay in your own Cloudflare account.").font(W.xs).foregroundStyle(W.mutedForeground)
        }
        .frame(maxWidth: 672)
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// Reply Later (left) and Set Aside (right) piles, pinned to the bottom of the Imbox like HEY.
struct Piles: View {
    let replyLater: [ThreadSummary]
    let setAside: [ThreadSummary]

    var body: some View {
        if !replyLater.isEmpty || !setAside.isEmpty {
            HStack(spacing: 2) {
                if !replyLater.isEmpty {
                    Pile(id: "pile-rl", threads: replyLater, label: "Reply later", icon: "clock", link: .replyLater, linkLabel: "Focus & Reply", removeLabel: "Done") { id in
                        Mail.bulk([id], .replyLater(false))
                    }
                }
                if !setAside.isEmpty {
                    Pile(id: "pile-sa", threads: setAside, label: "Set aside", icon: "bookmark", link: .setAside, linkLabel: "Board", removeLabel: "Done") { id in
                        Mail.bulk([id], .setAside(false))
                    }
                }
            }
            .padding(4)
            .background(W.background)
            .overlay(Capsule().strokeBorder(W.border, lineWidth: 1))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .padding(.bottom, 16)
        }
    }
}

/// One HEY-style pile: the latest cards fanned, a popover list on click.
struct Pile: View {
    let id: String
    let threads: [ThreadSummary]
    let label: String
    let icon: String
    let link: AppRoute
    let linkLabel: String
    let removeLabel: String
    var onRemove: (String) -> Void

    @Environment(PopLayerState.self) private var pops
    @Environment(Router.self) private var router
    @State private var hovering = false

    var body: some View {
        let open = pops.isOpen(id)
        Button {
            pops.toggle(id, side: .top, align: .center, offset: 8) { list }
        } label: {
            HStack(spacing: 8) {
                WAvatarStack(people: threads.prefix(3).map(\.lastFrom), size: 18, max: 3, plus: false)
                HStack(spacing: 6) {
                    Icon(icon, size: 13)
                    Text(label).font(W.font(13, 500))
                    Text("\(threads.count)").font(W.s13).monospacedDigit().foregroundStyle(W.tertiary)
                }
            }
            .foregroundStyle(hovering || open ? W.foreground : W.mutedForeground)
            .padding(.leading, 8).padding(.trailing, 12)
            .frame(height: 36)
            .background(hovering || open ? W.muted : Color.clear)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popAnchor(id)
        .help("\(label), \(threads.count) \(threads.count == 1 ? "thread" : "threads")")
    }

    private var list: some View {
        PopCard(width: 340) {
            VStack(spacing: 0) {
                HStack {
                    Text(label).font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
                    Spacer()
                    Button { pops.closeAll(); router.go(link) } label: {
                        HStack(spacing: 4) { Text(linkLabel); Icon("arrowRight", size: 12) }.font(W.xs).foregroundStyle(W.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8).frame(height: 32)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(threads) { t in PileRow(thread: t, removeLabel: removeLabel, onRemove: onRemove) }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }
}

private struct PileRow: View {
    let thread: ThreadSummary
    let removeLabel: String
    var onRemove: (String) -> Void
    @Environment(Router.self) private var router
    @Environment(PopLayerState.self) private var pops
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            WAvatar(thread.lastFrom, size: 20)
            Button { pops.closeAll(); router.go(.thread(thread.id, peek: false)) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.displaySubject).font(W.s13).foregroundStyle(W.foreground).lineLimit(1)
                    Text("\(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name) · \(Fmt.time(thread.lastMessageAt))").font(W.font(11)).foregroundStyle(W.mutedForeground).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hovering {
                WButton(removeLabel, icon: "check", variant: .ghost, size: .xs, muted: true) { onRemove(thread.id) }
            }
        }
        .padding(.horizontal, 8).frame(height: 40)
        .background(hovering ? W.accent : Color.clear)
        .rounded(W.radiusMd)
        .onHover { hovering = $0 }
    }
}
