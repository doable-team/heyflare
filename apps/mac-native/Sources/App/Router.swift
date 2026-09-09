import SwiftUI
import Observation

/// The web's routes, as a value. One page fills the content column at a time; the thread
/// page replaces the list, and Back returns, exactly as the browser does it.
enum AppRoute: Hashable {
    case imbox, feed, paperTrail, screener, screenedOut, powerThrough
    case replyLater, setAside, bubbleUp
    case previouslySeen, trash, sent, everything
    case contacts, contact(String), contactEmail(String, account: String?)
    case clips, collections, collection(String), files, labels, label(String)
    case drafts, scheduled
    case thread(String, peek: Bool), bundle(String)
    /// `/calendar?d=YYYY-MM-DD`: the day to reveal on open, or nil for today.
    case calendar(String?), journal(String?), habits
    case settings(String)
    case search(String)
    /// `/compose?to=&subject=`: the in-page composer.
    case compose(to: String, subject: String)

    var title: String {
        switch self {
        case .imbox: return "Imbox"
        case .feed: return "The Feed"
        case .paperTrail: return "Paper Trail"
        case .screener: return "Screener"
        case .screenedOut: return "Screened out"
        case .powerThrough: return "Power through new"
        case .replyLater: return "Reply Later"
        case .setAside: return "Set Aside"
        case .bubbleUp: return "Bubble Up"
        case .previouslySeen: return "Previously Seen"
        case .trash: return "Trash"
        case .sent: return "Sent"
        case .everything: return "Everything"
        case .contacts, .contact, .contactEmail: return "Contacts"
        case .clips: return "Clips"
        case .collections, .collection: return "Collections"
        case .files: return "Files"
        case .labels, .label: return "Labels"
        case .drafts: return "Drafts"
        case .scheduled: return "Scheduled"
        case .thread: return "Thread"
        case .bundle: return "Bundle"
        case .calendar: return "Calendar"
        case .journal: return "Journal"
        case .habits: return "Habits"
        case .settings: return "Settings"
        case .search: return "Search"
        case .compose: return "New message"
        }
    }

    /// The sidebar item this route lights up.
    var navKey: String {
        switch self {
        case .imbox: return "/"
        case .feed: return "/feed"
        case .paperTrail: return "/paper-trail"
        case .screener: return "/screener"
        case .screenedOut: return "/screened-out"
        case .replyLater: return "/reply-later"
        case .setAside: return "/set-aside"
        case .bubbleUp: return "/bubble-up"
        case .previouslySeen: return "/previously-seen"
        case .trash: return "/trash"
        case .sent: return "/sent"
        case .everything: return "/everything"
        case .contacts, .contact, .contactEmail: return "/contacts"
        case .clips: return "/clips"
        case .collections, .collection: return "/collections"
        case .files: return "/files"
        case .labels, .label: return "/labels"
        case .drafts: return "/drafts"
        case .scheduled: return "/scheduled"
        case .calendar: return "/calendar"
        case .journal: return "/journal"
        case .habits: return "/habits"
        case .settings: return "/settings"
        default: return ""
        }
    }

    /// Pages that scroll inside themselves (the calendar) rather than growing the page.
    var fullHeight: Bool { if case .calendar = self { return true }; return false }
}

/// Where the window is, with the history the browser would have kept.
@MainActor
@Observable
final class Router {
    private(set) var route: AppRoute = .imbox
    private var history: [AppRoute] = []
    private var forward: [AppRoute] = []

    /// `nav(to)`: push.
    func go(_ next: AppRoute) {
        guard next != route else { return }
        history.append(route)
        if history.count > 50 { history.removeFirst() }
        forward.removeAll()
        route = next
    }

    /// `nav(to, { replace: true })`.
    func replace(_ next: AppRoute) { route = next }

    /// `nav(-1)`: back, or the Imbox when there is nothing to go back to.
    func back() {
        if let prev = history.popLast() {
            forward.append(route)
            route = prev
        } else {
            route = .imbox
        }
    }

    func goForward() {
        if let next = forward.popLast() {
            history.append(route)
            route = next
        }
    }

    var canGoBack: Bool { !history.isEmpty }
}

