import SwiftUI

// MARK: - Endpoints

// MARK: - Reading preferences

// MARK: - Store

// MARK: - Screen

/// Settings: who is signed in, which mailboxes feed the app, and the switches a person
/// actually reaches for while holding a phone.
///
/// The everyday switches are inline — where new senders land, how long a sent message
/// waits, how this mailbox signs off. The rarer, heavier jobs each get a screen of their
/// own behind a row: Security (password, second factor), Domains, the AI assistant, and
/// per-mailbox tools in the mailbox sheet. Adding a domain is the one thing still left to
/// the browser, because it starts in Cloudflare's dashboard rather than here.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts

    @State private var store = SettingsStore()
    @State private var blockRemoteImages = ReadingPrefs.blockRemoteImages
    @State private var confirmSignOut = false
    @State private var confirmChangeServer = false
    @State private var editingName = false
    @State private var nameDraft = ""
    /// The mailbox whose detail sheet is open. Nil the rest of the time.
    @State private var editingMailbox: Account?
    /// Google's consent page, while it is up.
    @State private var connecting: ConnectTarget?
    @State private var mintingLink = false
    @State private var offset: CGFloat = 0

    private var compactTitleVisible: Bool { offset < -34 }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Settings", titleVisible: compactTitleVisible, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            RefreshableScroll(onRefresh: { await app.refreshAccounts() }, offset: $offset) {
                LargeTitle(title: "Settings")

                account
                mailboxes
                newSenders
                undoSend
                appearance
                reading
                assistant
                data
                session

                Text("heyflare · \(app.serverHost)")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .screenBackground()
        .task { await store.measureCache() }
        .sheet(item: $editingMailbox) { account in
            MailboxSheet(account: account)
        }
        // When Google's page is closed — by Done, or because the flow finished on its
        // confirmation page — the account list is asked again. There is no callback into
        // the app; the handoff ends in the browser by design.
        .sheet(item: $connecting, onDismiss: {
            Task {
                await app.refreshAccounts()
                app.didMutate()
            }
        }) { target in
            SafariView(url: target.url).ignoresSafeArea()
        }
        // An alert rather than a row that turns into a field: a name is one short answer,
        // and the system alert already brings its own keyboard, Cancel and Save.
        .alert("Your name", isPresented: $editingName) {
            TextField("Name", text: $nameDraft)
                .textInputAutocapitalization(.words)
            Button("Save") { saveName() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("How heyflare addresses you. The name on mail you send is set per mailbox.")
        }
        .confirmationDialog("Sign out of heyflare?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out") { Task { await app.signOut() } }
            Button("Stay signed in", role: .cancel) {}
        } message: {
            Text("Your mail stays on the server. You will need your password to come back.")
        }
        .confirmationDialog("Change server?", isPresented: $confirmChangeServer, titleVisibility: .visible) {
            Button("Forget this server") { Task { await app.clearServer() } }
            Button("Keep \(app.serverHost)", role: .cancel) {}
        } message: {
            Text("This signs you out and returns to the address screen. Nothing on \(app.serverHost) is changed.")
        }
    }

    // MARK: Account

    private var account: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Account")
            SettingsValueRow(title: "Name", value: app.user?.name ?? "") {
                nameDraft = app.user?.name ?? ""
                editingName = true
            }
            // Email and server are facts about the session, not preferences: changing
            // either means signing in somewhere else, which the Session group below does.
            SettingsValueRow(title: "Email", value: app.user?.email ?? "")
            SettingsValueRow(title: "Server", value: app.serverHost)
            SettingsActionRow(
                title: "Security",
                detail: app.user?.twoFactorEnabled == true ? "Password · two-factor on" : "Password · two-factor off",
                divider: false
            ) {
                nav.push(.security)
            }
        }
    }

    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != app.user?.name, !store.savingPreference else { return }
        store.savingPreference = true
        Task {
            do {
                app.user = try await APIClient.shared.updateMe(name: trimmed)
                // The cached identity is what the next cold launch draws before `/api/me`
                // answers, so it has to learn the new name too.
                if let user = app.user { ContentCache.shared.store(user, for: .user) }
                toasts.show("Name saved")
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
            store.savingPreference = false
        }
    }

    // MARK: Mailboxes

    /// One row per connected mailbox, carrying three separate targets: the row itself is
    /// the scope switch (the same gesture as the Imbox's title sheet), the middle button
    /// asks that mailbox to pull now, and the chevron opens how it signs off. Three buttons
    /// rather than one row with controls inside it, so each clears 44pt on its own.
    private var mailboxes: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Mailboxes", trailing: app.accounts.isEmpty ? nil : "\(app.accounts.count)")

            ForEach(Array(app.accounts.enumerated()), id: \.element.id) { index, item in
                MailboxRow(
                    account: item,
                    glyph: app.showsAccountGlyphs ? Theme.glyph(forAccountIndex: index) : nil,
                    selected: app.scope == item.id,
                    syncing: store.syncing.contains(item.id),
                    onSelect: { app.setScope(item.id) },
                    onSync: { sync(item) },
                    onOpen: { editingMailbox = item }
                )
            }
            SettingsActionRow(
                title: "Connect a Gmail account",
                detail: app.accounts.isEmpty ? "Nothing reaches the Imbox until one is connected" : "Opens Google in Safari to grant access",
                busy: mintingLink
            ) {
                connectGmail()
            }
            SettingsActionRow(title: "Domains", detail: "Custom domains and their mailboxes", divider: false) {
                nav.push(.domains)
            }
        }
    }

    /// The worker mints a one-time link that carries the session, and Safari does the rest.
    private func connectGmail() {
        guard !mintingLink else { return }
        mintingLink = true
        Task {
            defer { mintingLink = false }
            do {
                connecting = ConnectTarget(url: try await APIClient.shared.gmailConnectLink())
            } catch let error as APIError {
                toasts.error(error == .server("google_not_configured", 500)
                             ? "Google sign-in is not set up on this server. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET on the Worker."
                             : (error.errorDescription ?? "Could not start connecting."))
            } catch {
                toasts.error(error.localizedDescription)
            }
        }
    }

    private func sync(_ item: Account) {
        guard !store.syncing.contains(item.id) else { return }
        store.syncing.insert(item.id)
        Task {
            do {
                try await APIClient.shared.sync(accountID: item.id)
                toasts.show("Syncing \(item.email)")
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
            await app.refreshAccounts()
            // A sync that found mail has changed every list; the badges alone are not it.
            app.didMutate()
            store.syncing.remove(item.id)
        }
    }

    // MARK: New senders

    /// Where the Screener points before you touch it. Not a rule — every card can still be
    /// sent anywhere — but the answer that is already selected when a card comes up, which
    /// is what most of them get decided as.
    private var newSenders: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "New senders")
            ForEach(Array(Self.screenTargets.enumerated()), id: \.element.value) { index, option in
                SettingsChoiceRow(
                    title: option.title,
                    icon: option.icon,
                    selected: currentScreenTarget == option.value,
                    disabled: store.savingPreference,
                    divider: index < Self.screenTargets.count - 1
                ) {
                    setPreference(["defaultScreenTarget": option.value], changed: option.value != currentScreenTarget)
                }
            }
            SettingsFootnote(text: "Pre-selected when you let someone in from the Screener.")
        }
    }

    private static let screenTargets: [(value: String, title: String, icon: String)] = [
        ("imbox", "Imbox", "tray"),
        ("feed", "The Feed", "dot.radiowaves.up.forward"),
        ("paper_trail", "Paper Trail", "doc.text"),
    ]

    private var currentScreenTarget: String {
        let stored = app.user?.settings.defaultScreenTarget ?? "imbox"
        return stored.isEmpty ? "imbox" : stored
    }

    // MARK: Undo send

    /// How long a sent message sits on this phone before it actually goes.
    ///
    /// A fixed set rather than a number field: the web offers 0–60 because it has a
    /// keyboard, and on a phone the difference between 11 and 12 seconds is not a decision
    /// anybody is making. Off is first because turning it off is the reason most people
    /// open this row — the pause is a feature right up until it is in the way.
    private var undoSend: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Undo send")
            ForEach(Array(Self.undoWindows.enumerated()), id: \.element.seconds) { index, option in
                SettingsChoiceRow(
                    title: option.title,
                    icon: option.seconds == 0 ? "paperplane" : "clock.arrow.circlepath",
                    selected: currentUndoSeconds == option.seconds,
                    disabled: store.savingPreference,
                    divider: index < Self.undoWindows.count - 1
                ) {
                    setPreference(["undoSendSeconds": option.seconds], changed: option.seconds != currentUndoSeconds)
                }
            }
            SettingsFootnote(text: currentUndoSeconds == 0
                             ? "Send goes straight out, and a failure is reported there and then."
                             : "Sent mail waits \(currentUndoSeconds) seconds behind an Undo button before it leaves.")
        }
    }

    private static let undoWindows: [(seconds: Int, title: String)] = [
        (0, "Off"),
        (5, "5 seconds"),
        (10, "10 seconds"),
        (20, "20 seconds"),
        (30, "30 seconds"),
    ]

    /// Ten to match the web, which is also what the composer falls back to.
    private var currentUndoSeconds: Int { app.user?.settings.undoSendSeconds ?? 10 }

    /// One writer for every owner-level preference. `PATCH /api/me` merges, so a single key
    /// goes up and the whole user comes back — which is what keeps `app.user` the only copy
    /// of these values anywhere in the app.
    private func setPreference(_ settings: [String: Any], changed: Bool) {
        guard changed, !store.savingPreference else { return }
        store.savingPreference = true
        Task {
            do {
                app.user = try await APIClient.shared.updateMe(settings: settings)
                if let user = app.user { ContentCache.shared.store(user, for: .user) }
                Haptics.select()
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
            store.savingPreference = false
        }
    }

    // MARK: Appearance

    /// The choice is the owner's, not the device's, so it is stored on the server and the
    /// app root reads it back out of `app.user` to set the scheme.
    private var appearance: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Appearance")
            ForEach(ThemeChoice.all, id: \.value) { choice in
                SettingsChoiceRow(
                    title: choice.title,
                    icon: choice.icon,
                    selected: currentTheme == choice.value,
                    disabled: store.savingTheme
                ) {
                    setTheme(choice.value)
                }
            }

            // The same preference the web writes, so a phone and a laptop signed into the
            // same account agree about it. On this build it reaches the lists this feature
            // owns; the Imbox, the thread lists and the Feed pass `showsSnippet` themselves
            // and need a one-line change each to honour it — see the note in the report.
            Toggle(isOn: Binding(
                get: { app.user?.settings.showPreviews ?? true },
                set: { setPreference(["showPreviews": $0], changed: true) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show previews in lists")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.foreground)
                    Text("The first line of each message, under the subject.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.Colors.foreground)
            .disabled(store.savingPreference)
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.vertical, 10)
            .frame(minHeight: Theme.Metrics.denseRowHeight)
        }
    }

    private var currentTheme: String {
        let stored = app.user?.settings.theme ?? "system"
        return stored.isEmpty ? "system" : stored
    }

    private func setTheme(_ value: String) {
        guard value != currentTheme, !store.savingTheme else { return }
        store.savingTheme = true
        Task {
            do {
                app.user = try await APIClient.shared.updateMe(settings: ["theme": value])
                Haptics.select()
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
            store.savingTheme = false
        }
    }

    // MARK: Reading

    private var reading: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Reading")

            Toggle(isOn: $blockRemoteImages) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Block remote images")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.foreground)
                    Text("Images load only when you ask. Senders cannot see that you opened the message.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.Colors.foreground)
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.vertical, 10)
            .frame(minHeight: Theme.Metrics.denseRowHeight)
            .onChange(of: blockRemoteImages) { _, value in
                ReadingPrefs.blockRemoteImages = value
            }
        }
    }

    // MARK: Assistant

    private var assistant: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Assistant")
            SettingsActionRow(title: "AI assistant", detail: "Provider, key, model, behaviour and memory", divider: false) {
                nav.push(.aiSettings)
            }
        }
    }

    // MARK: Data

    private var data: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Data")
            SettingsActionRow(
                title: "Clear image cache",
                detail: "Avatars and message images kept on this phone",
                busy: store.clearingCache
            ) {
                guard !store.clearingCache else { return }
                store.clearingCache = true
                Task {
                    await ImageCache.shared.clear()
                    store.clearingCache = false
                    toasts.show("Image cache cleared")
                }
            }
            // Offered separately from images because the effect is different: clearing
            // this costs nothing but a slower next open, since every screen refetches
            // anyway. Nothing is lost — the server remains the record.
            SettingsActionRow(
                title: "Clear saved content",
                detail: store.cacheSizeLabel,
                busy: false,
                divider: false
            ) {
                ContentCache.shared.clear()
                Task { await store.measureCache() }
                toasts.show("Saved content cleared")
            }
        }
    }

    // MARK: Session

    /// Both of these throw something away, so both are named plainly and both ask first.
    /// Neither is tinted: in a grayscale app the word is the warning.
    private var session: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Session")
            SettingsActionRow(title: "Sign out", detail: app.user?.email) {
                confirmSignOut = true
            }
            SettingsActionRow(title: "Change server", detail: app.serverHost, divider: false) {
                confirmChangeServer = true
            }
        }
    }
}

