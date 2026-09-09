import SwiftUI
import AppKit

struct NavItem: Identifiable, Hashable {
    let key: String
    let label: String
    let icon: String
    var count: Int? = nil
    var kbd: String? = nil
    var id: String { key }

    var route: AppRoute {
        switch key {
        case "/": return .imbox
        case "/feed": return .feed
        case "/paper-trail": return .paperTrail
        case "/screener": return .screener
        case "/calendar": return .calendar(nil)
        case "/reply-later": return .replyLater
        case "/set-aside": return .setAside
        case "/bubble-up": return .bubbleUp
        case "/previously-seen": return .previouslySeen
        case "/contacts": return .contacts
        case "/clips": return .clips
        case "/collections": return .collections
        case "/files": return .files
        case "/labels": return .labels
        case "/drafts": return .drafts
        case "/journal": return .journal(nil)
        case "/habits": return .habits
        case "/sent": return .sent
        case "/scheduled": return .scheduled
        case "/everything": return .everything
        case "/screened-out": return .screenedOut
        case "/trash": return .trash
        case "/settings": return .settings("profile")
        default: return .imbox
        }
    }
}

/// `AppSidebar`: 256pt (48 collapsed), the sidebar colour, no right border.
struct Sidebar: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(UIState.self) private var ui
    @Environment(PopLayerState.self) private var pops
    @Environment(Toasts.self) private var toasts
    @Environment(SheetState.self) private var sheet
    @Environment(DialogState.self) private var dialogs

    private var collapsed: Bool { !ui.sidebarOpen }

    private var primary: [NavItem] {
        let c = app.counts
        return [
            NavItem(key: "/", label: "Imbox", icon: "inbox", count: c.imboxNew),
            NavItem(key: "/feed", label: "The Feed", icon: "rss", count: c.feedNew),
            NavItem(key: "/paper-trail", label: "Paper Trail", icon: "fileText", count: c.paperTrailNew),
            NavItem(key: "/screener", label: "Screener", icon: "shield", count: c.screener),
            NavItem(key: "/calendar", label: "Calendar", icon: "calendarDays", kbd: "0"),
        ]
    }
    private var trays: [NavItem] {
        [
            NavItem(key: "/reply-later", label: "Reply Later", icon: "clock", count: app.counts.replyLater),
            NavItem(key: "/set-aside", label: "Set Aside", icon: "bookmark", count: app.counts.setAside),
            NavItem(key: "/bubble-up", label: "Bubble Up", icon: "arrowUpCircle"),
        ]
    }
    private let library: [NavItem] = [
        NavItem(key: "/previously-seen", label: "Previously Seen", icon: "eye"),
        NavItem(key: "/contacts", label: "Contacts", icon: "users"),
        NavItem(key: "/clips", label: "Clips", icon: "scissors"),
        NavItem(key: "/collections", label: "Collections", icon: "folderOpen"),
        NavItem(key: "/files", label: "Files", icon: "files"),
        NavItem(key: "/labels", label: "Labels", icon: "tag"),
        NavItem(key: "/drafts", label: "Drafts", icon: "penSquare"),
    ]
    private let more: [NavItem] = [
        NavItem(key: "/journal", label: "Journal", icon: "bookOpen"),
        NavItem(key: "/habits", label: "Habits", icon: "repeat"),
        NavItem(key: "/sent", label: "Sent", icon: "send"),
        NavItem(key: "/scheduled", label: "Scheduled", icon: "calendarClock"),
        NavItem(key: "/everything", label: "Everything", icon: "mail"),
        NavItem(key: "/screened-out", label: "Screened out", icon: "shieldOff"),
        NavItem(key: "/trash", label: "Trash", icon: "trash2"),
    ]

    private var moreExpanded: Bool { ui.moreOpen || more.contains { $0.key == router.route.navKey } }
    private var flatNav: [NavItem] { primary + trays + library + (moreExpanded ? more : []) }
    private var focusedKey: String? {
        ui.region == .sidebar && flatNav.indices.contains(ui.sidebarFocusIndex) ? flatNav[ui.sidebarFocusIndex].key : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        group(nil, primary)
                        group("Trays", trays)
                        group("Library", library)
                        moreGroup
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.hidden)
                // `Shell.tsx`: the keyboard-focused row is scrolled into view (`block: "nearest"`).
                .onChange(of: focusedKey) { _, key in if let key { proxy.scrollTo(key) } }
            }
            footer
        }
        .background(W.sidebar)
        .onKeys([
            "ArrowLeft": { if ui.region == .content && !ui.assistantOpen { focusSidebar() } else if ui.assistantOpen && ui.region != .sidebar { ui.closeAssistant() } },
            "ArrowRight": { if ui.region == .sidebar { activateFocused() } else { ui.openAssistant() } },
        ], enabled: !sheet.isOpen && !dialogs.isOpen, priority: -5)
        .onKeys([
            "ArrowDown": { ui.sidebarFocusIndex = (ui.sidebarFocusIndex + 1) % max(flatNav.count, 1) },
            "ArrowUp": { ui.sidebarFocusIndex = (ui.sidebarFocusIndex - 1 + flatNav.count) % max(flatNav.count, 1) },
            "Enter": { activateFocused() },
            "Escape": { ui.region = .content },
        ], enabled: ui.region == .sidebar, priority: 5)
    }

    private func focusSidebar() {
        ui.region = .sidebar
        ui.sidebarFocusIndex = max(0, flatNav.firstIndex { $0.key == router.route.navKey } ?? 0)
    }

    private func activateFocused() {
        guard flatNav.indices.contains(ui.sidebarFocusIndex) else { return }
        router.go(flatNav[ui.sidebarFocusIndex].route)
        ui.region = .content
    }

    // MARK: Header

    private var scopeTitle: String {
        if app.scope == ServerConfig.allAccounts {
            return app.accounts.count > 1 ? "All accounts" : (app.accounts.first?.email ?? "No Gmail yet")
        }
        return app.scopedAccount?.email ?? "All accounts"
    }

    private var header: some View {
        VStack(spacing: 4) {
            // The scope switcher: mark, wordmark, scope, chevron.
            SidebarButton(height: 36, collapsed: collapsed, active: false, expanded: pops.isOpen("scope-menu")) {
                HStack(spacing: 8) {
                    Mark(size: 20)
                    if !collapsed {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("heyflare").font(W.font(14, 600)).foregroundStyle(W.foreground).lineLimit(1)
                            Text(scopeTitle).font(W.font(11)).foregroundStyle(W.mutedForeground).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Icon("chevronDown", size: 14).foregroundStyle(W.mutedForeground)
                    }
                }
            } action: {
                pops.toggle("scope-menu", side: collapsed ? .right : .bottom, align: .start) { scopeMenu }
            }
            .popAnchor("scope-menu")

            VStack(spacing: 0) {
                SidebarButton(height: 28, collapsed: collapsed, active: false) {
                    HStack(spacing: 8) {
                        Icon("penSquare", size: 16).foregroundStyle(W.mutedForeground)
                        if !collapsed { Text("New message").font(W.sm).foregroundStyle(W.foreground); Spacer(); Kbd("c") }
                    }
                } action: { Compose.open() }
                .webTooltip("Compose c", side: .right, enabled: collapsed)
                SidebarButton(height: 28, collapsed: collapsed, active: false) {
                    HStack(spacing: 8) {
                        Icon("search", size: 16).foregroundStyle(W.mutedForeground)
                        if !collapsed { Text("Search").font(W.sm).foregroundStyle(W.foreground); Spacer(); Kbd("⌘K") }
                    }
                } action: { ui.paletteOpen = true }
                .webTooltip("Search ⌘K", side: .right, enabled: collapsed)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 8)
        .padding(.top, 40)   // pt-10: clears the traffic lights, as the web's Mac build does.
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var scopeMenu: some View {
        PopCard(width: 256) {
            VStack(alignment: .leading, spacing: 0) {
                MenuLabel("Inbox scope")
                MenuItem("All accounts", icon: "layers", shortcut: app.accounts.count > 1 ? "\(app.accounts.count)" : nil, checked: app.scope == ServerConfig.allAccounts) {
                    app.setScope(ServerConfig.allAccounts); router.go(.imbox)
                }
                ForEach(Array(app.accounts.enumerated()), id: \.element.id) { i, a in
                    MenuItem(a.email, glyph: Theme.glyph(forAccountIndex: i), checked: app.scope == a.id) { app.setScope(a.id); router.go(.imbox) }
                }
                if app.accounts.isEmpty {
                    Text("Nothing connected yet.").font(W.xs).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 6)
                }
                MenuSeparator()
                // `Shell.tsx`: only offered when the server can actually start the consent.
                if app.googleConfigured { MenuItem("Connect Gmail", icon: "plus") { GoogleConnect.start(toasts: toasts) } }
                if app.microsoftConfigured { MenuItem("Connect Outlook", icon: "plus") { GoogleConnect.start(toasts: toasts, provider: "microsoft") } }
                MenuItem("Manage accounts", icon: "settings") { router.go(.settings("accounts")) }
            }
        }
    }

    // MARK: Groups

    @ViewBuilder
    private func group(_ label: String?, _ items: [NavItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label, !collapsed {
                Text(label).font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
                    .padding(.horizontal, 8).frame(height: 28)
            }
            ForEach(items) { item in navRow(item) }
        }
        .padding(.vertical, 4)
    }

    private var moreGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !collapsed {
                MoreTrigger(expanded: moreExpanded) { ui.moreOpen.toggle() }
            }
            if moreExpanded {
                ForEach(more) { item in navRow(item) }
            }
        }
        .padding(.vertical, 4)
    }

    private func navRow(_ item: NavItem) -> some View {
        let active = router.route.navKey == item.key
        let focused = focusedKey == item.key
        return SidebarButton(height: 28, collapsed: collapsed, active: active, focused: focused) {
            HStack(spacing: 8) {
                Icon(item.icon, size: 16).foregroundStyle(active ? W.foreground : W.mutedForeground)
                if !collapsed {
                    Text(item.label).font(W.font(14, active ? 500 : 400)).foregroundStyle(W.foreground).lineLimit(1)
                    Spacer(minLength: 4)
                    if let n = item.count, n > 0 {
                        Text("\(n)").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
                    }
                }
            }
        } action: {
            router.go(item.route)
            ui.region = .content
        }
        .id(item.key)
        .webTooltip(item.kbd.map { "\(item.label) \($0)" } ?? item.label, side: .right, enabled: collapsed)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            SidebarButton(height: 28, collapsed: collapsed, active: router.route.navKey == "/settings") {
                HStack(spacing: 8) {
                    Icon("settings", size: 16).foregroundStyle(router.route.navKey == "/settings" ? W.foreground : W.mutedForeground)
                    if !collapsed { Text("Settings").font(W.sm).foregroundStyle(W.foreground) }
                }
            } action: { router.go(.settings("profile")) }
            .webTooltip("Settings", side: .right, enabled: collapsed)

            SidebarButton(height: 32, collapsed: collapsed, active: false, expanded: pops.isOpen("user-menu")) {
                HStack(spacing: 8) {
                    WAvatar(email: app.user?.email ?? "", name: app.user?.name ?? "", src: app.accounts.first(where: { !$0.avatarURL.isEmpty })?.avatarURL, size: 20)
                    if !collapsed {
                        Text(app.user?.name.isEmpty == false ? app.user!.name : (app.user?.email ?? "")).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                        Spacer(minLength: 0)
                        Icon("chevronDown", size: 14).foregroundStyle(W.mutedForeground)
                    }
                }
            } action: {
                pops.toggle("user-menu", side: collapsed ? .right : .top, align: .start) { userMenu }
            }
            .popAnchor("user-menu")
            .webTooltip(app.user?.name.isEmpty == false ? app.user!.name : (app.user?.email ?? ""), side: .right, enabled: collapsed)
        }
        .padding(8)
    }

    @ViewBuilder
    private var userMenu: some View {
        let theme = app.user?.settings.theme ?? "system"
        PopCard(width: 224) {
            VStack(alignment: .leading, spacing: 0) {
                // `DropdownMenuLabel font-normal`: px-1.5 py-1.
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.user?.name.isEmpty == false ? app.user!.name : (app.user?.email ?? "")).font(W.sm).webLine(14).foregroundStyle(W.foreground)
                    Text(app.user?.email ?? "").font(W.xs).webLine(12).foregroundStyle(W.mutedForeground).lineLimit(1)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                MenuSeparator()
                MenuLabel("Theme")
                MenuItem("Light", icon: "sun", checked: theme == "light") { setTheme("light") }
                MenuItem("Dark", icon: "moon", checked: theme == "dark") { setTheme("dark") }
                MenuItem("System", icon: "monitor", checked: theme == "system") { setTheme("system") }
                MenuSeparator()
                MenuItem("Keyboard shortcuts", icon: "keyboard", shortcut: "?") { ui.shortcutsOpen = true }
                MenuItem("Settings", icon: "settings") { router.go(.settings("profile")) }
                MenuSeparator()
                MenuItem("Log out", icon: "logOut") { Task { await app.signOut() } }
            }
        }
    }

    /// `Shell.tsx`: the theme mutation is silent when it fails.
    private func setTheme(_ t: String) {
        Task {
            if let user = try? await APIClient.shared.updateMe(settings: ["theme": t]) { await app.adopt(user: user) }
        }
    }
}

