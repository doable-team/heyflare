#if DEBUG
import SwiftUI
import AppKit

/// A scripted walk through the window for debug builds, writing a PNG of every visible
/// window at each stop, so a build can be checked from a terminal.
///
///     HEY_TOUR_DIR=<inside the sandbox container> HEY_TOUR_EMAIL=… HEY_TOUR_PASSWORD=… heyflare.app/Contents/MacOS/heyflare
@MainActor
enum DebugTour {
    static var directory: URL? { ProcessInfo.processInfo.environment["HEY_TOUR_DIR"].map { URL(fileURLWithPath: $0) } }

    static func run(app: AppState, router: Router, ui: UIState) async {
        guard let dir = directory else { return }
        let env = ProcessInfo.processInfo.environment
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for _ in 0..<50 { if case .launching = app.phase { try? await Task.sleep(for: .milliseconds(200)) } else { break } }
        await snap("01-start", dir)
        if case .needsServer = app.phase, let server = env["HEY_TOUR_SERVER"], let url = ServerConfig.normalize(server) {
            await app.setServer(url)
            await app.loadSession()
        }
        if case .signedOut = app.phase, let email = env["HEY_TOUR_EMAIL"], let password = env["HEY_TOUR_PASSWORD"] {
            if let user = try? await APIClient.shared.login(email: email, password: password).user { await app.adopt(user: user) }
        }
        guard case .signedIn = app.phase else { return }
        await pause(3)
        await snap("02-imbox", dir)

        if let thread = (try? await APIClient.shared.imbox()).flatMap({ $0.seenThreads.first ?? $0.newThreads.first }) {
            router.go(.thread(thread.id, peek: false))
            await pause(3)
            await snap("03-thread", dir)
            KeyBus.shared.simulate("r")
            await pause(2)
            await snap("04-reply", dir)
            router.go(.imbox)
            await pause(1)
        }
        Compose.open()
        await pause(2)
        await snap("05-compose", dir)
        Compose.close()
        await pause(1)
        for (name, route) in [("06-feed", AppRoute.feed), ("07-paper-trail", .paperTrail), ("08-screener", .screener), ("09-reply-later", .replyLater), ("10-set-aside", .setAside), ("11-calendar", .calendar), ("12-contacts", .contacts), ("13-files", .files), ("14-settings", .settings("profile")), ("15-drafts", .drafts)] {
            router.go(route)
            await pause(2)
            await snap(name, dir)
        }
        router.go(.imbox)
        await pause(1)
        ui.paletteOpen = true
        await pause(1.5)
        await snap("16-palette", dir)
        ui.paletteOpen = false
        ui.openAssistant()
        await pause(2)
        await snap("17-assistant", dir)
        ui.closeAssistant()
        ui.shortcutsOpen = true
        await pause(1)
        await snap("18-shortcuts", dir)
        ui.shortcutsOpen = false
        try? "done".write(to: dir.appendingPathComponent("done"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func snap(_ name: String, _ dir: URL) async {
        await pause(0.3)
        for (i, window) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).enumerated() {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { continue }
            try? data.write(to: dir.appendingPathComponent("\(name)\(i == 0 ? "" : "-\(i)").png"))
        }
    }
}

extension KeyBus {
    /// Fires a key through the same handlers a real key press would reach.
    func simulate(_ key: String) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { return }
        let e = KeyEvent(key: key, meta: false, shift: false, typing: false, nsEvent: event)
        for h in handlersSnapshot() where h.handle(e) { return }
    }
}
#endif
