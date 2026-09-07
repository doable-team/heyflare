import SwiftUI
import AppKit

/// `FeedCard`: the message opened right in the list, capped, with its actions.
struct FeedCard: View {
    let thread: ThreadSummary
    var onLeave: (String, @escaping () -> Void) -> Void

    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @State private var expanded = false
    @State private var bodyHeight: CGFloat = 0

    private let cap: CGFloat = 480
    private var m: Message? { thread.latestMessage }
    private var unsubscribe: (url: URL?, mailto: String?) {
        let h = m?.listUnsubscribe ?? ""
        var url: URL?; var mailto: String?
        if let r = h.range(of: #"https?://[^>,\s]+"#, options: .regularExpression) { url = URL(string: String(h[r])) }
        if let r = h.range(of: #"mailto:([^>,\s?]+)"#, options: .regularExpression) { mailto = String(h[r]).replacingOccurrences(of: "mailto:", with: "") }
        return (url, mailto)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                WAvatar(thread.lastFrom, size: 20)
                Text(thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name).font(W.font(14, 500)).lineLimit(1)
                if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: thread.accountID)) }
                Text(thread.lastFrom.email).font(W.xs).foregroundStyle(W.mutedForeground).lineLimit(1)
                Spacer()
                Text(Fmt.time(thread.lastMessageAt)).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).help(Fmt.full(thread.lastMessageAt))
            }
            .padding(.horizontal, 20).padding(.top, 20)
            Button { router.go(.thread(thread.id, peek: false)) } label: {
                Text(thread.displaySubject).font(W.font(20, 600)).tracking(-0.2).foregroundStyle(W.foreground).multilineTextAlignment(.leading).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.top, 12)

            ZStack(alignment: .bottom) {
                Group {
                    if let m { HtmlBodyView(html: m.htmlBody, text: m.textBody, trackers: m.trackers) } else { Text(thread.snippet).font(W.sm) }
                }
                .background(GeometryReader { g in Color.clear.onChange(of: g.size.height, initial: true) { _, h in bodyHeight = h } })
                .frame(maxHeight: expanded ? nil : cap, alignment: .top)
                .clipped()
                if !expanded && bodyHeight > cap + 24 {
                    LinearGradient(colors: [W.background.opacity(0), W.background.opacity(0.8), W.background], startPoint: .top, endPoint: .bottom)
                        .frame(height: 96)
                        .overlay(alignment: .bottom) { WButton("Read more", trailingIcon: "chevronDown", variant: .outline, size: .sm) { expanded = true }.padding(.bottom, 8) }
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)

            HStack(spacing: 4) {
                WButton("Open thread", variant: .ghost, size: .sm, muted: true) { router.go(.thread(thread.id, peek: false)) }
                if let url = unsubscribe.url {
                    WButton("Unsubscribe", trailingIcon: "arrowUpRight", variant: .ghost, size: .sm, muted: true) { NSWorkspace.shared.open(url) }
                } else if let mailto = unsubscribe.mailto {
                    WButton("Unsubscribe", trailingIcon: "arrowUpRight", variant: .ghost, size: .sm, muted: true, help: "Email \(mailto) to unsubscribe") { Compose.open(ComposerInitial(to: [Address(email: mailto)], subject: "Unsubscribe")) }
                }
                Spacer()
                WButton("Done", icon: "check", variant: .ghost, size: .sm, muted: true) { onLeave(thread.id) { Mail.bulk([thread.id], .seen, toast: "Done") } }
                WButton("Paper Trail", icon: "fileText", variant: .ghost, size: .sm, muted: true) { onLeave(thread.id) { Mail.bulk([thread.id], .move(.paperTrail), toast: "Moved to Paper Trail") } }
                WButton("Imbox", icon: "inbox", variant: .ghost, size: .sm, muted: true) { onLeave(thread.id) { Mail.bulk([thread.id], .move(.imbox), toast: "Moved to Imbox") } }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(W.muted40)
        .rounded(W.radiusMd)
    }
}

/// `Feed.tsx`.
struct FeedPage: View {
    @Environment(AppState.self) private var app
    @State private var store = FeedStore()
    @State private var show = "new"
    @State private var leaving: Set<String> = []

    private var filter: FeedFilter { show == "all" ? .all : .new }

    var body: some View {
        if app.accounts.isEmpty { ConnectGmailCard() } else {
            let n = store.threads.count
            PageColumn(width: 672) {
                PageHeader(title: "The Feed", subtitle: n > 0 ? "\(n)\(store.hasMore ? "+" : "") \(n == 1 && !store.hasMore ? "item" : "items"). Newsletters and long reads. Scroll, don't sort." : "Newsletters and long reads. Scroll, don't sort.") {
                    WToggleGroup(options: [ToggleOption(id: "new", label: "New", help: "Show new"), ToggleOption(id: "all", label: "All", help: "Show everything")], value: $show, outline: true)
                }
                .padding(.horizontal, 8)
                if let error = store.error { ErrorStateView(message: error) { Task { await store.refresh(filter) } } }
                if store.loading && store.threads.isEmpty {
                    VStack(spacing: 16) { FeedSkeleton(); FeedSkeleton() }
                }
                if !store.loading && store.threads.isEmpty && store.error == nil {
                    EmptyStateView(icon: "rss", title: "Your Feed is quiet.", body: "Screen a newsletter into The Feed and it shows up here, fully opened.")
                }
                LazyVStack(spacing: 16) {
                    ForEach(store.threads) { t in
                        FeedCard(thread: t, onLeave: leave).opacity(leaving.contains(t.id) ? 0 : 1).id(t.id)
                    }
                }
                LoadMore(hasMore: store.hasMore, loading: store.loadingMore) { Task { await store.loadMore(filter) } }
            }
            .task { await store.firstLoad(filter) }
            .onChange(of: show) { _, _ in Task { await store.refresh(filter) } }
            .syncsWithMail { await store.refresh(filter) }
        }
    }

