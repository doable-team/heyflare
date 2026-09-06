import SwiftUI

/// Three doors: point at a server, sign in, or the app itself.
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            switch app.phase {
            case .launching:
                LaunchView()
            case .needsServer:
                ServerSetupView()
                    .transition(.opacity)
            case .signedOut(let message):
                LoginView(initialMessage: message)
                    .transition(.opacity)
            case .signedIn:
                MainShell()
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.navigation, value: app.phase)
        .screenBackground()
    }
}

struct LaunchView: View {
    var body: some View {
        VStack(spacing: 10) {
            Wordmark(size: 20)
            ProgressView()
                .tint(Theme.Colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }
}

struct Wordmark: View {
    var size: CGFloat = 17

    var body: some View {
        HStack(spacing: 7) {
            HeyflareMark(size: size * 1.15)
            Text("heyflare")
                .font(.system(size: size, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Theme.Colors.foreground)
        }
    }
}

// MARK: - Main shell

/// Five tabs, each with its own navigation stack, plus the app-wide composer and toast layer.
struct MainShell: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        @Bindable var nav = nav

        ZStack(alignment: .bottom) {
            Group {
                switch nav.tab {
                case .imbox:
                    stack(path: $nav.imbox) { ImboxView() }
                case .assistant:
                    stack(path: $nav.assistant) { AssistantView() }
                case .calendar:
                    stack(path: $nav.calendar) { CalendarScreen() }
                case .screener:
                    stack(path: $nav.screener) { ScreenerView() }
                case .more:
                    stack(path: $nav.more) { MoreView() }
                }
            }
            .padding(.bottom, Theme.Metrics.tabBarHeight)

            VStack(spacing: 10) {
                if let toast = toasts.current {
                    ToastView(toast: toast) {
                        let undo = toast.undo
                        toasts.dismiss()
                        Task { await undo?() }
                    }
                }
                TabBarView()
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .screenBackground()
        .sheet(item: $nav.composing) { intent in
            ComposeView(intent: intent)
        }
    }

    @ViewBuilder
    private func stack<Content: View>(path: Binding<NavigationPath>, @ViewBuilder root: () -> Content) -> some View {
        NavigationStack(path: path) {
            root()
                .navigationBarHidden(true)
                .navigationDestination(for: Route.self) { route in
                    RouteView(route: route)
                        .navigationBarHidden(true)
                }
        }
    }
}

/// One place that turns a `Route` into a screen, so every stack behaves the same.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .thread(let id):
            ThreadView(threadID: id)
        case .peekThread(let id):
            ThreadView(threadID: id, peek: true)
        case .feed:
            FeedView()
        case .files:
            FilesScreen()
        case .scheduled:
            ScheduledScreen()
        case .screenedOutPeople:
            ScreenedOutPeopleScreen()
        case .calendarDay(let date):
            CalendarDayScreen(date: date)
        case .habits:
            HabitsScreen()
        case .journal:
            JournalScreen()
        case .list(let kind):
            ThreadListScreen(kind: kind)
        case .bundle(let bundle):
            BundleScreen(bundle: bundle)
        case .contacts:
            ContactsScreen()
        case .clips:
            ClipsScreen()
        case .collections:
            CollectionsScreen()
        case .labels:
            LabelsScreen()
        case .drafts:
            DraftsScreen()
        case .settings:
            SettingsView()
        case .search:
            SearchScreen()
        case .powerThrough:
            PowerThroughView()
        case .security:
            SecurityScreen()
        case .domains:
            DomainsScreen()
        case .aiSettings:
            AiSettingsScreen()
        case .aiMemory:
            AiMemoryScreen()
        case .week:
            WeekScreen()
        }
    }
}

// MARK: - Tab bar

struct TabBarView: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                let active = nav.tab == tab
                Button {
                    nav.select(tab)
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: active ? tab.selectedIcon : tab.icon)
                                .font(.system(size: 20, weight: active ? .semibold : .regular))
                                .frame(height: 24)
                            if let n = badge(for: tab), n > 0 {
                                Circle()
                                    .fill(Theme.Colors.foreground)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().strokeBorder(Theme.Colors.background, lineWidth: 1.5))
                                    .offset(x: 7, y: -2)
                            }
                        }
                        Text(tab.title)
                            .font(.system(size: 10, weight: active ? .semibold : .medium))
                    }
                    .foregroundStyle(active ? Theme.Colors.foreground : Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.Metrics.tabBarHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
            }
        }
        .background(Theme.Colors.chrome)
        .background(.ultraThinMaterial)
        .hairline(.top)
    }

    private func badge(for tab: Tab) -> Int? {
        switch tab {
        case .imbox: return app.counts.imboxNew
        case .screener: return app.counts.screener
        default: return nil
        }
    }
}