// MARK: - Theme choices

private struct ThemeChoice {
    let value: String
    let title: String
    let icon: String

    static let all = [
        ThemeChoice(value: "system", title: "System", icon: "circle.lefthalf.filled"),
        ThemeChoice(value: "light", title: "Light", icon: "sun.max"),
        ThemeChoice(value: "dark", title: "Dark", icon: "moon"),
    ]
}

// MARK: - Rows

/// Label on the left, value on the right. A fact when there is no `action`, and a control
/// when there is — the chevron is what tells the two apart, so a row never looks tappable
/// without being it.
private struct SettingsValueRow: View {
    let title: String
    let value: String
    var divider: Bool = true
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { line }
                .buttonStyle(PressableRowStyle())
                .settingsDivider(divider)
                .accessibilityLabel("\(title), \(value.isEmpty ? "not set" : value)")
                .accessibilityHint("Change it")
        } else {
            line
                .settingsDivider(divider)
                .accessibilityElement(children: .combine)
        }
    }

    private var line: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
            Spacer(minLength: 12)
            Text(value.isEmpty ? "—" : value)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.mutedForeground.opacity(0.5))
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// The sentence under a group that says what the choice above it does. Sits outside the
/// rows so it never has to fit on one line beside a control.
private struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.small)
            .foregroundStyle(Theme.Colors.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.top, 8)
    }
}

