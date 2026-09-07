import SwiftUI

/// `Shell.tsx`: the sidebar, the inset with its 44pt top bar, the page, and every overlay.
struct AppShell: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @Environment(PopLayerState.self) private var pops
    @Environment(DialogState.self) private var dialogs
    @Environment(SheetState.self) private var sheet

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The window height, published so `vh` lengths resolve as they do on the web.
            GeometryReader { g in
                Color.clear
                    .onAppear { ui.viewportHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in ui.viewportHeight = h }
            }
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: ui.sidebarOpen ? 256 : 48)
                    .clipped()
                VStack(spacing: 0) {
                    InsetTopBar()
                    PageHost()
                        .overlay(alignment: .bottom) {
                            if let dock = ui.dock { dock }
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(W.background)
                .overlay(alignment: .bottomTrailing) {
                    if !ui.assistantOpen { AssistantFab() }
                }
                if ui.assistantOpen && ui.assistantDocked {
                    AssistantPanel()
                        .frame(width: ui.assistantWidth)
                        .edgeLine(.leading)
                        .transition(.move(edge: .trailing))
                }
            }
            if ui.assistantOpen && !ui.assistantDocked {
                AssistantPanel()
                    .frame(width: 400, height: 560)
                    .background(W.popover)
                    .overlay(RoundedRectangle(cornerRadius: W.radiusXl, style: .continuous).strokeBorder(W.border, lineWidth: 1))
                    .rounded(W.radiusXl)
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)
            }
            SheetLayer()
            CommandPalette()
            ShortcutsOverlay()
            DialogLayer()
            PopLayer()
            ToastLayer()
        }
        .coordinateSpace(name: "window")
        .animation(.easeOut(duration: 0.15), value: ui.sidebarOpen)
        .animation(.easeOut(duration: 0.15), value: ui.assistantOpen)
        // The keys the web binds everywhere.
        .onKeys([
            "c": { Compose.open() },
            "/": { ui.paletteOpen = true },
            "s": { ui.paletteOpen = true },
            "?": { ui.shortcutsOpen = true },
            "i": { router.go(.imbox) },
            "0": { router.go(router.route == .calendar ? .imbox : .calendar) },
            "q": { Compose.undoSend() },
        ], enabled: !overlayOpen, priority: -10)
        .onKeys([
            "Escape": {
                if !pops.stack.isEmpty { pops.closeTop() }
                else if dialogs.isOpen { dialogs.dismissTop() }
                else if ui.paletteOpen { ui.paletteOpen = false }
                else if ui.shortcutsOpen { ui.shortcutsOpen = false }
                else if sheet.isOpen { sheet.requestClose() }
            },
        ], enabled: overlayOpen, priority: 100)
        .onChange(of: router.route) { _, _ in
            pops.closeAll()
            ui.region = .content
        }
        .onAppear { Mail.app = app }
    }

    /// `overlayOpen()`: something modal is up, so page keys stay quiet.
    private var overlayOpen: Bool {
        !pops.stack.isEmpty || dialogs.isOpen || ui.paletteOpen || ui.shortcutsOpen || sheet.isOpen
    }
}

/// `InsetTopBar`: the rail toggle, the page title, the scope.
struct InsetTopBar: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui

    var body: some View {
        HStack(spacing: 8) {
            WButton(icon: "panelLeft", variant: .ghost, size: .iconSm, muted: true, help: "Toggle sidebar (⌘B)") {
                withAnimation(.easeOut(duration: 0.15)) { ui.sidebarOpen.toggle() }
            }
            HStack(spacing: 6) {
                Text(router.route.title).font(W.font(14, 500)).foregroundStyle(W.foreground).lineLimit(1)
                if app.accounts.count > 1 {
                    Icon("chevronRight", size: 12).foregroundStyle(W.tertiary)
                    Text(app.scope == ServerConfig.allAccounts ? "All accounts" : (app.scopedAccount?.email ?? "")).font(W.sm).foregroundStyle(W.mutedForeground).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(W.background.opacity(0.9))
    }
}

/// `<main>`: the page in a scroll view with the web's padding, or the calendar filling the
/// height and scrolling inside itself.
struct PageHost: View {
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if router.route.fullHeight {
                page
                    // Full-height pages run edge to edge: the web's card lands at x=292.
                    .padding(.horizontal, 36)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    page
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 32)
                        .padding(.top, 16)
                        .padding(.bottom, 96)
                }
                // Browsers overlay their scrollbar; a reserved gutter would shift the
                // centred column left by half its width.
                .scrollIndicators(.never)
            }
        }
        .id(router.route)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var page: some View {
        switch router.route {
        case .imbox: ImboxPage()
        case .feed: FeedPage()
        case .paperTrail: PaperTrailPage()
        case .screener: ScreenerPage()
        case .screenedOut: ScreenedOutPage()
        case .powerThrough: PowerThroughPage()
        case .replyLater: ReplyLaterPage()
        case .setAside: SetAsidePage()
        case .bubbleUp: BubbleUpPage()
        case .previouslySeen: ListPage(kind: .everything, title: "Previously seen", subtitle: "Everything you've already looked at.", previouslySeen: true)
        case .trash: ListPage(kind: .trash, title: "Trash", subtitle: "Gone, but not forgotten. Yet.")
        case .sent: ListPage(kind: .sent, title: "Sent", subtitle: "Things you've said.")
        case .everything: ListPage(kind: .everything, title: "Everything", subtitle: "All your mail, every bucket, one list.", showBucket: true)
        case .contacts: ContactsPage()
        case .contact(let id): ContactDetailPage(contactID: id)
        case .contactEmail(let email, _): ContactByEmailPage(email: email)
        case .clips: ClipsPage()
        case .collections: CollectionsPage()
        case .collection(let id): CollectionDetailPage(collectionID: id)
        case .files: FilesPage()
        case .labels: LabelsPage()
        case .label(let id): LabelThreadsPage(labelID: id)
        case .drafts: DraftsPage(scheduled: false)
        case .scheduled: DraftsPage(scheduled: true)
        case .thread(let id, let peek): ThreadPageView(threadID: id, peek: peek)
        case .bundle(let id): BundlePage(bundleID: id)
        case .calendar: CalendarPage()
        case .journal: ComingSoonPage(title: "Journal", body: "The journal lives on the web and the phone for now.")
        case .habits: ComingSoonPage(title: "Habits", body: "Habits live on the web and the phone for now.")
        case .settings(let tab): SettingsPage(tab: tab)
        case .search(let q): SearchPage(query: q)
        }
    }
}

struct ComingSoonPage: View {
    let title: String
    let body_: String
    init(title: String, body: String) { self.title = title; self.body_ = body }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: title, subtitle: body_)
        }
        .frame(maxWidth: 768)
        .frame(maxWidth: .infinity)
    }
}

/// The page column widths the web uses: `max-w-3xl` (768), `max-w-2xl` (672), 1100.
struct PageColumn<Content: View>: View {
    var width: CGFloat = 768
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: width)
            .frame(maxWidth: .infinity)
    }
}
