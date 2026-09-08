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
        // The container can already hold a real, signed-in session from ordinary use — the tour
        // types into threads, toggles them and sends mail, so it must never touch one it did not
        // establish itself. Refusing to run against a session that already exists, on whatever
        // server it happens to point at, is the only check that cannot be fooled by the server
        // matching what HEY_TOUR_SERVER expected.
        if case .signedIn = app.phase {
            check("refused: already signed in", false, dir)
            try? "done".write(to: dir.appendingPathComponent("done"), atomically: true, encoding: .utf8)
            return
        }
        if case .needsServer = app.phase, let server = env["HEY_TOUR_SERVER"], let url = ServerConfig.normalize(server) {
            await app.setServer(url)
            await app.loadSession()
        }
        if case .signedOut = app.phase {
            await pause(1.5)
            await snap("01b-login", dir)
        }
        if case .signedOut = app.phase, let email = env["HEY_TOUR_EMAIL"], let password = env["HEY_TOUR_PASSWORD"] {
            if let user = try? await APIClient.shared.login(email: email, password: password).user { await app.adopt(user: user) }
        }
        guard case .signedIn = app.phase else { return }
        // Typed keys only reach a field when the window is key; the launch from a shell
        // does not always bring the app forward.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        await pause(3)
        check("window is key", NSApp.keyWindow != nil, dir)
        check("changes endpoint", (try? await APIClient.shared.changes()) != nil, dir)
        await snap("02-imbox", dir)

        // Keyboard cursor over the list.
        KeyBus.shared.simulate("j"); KeyBus.shared.simulate("j")
        await pause(0.5)
        await snap("02b-cursor", dir)

        if let thread = (try? await APIClient.shared.imbox()).flatMap({ $0.seenThreads.first ?? $0.newThreads.first }) {
            router.go(.thread(thread.id, peek: false))
            await pause(3)
            await snap("03-thread", dir)
            // Reply later and back, checking the toast and the thread's state follow.
            KeyBus.shared.simulate("l")
            await pause(1.5)
            await snap("03b-reply-later", dir)
            check("reply-later toast", Toasts.shared.items.contains { $0.title.contains("Reply Later") }, dir)
            if let d = try? await APIClient.shared.thread(thread.id, peek: true) { check("reply-later applied", d.summary.replyLater, dir) }
            KeyBus.shared.simulate("l")
            await pause(1.5)
            let draftsBefore = (try? await APIClient.shared.drafts())?.count ?? -1
            KeyBus.shared.simulate("r")
            await pause(2.5)
            await snap("04-reply", dir)
            // Opening a reply is not an edit: nothing may be autosaved yet.
            check("reply open saves nothing", (try? await APIClient.shared.drafts())?.count == draftsBefore, dir)
            check("reply focuses body", window?.firstResponder is NSTextView, dir)
            // Type into the inline reply's body (the reply focuses it) and let it autosave.
            type("Thanks, will do.")
            await pause(2.5)
            await snap("04b-reply-typed", dir)
            check("inline reply model", Compose.current != nil, dir)
            check("inline reply typed", Compose.current?.editor.plainText().contains("Thanks, will do.") == true, dir)
            KeyBus.shared.simulate("Escape")
            await pause(1.5)
            check("reply escape closes", Compose.current == nil, dir)
            let replyDrafts = (try? await APIClient.shared.drafts()) ?? []
            check("reply draft saved on escape", replyDrafts.count == draftsBefore + 1, dir)
            for d in replyDrafts where d.subject.hasPrefix("Re: ") && d.threadID == thread.id { try? await APIClient.shared.deleteDraft(d.id) }
            router.go(.imbox)
            await pause(1)
        }
        Compose.open()
        await pause(2)
        await snap("05-compose", dir)
        // Recipient autocomplete → chip → subject → body → autosave → close saves a draft.
        type("marc")
        await pause(1.5)
        await snap("05b-suggest", dir)
        key(36) // return: takes the suggestion
        await pause(0.5)
        check("recipient chip", Compose.current?.to.first?.email.contains("marcus") == true, dir)
        focus(placeholder: "Subject")
        await pause(0.3)
        type("Tour draft")
        focus(placeholder: "Write something…")
        await pause(0.3)
        type("Written by the tour.")
        await pause(2.5)
        await snap("05c-filled", dir)
        check("subject typed", Compose.current?.subject == "Tour draft", dir)
        check("body typed", Compose.current?.editor.plainText().contains("Written by the tour") == true, dir)
        check("draft autosaved", Compose.current?.draftID != nil, dir)
        KeyBus.shared.simulate("Escape")
        await pause(2)
        check("sheet closed", !SheetState.shared.isOpen, dir)
        let drafts = (try? await APIClient.shared.drafts()) ?? []
        check("draft on server", drafts.contains { $0.subject == "Tour draft" }, dir)
        for d in drafts where d.subject == "Tour draft" { try? await APIClient.shared.deleteDraft(d.id) }
        for (name, route) in [("06-feed", AppRoute.feed), ("07-paper-trail", .paperTrail), ("08-screener", .screener), ("09-reply-later", .replyLater), ("10-set-aside", .setAside), ("11-calendar", .calendar), ("12-contacts", .contacts), ("13-files", .files), ("14-settings", .settings("profile")), ("14b-settings-calendar", .settings("calendar")), ("15-drafts", .drafts), ("19-habits", .habits), ("20-journal", .journal(nil)), ("21-journal-today", .journal(CalDate.todayKey))] {
            router.go(route)
            await pause(2)
            await snap(name, dir)
        }
        // Habits: a row made through the API draws, Enter ticks today off, then it goes.
        if let habit = try? await CalendarAPI.createHabit(name: "Tour habit", icon: "🌱", days: [0, 1, 2, 3, 4, 5, 6], color: "#37352f") {
            router.go(.habits)
            await pause(2)
            KeyBus.shared.simulate("j"); KeyBus.shared.simulate("Enter")
            await pause(1.5)
            await snap("19b-habit-ticked", dir)
            let fresh = (try? await CalendarAPI.habits(from: CalDate.addingDays(-83, toKey: CalDate.todayKey), to: CalDate.todayKey))?.first { $0.id == habit.id }
            check("habit ticked today", fresh?.completions.contains(CalDate.todayKey) == true, dir)
            try? await CalendarAPI.deleteHabit(id: habit.id)
        }
        // Journal: what is typed lands on the server within the autosave window.
        let day = "2001-01-01"
        router.go(.journal(day))
        await pause(2.5)
        type("Written by the tour.")
        await pause(2)
        await snap("21b-journal-typed", dir)
        let saved = (try? await CalendarAPI.journal(date: day))?.journalHTML ?? ""
        check("journal autosaved", saved.contains("Written by the tour"), dir)
        _ = try? await CalendarAPI.saveJournal(date: day, html: "")
        router.go(.imbox)
        await pause(1)
        ui.paletteOpen = true
        await pause(1.5)
        await snap("16-palette", dir)
        type("feed")
        await pause(0.8)
        await snap("16b-palette-typed", dir)
        KeyBus.shared.simulate("Enter")
        await pause(1)
        check("palette enter navigates", router.route == .feed, dir)
        ui.paletteOpen = false
        router.go(.imbox)
        await pause(1)
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

    private static var window: NSWindow? { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } }

    /// Types into whatever has focus. Straight into the responder rather than through the
    /// event queue: a shell-launched app is often not the key window, and a key event that
    /// finds no key window lands as a shortcut instead of a letter.
    private static func type(_ text: String) {
        guard let responder = window?.firstResponder else { return }
        if let tv = responder as? NSTextView { tv.insertText(text, replacementRange: tv.selectedRange()) }
        else if let field = responder as? NSTextField { field.stringValue += text; field.sendAction(field.action, to: field.target) }
    }

    /// 36 = return, 48 = tab.
    private static func key(_ code: UInt16, _ chars: String = "") {
        guard let window, let responder = window.firstResponder else { return }
        switch code {
        case 36: (responder as? NSTextView)?.insertNewline(nil)
        case 48: window.selectNextKeyView(nil)
        default: break
        }
    }

    /// Puts the focus in the field showing `placeholder` — a Tab does not walk SwiftUI's
    /// fields from outside the key window, so the composer's fields are picked directly.
    private static func focus(placeholder: String) {
        guard let window, let root = window.contentView else { return }
        func walk(_ v: NSView) -> NSView? {
            if let f = v as? NSTextField, f.placeholderString == placeholder { return f }
            if let t = v as? PlaceholderTextView, t.placeholder == placeholder { return t }
            for s in v.subviews { if let hit = walk(s) { return hit } }
            return nil
        }
        if let hit = walk(root) { window.makeFirstResponder(hit) }
    }

    /// Appends a pass/fail line to results.txt.
    private static func check(_ name: String, _ ok: Bool, _ dir: URL) {
        let line = "\(ok ? "PASS" : "FAIL") \(name)\n"
        let url = dir.appendingPathComponent("results.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

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
