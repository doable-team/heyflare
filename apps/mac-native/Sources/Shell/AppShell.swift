import SwiftUI
import AppKit

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
                    .onChange(of: g.size.width) { _, _ in pops.closeAll() }
            }
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: ui.sidebarOpen ? 256 : 48)
                    .clipped()
                    // `SidebarRail`: the strip on the sidebar's edge that toggles it.
                    .overlay(alignment: .trailing) { SidebarRail().offset(x: 8) }
                    .zIndex(1)
                PageHost()
                    // `sticky top-0` header: the page scrolls under the bar.
                    .safeAreaInset(edge: .top, spacing: 0) { InsetTopBar() }
                    .overlay(alignment: .bottom) {
                        if let dock = ui.dock { dock }
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
                    .frame(width: 400, height: min(560, ui.viewportHeight - 32))
                    .background(W.popover)
                    .overlay(RoundedRectangle(cornerRadius: W.radiusXl, style: .continuous).strokeBorder(W.border, lineWidth: 1))
                    .rounded(W.radiusXl)
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(16)
            }
        }
        // `backdrop-blur-xs` on the dialog, sheet and palette overlays: the app behind blurs.
        .blur(radius: blurOpen ? 4 : 0)
        .animation(.easeOut(duration: 0.1), value: blurOpen)
        .overlay {
            ZStack(alignment: .topLeading) {
                SheetLayer()
                CommandPalette()
                ShortcutsOverlay()
                DialogLayer()
                PopLayer()
                TooltipLayer()
                ToastLayer()
            }
        }
        .coordinateSpace(name: "window")
        // `ui/sidebar.tsx`: `transition-[width] duration-200 ease-linear`.
        .animation(.linear(duration: 0.2), value: ui.sidebarOpen)
        .animation(.easeOut(duration: 0.15), value: ui.assistantOpen)
        // The keys the web binds everywhere.
        .onKeys([
            "c": { Compose.open() },
            "/": { ui.paletteOpen = true },
            "s": { ui.paletteOpen = true },
            "?": { ui.shortcutsOpen = true },
            "i": { router.go(.imbox) },
            "0": { if case .calendar = router.route { router.go(.imbox) } else { router.go(.calendar(nil)) } },
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
            dialogs.stack.removeAll()
            ui.region = .content
        }
        // A popover is placed by the frame its button had when it opened; once the sidebar
        // slides or the window resizes that frame is stale, so the popover goes instead.
        .onChange(of: ui.sidebarOpen) { _, _ in pops.closeAll(); TooltipState.shared.hideAll() }
        .onChange(of: ui.viewportHeight) { _, _ in pops.closeAll() }
        .onAppear { Mail.app = app }
    }

    /// `overlayOpen()`: something modal is up, so page keys stay quiet.
    private var overlayOpen: Bool {
        !pops.stack.isEmpty || dialogs.isOpen || ui.paletteOpen || ui.shortcutsOpen || sheet.isOpen
    }

    /// The overlays that carry `backdrop-blur-xs` (dropdown menus do not).
    private var blurOpen: Bool {
        dialogs.isOpen || ui.paletteOpen || ui.shortcutsOpen || sheet.isOpen
    }
}

/// `SidebarRail`: a 16pt strip centred on the sidebar's edge; hovering draws a 2pt line in
/// the sidebar border colour and shows a resize cursor, clicking toggles the sidebar.
struct SidebarRail: View {
    @Environment(UIState.self) private var ui
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 16)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle().fill(hovering ? W.border : Color.clear).frame(width: 2)
            }
            .contentShape(Rectangle())
            .onHover { over in
                hovering = over
                if over { (ui.sidebarOpen ? NSCursor.resizeLeft : NSCursor.resizeRight).push() } else { NSCursor.pop() }
            }
            .onTapGesture { withAnimation(.linear(duration: 0.2)) { ui.sidebarOpen.toggle() } }
            .help("Toggle Sidebar")
    }
}

