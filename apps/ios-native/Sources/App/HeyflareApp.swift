import SwiftUI

@main
struct HeyflareApp: App {
    @State private var app = AppState()
    @State private var navigator = Navigator()
    @State private var toasts = ToastCenter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(navigator)
                .environment(toasts)
                .tint(Theme.Colors.foreground)
                .preferredColorScheme(colorScheme)
                .task {
                    // The cache is read synchronously afterwards, so it has to be in
                    // memory before the first screen is drawn.
                    await ContentCache.shared.preload()
                    await app.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Anything still only in memory is written before the app is suspended.
                    if phase != .active { ContentCache.shared.flushNow(); app.resignedActive() }
                    if phase == .active { Task { await app.becameActive() } }
                }
        }
    }

    /// The owner's theme choice lives in user settings on the server; "system" means
    /// follow the device, which is what a nil scheme does.
    private var colorScheme: ColorScheme? {
        switch app.user?.settings.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
