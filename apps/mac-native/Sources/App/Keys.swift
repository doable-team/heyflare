import SwiftUI
import AppKit

/// `useKeys`: single-key shortcuts that fire unless the person is typing. Pages register a
/// map while they are on screen; the newest map that handles a key wins, so an open
/// overlay takes precedence over the list beneath it.
@MainActor
final class KeyBus {
    static let shared = KeyBus()

    struct Handler {
        let id: UUID
        let priority: Int
        /// Overlays with their own text field (the palette) still want ↑ ↓ ↵ while typing.
        let whileTyping: Bool
        let handle: (KeyEvent) -> Bool
    }

    struct KeyEvent {
        let key: String          // "j", "ArrowDown", "Escape", "Enter", "#", "?"
        let meta: Bool
        let shift: Bool
        let typing: Bool
        let nsEvent: NSEvent
    }

    private var handlers: [Handler] = []
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let key = Self.name(for: event) else { return event }
            let typing = Self.isTyping()
            let e = KeyEvent(key: key, meta: event.modifierFlags.contains(.command), shift: event.modifierFlags.contains(.shift), typing: typing, nsEvent: event)
            // ⌘-shortcuts belong to the menu bar; ⌥ and ⌃ are left alone too.
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) { return event }
            // `overlayOpen()`: with a dialog, popover or sheet up, only the overlays' own
            // handlers (priority 50 and above) get a say — `#` must not trash the thread
            // behind a "Delete forever?" confirm, and `j` must not walk the list under a menu.
            let overlay = DialogState.shared.isOpen || !PopLayerState.shared.stack.isEmpty || SheetState.shared.isOpen
            for h in self.handlers.sorted(by: { $0.priority > $1.priority }) {
                if overlay && h.priority < 50 { continue }
                if typing && key != "Escape" && !h.whileTyping { continue }
                if h.handle(e) { return nil }
            }
            return event
        }
    }

    func register(priority: Int, whileTyping: Bool = false, _ handle: @escaping (KeyEvent) -> Bool) -> UUID {
        let id = UUID()
        handlers.append(Handler(id: id, priority: priority, whileTyping: whileTyping, handle: handle))
        return id
    }

    func unregister(_ id: UUID) { handlers.removeAll { $0.id == id } }

    func handlersSnapshot() -> [Handler] { handlers.sorted { $0.priority > $1.priority } }

    /// The web's `isTyping`: a text field or text view has focus.
    static func isTyping() -> Bool {
        guard let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder else { return false }
        if responder is NSTextView { return true }
        // Text fields, date pickers and the like: any control that eats keys.
        if responder is NSControl { return true }
        return false
    }

    static func name(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 53: return "Escape"
        case 36, 76: return "Enter"
        case 48: return "Tab"
        case 51: return "Backspace"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 49: return " "
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers, chars.count == 1 else { return nil }
        // With shift, `charactersIgnoringModifiers` gives the unshifted key; `characters`
        // gives the typed one ("?" for shift-/, "#" for shift-3), which is what the web maps.
        if event.modifierFlags.contains(.shift), let typed = event.characters, typed.count == 1 { return typed }
        return chars
    }
}

/// `.onKeys(["j": …])` — bound while the view is on screen.
struct KeysModifier: ViewModifier {
    let map: [String: () -> Void]
    let enabled: Bool
    let priority: Int
    let whileTyping: Bool
    @State private var id: UUID?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { if let id { KeyBus.shared.unregister(id) }; id = nil }
            .onChange(of: enabled) { _, _ in install() }
    }

    private func install() {
        if let id { KeyBus.shared.unregister(id); self.id = nil }
        guard enabled else { return }
        let map = self.map
        id = KeyBus.shared.register(priority: priority, whileTyping: whileTyping) { e in
            guard let fn = map[e.key] else { return false }
            fn()
            return true
        }
    }
}

extension View {
    /// Keys the page answers to. Higher priority wins when several views are listening.
    func onKeys(_ map: [String: () -> Void], enabled: Bool = true, priority: Int = 0, whileTyping: Bool = false) -> some View {
        modifier(KeysModifier(map: map, enabled: enabled, priority: priority, whileTyping: whileTyping))
    }
}