/// `InsetTopBar`: the rail toggle, the page title, the scope — `bg-background/90 backdrop-blur`.
struct InsetTopBar: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui

    var body: some View {
        HStack(spacing: 8) {
            WButton(icon: "panelLeft", variant: .ghost, size: .iconSm, muted: true) {
                withAnimation(.linear(duration: 0.2)) { ui.sidebarOpen.toggle() }
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
        .background { BlurBehind() }
    }
}

/// `backdrop-blur`: an `NSVisualEffectView` blending with what is behind it in the window.
struct BlurBehind: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .withinWindow
        v.material = .headerView
        v.state = .active
        return v
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// `<main>`: the page in a scroll view with the web's padding, or the calendar filling the
/// height and scrolling inside itself.
struct PageHost: View {
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if router.route.fullHeight {
                page
                    // `px-8 pt-4 pb-3`.
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        page
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 32)
                            .padding(.top, 16)
                            .padding(.bottom, 96)
                            // Hands the page's NSScrollView to `PageScroll`, so keys can
                            // scroll by a fraction of the window (the web's `scrollPageBy`).
                            .background(PageScrollHook())
                    }
                    // The web's thin overlay scrollbar (`scrollbar-width: thin`): shown while
                    // scrolling, over the content, never in a gutter of its own.
                    .scrollIndicators(.automatic)
                    // Lets a list further down (ThreadListView) keep the keyboard cursor
                    // on screen without owning the scroll view itself.
                    .environment(\.pageScrollProxy, proxy)
                }
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
        case .contactEmail(let email, let account): ContactByEmailPage(email: email, account: account)
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
        case .calendar(let date): CalendarPage(initialDate: date)
        case .journal(let date): if let date { JournalEntryPage(date: date) } else { JournalIndexPage() }
        case .habits: HabitsPage()
        case .settings(let tab): SettingsPage(tab: tab)
        case .search(let q): SearchPage(query: q)
        case .compose(let to, let subject): ComposePage(to: to, subject: subject)
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

/// `scrollPageBy` in cardKeys.ts: the page scrolls by a fraction of the window, smoothly.
@MainActor
enum PageScroll {
    weak static var scrollView: NSScrollView?

    static func by(_ fraction: CGFloat) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        let step = round(clip.bounds.height * fraction)
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(max(origin.y + step, 0), maxY)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(origin)
        }
        sv.reflectScrolledClipView(clip)
    }
}

/// Finds the scroll view the page sits in once the view lands in the window.
private struct PageScrollHook: NSViewRepresentable {
    func makeNSView(context: Context) -> HookView { HookView() }
    func updateNSView(_ view: HookView, context: Context) {}
    final class HookView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let sv = enclosingScrollView {
                PageScroll.scrollView = sv
                // Browsers overlay their scrollbar; a legacy scroller's gutter would shift the
                // centred column left by half its width.
                sv.scrollerStyle = .overlay
                sv.autohidesScrollers = true
            }
        }
    }
}

extension View {
    /// `useCardScroll`: arrows and j / k scroll a reading page by a quarter of the window,
    /// Page Up / Down and Space by most of it. `arrows: false` keeps only the big jumps for
    /// pages whose arrows already drive a cursor (the thread's message cursor).
    func cardScrollKeys(arrows: Bool = true, enabled: Bool = true) -> some View {
        var map: [String: () -> Void] = [
            "PageDown": { PageScroll.by(0.9) }, "PageUp": { PageScroll.by(-0.9) }, " ": { PageScroll.by(0.9) },
        ]
        if arrows {
            map["ArrowDown"] = { PageScroll.by(0.25) }; map["ArrowUp"] = { PageScroll.by(-0.25) }
            map["j"] = { PageScroll.by(0.25) }; map["k"] = { PageScroll.by(-0.25) }
        }
        return onKeys(map, enabled: enabled)
    }
}

private struct PageScrollProxyKey: EnvironmentKey { static let defaultValue: ScrollViewProxy? = nil }
extension EnvironmentValues {
    /// The page's own scroll view, so a keyboard cursor further down can keep itself visible
    /// without every list needing its own `ScrollView`.
    var pageScrollProxy: ScrollViewProxy? {
        get { self[PageScrollProxyKey.self] }
        set { self[PageScrollProxyKey.self] = newValue }
    }
}