    private func leave(_ id: String, _ then: @escaping () -> Void) {
        leaving.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            then()
            _ = store.remove(id)
            leaving.remove(id)
        }
    }
}

struct FeedSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) { SkeletonBlock(width: 20, height: 20, radius: 4); SkeletonBlock(width: 160) }
            SkeletonBlock(width: 380, height: 20)
            VStack(alignment: .leading, spacing: 8) { SkeletonBlock(); SkeletonBlock(width: 520); SkeletonBlock(width: 440); SkeletonBlock(height: 128) }
        }
        .padding(20)
        .background(W.muted40)
        .rounded(W.radiusMd)
    }
}

/// `BundlePage.tsx`: a bundle read like The Feed.
struct BundlePage: View {
    let bundleID: String
    @Environment(Router.self) private var router
    @Environment(DialogState.self) private var dialogs
    @Environment(Toasts.self) private var toasts
    @State private var store = BundleStore()
    @State private var leaving: Set<String> = []
    @State private var marked = false

    var body: some View {
        if let error = store.error, store.detail == nil {
            ErrorStateView(message: error) { Task { await store.firstLoad(bundleID) } }
        } else if let d = store.detail {
            let b = d.bundle
            PageColumn(width: 672) {
                WButton("Back", icon: "arrowLeft", variant: .ghost, size: .sm, muted: true, kbd: "esc") { router.back() }.padding(.bottom, 12)
                HStack(spacing: 12) {
                    BundleAvatar(email: b.email, name: b.name, src: b.avatarURL, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(b.name.isEmpty ? b.email : b.name).font(W.font(22, 600)).tracking(-0.22).lineLimit(1)
                            Icon("layers", size: 16).foregroundStyle(W.mutedForeground)
                        }
                        HStack(spacing: 4) {
                            Text("\(b.messageCount) \(b.messageCount == 1 ? "message" : "messages") · \(b.threadCount) \(b.threadCount == 1 ? "thread" : "threads") ·")
                            Button { router.go(.contact(b.contactID)) } label: { Text("Open contact").underline() }.buttonStyle(.plain)
                        }
                        .font(W.s13).monospacedDigit().foregroundStyle(W.mutedForeground)
                    }
                    Spacer()
                    if b.isOpen && !store.closed {
                        WButton("Mark as seen", icon: "check", variant: .outline, size: .sm) { Task { _ = await store.markAllSeen(bundleID); Mail.invalidate(); toasts.show("Marked as seen") } }
                    } else {
                        WButton("Mark unread", icon: "mailOpen", variant: .outline, size: .sm) { Task { try? await APIClient.shared.markBundleUnseen(bundleID); await store.refresh(bundleID); Mail.invalidate(); toasts.show("Marked unread") } }
                    }
                    WButton("Unbundle", icon: "ungroup", variant: .ghost, size: .sm, muted: true) {
                        dialogs.confirm(title: "Unbundle these messages?", description: "The \(b.threadCount) \(b.threadCount == 1 ? "thread" : "threads") in this bundle go back to being separate rows. The sender stays bundled for future mail; turn that off on their contact page.", action: "Unbundle") {
                            Task {
                                do { try await APIClient.shared.delete("/api/bundles/\(bundleID)") } catch { toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription); return }
                                Mail.invalidate(); toasts.show("Unbundled")
                                router.go(b.latest.bucket == .paperTrail ? .paperTrail : .imbox)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 24)
                LazyVStack(spacing: 16) {
                    ForEach(store.threads.filter { $0.latestMessage != nil }) { t in
                        FeedCard(thread: t, onLeave: leave).opacity(leaving.contains(t.id) ? 0 : 1)
                    }
                    if store.threads.isEmpty { Text("Nothing in this bundle yet.").font(W.sm).foregroundStyle(W.mutedForeground).padding(.horizontal, 8) }
                }
            }
            .onKeys(["Escape": { router.back() }])
            .task {
                if b.isOpen && !marked { marked = true; _ = await store.markAllSeen(bundleID); Mail.invalidate() }
            }
        } else {
            PageColumn(width: 672) { SkeletonBlock(width: 192, height: 32).padding(.bottom, 12); SkeletonBlock(height: 160).padding(.bottom, 12); SkeletonBlock(height: 160) }
                .task { await store.firstLoad(bundleID) }
        }
    }

    private func leave(_ id: String, _ then: @escaping () -> Void) {
        leaving.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { then(); _ = store.remove(id); leaving.remove(id) }
    }
}