private struct SettingsActionRow: View {
    let title: String
    var detail: String?
    var busy: Bool = false
    var divider: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.foreground)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if busy {
                    ProgressView().tint(Theme.Colors.mutedForeground)
                }
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(minHeight: Theme.Metrics.denseRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .settingsDivider(divider)
    }
}

/// One option in a picker drawn as a list rather than a segmented control, because the
/// choices are named and the list already scrolls.
private struct SettingsChoiceRow: View {
    let title: String
    let icon: String
    let selected: Bool
    var disabled: Bool = false
    var divider: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 22)
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.foreground)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .disabled(disabled)
        .settingsDivider(divider)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A mailbox: its glyph and address, what the sync is doing, and a pull-now button.
/// Tapping the row scopes the whole app to that mailbox, which is why the current one
/// carries a checkmark rather than only a highlight.
private struct MailboxRow: View {
    let account: Account
    let glyph: String?
    let selected: Bool
    let syncing: Bool
    var divider: Bool = true
    let onSelect: () -> Void
    let onSync: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    if let glyph {
                        Text(glyph)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .frame(width: 14)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.email)
                            .font(Theme.Typography.bodyMedium)
                            .foregroundStyle(Theme.Colors.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.foreground)
                        .opacity(selected ? 1 : 0)
                }
                .padding(.leading, Theme.Metrics.hPadding)
                .frame(minHeight: Theme.Metrics.denseRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .accessibilityLabel("\(account.email), \(subtitle)")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)

            Button(action: onSync) {
                Group {
                    if syncing {
                        ProgressView().tint(Theme.Colors.mutedForeground)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.Colors.foreground)
                    }
                }
                .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .disabled(syncing)
            .accessibilityLabel("Sync \(account.email) now")

            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.mutedForeground.opacity(0.6))
                    .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .accessibilityLabel("Sending settings for \(account.email)")
            .padding(.trailing, 4)
        }
        .settingsDivider(divider)
    }

    /// Provider, sync state and when it last pulled, in that order — the same wording the
    /// web build uses, so a person reading both does not have to translate.
    private var subtitle: String {
        var parts = [provider, status]
        if !account.isDomain, let last = account.lastSyncedAt, last > 0 {
            parts.append(RelativeTime.short(Date(timeIntervalSince1970: last / 1000)))
        }
        return parts.joined(separator: " · ")
    }

    private var provider: String {
        if account.isDomain { return "Mailbox" }
        if account.provider == "gmail" { return "Gmail" }
        return account.provider.capitalized
    }

    private var status: String {
        if account.isDomain { return "Receives via Cloudflare" }
        switch account.syncStatus {
        case "disconnected": return "Disconnected"
        case "error": return "Sync error"
        case "syncing": return "Syncing"
        default: return account.initialSyncDone ? "Synced" : "Connecting"
        }
    }
}

