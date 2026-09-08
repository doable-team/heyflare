import SwiftUI
import Observation

/// Who is signed in, which mailboxes they have, and which one the app is looking through.
/// Everything else in the app reads this and nothing else owns auth.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case launching
        case needsServer
        case signedOut(message: String?)
        /// A fresh server with nobody on it yet: create the owner first.
        case needsSetup
        case signedIn
    }

    var phase: Phase = .launching
    var user: User?
    var accounts: [Account] = []
    var counts: Counts = .zero
    var scope: String = ServerConfig.shared.scope
    /// Set when a background refresh failed but cached content is still on screen.
    var banner: String?

    private var countsTask: Task<Void, Never>?

    var serverHost: String { ServerConfig.shared.baseURL?.host ?? "" }

    /// The mailbox the app is scoped to, or nil in the unified view.
    var scopedAccount: Account? {
        scope == ServerConfig.allAccounts ? nil : accounts.first { $0.id == scope }
    }

    var scopeLabel: String {
        if accounts.isEmpty { return "" }
        if let a = scopedAccount { return a.email }
        return accounts.count > 1 ? "All accounts" : accounts[0].email
    }

    /// `settings.showPreviews`: whether a list row shows a line of the message. A missing
    /// value means on, because the preference was added after the lists were and an
    /// account that has never touched it should keep the rows it already had.
    var showsPreviews: Bool { user?.settings.showPreviews ?? true }

    /// Glyphs only earn their place once a second mailbox exists.
    var showsAccountGlyphs: Bool { accounts.count > 1 }

    func glyph(for accountID: String?) -> String? {
        guard showsAccountGlyphs, let accountID,
              let index = accounts.firstIndex(where: { $0.id == accountID }) else { return nil }
        return Theme.glyph(forAccountIndex: index)
    }

    func account(_ id: String?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    // MARK: - Lifecycle

    /// Decides which of the three doors the app opens on: pick a server, sign in, or the Imbox.
    ///
    /// A session that worked last time is assumed to still work. The alternative — holding
    /// the launch screen until `/api/me` answers — means the app cannot open at all on a
    /// train, and it throws away the cached Imbox at the moment it is most useful. The
    /// check still runs, behind the already-drawn screen, and a genuine 401 signs out then.
    func start() async {
        guard ServerConfig.shared.baseURL != nil else {
            phase = .needsServer
            return
        }
        // Read here rather than in a property initialiser: `AppState` is built before
        // the cache has been brought in from disk, so an initialiser would always miss.
        adoptCachedIdentity()

        if user != nil {
            phase = .signedIn
            refreshCounts()
            // A message held for undo when the app was killed is either overdue, and goes
            // now, or still waiting, and is re-armed. Either way it is not lost.
            await PendingSendCenter.shared.recoverOnLaunch()
            await loadSession()
        } else {
            await loadSession(initial: true)
        }
    }

    /// Restores who this phone was signed in as, and enough around it that the first
    /// frame is complete: the mailbox list feeds the scope line and the account glyphs,
    /// and the counts feed the tab badges.
    private func adoptCachedIdentity() {
        guard user == nil else { return }
        user = ContentCache.shared.value(User.self, for: .user)
        guard user != nil else { return }
        accounts = ContentCache.shared.value([Account].self, for: .accounts) ?? []
        counts = ContentCache.shared.value(Counts.self, for: .counts) ?? .zero
        scope = ServerConfig.shared.scope
    }

    func loadSession(initial: Bool = false) async {
        do {
            let me = try await APIClient.shared.me()
            if let user = me.user {
                self.user = user
                self.accounts = me.accounts
                ContentCache.shared.store(user, for: .user)
                ContentCache.shared.store(me.accounts, for: .accounts)
                reconcileScope()
                phase = .signedIn
                refreshCounts()
                watchChanges(active: true)
            } else {
                phase = me.setupRequired ? .needsSetup : .signedOut(message: nil)
            }
            googleConfigured = me.googleConfigured ?? true
            microsoftConfigured = me.microsoftConfigured ?? false
        } catch let error as APIError {
            if case .notConfigured = error {
                phase = .needsServer
            } else if error.isAuthFailure {
                // The only answer that really ends a session.
                ContentCache.shared.clear()
                user = nil
                phase = .signedOut(message: nil)
            } else if user != nil {
                // Offline, or the Worker is down. Keep what is on screen and say so.
                banner = error.errorDescription
            } else if initial {
                // Cannot reach the server on a cold start: say so on the sign-in screen
                // rather than pretending the session is gone.
                phase = .signedOut(message: error.errorDescription)
            } else {
                banner = error.errorDescription
            }
        } catch {
            phase = .signedOut(message: error.localizedDescription)
        }
    }

    /// Drops a scope that points at a mailbox which is no longer connected.
    private func reconcileScope() {
        let stored = ServerConfig.shared.scope
        if stored != ServerConfig.allAccounts && !accounts.contains(where: { $0.id == stored }) {
            setScope(ServerConfig.allAccounts)
        } else {
            scope = stored
        }
    }

    func setScope(_ id: String) {
        guard scope != id else { return }
        ServerConfig.shared.scope = id
        scope = id
        Haptics.select()
        // Every scoped list is now answering a different question, including the ones
        // parked on other tabs' stacks; they catch up the moment they are shown again.
        didMutate()
    }

    func setServer(_ url: URL) async {
        ServerConfig.shared.baseURL = url
        await APIClient.shared.clearCookies()
        // Rows cached from one server must never be shown against another.
        ContentCache.shared.clear()
        user = nil
        accounts = []
        phase = .signedOut(message: nil)
    }

    /// Forgets the server entirely and returns to the address screen.
    func clearServer() async {
        stopWatching()
        try? await APIClient.shared.logout()
        ServerConfig.shared.baseURL = nil
        ContentCache.shared.clear()
        user = nil
        accounts = []
        counts = .zero
        phase = .needsServer
    }

    func signOut() async {
        stopWatching()
        try? await APIClient.shared.logout()
        // Cached mail outlives the session otherwise, and the next person to sign in
        // on this phone would see the last one's Imbox for a frame.
        ContentCache.shared.clear()
        user = nil
        accounts = []
        counts = .zero
        phase = .signedOut(message: nil)
    }

    /// Called after a successful login or 2FA step.
    func adopt(user: User) async {
        self.user = user
        phase = .signedIn
        await loadSession()
    }

    // MARK: - Counts

    /// Badge numbers for the tab bar. Coalesced so a burst of screen changes makes one call.
    func refreshCounts() {
        countsTask?.cancel()
        countsTask = Task { [weak self] in
            guard let self else { return }
            guard let value = try? await APIClient.shared.counts() else { return }
            guard !Task.isCancelled else { return }
            self.counts = value
            ContentCache.shared.store(value, for: .counts)
        }
    }

    func refreshAccounts() async {
        guard let list = try? await APIClient.shared.accounts() else { return }
        accounts = list
        ContentCache.shared.store(list, for: .accounts)
        reconcileScope()
    }

    /// Asks every connected mailbox to pull now. Used by pull-to-refresh on the Imbox.
    func syncAll() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts where account.syncStatus != "disconnected" {
                group.addTask { try? await APIClient.shared.sync(accountID: account.id) }
            }
        }
        await refreshAccounts()
        refreshCounts()
    }

    /// Anything that changes mail on the server calls this. It refreshes the tab badges
    /// and tells every list on screen — or the next one to come on screen — to refetch.
    /// The lists used to hear nothing, so a thread read on its own page stayed bold in
    /// the Imbox behind it until the next pull.
    func didMutate() {
        MailBus.shared.changed()
        refreshCounts()
    }

    private var lastForeground = Date.distantPast

    /// Whether the server can start a Google / Microsoft sign-in at all (`google_configured`
    /// on `/api/me`); the web hides "Connect Gmail" when it cannot.
    var googleConfigured = true
    var microsoftConfigured = false

    /// heyflare syncs on focus in the browser; the phone does the same when it comes back
    /// to the foreground, throttled so tabbing around does not hammer the worker. App-wide
    /// rather than per screen, so it is whichever screen is showing that gets refreshed.
    func becameActive() async {
        watchChanges(active: true)
        guard phase == .signedIn, Date().timeIntervalSince(lastForeground) > 30 else { return }
        lastForeground = Date()
        lastSyncKick = Date()
        await syncAll()
        didMutate()
    }

    /// The window lost focus (or the phone went to the background): keep an eye on the
    /// server, just less often — enough for the badge to stay right.
    func resignedActive() {
        watchChanges(active: false)
    }

    // MARK: Staying current

    private var changeWatch: Task<Void, Never>?
    private var lastRevision: Int?
    private var lastSyncKick = Date.distantPast

    /// Polls `/api/changes` — one number that moves whenever any of the user's mail changes —
    /// and, when it moves, tells every list on screen to refetch and the badges to recount.
    /// Every ten seconds while the app is in front, once a minute behind; and while in front
    /// it also asks each mailbox to pull every half minute, so mail that has just landed at
    /// the provider is here well inside the worker's own minute-long cron. This is what makes
    /// a change made on the web, or on the phone, show up here without anyone touching
    /// anything — the app used to refetch only when it happened to write or navigate.
    func watchChanges(active: Bool) {
        changeWatch?.cancel()
        changeWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(active: active)
                try? await Task.sleep(for: .seconds(active ? 10 : 60))
            }
        }
    }

    func stopWatching() {
        changeWatch?.cancel()
        changeWatch = nil
        lastRevision = nil
    }

    private func tick(active: Bool) async {
        guard phase == .signedIn else { return }
        // In front, a mailbox that has not pulled for half a minute pulls now. Incremental
        // sync is one cheap history call when nothing has changed.
        if active, Date().timeIntervalSince(lastSyncKick) > 30, !accounts.isEmpty {
            lastSyncKick = Date()
            await withTaskGroup(of: Void.self) { group in
                for account in accounts where account.syncStatus != "disconnected" {
                    group.addTask { try? await APIClient.shared.sync(accountID: account.id) }
                }
            }
        }
        guard let revision = try? await APIClient.shared.changes(), !Task.isCancelled else { return }
        if let last = lastRevision, last != revision { didMutate() }
        lastRevision = revision
    }
}