/// App-wide UI state the web keeps in small stores: the sidebar rail, the palette, the
/// shortcuts overlay, the assistant panel and which keyboard region has focus.
@MainActor
@Observable
final class UIState {
    var sidebarOpen = UserDefaults.standard.object(forKey: "hey.rail") as? Bool ?? true { didSet { UserDefaults.standard.set(sidebarOpen, forKey: "hey.rail") } }
    var moreOpen = UserDefaults.standard.bool(forKey: "hey.more") { didSet { UserDefaults.standard.set(moreOpen, forKey: "hey.more") } }
    var paletteOpen = false
    var shortcutsOpen = false
    /// Keyboard focus region: the sidebar owns ↑↓↵ while it is focused.
    var region: Region = .content
    var sidebarFocusIndex = 0
    // `assistantStore.ts`: `open`, `mode`, `width` and `conversationId` live in `hey.assistant`,
    // so a relaunch reopens the panel on the same chat at the same width.
    var assistantOpen = AssistantPrefs.load().open { didSet { saveAssistant() } }
    var assistantDocked = true
    var assistantWidth: CGFloat = AssistantPrefs.load().width { didSet { saveAssistant() } }
    var assistantConversationID: String? = AssistantPrefs.load().conversationID { didSet { saveAssistant() } }
    var assistantContext: [ContextChip] = []
    /// Bumped whenever something asks the assistant's input for focus (→ with the panel
    /// already open, the FAB, a suggestion chip).
    var assistantFocusRequest = 0

    private func saveAssistant() {
        AssistantPrefs(open: assistantOpen, width: assistantWidth, conversationID: assistantConversationID).save()
    }

    /// `clampWidth`: 320–720, 400 when unset.
    static func clampAssistantWidth(_ w: CGFloat) -> CGFloat { AssistantPrefs.clamp(w) }
    /// The thread on screen, for the assistant's context chip.
    var currentThread: ContextChip?
    /// A view the page pins to the bottom of the content area (piles, the thread's action bar).
    private(set) var dock: AnyView?
    private var dockOwner = ""

    /// Pages appear and disappear in no fixed order, so a page clears only what it set.
    func setDock(_ view: AnyView?, owner: String) { dock = view; dockOwner = owner }
    func clearDock(owner: String) { if dockOwner == owner { dock = nil; dockOwner = "" } }
    /// An event prefilled from a thread, consumed by the calendar when it opens.
    /// The window height, so `vh` units resolve exactly as they do on the web.
    var viewportHeight: CGFloat = 900
    var pendingEvent: EventDraft?

    enum Region { case sidebar, content, assistant }

    struct ContextChip: Identifiable, Hashable {
        let id: String
        let subject: String
        let from: String
    }

    func openAssistant(_ conversation: String? = nil) {
        if let conversation { assistantConversationID = conversation }
        assistantOpen = true
        region = .assistant
        // `Shell.tsx`: → with the panel already open puts the caret back in the box.
        assistantFocusRequest += 1
    }
    func closeAssistant() {
        assistantOpen = false
        region = .content
    }
    func toggleAssistant() { assistantOpen ? closeAssistant() : openAssistant() }
    func newChat() { assistantConversationID = nil; assistantContext = [] }
    /// `assistant.addContext`: at most three chips, the newest kept (`slice(-3)`).
    func addContext(_ chip: ContextChip) {
        if assistantContext.contains(where: { $0.id == chip.id }) { return }
        assistantContext = Array((assistantContext + [chip]).suffix(3))
    }
}

/// `hey.assistant` in `localStorage`, as the web writes it.
struct AssistantPrefs: Codable {
    var open = false
    var mode = "dock"
    var width: CGFloat = 400
    var conversationID: String?

    enum CodingKeys: String, CodingKey { case open, mode, width, conversationID = "conversationId" }

    init(open: Bool, width: CGFloat, conversationID: String?) {
        self.open = open; self.width = width; self.conversationID = conversationID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = (try? c.decode(Bool.self, forKey: .open)) ?? false
        width = AssistantPrefs.clamp((try? c.decode(CGFloat.self, forKey: .width)) ?? 400)
        conversationID = try? c.decodeIfPresent(String.self, forKey: .conversationID)
    }

    static func clamp(_ w: CGFloat) -> CGFloat { min(720, max(320, w.rounded())) }

    static func load() -> AssistantPrefs {
        if let raw = UserDefaults.standard.string(forKey: "hey.assistant"), let data = raw.data(using: .utf8),
           let prefs = try? JSONDecoder().decode(AssistantPrefs.self, from: data) { return prefs }
        return AssistantPrefs(open: false, width: 400, conversationID: nil)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self), let raw = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(raw, forKey: "hey.assistant")
        }
    }
}

/// A shared refresh signal the web gets from `invalidateMail`: any page listening reloads.
/// Wraps `MailBus` so pages can `.task(id:)` on it.
extension MailBus {
    var tick: Int { revision }
}
