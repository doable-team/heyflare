import SwiftUI
import AppKit
import UserNotifications

/// The app's long-lived objects, reachable from the SwiftUI scene and from the AppKit
/// delegate alike.
@MainActor
enum Services {
    static let app = AppState()
    static let router = Router()
    static let ui = UIState()
}

/// AppKit's window restoration keys SwiftUI windows by the root view's type. After that
/// type changes between builds, restoration fails and SwiftUI opens no window at all —
/// on some Macs, for good. So the window is hosted here, by hand, when the scene has not
/// produced one; the SwiftUI scene still provides the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    override init() {
        // Browsers draw text without macOS font smoothing, which is why the same weight of
        // Geist looks heavier in an AppKit window than in the web app. Registering it off
        // here (rather than writing it) keeps our text the weight the web draws.
        UserDefaults.standard.register(defaults: ["AppleFontSmoothing": 0])
        super.init()
    }

    private var hosted: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if NSApp.windows.filter({ $0.isVisible }).isEmpty { openHostedWindow() }
        }
    }

    // The window is hosted here rather than by a WindowGroup, so SwiftUI's scenePhase does
    // not track it. AppKit's own activation is what says whether someone is looking.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await Services.app.becameActive() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        ContentCache.shared.flushNow()
        Services.app.resignedActive()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the hosted window is the whole reopen; letting SwiftUI add a WindowGroup
        // window too would run a second RootHost.
        // A minimised window does not count as visible, but it is still the window.
        if let w = NSApp.windows.first(where: { $0.isMiniaturized }) { w.deminiaturize(nil); return false }
        if !flag { openHostedWindow(); return false }
        return true
    }

    /// `ComposeContext.tsx`: a message still inside its undo window goes out when the app
    /// closes (the web fires a beacon on `beforeunload`), rather than being dropped.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Compose.hasPendingSend else { return .terminateNow }
        Task { @MainActor in
            await Compose.flushPendingSend()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Notifications

    /// `native.notify(title, body, url)`: the deep link rides in `userInfo` and is followed
    /// when the notification is clicked (the web's `takePendingUrl` on focus).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["url"] as? String else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if path.hasPrefix("/t/") { Services.router.go(.thread(String(path.dropFirst(3)), peek: false)) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    @MainActor
    private func openHostedWindow() {
        if let hosted { hosted.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("heyflare.main")
        window.minSize = NSSize(width: 960, height: 600)
        window.title = "heyflare"
        window.contentView = NSHostingView(rootView: RootHost(app: Services.app, router: Services.router, ui: Services.ui))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hosted = window
    }
}

/// `Shell.tsx`: a system notification for the newest Imbox thread whenever `imbox_new`
/// grows while the window is not in front.
@MainActor
enum NewMailNotifier {
    private static var previousNew: Int?
    private static var asked = false

    static func countsChanged(_ counts: Counts) {
        let now = counts.imboxNew
        defer { previousNew = now }
        guard let prev = previousNew, now > prev, !NSApp.isActive else { return }
        Task {
            guard let thread = (try? await APIClient.shared.imbox())?.newThreads.first else { return }
            await notify(title: thread.lastFrom.name.isEmpty ? thread.lastFrom.email : thread.lastFrom.name,
                         body: thread.subject.isEmpty ? "(no subject)" : thread.subject,
                         url: "/t/\(thread.id)")
        }
    }

    static func notify(title: String, body: String, url: String) async {
        let center = UNUserNotificationCenter.current()
        if !asked {
            asked = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["url": url]
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

@main
struct HeyflareMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var app: AppState { Services.app }
    private var router: Router { Services.router }
    private var ui: UIState { Services.ui }
    var body: some Scene {
        WindowGroup(id: "main") {
            RootHost(app: app, router: router, ui: ui)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands { MenuCommands(app: app, router: router, ui: ui) }
    }

}

/// The window's content with every environment object attached; split out of the scene so
/// the type checker has a view to look at rather than a scene.
struct RootHost: View {
    let app: AppState
    let router: Router
    let ui: UIState
    @Environment(\.scenePhase) private var scenePhase

    private var colorScheme: ColorScheme? {
        switch app.user?.settings.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        RootView()
            .ignoresSafeArea()
            .environment(app)
            .environment(router)
            .environment(ui)
            .environment(PopLayerState.shared)
            .environment(DialogState.shared)
            .environment(SheetState.shared)
            .environment(Toasts.shared)
            .environment(TooltipState.shared)
            .font(W.sm)
            .tint(W.foreground)
            .preferredColorScheme(colorScheme)
            .frame(minWidth: 960, minHeight: 600)
            .task { await launch() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { ContentCache.shared.flushNow() }
                if phase == .active { Task { await app.becameActive() } }
            }
            .onChange(of: app.counts, initial: true) { _, counts in
                let n = counts.imboxNew + counts.screener
                NSApp?.dockTile.badgeLabel = n > 0 ? String(n) : nil
                NewMailNotifier.countsChanged(counts)
            }
            .onAppear {
                // Not in `App.init`: touching NSEvent there instantiates NSApplication before
                // SwiftUI does, and the window group then never opens a window.
                KeyBus.shared.install()
                for w in NSApp.windows {
                    w.isMovableByWindowBackground = true
                    // SwiftUI keys saved window state by the root view's type. When that type
                    // changes between builds, AppKit's restoration fails and no window opens at
                    // all — so this window is never saved for restoration.
                    w.isRestorable = false
                }
            }
    }

    private func launch() async {
        await ContentCache.shared.preload()
        await app.start()
        #if DEBUG
        await DebugTour.run(app: app, router: router, ui: ui)
        #endif
    }
}

/// The menu bar the Tauri app shipped (`apps/mac/src-tauri/src/lib.rs`): heyflare (Settings…
/// ⌘, / Switch Server…), File (New Message ⌘N), View (Imbox ⌘1 … Contacts ⌘9, Toggle Sidebar
/// ⌘B, Assistant ⌘J, Reload ⌘R, Full Screen), Go (Search ⌘K, Back ⌘[, Forward ⌘]), Help
/// (heyflare on GitHub). `0` stays a plain key: ⌘0 was "Actual Size" there, and a native
/// window has no page zoom.
struct MenuCommands: Commands {
    let app: AppState
    let router: Router
    let ui: UIState

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router.go(.settings("profile")) }.keyboardShortcut(",", modifiers: .command)
            Button("Switch Server…") { Task { await app.clearServer() } }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Message") { Compose.open() }.keyboardShortcut("n", modifiers: .command)
        }
        // The system View menu keeps "Enter Full Screen"; the Tauri items go in front of it.
        CommandGroup(replacing: .sidebar) {
            Button("Imbox") { router.go(.imbox) }.keyboardShortcut("1", modifiers: .command)
            Button("The Feed") { router.go(.feed) }.keyboardShortcut("2", modifiers: .command)
            Button("Paper Trail") { router.go(.paperTrail) }.keyboardShortcut("3", modifiers: .command)
            Button("Screener") { router.go(.screener) }.keyboardShortcut("4", modifiers: .command)
            Button("Reply Later") { router.go(.replyLater) }.keyboardShortcut("5", modifiers: .command)
            Button("Set Aside") { router.go(.setAside) }.keyboardShortcut("6", modifiers: .command)
            Button("Bubble Up") { router.go(.bubbleUp) }.keyboardShortcut("7", modifiers: .command)
            Button("Previously Seen") { router.go(.previouslySeen) }.keyboardShortcut("8", modifiers: .command)
            Button("Contacts") { router.go(.contacts) }.keyboardShortcut("9", modifiers: .command)
            Divider()
            Button("Toggle Sidebar") { withAnimation(.linear(duration: 0.2)) { ui.sidebarOpen.toggle() } }.keyboardShortcut("b", modifiers: .command)
            Button("Assistant") { ui.toggleAssistant() }.keyboardShortcut("j", modifiers: .command)
            Divider()
            // The webview's reload: fetch the session and every list again.
            Button("Reload") { Task { await app.loadSession(); Mail.invalidate() } }.keyboardShortcut("r", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Search") { ui.paletteOpen = true }.keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Back") { router.back() }.keyboardShortcut("[", modifiers: .command)
            Button("Forward") { router.goForward() }.keyboardShortcut("]", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("heyflare on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/doable-team/heyflare")!) }
        }
    }
}

/// Launch → server → login → the app.
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            W.background.ignoresSafeArea()
            switch app.phase {
            case .launching:
                VStack(spacing: 16) {
                    Mark(size: 40)
                    HStack(spacing: 8) { Spinner(size: 14); Text("Loading…") }
                        .font(W.sm).foregroundStyle(W.mutedForeground)
                }
            case .needsServer:
                ServerSetupPage()
            case .signedOut(let message):
                LoginPage(initialMessage: message)
            case .needsSetup:
                SetupPage()
            case .signedIn:
                AppShell()
            }
        }
        .animation(.easeOut(duration: 0.15), value: app.phase)
    }
}

/// The heyflare mark: an "h" whose flare is a spark, as in `Logo.tsx`.
struct Mark: View {
    var size: CGFloat = 20
    var body: some View {
        HeyflareMark(size: size, plate: W.foreground, ink: W.background)
    }
}