// MARK: - Routing

/// One value per pushable screen. Kept small on purpose: deep links and back
/// gestures both work for free once every destination is a `Hashable` value.
enum Route: Hashable {
    case thread(String)
    /// A thread opened as a preview. The worker marks a thread seen on any ordinary read,
    /// so looking at someone's mail before deciding about them — in the Screener, or in a
    /// tray — has to ask for a peek or the decision consumes the unread state.
    case peekThread(String)
    case feed
    /// The attachment library.
    case files
    /// Mail queued to go out later, which can still be pulled back.
    case scheduled
    /// The people you turned away, so one can be let back in.
    case screenedOutPeople
    /// One day of the calendar, in full.
    case calendarDay(String)
    case habits
    case journal
    case list(ThreadListKind)
    case bundle(MailBundle)
    case contacts
    case clips
    case collections
    case labels
    case drafts
    case settings
    case search
    case powerThrough
    /// Password and second factor.
    case security
    /// Custom domains and the mailboxes on them.
    case domains
    /// The assistant's provider, behaviour and memory.
    case aiSettings
    case aiMemory
    /// This week's loose tasks and the stopwatch.
    case week
}

/// The five tabs. Calendar took the Paper Trail's slot and the Assistant took the Feed's,
/// on the same reasoning in reverse: the Feed is somewhere you go when you have time to
/// read, while the assistant is something you reach for in the middle of another task and
/// should never be two taps away. The Feed and the Paper Trail both live under More.
enum Tab: Int, Hashable, CaseIterable, Identifiable {
    case imbox, assistant, calendar, screener, more

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .imbox: return "Imbox"
        case .assistant: return "Assistant"
        case .calendar: return "Calendar"
        case .screener: return "Screener"
        case .more: return "More"
        }
    }

    var icon: String {
        switch self {
        case .imbox: return "tray"
        case .assistant: return "sparkles"
        case .calendar: return "calendar"
        case .screener: return "shield"
        case .more: return "line.3.horizontal"
        }
    }

    var selectedIcon: String {
        switch self {
        case .imbox: return "tray.fill"
        case .assistant: return "sparkles"
        case .calendar: return "calendar"
        case .screener: return "shield.fill"
        case .more: return "line.3.horizontal"
        }
    }
}

/// Navigation stacks, one per tab, so switching tabs keeps each stack where it was.
@MainActor
@Observable
final class Navigator {
    var tab: Tab = .imbox
    var imbox = NavigationPath()
    var assistant = NavigationPath()
    var calendar = NavigationPath()
    var screener = NavigationPath()
    var more = NavigationPath()

    /// Composer presentation is app-wide: a reply can start from any tab.
    var composing: ComposeIntent?

    func push(_ route: Route) {
        switch tab {
        case .imbox: imbox.append(route)
        case .assistant: assistant.append(route)
        case .calendar: calendar.append(route)
        case .screener: screener.append(route)
        case .more: more.append(route)
        }
    }

    /// Tapping the active tab again pops to its root, the way system apps behave.
    func popToRoot(_ tab: Tab) {
        switch tab {
        case .imbox: imbox = NavigationPath()
        case .assistant: assistant = NavigationPath()
        case .calendar: calendar = NavigationPath()
        case .screener: screener = NavigationPath()
        case .more: more = NavigationPath()
        }
    }

    func select(_ next: Tab) {
        if next == tab { popToRoot(next) } else { tab = next }
        Haptics.select()
    }
}