/// The "More" `SidebarGroupLabel`: `h-7 cursor-pointer hover:bg-sidebar-accent`, with the
/// chevron turning (`transition-transform`).
private struct MoreTrigger: View {
    let expanded: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text("More").font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
                Spacer()
                Icon("chevronRight", size: 12).foregroundStyle(W.mutedForeground)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: expanded)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(hovering ? W.sidebarAccent : Color.clear)
            .rounded(W.radiusMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `SidebarMenuButton`: full width, rounded-md, p-2, hover/active in the sidebar accent.
/// Collapsed (`group-data-[collapsible=icon]:size-8`) every button is a 32×32 square.
struct SidebarButton<Label: View>: View {
    var height: CGFloat = 28
    var collapsed = false
    var active = false
    var focused = false
    var expanded = false
    @ViewBuilder var label: () -> Label
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, collapsed ? 0 : 8)
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                .frame(height: collapsed ? 32 : height)
                .background(active || hovering || expanded || focused ? W.sidebarAccent : Color.clear)
                .overlay {
                    if focused { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.ring, lineWidth: 1) }
                }
                .rounded(W.radiusMd)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `startGoogleConnect()` / `startMicrosoftConnect()`: the OAuth start page opens in the
/// browser; the app refreshes its accounts when it comes back to the front.
enum GoogleConnect {
    @MainActor
    static func start(toasts: Toasts, loginHint: String? = nil, provider: String = "google") {
        Task {
            do {
                let url = try await APIClient.shared.gmailConnectLink(loginHint: loginHint, provider: provider)
                NSWorkspace.shared.open(url)
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? (provider == "microsoft" ? "Microsoft sign-in isn't configured on this server." : "Google sign-in isn't configured on this server."))
            }
        }
    }
}