private extension View {
    /// The inset hairline between rows in a section; the last row of a section drops it.
    func settingsDivider(_ active: Bool) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.leading, Theme.Metrics.hPadding)
                .opacity(active ? 1 : 0)
        }
    }
}

// MARK: - Mailbox detail

/// How one mailbox signs off: the name on the envelope and the signature under the words.
///
/// Signature is the reason this sheet exists. Mail sent from this phone currently goes out
/// unsigned, because the composer appends whatever the account carries and nothing on the
/// device could ever set it. That is a real difference between mail sent from a laptop and
/// from a pocket, visible to everyone who receives it.
///
/// Below the signature: the sync tools and the two ways out. Starting fresh and
/// disconnecting are irreversible, so both are named for exactly what they do and both
/// ask first — but they are here, because a phone is where you are when Gmail stops
/// syncing and the fix is a reset.
private struct MailboxSheet: View {
    let account: Account

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(ToastCenter.self) private var toasts

    @State private var displayName: String
    @State private var signature: String
    @State private var saving = false
    @State private var busy: String?
    @State private var showingLog = false
    @State private var confirmReset = false
    @State private var confirmRemove = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case name, signature }

    init(account: Account) {
        self.account = account
        _displayName = State(initialValue: account.displayName)
        _signature = State(initialValue: account.signature)
    }

    private var dirty: Bool {
        displayName != account.displayName || signature != account.signature
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: account.isDomain ? "Mailbox" : "Account", titleVisible: true, leading: {
                BarButton(icon: "chevron.down", label: "Close") { dismiss() }
            }, trailing: { EmptyView() })

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    SectionHeader(title: "Sending")

                    field(
                        label: "Display name",
                        hint: "The name people see instead of the address."
                    ) {
                        TextField(account.email, text: $displayName)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.foreground)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focused, equals: .name)
                            .padding(10)
                            .frame(minHeight: Theme.Metrics.minTouchTarget, alignment: .leading)
                            .background(Theme.Colors.muted)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                            .accessibilityLabel("Display name")
                    }

                    field(
                        label: "Signature",
                        hint: "Added under new messages. HTML is allowed, which is why it is shown in a plain face."
                    ) {
                        TextField("", text: $signature, axis: .vertical)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(Theme.Colors.foreground)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(4...12)
                            .focused($focused, equals: .signature)
                            .padding(10)
                            .frame(minHeight: 96, alignment: .topLeading)
                            .background(Theme.Colors.muted)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                            .accessibilityLabel("Signature")
                    }

                    Button {
                        save()
                    } label: {
                        if saving {
                            ProgressView().tint(Theme.Colors.background)
                        } else {
                            Text("Save")
                        }
                    }
                    .buttonStyle(FilledButtonStyle())
                    .disabled(!dirty || saving)
                    .opacity(dirty ? 1 : 0.5)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.top, 16)

                    tools
                }
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .screenBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showingLog) { SyncLogSheet(account: account) }
        .confirmationDialog("Start fresh with \(account.email)?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Start fresh", role: .destructive) { Task { await reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes everything heyflare has synced for this account — threads, contacts, screener decisions, clips, drafts. Gmail itself is untouched. New mail from now on goes through the Screener.")
        }
        .confirmationDialog(
            account.isDomain ? "Delete \(account.email)?" : "Disconnect \(account.email)?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button(account.isDomain ? "Delete mailbox" : "Disconnect", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(account.isDomain
                 ? "This deletes the mailbox and every message stored in it. Mail sent to this address will bounce, or land in the domain's catch-all."
                 : "This removes the account and all of its synced mail from heyflare. Nothing changes in Gmail.")
        }
    }

    // MARK: Tools

    private var tools: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !account.isDomain {
                SectionHeader(title: "Sync")
                SettingsActionRow(title: "Sync now", detail: "Pull new mail from Gmail", busy: busy == "sync") {
                    Task { await syncNow() }
                }
                SettingsActionRow(title: "Sync contact photos", detail: "Fetch faces from Google Contacts", busy: busy == "photos") {
                    Task { await syncPhotos() }
                }
                SettingsActionRow(title: "Sync log", detail: "What the last syncs did, and where they stopped", divider: false) {
                    showingLog = true
                }
            }

            SectionHeader(title: account.isDomain ? "Mailbox" : "Account")
            if !account.isDomain {
                SettingsActionRow(title: "Start fresh", detail: "Wipe what is synced and begin again from now", busy: busy == "reset") {
                    confirmReset = true
                }
            }
            SettingsActionRow(
                title: account.isDomain ? "Delete mailbox" : "Disconnect",
                detail: account.isDomain ? "Removes the address and its mail" : "Removes the account and its mail from heyflare",
                busy: busy == "remove",
                divider: false
            ) {
                confirmRemove = true
            }
        }
        .disabled(busy != nil)
    }

    private func syncNow() async {
        busy = "sync"
        defer { busy = nil }
        do {
            let added = try await APIClient.shared.syncNow(accountID: account.id)
            await app.refreshAccounts()
            app.didMutate()
            toasts.show(added.map { "Synced · \($0) new" } ?? "Synced")
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func syncPhotos() async {
        busy = "photos"
        defer { busy = nil }
        do {
            let updated = try await APIClient.shared.syncContactPhotos(accountID: account.id)
            app.didMutate()
            toasts.show(updated == 0 ? "Photos are up to date" : "Updated \(updated) photo\(updated == 1 ? "" : "s")")
        } catch let error as APIError {
            toasts.error(error == .server("photos_failed", 502)
                         ? "Google refused the photo sync. Reconnect the account to grant the People scope."
                         : (error.errorDescription ?? "Could not sync photos."))
        } catch {
            toasts.error(error.localizedDescription)
        }
    }

    private func reset() async {
        busy = "reset"
        defer { busy = nil }
        do {
            let firstSyncError = try await APIClient.shared.resetAccount(account.id)
            await app.refreshAccounts()
            ContentCache.shared.clear()
            app.didMutate()
            if let firstSyncError, !firstSyncError.isEmpty {
                toasts.error("Reset done, but the first sync failed: \(firstSyncError)")
            } else {
                toasts.show("Starting fresh — watching for new mail from now on")
            }
            dismiss()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func remove() async {
        busy = "remove"
        defer { busy = nil }
        do {
            try await APIClient.shared.deleteAccount(account.id)
            await app.refreshAccounts()
            ContentCache.shared.clear()
            app.didMutate()
            toasts.show(account.isDomain ? "Deleted \(account.email)" : "Disconnected \(account.email)")
            dismiss()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(account.email)
                .font(Theme.Typography.section)
                .foregroundStyle(Theme.Colors.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(status)
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
            if let error = account.syncError, !error.isEmpty {
                Text(error)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 12)
    }

    private var status: String {
        var parts = [account.isDomain ? "Mailbox" : (account.provider == "gmail" ? "Gmail" : account.provider.capitalized)]
        if account.isDomain {
            parts.append("Receives via Cloudflare")
        } else if let last = account.lastSyncedAt, last > 0 {
            parts.append("synced \(RelativeTime.short(Date(timeIntervalSince1970: last / 1000)))")
        }
        return parts.joined(separator: " · ")
    }

    /// A labelled field with its explanation above the control rather than beside it, so
    /// neither has to be truncated to share a line.
    @ViewBuilder
    private func field<Content: View>(label: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.Typography.small.weight(.medium))
                .foregroundStyle(Theme.Colors.foreground)
            Text(hint)
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 12)
    }

    /// Both fields go up together, because the worker takes them together and a half-saved
    /// sheet is a state nobody asked for.
    private func save() {
        guard dirty, !saving else { return }
        saving = true
        focused = nil
        Task {
            do {
                try await APIClient.shared.updateAccount(
                    account.id,
                    displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    signature: signature
                )
                // Refreshed rather than patched in place: the composer reads the signature
                // off `app.accounts`, and that list is the one copy everything else trusts.
                await app.refreshAccounts()
                toasts.show("Saved")
                dismiss()
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
            saving = false
        }
    }
}
