import SwiftUI
import AppKit

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hosted: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if NSApp.windows.filter({ $0.isVisible }).isEmpty { openHostedWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the hosted window is the whole reopen; letting SwiftUI add a WindowGroup
        // window too would run a second RootHost.
        if !flag { openHostedWindow(); return false }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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

/// The menu bar the Tauri app shipped: ⌘N, ⌘K, ⌘J, ⌘B, ⌘1–9, ⌘[ ⌘].
struct MenuCommands: Commands {
    let app: AppState
    let router: Router
    let ui: UIState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { Compose.open() }.keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router.go(.settings("profile")) }.keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Imbox") { router.go(.imbox) }.keyboardShortcut("1", modifiers: .command)
            Button("The Feed") { router.go(.feed) }.keyboardShortcut("2", modifiers: .command)
            Button("Paper Trail") { router.go(.paperTrail) }.keyboardShortcut("3", modifiers: .command)
            Button("Screener") { router.go(.screener) }.keyboardShortcut("4", modifiers: .command)
            Button("Reply Later") { router.go(.replyLater) }.keyboardShortcut("5", modifiers: .command)
            Button("Set Aside") { router.go(.setAside) }.keyboardShortcut("6", modifiers: .command)
            Button("Bubble Up") { router.go(.bubbleUp) }.keyboardShortcut("7", modifiers: .command)
            Button("Previously Seen") { router.go(.previouslySeen) }.keyboardShortcut("8", modifiers: .command)
            Button("Contacts") { router.go(.contacts) }.keyboardShortcut("9", modifiers: .command)
            Button("Calendar") { router.go(.calendar) }.keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Back") { router.back() }.keyboardShortcut("[", modifiers: .command)
            Button("Forward") { router.goForward() }.keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Search & Commands…") { ui.paletteOpen.toggle() }.keyboardShortcut("k", modifiers: .command)
            Button("Assistant") { ui.toggleAssistant() }.keyboardShortcut("j", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { withAnimation(.easeOut(duration: 0.15)) { ui.sidebarOpen.toggle() } }.keyboardShortcut("b", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Send") { Compose.sendShortcut() }.keyboardShortcut(.return, modifiers: .command)
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
