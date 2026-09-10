import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

/// `Settings.tsx`: a page with line tabs.
struct SettingsPage: View {
    let tab: String
    @Environment(Router.self) private var router

    private let tabs: [(String, String, String)] = [("profile", "Profile", "user"), ("preferences", "Preferences", "slidersHorizontal"), ("accounts", "Accounts", "mail"), ("domains", "Domains", "globe"), ("calendar", "Calendar", "calendarDays"), ("ai", "AI", "sparkles"), ("security", "Security", "keyRound")]

    var body: some View {
        let current = tabs.contains { $0.0 == tab } ? tab : "profile"
        PageColumn {
            PageHeader(title: "Settings").padding(.horizontal, -8)
            // `TabsList variant="line"` puts `gap-1` between the triggers.
            HStack(spacing: 4) {
                ForEach(tabs, id: \.0) { t in
                    Button { router.replace(.settings(t.0)) } label: {
                        HStack(spacing: 6) { Icon(t.2, size: 14); Text(t.1) }
                            .font(W.font(14, 500)).foregroundStyle(current == t.0 ? W.foreground : W.mutedForeground)
                            .padding(.horizontal, 8).frame(height: 32)
                            .overlay(alignment: .bottom) { if current == t.0 { Rectangle().fill(W.foreground).frame(height: 2) } }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .edgeLine(.bottom)
            .padding(.horizontal, -8)
            .padding(.bottom, 24)
            switch current {
            case "preferences": PreferencesSection()
            case "accounts": AccountsSection()
            case "domains": DomainsSection()
            case "calendar": CalendarSettingsSection()
            case "ai": AiSection()
            case "security": SecuritySection()
            default: ProfileSection()
            }
        }
    }
}

// MARK: - Building blocks (Notion-style property rows)

struct SettingsSection<Content: View, Actions: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(W.font(16, 600)).webLine(16, 24, weight: 600)
                    if let description { Text(description).font(W.s13).foregroundStyle(W.mutedForeground) }
                }
                Spacer()
                actions()
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
            content()
        }
        .padding(.bottom, 40)
    }
}

extension SettingsSection where Actions == EmptyView {
    init(title: String, description: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, description: description, actions: { EmptyView() }, content: content)
    }
}

/// `Row`: label and hint on the left, the control on the right, a rule underneath —
/// `last:border-b-0`, so the closing row of a section passes `last`.
struct SettingsRow<Content: View>: View {
    let label: String
    var hint: String? = nil
    var last = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(W.sm)
                if let hint { Text(hint).font(W.xs).foregroundStyle(W.mutedForeground) }
            }
            Spacer()
            content()
        }
        .padding(.horizontal, 8).padding(.vertical, 12)
        .edgeLine(.bottom, last ? Color.clear : W.border)
    }
}

struct SavedMark: View {
    let show: Bool
    var body: some View { HStack(spacing: 4) { Icon("check", size: 12); Text("Saved") }.font(W.xs).foregroundStyle(W.mutedForeground).opacity(show ? 1 : 0) }
}

/// shadcn `FieldDescription`: text-sm, muted.
private struct FieldDesc: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(W.sm).webLine(14).foregroundStyle(W.mutedForeground).fixedSize(horizontal: false, vertical: true) }
}

/// A Lucide icon that turns while something is pending (`animate-spin`), still otherwise.
private struct SpinIcon: View {
    let name: String
    var size: CGFloat = 14
    let spinning: Bool
    @State private var angle: Double = 0
    var body: some View {
        Icon(name, size: size)
            .rotationEffect(.degrees(angle))
            .onChange(of: spinning, initial: true) { _, on in
                if on { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { angle = 360 } }
                else { withAnimation(.linear(duration: 0)) { angle = 0 } }
            }
    }
}

/// The Edit / Details chevron: `rotate-180` while open, over 100ms.
private struct OpenChevron: View {
    let open: Bool
    var body: some View {
        Icon("chevronDown", size: 14).rotationEffect(.degrees(open ? 180 : 0)).animation(.easeOut(duration: 0.1), value: open)
    }
}

/// `CopyButton`: the copy glyph swaps to a check for 1.2s.
private struct CopyButton: View {
    let text: String
    @State private var ok = false
    var body: some View {
        WButton(icon: ok ? "check" : "copy", variant: .ghost, size: .iconXs, muted: true, help: "Copy") {
            Platform.copy(text)
            ok = true
            Task { try? await Task.sleep(for: .seconds(1.2)); ok = false }
        }
    }
}

/// `<a class="underline underline-offset-2 hover:text-foreground">` inside a muted line.
private struct InlineLink: View {
    let label: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) { Text(label).underline().foregroundStyle(hovering ? W.foreground : W.mutedForeground) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
    }
}

/// `text-xs` (12) is `.font(W.xs)`; where the web wants 13 it is `.font(W.s13)`.
private func friendly(_ error: Error) -> String {
    (error as? APIError)?.errorDescription ?? error.localizedDescription
}

// MARK: - Profile

struct ProfileSection: View {
    @Environment(AppState.self) private var app
    @State private var name = ""
    @State private var saved = false

    var body: some View {
        if let user = app.user {
            SettingsSection(title: "Profile", description: "Your name appears in the sidebar. Sending uses each account's own name.") {
                HStack(spacing: 12) {
                    WAvatar(email: user.email, name: user.name, src: app.accounts.first(where: { !$0.avatarURL.isEmpty })?.avatarURL, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.name.isEmpty ? user.email : user.name).font(W.font(14, 500))
                        HStack(spacing: 4) { Text("\(user.email) ·").font(W.xs).foregroundStyle(W.mutedForeground); WBadge("Owner", variant: .secondary, muted: true) }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 16)
                // Saves on blur, as the web's input does; Enter is just a keystroke there.
                SettingsRow(label: "Name") {
                    HStack(spacing: 8) {
                        WTextField(placeholder: "", text: $name, onBlur: { if name.trimmingCharacters(in: .whitespaces) != user.name { save(user) } }).frame(width: 224)
                        SavedMark(show: saved)
                    }
                }
                SettingsRow(label: "Email", hint: "Used to log in. Can't be changed here.", last: true) {
                    Text(user.email).font(W.sm).foregroundStyle(W.mutedForeground).padding(.horizontal, 10).frame(width: 224, height: 32, alignment: .leading).background(W.input.opacity(0.5)).rounded(W.radiusMd)
                }
            }
            .onAppear { name = user.name }
            // The field follows the user wherever the change came from, as the web's effect does.
            .onChange(of: user.name) { _, n in name = n }
        }
    }

    private func save(_ user: User) {
        let n = name.trimmingCharacters(in: .whitespaces)
        Task {
            // The web's mutation has no error handler here: a failure leaves the field as typed.
            if let u = try? await APIClient.shared.updateMe(name: n) {
                await app.adopt(user: u); saved = true; try? await Task.sleep(for: .seconds(2)); saved = false
            }
        }
    }
}

// MARK: - Preferences

struct PreferencesSection: View {
    @Environment(AppState.self) private var app
    @State private var undo = "10"
    @State private var saved = false

    private var settings: UserSettings { app.user?.settings ?? UserSettings() }

    var body: some View {
        SettingsSection(title: "Appearance") {
            SettingsRow(label: "Theme", hint: "System follows your device.") {
                WToggleGroup(options: [ToggleOption(id: "system", label: "System", icon: "monitor"), ToggleOption(id: "light", label: "Light", icon: "sun"), ToggleOption(id: "dark", label: "Dark", icon: "moon")], value: Binding(get: { settings.theme ?? "system" }, set: { patch(["theme": $0]) }))
            }
            SettingsRow(label: "Show previews in lists", hint: "The first line of each message next to the subject.", last: true) {
                WSwitch(on: Binding(get: { settings.showPreviews != false }, set: { patch(["showPreviews": $0]) }))
            }
        }
        SettingsSection(title: "Mail", actions: { SavedMark(show: saved) }) {
            SettingsRow(label: "Default place for new senders", hint: "Pre-selected when you say yes in the Screener.") {
                WToggleGroup(options: [ToggleOption(id: "imbox", label: "Imbox", icon: "inbox"), ToggleOption(id: "feed", label: "The Feed", icon: "rss"), ToggleOption(id: "paper_trail", label: "Paper Trail", icon: "fileText")], value: Binding(get: { settings.defaultScreenTarget ?? "imbox" }, set: { patch(["defaultScreenTarget": $0]) }))
            }
            SettingsRow(label: "Undo send window", hint: "Seconds to change your mind after hitting Send. 0 turns it off.", last: true) {
                HStack(spacing: 8) {
                    // Clamped to 0…60 on every keystroke, saved on blur — the web's number input.
                    WTextField(placeholder: "10", text: $undo, onBlur: { saveUndo() }).frame(width: 80).multilineTextAlignment(.trailing)
                        .onChange(of: undo) { _, v in
                            let n = max(0, min(60, Int(v) ?? 0))
                            if String(n) != v { undo = String(n) }
                        }
                    Text("sec").font(W.s13).foregroundStyle(W.mutedForeground)
                }
            }
        }
        .onAppear { undo = String(settings.undoSendSeconds ?? 10) }
    }

    private func saveUndo() { patch(["undoSendSeconds": max(0, min(60, Int(undo) ?? 0))]) }

    private func patch(_ fields: [String: Any]) {
        Task {
            do {
                var all: [String: Any] = ["theme": settings.theme ?? "system", "defaultScreenTarget": settings.defaultScreenTarget ?? "imbox", "undoSendSeconds": settings.undoSendSeconds ?? 10, "showPreviews": settings.showPreviews ?? true]
                for (k, v) in fields { all[k] = v }
                let u = try await APIClient.shared.updateMe(settings: all)
                await app.adopt(user: u)
                saved = true; try? await Task.sleep(for: .seconds(2)); saved = false
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }
}

// MARK: - Accounts

struct AccountsSection: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(Toasts.self) private var toasts
    @Environment(DialogState.self) private var dialogs

    var body: some View {
        let remote = app.accounts.filter { !$0.isDomain }
        let boxes = app.accounts.filter(\.isDomain)
        SettingsSection(title: "Connected accounts", description: "What's connected, and how it signs off.", actions: {
            HStack(spacing: 4) {
                if app.googleConfigured { WButton("Connect Gmail", icon: "plus", variant: .ghost, size: .sm, muted: true) { GoogleConnect.start(toasts: toasts) } }
                if app.microsoftConfigured { WButton("Connect Outlook", icon: "plus", variant: .ghost, size: .sm, muted: true) { GoogleConnect.start(toasts: toasts, provider: "microsoft") } }
                WButton("Add mailbox", icon: "plus", variant: .ghost, size: .sm, muted: true) { addImap() }
            }
        }) {
            if !app.googleConfigured || !app.microsoftConfigured { oauthNotice }
            if remote.isEmpty { Text("Nothing connected yet.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 8) }
            ForEach(remote) { AccountBlock(account: $0, last: $0.id == remote.last?.id) }
        }
        ConnectorCredentialsSection()
        SettingsSection(title: "Domain mailboxes", description: "Addresses on your own domains.", actions: {
            WButton("New mailbox", icon: "plus", variant: .ghost, size: .sm, muted: true) { router.replace(.settings("domains")) }
        }) {
            if boxes.isEmpty { Text("No mailboxes yet. Add a domain first.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 8) }
            ForEach(boxes) { AccountBlock(account: $0, last: $0.id == boxes.last?.id) }
        }
    }

    /// Which providers still lack an OAuth client, and where to add one.
    private var oauthNotice: some View {
        let neither = !app.googleConfigured && !app.microsoftConfigured
        let who = neither ? "Gmail and Outlook need" : !app.googleConfigured ? "Gmail needs" : "Outlook needs"
        let pronoun = neither ? "they" : "it"
        return (Text("\(who) an OAuth client before \(pronoun) can be connected — add the credentials under ")
                + Text("Provider credentials").font(W.font(13, 700))
                + Text(" below. IMAP mailboxes need no setup."))
            .font(W.s13).foregroundStyle(W.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(W.muted60).rounded(W.radiusMd)
            .padding(.horizontal, 8).padding(.bottom, 12)
    }

    private func addImap() {
        dialogs.present("add-imap", width: 448) {
            AddImapForm(onDone: { dialogs.dismiss("add-imap"); Task { await app.refreshAccounts() } }, onCancel: { dialogs.dismiss("add-imap") })
        }
    }
}

struct AccountBlock: View {
    let account: Account
    var last = false
    @Environment(AppState.self) private var app
    @Environment(DialogState.self) private var dialogs
    @Environment(Toasts.self) private var toasts
    @State private var open = false
    @State private var displayName = ""
    @State private var signature = ""
    @State private var saved = false
    @State private var saving = false
    @State private var syncing = false
    @State private var resetting = false

    /// `statusOf` in Settings.tsx.
    private var status: (label: String, spin: Bool) {
        if account.isDomain { return ("Mailbox · receives via Cloudflare", false) }
        if account.provider == "imap" && account.syncStatus == "idle" { return ("Mailbox · IMAP", false) }
        if account.syncStatus == "disconnected" { return ("Disconnected", false) }
        if account.syncStatus == "error" { return ("Sync error", false) }
        if !account.initialSyncDone { return ("Connecting", true) }
        if account.syncStatus == "syncing" { return ("Syncing", true) }
        return ("Synced", false)
    }
    private var dirty: Bool { signature != account.signature || displayName != account.displayName }
    /// `isGmail` on the web: Outlook is handled like Gmail (synced, resettable, disconnectable).
    /// An IMAP mailbox is a "Mailbox" — deleted rather than disconnected, its servers edited here.
    private var isGmail: Bool { account.provider == "gmail" || account.provider == "outlook" }
    private var isImap: Bool { account.provider == "imap" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WAvatar(email: account.email, name: account.displayName, src: account.avatarURL, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: account.id), label: account.email) }
                        Text(account.email).font(W.font(14, 500)).lineLimit(1)
                        WBadge(isGmail ? "Gmail" : "Mailbox", variant: .outline, muted: true)
                    }
                    HStack(spacing: 6) {
                        if status.spin { Spinner(size: 11) }
                        Text(status.label)
                        if isGmail, let at = account.lastSyncedAt { Text("· \(Fmt.relative(at))") }
                        if let e = account.syncError, !e.isEmpty { Text("· \(e)") }
                        // `/auth/google/start`, for any provider, with no hint — as the web links it.
                        if account.syncStatus == "disconnected" { InlineLink(label: "Reconnect") { GoogleConnect.start(toasts: toasts) } }
                    }
                    .font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
                    if isGmail && account.syncStatus != "disconnected" && account.photosSyncedAt == nil {
                        HStack(spacing: 8) {
                            Text("Reconnect Gmail to enable contact photos.")
                            InlineLink(label: "Reconnect") { GoogleConnect.start(toasts: toasts, loginHint: account.email) }
                        }
                        .font(W.xs).foregroundStyle(W.mutedForeground)
                    }
                }
                Spacer()
                if isGmail {
                    WButton("Sync", icon: "refreshCw", variant: .ghost, size: .sm, muted: true) {
                        syncing = true
                        Task { defer { syncing = false }; do { let n = try await APIClient.shared.syncNow(accountID: account.id); toasts.show("Synced\(n.map { " · \($0) new" } ?? "")"); Mail.invalidate() } catch { toasts.error(friendly(error)) } }
                    }
                    .disabled(syncing)
                }
                Button { open.toggle() } label: { HStack(spacing: 4) { Text("Edit"); OpenChevron(open: open) } }
                    .buttonStyle(.web(.ghost, .sm, muted: true))
            }
            .padding(.horizontal, 8).frame(minHeight: 48)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) { FieldLabel("Display name"); WTextField(placeholder: "Shown as the sender name", text: $displayName).frame(maxWidth: 384) }
                        VStack(alignment: .leading, spacing: 6) { FieldLabel("Signature"); WTextArea(placeholder: "HTML allowed. Added under new messages.", text: $signature, minHeight: 72, fontSize: 12, mono: true) }
                    }
                    HStack(spacing: 8) {
                        WButton("Save", size: .sm) { save() }.disabled(!dirty || saving)
                        SavedMark(show: saved && !dirty)
                        Spacer()
                        if isImap {
                            WButton("Server settings", icon: "slidersHorizontal", variant: .ghost, size: .sm, muted: true) { editImap() }
                        }
                        if isGmail {
                            WButton("Start fresh", icon: "refreshCw", variant: .ghost, size: .sm, muted: true) {
                                dialogs.confirm(title: "Start fresh with \(account.email)?", description: "This deletes everything heyflare has synced for this account — threads, contacts, screener decisions, clips, drafts. Gmail itself is untouched. New mail from now on will go through the Screener.", action: "Start fresh") { reset() }
                            }
                            .disabled(resetting)
                        }
                        WButton(isGmail ? "Disconnect" : "Delete mailbox", icon: isGmail ? "unplug" : "trash2", variant: .ghost, size: .sm, muted: true) {
                            dialogs.confirm(title: isGmail ? "Disconnect \(account.email)?" : "Delete \(account.email)?", description: isGmail ? "This removes the account and all of its synced mail from heyflare. Nothing changes in Gmail." : "This deletes the mailbox and every message stored in it. Mail sent to this address will bounce (or land in the domain's catch-all).", action: isGmail ? "Disconnect" : "Delete mailbox") {
                                Task { do { try await APIClient.shared.deleteAccount(account.id); await app.refreshAccounts(); Mail.invalidate() } catch { toasts.error(friendly(error)) } }
                            }
                        }
                    }
                    .padding(.top, 12)
                }
                .padding(.leading, 44).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 16)
            }
        }
        .edgeLine(.bottom, last ? Color.clear : W.border)
        .onAppear { displayName = account.displayName; signature = account.signature }
        .onChange(of: account.displayName) { _, v in displayName = v }
        .onChange(of: account.signature) { _, v in signature = v }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do { _ = try await APIClient.shared.updateAccount(account.id, displayName: displayName, signature: signature); await app.refreshAccounts(); saved = true; try? await Task.sleep(for: .seconds(2)); saved = false }
            catch { toasts.error(friendly(error)) }
        }
    }

    private func reset() {
        resetting = true
        Task {
            defer { resetting = false }
            do {
                let e = try await APIClient.shared.resetAccount(account.id)
                if let e { toasts.error("Reset done, but the first sync failed: \(e)") } else { toasts.show("Starting fresh — watching for new mail from now on") }
                await app.refreshAccounts(); Mail.invalidate()
            } catch { toasts.error(friendly(error)) }
        }
    }

    private func editImap() {
        dialogs.present("edit-imap-\(account.id)", width: 448) {
            EditImapForm(account: account, onDone: { dialogs.dismiss("edit-imap-\(account.id)"); Task { await app.refreshAccounts() } }, onCancel: { dialogs.dismiss("edit-imap-\(account.id)") })
        }
    }
}

/// `EditImapDialog`: change an IMAP mailbox's server settings or password without losing its
/// synced mail.
private struct EditImapForm: View {
    let account: Account
    var onDone: () -> Void
    var onCancel: () -> Void
    @State private var imapHost = ""
    @State private var smtpHost = ""
    @State private var imapPort = "993"
    @State private var smtpPort = "465"
    @State private var password = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var testing = false

    var body: some View {
        FormDialog(title: "Edit \(account.email)", description: "Checked against both servers before anything is saved. Your mail is kept.") {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Password")
                    WTextField(placeholder: "Leave blank to keep the current one", text: $password, secure: true)
                    FieldDesc("Set this when your provider's app password has been rotated.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("IMAP server")
                    HStack(spacing: 8) { WTextField(placeholder: "", text: $imapHost); WTextField(placeholder: "", text: $imapPort).frame(width: 96) }
                    FieldDesc("993 for implicit TLS, or 143 for STARTTLS.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("SMTP server")
                    HStack(spacing: 8) { WTextField(placeholder: "", text: $smtpHost); WTextField(placeholder: "", text: $smtpPort).frame(width: 96) }
                    FieldDesc("465 for implicit TLS, 587 for STARTTLS. Port 25 is blocked by Cloudflare.")
                }
                HStack {
                    Button { test() } label: { HStack(spacing: 4) { if testing { Spinner(size: 14) }; Text("Test stored credentials") } }
                        .buttonStyle(.web(.outline, .sm)).disabled(testing)
                }
            }
        } footer: {
            WButton("Cancel", variant: .ghost, action: onCancel)
            Button { submit() } label: { HStack(spacing: 6) { if saving { Spinner(size: 16) }; Text("Save") } }
                .buttonStyle(.web(.default, .default)).disabled(!loaded || saving)
        }
        .task {
            do {
                let r = try await APIClient.shared.imapSettings(accountID: account.id)
                imapHost = r.imapHost; imapPort = String(r.imapPort); smtpHost = r.smtpHost; smtpPort = String(r.smtpPort)
                loaded = true
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func submit() {
        let ip = Int(imapPort) ?? 993, sp = Int(smtpPort) ?? 465
        var body: [String: Any] = [
            "imap_host": imapHost.trimmingCharacters(in: .whitespaces), "imap_port": ip, "imap_security": ip == 143 ? "starttls" : "tls",
            "smtp_host": smtpHost.trimmingCharacters(in: .whitespaces), "smtp_port": sp, "smtp_security": sp == 587 ? "starttls" : "tls",
        ]
        let pw = password.trimmingCharacters(in: .whitespaces)
        if !pw.isEmpty { body["password"] = pw }
        saving = true
        Task {
            defer { saving = false }
            do { _ = try await APIClient.shared.updateImapAccount(account.id, body); Toasts.shared.show("\(account.email) updated"); onDone() }
            catch { Toasts.shared.show("Couldn't connect", description: friendly(error), kind: .error, duration: 12) }
        }
    }

    private func test() {
        testing = true
        Task {
            defer { testing = false }
            do {
                let r = try await APIClient.shared.testImapAccount(account.id)
                if r.ok { Toasts.shared.show("Both servers answered") } else { Toasts.shared.error(r.error ?? "Failed") }
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }
}

/// Common providers, so nobody has to look up host names. "Other" leaves the fields blank for
/// a cPanel-style webmail host, which is usually mail.<your-domain>.
private struct ImapPreset {
    let id: String
    let label: String
    let imapHost: String
    let smtpHost: String
    var note: String? = nil

    static let all: [ImapPreset] = [
        ImapPreset(id: "zoho", label: "Zoho Mail (personal @zohomail.com)", imapHost: "imap.zoho.com", smtpHost: "smtp.zoho.com", note: "Enable IMAP under Settings → Mail Accounts, and use an app password if two-factor is on. IMAP needs a paid plan — the free plan is browser-only."),
        ImapPreset(id: "zoho-pro", label: "Zoho Mail (your own domain)", imapHost: "imappro.zoho.com", smtpHost: "smtppro.zoho.com", note: "Organisation accounts on a custom domain use the 'pro' servers. On a non-US data centre swap .com for .eu, .in or .com.au."),
        ImapPreset(id: "fastmail", label: "Fastmail", imapHost: "imap.fastmail.com", smtpHost: "smtp.fastmail.com", note: "Create an app password in Fastmail under Settings → Privacy & Security."),
        ImapPreset(id: "migadu", label: "Migadu", imapHost: "imap.migadu.com", smtpHost: "smtp.migadu.com"),
        ImapPreset(id: "other", label: "Other / webmail", imapHost: "", smtpHost: "", note: "For cPanel-style hosting this is usually mail.yourdomain.com on 993 and 465."),
    ]
}

/// `AddImapDialog`: any mailbox that speaks IMAP and SMTP.
private struct AddImapForm: View {
    var onDone: () -> Void
    var onCancel: () -> Void
    @State private var preset = "zoho"
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var imapHost = "imap.zoho.com"
    @State private var smtpHost = "smtp.zoho.com"
    @State private var imapPort = "993"
    @State private var smtpPort = "465"
    @State private var advanced = false
    @State private var busy = false

    private var ready: Bool { !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !imapHost.trimmingCharacters(in: .whitespaces).isEmpty && !smtpHost.trimmingCharacters(in: .whitespaces).isEmpty }
    private var note: String? { ImapPreset.all.first { $0.id == preset }?.note }

    var body: some View {
        FormDialog(title: "Add a mailbox", description: "Connect any mailbox that speaks IMAP and SMTP — Zoho, Fastmail, Migadu or your own webmail.") {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Provider")
                    WSelect(id: "imap-preset", options: ImapPreset.all.map { WSelectOption($0.id, $0.label) }, value: Binding(get: { preset }, set: { pick($0) }), fullWidth: true, filled: true)
                    if let note { FieldDesc(note) }
                }
                VStack(alignment: .leading, spacing: 8) { FieldLabel("Email address"); WTextField(placeholder: "you@example.com", text: $email, onSubmit: { if ready { submit() } }) }
                VStack(alignment: .leading, spacing: 8) { FieldLabel("Display name"); WTextField(placeholder: "Sanjay", text: $name, onSubmit: { if ready { submit() } }) }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Password")
                    WTextField(placeholder: "App password", text: $password, secure: true, onSubmit: { if ready { submit() } })
                    FieldDesc("Stored encrypted on your server and never shown again. Use an app-specific password where your provider offers one.")
                }
                HStack(alignment: .center, spacing: 8) {
                    WSwitch(on: $advanced)
                    VStack(alignment: .leading, spacing: 2) {
                        FieldLabel("Server settings")
                        FieldDesc("Only needed for a host that is not in the list above.")
                    }
                }
                if advanced {
                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel("IMAP server")
                        HStack(spacing: 8) { WTextField(placeholder: "imap.example.com", text: $imapHost); WTextField(placeholder: "", text: $imapPort).frame(width: 96) }
                        FieldDesc("993 for implicit TLS, or 143 for STARTTLS.")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel("SMTP server")
                        HStack(spacing: 8) { WTextField(placeholder: "smtp.example.com", text: $smtpHost); WTextField(placeholder: "", text: $smtpPort).frame(width: 96) }
                        FieldDesc("465 for implicit TLS, or 587 for STARTTLS. Port 25 is blocked by Cloudflare and cannot be used.")
                    }
                }
            }
        } footer: {
            WButton("Cancel", variant: .ghost, action: onCancel)
            Button { submit() } label: { HStack(spacing: 6) { if busy { Spinner(size: 16) }; Text("Connect") } }
                .buttonStyle(.web(.default, .default)).disabled(!ready || busy)
        }
    }

    private func pick(_ id: String) {
        guard let p = ImapPreset.all.first(where: { $0.id == id }) else { return }
        preset = id
        imapHost = p.imapHost; smtpHost = p.smtpHost
        imapPort = "993"; smtpPort = "465"
    }

    private func submit() {
        // 143 and 587 mean STARTTLS; anything else is implicit TLS — the web's port handlers.
        let ip = Int(imapPort) ?? 993, sp = Int(smtpPort) ?? 465
        let body: [String: Any] = [
            "email": email.trimmingCharacters(in: .whitespaces).lowercased(),
            "display_name": name.trimmingCharacters(in: .whitespaces),
            "imap_host": imapHost.trimmingCharacters(in: .whitespaces), "imap_port": ip, "imap_security": ip == 143 ? "starttls" : "tls",
            "smtp_host": smtpHost.trimmingCharacters(in: .whitespaces), "smtp_port": sp, "smtp_security": sp == 587 ? "starttls" : "tls",
            "password": password,
        ]
        busy = true
        Task {
            defer { busy = false }
            do { let a = try await APIClient.shared.createImapAccount(body); Toasts.shared.show("\(a.email) is connected"); onDone() }
            catch { Toasts.shared.show("Couldn't connect", description: friendly(error), kind: .error, duration: 12) }
        }
    }
}

// MARK: - Provider credentials

private struct ProviderMeta {
    let name: String
    let hint: String
    let secret: String
    static func of(_ provider: String) -> ProviderMeta {
        provider == "microsoft"
            ? ProviderMeta(name: "Microsoft", hint: "Application (client) ID and a client secret from your Entra app registration.", secret: "MS_CLIENT_SECRET")
            : ProviderMeta(name: "Google", hint: "Client ID and secret from the Google Cloud OAuth client.", secret: "GOOGLE_CLIENT_SECRET")
    }
}

/// `ConnectorCredentialsSection`: the OAuth apps heyflare uses to connect Gmail and Outlook.
private struct ConnectorCredentialsSection: View {
    @State private var rows: [OAuthCredentialStatus] = []
    @State private var loading = true

    var body: some View {
        SettingsSection(title: "Provider credentials", description: "The OAuth apps heyflare uses to connect Gmail and Outlook. Rotate a secret here without redeploying.") {
            if loading {
                SkeletonBlock(height: 64).padding(.horizontal, 8).padding(.vertical, 8)
            } else {
                ForEach(rows) { c in CredentialRow(c: c, last: c.id == rows.last?.id, reload: load) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do { rows = try await APIClient.shared.oauthCredentials() } catch { Toasts.shared.error(friendly(error)) }
        loading = false
    }
}

private struct CredentialRow: View {
    let c: OAuthCredentialStatus
    var last = false
    var reload: () async -> Void
    @Environment(AppState.self) private var app
    @State private var takingOver = false
    @State private var clientID = ""
    @State private var secret = ""
    @State private var dirty = false
    @State private var saving = false

    private var meta: ProviderMeta { ProviderMeta.of(c.provider) }
    // A Worker secret is used by default, but you can take over here — otherwise a deployment
    // set up with `wrangler secret put` could never rotate an expiring secret without the CLI.
    private var managed: Bool { c.source == "env" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(meta.name).font(W.font(14, 500))
                if c.configured { WBadge("Connected", variant: .secondary) } else { WBadge("Not set", variant: .outline) }
                if managed { WBadge("Worker secret", variant: .outline) }
                if c.overriding { WBadge("Overriding Worker secret", variant: .outline) }
            }
            .padding(.bottom, 8)
            if managed && !takingOver {
                VStack(alignment: .leading, spacing: 8) {
                    (Text("Currently using the ") + Text(meta.secret).font(W.mono(12)) + Text(" Worker secret. Rotate it with ") + Text("wrangler secret put").font(W.mono(12)) + Text(", or manage it here instead."))
                        .font(W.s13).foregroundStyle(W.mutedForeground).fixedSize(horizontal: false, vertical: true)
                    WButton("Manage here instead", variant: .outline, size: .sm) { takingOver = true; clientID = c.clientID }
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel("Client ID")
                        WTextField(placeholder: "", text: $clientID).onChange(of: clientID) { _, _ in dirty = true }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        FieldLabel("Client secret")
                        WTextField(placeholder: c.secretHint.isEmpty ? "Client secret" : "Stored · \(c.secretHint)", text: $secret, secure: true).onChange(of: secret) { _, _ in dirty = true }
                        HStack(alignment: .top, spacing: 8) {
                            FieldDesc("\(meta.hint) Encrypted on your server and never shown again.")
                            if !c.secretHint.isEmpty {
                                Button("Remove") { removeSecret() }.buttonStyle(.plain).underline().font(W.sm).foregroundStyle(W.mutedForeground)
                            }
                        }
                    }
                    if managed && takingOver {
                        Text("Saving will use these credentials instead of the Worker secret. Enter both a client ID and a secret.")
                            .font(W.s13).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(W.muted60).rounded(W.radiusMd)
                    }
                    HStack(spacing: 8) {
                        Button { submit() } label: { HStack(spacing: 4) { if saving { Spinner(size: 14) }; Text("Save") } }
                            .buttonStyle(.web(.default, .sm)).disabled(saving || (!dirty && secret.isEmpty))
                        if takingOver { WButton("Cancel", variant: .ghost, size: .sm) { takingOver = false; secret = ""; dirty = false } }
                        if c.overriding { WButton("Use the Worker secret", variant: .ghost, size: .sm) { revert() }.disabled(saving) }
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .edgeLine(.bottom, last ? Color.clear : W.border)
        .onAppear { clientID = c.clientID }
        // Without edits in flight, the field follows the server; with them, it keeps the typing.
        .onChange(of: c.clientID) { _, v in if !dirty { clientID = v } }
    }

    private func finish() async {
        await reload()
        // `googleConfigured` / `microsoftConfigured` come with `/api/me`, which the web invalidates too.
        await app.loadSession()
    }

    private func submit() {
        saving = true
        Task {
            defer { saving = false }
            do {
                let s = secret.trimmingCharacters(in: .whitespaces)
                _ = try await APIClient.shared.saveOAuthCredential(provider: c.provider, clientID: clientID.trimmingCharacters(in: .whitespaces), clientSecret: s.isEmpty ? nil : .some(s))
                Toasts.shared.show("\(meta.name) credentials saved"); secret = ""; dirty = false; takingOver = false
                await finish()
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func revert() {
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await APIClient.shared.saveOAuthCredential(provider: c.provider, overrideEnv: false)
                Toasts.shared.show("Using the Worker secret for \(meta.name) again"); takingOver = false
                await finish()
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func removeSecret() {
        Task {
            do { _ = try await APIClient.shared.saveOAuthCredential(provider: c.provider, clientSecret: .some(nil)); Toasts.shared.show("Secret removed"); await finish() }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }
}

// MARK: - Domains

struct DomainsSection: View {
    @Environment(DialogState.self) private var dialogs
    @Environment(Toasts.self) private var toasts
    @State private var domains: [MailDomain] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        SettingsSection(title: "Custom domains", description: "Receive at your own addresses through Cloudflare Email Routing, and send from them.", actions: {
            WButton("Add domain", icon: "plus", variant: .ghost, size: .sm, muted: true) { addDomain() }
        }) {
            if loading { VStack(spacing: 8) { SkeletonBlock(height: 32); SkeletonBlock(width: 400, height: 32) }.padding(.horizontal, 8) }
            if let error { Text(error).font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8) }
            if !loading && domains.isEmpty && error == nil {
                (Text("No domains yet. Add one that lives on your Cloudflare account, then create mailboxes like ") + Text("you@yourdomain.com").font(W.mono(12)) + Text("."))
                    .font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 8)
            }
            ForEach(domains) { d in DomainBlock(domain: d, last: d.id == domains.last?.id, reload: load) }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { domains = try await APIClient.shared.domains(); error = nil } catch { self.error = friendly(error) }
    }

    private func addDomain() {
        dialogs.present("add-domain", width: 448) {
            AddDomainForm(onDone: { dialogs.dismiss("add-domain"); Task { await load() } }, onCancel: { dialogs.dismiss("add-domain") })
        }
    }
}

private struct AddDomainForm: View {
    var onDone: () -> Void
    var onCancel: () -> Void
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    /// The worker answers 409 `mx_in_use` when the domain's mail goes elsewhere, naming the
    /// hosts; then the takeover has to be spelled out and ticked, as on the web.
    @State private var mx: [String]?
    @State private var confirm = false
    var body: some View {
        FormDialog(title: "Add a domain", description: "The domain must be on your Cloudflare account with Cloudflare nameservers.") {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Domain")
                    WTextField(placeholder: "example.com", text: $name, onSubmit: { submit() }, autofocus: true)
                        .onChange(of: name) { _, _ in mx = nil; confirm = false }
                    if let error { Text(error).font(W.sm).webLine(14).foregroundStyle(W.foreground).fixedSize(horizontal: false, vertical: true) }
                }
                if let mx {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Icon("triangleAlert", size: 16).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("This will take over ALL mail for \(name.trimmingCharacters(in: .whitespaces).lowercased()).").font(W.font(14, 500))
                                (Text("It currently goes to ") + hosts(mx) + Text(". Enabling Cloudflare Email Routing replaces those MX records, so mail stops arriving there."))
                                    .font(W.s13).foregroundStyle(W.mutedForeground).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack(alignment: .top, spacing: 8) {
                            WCheckbox(checked: confirm) { confirm.toggle() }.padding(.top, 1)
                            Text("I understand. Route all mail for this domain to heyflare.").font(W.s13)
                        }
                    }
                    .padding(12).background(W.muted60).rounded(W.radiusMd)
                }
            }
        } footer: {
            WButton("Cancel", variant: .ghost, action: onCancel)
            WButton(mx != nil ? "Take over domain" : "Add domain") { submit() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy || (mx != nil && !confirm))
        }
    }

    /// The MX hosts in mono, comma-separated; "another provider" when the worker named none.
    private func hosts(_ mx: [String]) -> Text {
        guard !mx.isEmpty else { return Text("another provider") }
        return mx.enumerated().reduce(Text("")) { acc, pair in
            acc + Text(pair.element).font(W.mono(12)) + Text(pair.offset < mx.count - 1 ? ", " : "")
        }
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !(mx != nil && !confirm) else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let d = try await APIClient.shared.createDomain(name: name.trimmingCharacters(in: .whitespaces).lowercased(), confirm: mx != nil ? confirm : nil)
                Toasts.shared.show(d.status == "active" ? "\(d.name) is receiving mail" : "\(d.name) added — finish the setup steps")
                onDone()
            } catch let e as DomainMxInUse {
                mx = e.mx; confirm = false
            } catch { self.error = friendly(error) }
        }
    }
}

private struct DomainBlock: View {
    let domain: MailDomain
    var last = false
    var reload: () async -> Void
    @Environment(DialogState.self) private var dialogs
    @Environment(AppState.self) private var app
    /// Open from the start while there is something to do: not yet active, or no mailbox.
    @State private var open = false
    @State private var verifying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Icon("globe", size: 16).foregroundStyle(W.mutedForeground).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(domain.name).font(W.font(14, 500))
                        WBadge(domain.status == "active" ? "Active" : domain.status == "error" ? "Error" : "Pending", variant: domain.status == "active" ? .default : .outline, muted: domain.status != "active")
                        WBadge(domain.routing == "enabled" ? "Routing on" : domain.routing == "manual" ? "Manual setup" : "Routing off", variant: .outline, muted: true)
                        WBadge(domain.sending == "cloudflare" ? "Sends via Cloudflare" : domain.sending == "resend" ? "Sends via Resend" : "No outbound", variant: .outline, muted: true)
                    }
                    Text("\(domain.mailboxes.count) mailbox\(domain.mailboxes.count == 1 ? "" : "es")\(domain.error.map { " · \($0)" } ?? "")").font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
                }
                Spacer()
                HStack(spacing: 4) {
                    Button { verify() } label: { HStack(spacing: 4) { SpinIcon(name: "refreshCw", spinning: verifying); Text("Verify") } }
                        .buttonStyle(.web(.ghost, .sm, muted: true)).disabled(verifying)
                    Button { open.toggle() } label: { HStack(spacing: 4) { Text("Details"); OpenChevron(open: open) } }
                        .buttonStyle(.web(.ghost, .sm, muted: true))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            if open { details }
        }
        .edgeLine(.bottom, last ? Color.clear : W.border)
        .onAppear { open = domain.status != "active" || domain.mailboxes.isEmpty }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            if domain.routing != "enabled", !domain.instructions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up receiving").font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
                    ForEach(Array(domain.instructions.filter { !$0.hasPrefix("Outbound") }.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 8) { Text("\(i + 1).").monospacedDigit(); Text(s) }.font(W.s13).foregroundStyle(W.foreground90)
                    }
                }
            }
            if domain.routing != "enabled", !domain.dns.isEmpty { dnsTable }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Mailboxes").font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
                    Spacer()
                    WButton("New mailbox", icon: "plus", variant: .ghost, size: .sm, muted: true) { newMailbox() }
                }
                if domain.mailboxes.isEmpty { Text("No mailboxes yet. Create one to start receiving.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.vertical, 4) }
                ForEach(domain.mailboxes) { m in
                    HStack(spacing: 10) {
                        WAvatar(email: m.email, name: m.displayName, src: m.avatarURL, size: 20)
                        Text(m.email).font(W.sm).lineLimit(1)
                        if !m.displayName.isEmpty { Text("· \(m.displayName)").font(W.sm).foregroundStyle(W.mutedForeground) }
                        if domain.catchAllAccountID == m.id { WBadge("catch-all", variant: .secondary, muted: true) }
                    }
                    .frame(height: 36)
                }
                if !domain.mailboxes.isEmpty { Text("Signatures, display names and deletion live under Accounts.").font(W.xs).foregroundStyle(W.mutedForeground).padding(.top, 4) }
            }
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Catch-all mailbox").font(W.sm)
                    Text("Where mail to unknown addresses on \(domain.name) goes. Off means it bounces.").font(W.xs).foregroundStyle(W.mutedForeground)
                }
                Spacer()
                WSelect(id: "catch-all-\(domain.id)",
                        options: [WSelectOption("none", "Off (bounce)")] + domain.mailboxes.map { WSelectOption($0.id, $0.email) },
                        value: Binding(get: { domain.catchAllAccountID ?? "none" }, set: { setCatchAll($0) }),
                        size: .sm, minWidth: 160, align: .end)
            }
            sendingNote
            HStack { Spacer(); WButton("Remove domain", icon: "trash2", variant: .ghost, size: .sm, muted: true) {
                dialogs.confirm(title: "Remove \(domain.name)?", description: "Deletes every mailbox on it and all of their mail from heyflare. Email Routing on Cloudflare is left as it is.", action: "Remove domain") {
                    Task {
                        do { try await APIClient.shared.delete("/api/domains/\(domain.id)", scoped: false) } catch { Toasts.shared.error(friendly(error)) }
                        await reload(); await app.refreshAccounts()
                    }
                }
            } }
        }
        .padding(.leading, 36).padding(.trailing, 8).padding(.bottom, 20)
    }

    /// The web's `Table`: a 28pt muted header, 24pt mono rows, Type 64 / Name ≤160 /
    /// Content ≤260 / Prio 56 / copy 32, every cell `px-2`.
    private var dnsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DNS records Cloudflare adds when Email Routing is enabled").font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    dnsHead("Type").frame(width: 64, alignment: .leading)
                    dnsHead("Name").frame(width: 160, alignment: .leading)
                    dnsHead("Content").frame(maxWidth: 260, alignment: .leading)
                    Spacer(minLength: 0)
                    dnsHead("Prio").frame(width: 56, alignment: .leading)
                    Color.clear.frame(width: 32)
                }
                .frame(height: 28)
                ForEach(Array(domain.dns.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 0) {
                        dnsCell(r.type).frame(width: 64, alignment: .leading)
                        dnsCell(r.name).frame(width: 160, alignment: .leading)
                        dnsCell(r.content).help(r.content).frame(maxWidth: 260, alignment: .leading)
                        Spacer(minLength: 0)
                        dnsCell(r.priority.map { "\($0)" } ?? "").frame(width: 56, alignment: .leading)
                        CopyButton(text: r.content).frame(width: 32)
                    }
                    .frame(height: 24)
                }
            }
            .background(W.muted40).rounded(W.radiusMd)
        }
    }

    private func dnsHead(_ s: String) -> some View { Text(s).font(W.xs).foregroundStyle(W.mutedForeground).padding(.horizontal, 8) }
    private func dnsCell(_ s: String) -> some View { Text(s).font(W.mono(12)).monospacedDigit().lineLimit(1).truncationMode(.tail).padding(.horizontal, 8) }

    private var sendingNote: some View {
        Group {
            if domain.sending == "cloudflare" {
                Text("Outbound mail from these mailboxes goes through Cloudflare Email Sending.")
            } else if domain.sending == "resend" {
                Text("Outbound mail from these mailboxes goes through Resend. Make sure \(domain.name) is verified there.")
            } else {
                Text("Outbound isn't configured yet, so these mailboxes can receive but not send. Enable Cloudflare Email Sending (Workers Paid) and add the ")
                    + Text("send_email").font(W.mono(12))
                    + Text(" binding, or set a ")
                    + Text("RESEND_API_KEY").font(W.mono(12))
                    + Text(" secret — see README → Custom domain mailboxes.")
            }
        }
        .font(W.s13).foregroundStyle(W.mutedForeground).fixedSize(horizontal: false, vertical: true)
    }

    private func verify() {
        verifying = true
        Task {
            defer { verifying = false }
            do { let r = try await APIClient.shared.verifyDomain(domain.id); Toasts.shared.show(r.status == "active" ? "\(domain.name) is receiving mail" : "\(domain.name): \(r.error ?? "still pending")"); await reload() }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func setCatchAll(_ v: String) {
        Task {
            do { _ = try await APIClient.shared.setDomainCatchAll(domain.id, accountID: v == "none" ? nil : v); await reload() }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func newMailbox() {
        dialogs.present("new-mailbox", width: 448) {
            NewMailboxForm(domain: domain, onDone: { dialogs.dismiss("new-mailbox"); Task { await reload(); await app.refreshAccounts() } }, onCancel: { dialogs.dismiss("new-mailbox") })
        }
    }
}

private struct NewMailboxForm: View {
    let domain: MailDomain
    var onDone: () -> Void
    var onCancel: () -> Void
    @State private var local = ""
    @State private var name = ""
    /// A domain's first mailbox is the catch-all unless untickd.
    @State private var catchAll = false
    @State private var busy = false

    /// `pattern="[A-Za-z0-9._+\-]{1,64}"` — checked by the browser on Enter, not on the button.
    private var validLocal: Bool { local.range(of: "^[A-Za-z0-9._+\\-]{1,64}$", options: .regularExpression) != nil }

    var body: some View {
        FormDialog(title: "New mailbox on \(domain.name)", description: "Mail to this address lands in your unified Imbox like any other account.") {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel("Address")
                    HStack(spacing: 0) {
                        WTextFieldPlain(placeholder: "hello", text: $local, autofocus: true).padding(.leading, 10)
                            .onSubmit { if !local.trimmingCharacters(in: .whitespaces).isEmpty && validLocal { submit() } }
                        Text("@\(domain.name)").font(W.sm).foregroundStyle(W.mutedForeground).padding(.trailing, 10)
                    }
                    .frame(height: 32).background(W.input).rounded(W.radiusMd)
                    FieldDesc("Letters, numbers, dots, dashes, plus or underscores.")
                }
                VStack(alignment: .leading, spacing: 8) { FieldLabel("Display name"); WTextField(placeholder: "Farhan", text: $name) }
                HStack(alignment: .center, spacing: 8) {
                    WSwitch(on: $catchAll)
                    VStack(alignment: .leading, spacing: 2) {
                        FieldLabel("Catch-all")
                        FieldDesc("Also receive mail sent to any other address on \(domain.name).")
                    }
                }
            }
        } footer: {
            WButton("Cancel", variant: .ghost, action: onCancel)
            WButton("Create mailbox") { submit() }.disabled(local.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
        .onAppear { catchAll = domain.mailboxes.isEmpty }
    }

    private func submit() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let a = try await APIClient.shared.createMailbox(domainID: domain.id, localPart: local.trimmingCharacters(in: .whitespaces).lowercased(), displayName: name.trimmingCharacters(in: .whitespaces), catchAll: catchAll)
                Toasts.shared.show("\(a.email) is ready"); onDone()
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }
}

// MARK: - Calendar

/// `CalendarSettingsSection.tsx`: the calendars list grouped by who owns them, the
/// subscribe-and-import block, then the calendar-wide preferences. Everything writes to the
/// same `/api/calendar` the web does, which is what makes it "synced" rather than a second copy
/// of the setting; Google's consent screen itself runs in the browser, opened from here.
struct CalendarSettingsSection: View {
    @Environment(Router.self) private var router
    @State private var calendars: [CalSource] = []
    @State private var accounts: [CalGoogleAccount] = []
    @State private var loading = true
    @State private var error: String?
    @State private var creating = false
    /// Which connect button is waiting for its link; `newAccount` for the calendar-only one.
    @State private var pending: String?

    private static let newAccount = "__new__"
    private var local: [CalSource] { calendars.filter { $0.source == "local" } }
    private var ics: [CalSource] { calendars.filter { $0.source == "ics" } }
    private var orphans: [CalSource] { calendars.filter { c in c.source == "google" && !accounts.contains { $0.id == c.accountID } } }

    var body: some View {
        SettingsSection(title: "Calendars", description: "Untick to hide, without deleting.") {
            if loading {
                VStack(spacing: 8) { SkeletonBlock(height: 32); SkeletonBlock(width: 500, height: 32).frame(maxWidth: .infinity, alignment: .leading) }.padding(.horizontal, 8)
            } else if let error {
                Text(error).font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8)
            } else {
                if accounts.isEmpty {
                    HStack(spacing: 0) {
                        Text("No Google account yet — connect one for mail under ")
                        InlineLink(label: "Accounts") { router.replace(.settings("accounts")) }
                        Text(", or for calendar below.")
                    }
                    .font(W.xs).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 6).padding(.bottom, 12)
                }
                ForEach(accounts) { a in
                    // An account we hold no mail scope for stays that way: reconnecting it must not
                    // quietly ask for mail the owner never granted.
                    CalendarAccountGroup(account: a, calendars: calendars.filter { $0.accountID == a.id }, busy: pending == a.id, onConnect: { open(a.id, accountID: a.id, calendarOnly: !a.mail) }, onChange: refreshOne)
                }
                if !orphans.isEmpty {
                    CalendarGroupBlock(title: "Google Calendar", hint: "account no longer connected", calendars: orphans, onChange: refreshOne)
                }
                CalendarGroupBlock(title: "In heyflare", calendars: local, onChange: refreshOne, empty: "None yet.", last: ics.isEmpty) {
                    WButton("New calendar", icon: "plus", variant: .outline, size: .sm) { createCalendar() }.disabled(creating)
                }
                if !ics.isEmpty {
                    CalendarGroupBlock(title: "Subscribed links", calendars: ics, onChange: refreshOne, last: true)
                }
            }
            WButton(pending == Self.newAccount ? "Opening…" : "Connect a calendar-only account", icon: "calendarPlus", variant: .outline, size: .sm, help: "Asks Google for calendar access only, never mail") {
                open(Self.newAccount, accountID: nil, calendarOnly: true)
            }
            .disabled(pending == Self.newAccount)
            .padding(.horizontal, 8).padding(.top, 12)
        }
        SubscribeSection(calendars: calendars)
        CalendarPreferencesSection()
        .task { await load() }
        // A removal, a new default or a sync elsewhere changes this list too.
        .onChange(of: CalendarBus.shared.revision) { _, _ in Task { await load() } }
    }

    private func load() async {
        loading = calendars.isEmpty
        defer { loading = false }
        do {
            let r = try await CalendarAPI.sourcesFull()
            calendars = r.calendars; accounts = r.accounts; error = nil
        } catch { self.error = friendly(error) }
    }

    private func refreshOne(_ c: CalSource) {
        if let i = calendars.firstIndex(where: { $0.id == c.id }) { calendars[i] = c }
    }

    private func createCalendar() {
        creating = true
        Task {
            defer { creating = false }
            do { let c = try await CalendarAPI.createSource(name: "New calendar", color: "#111111"); calendars.append(c); Toasts.shared.show("Calendar added") }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }

    /// The consent screen has to run where the user's Google session lives: the real browser.
    private func open(_ key: String, accountID: String?, calendarOnly: Bool) {
        pending = key
        Task {
            defer { pending = nil }
            do {
                let url = try await CalendarAPI.googleConnectLink(accountID: accountID, calendarOnly: calendarOnly)
                NSWorkspace.shared.open(url)
                Toasts.shared.show("Finish in your browser, then come back.")
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }
}

/// One Google account: the address, what it's connected for, its actions — then its calendars.
private struct CalendarAccountGroup: View {
    let account: CalGoogleAccount
    let calendars: [CalSource]
    let busy: Bool
    let onConnect: () -> Void
    let onChange: (CalSource) -> Void
    @Environment(DialogState.self) private var dialogs
    @State private var disconnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Without the scope there is nothing to list and the button above says so; with it,
            // an empty account gets one quiet line rather than a gap.
            if account.calendar || !calendars.isEmpty {
                if calendars.isEmpty {
                    Text("No calendars yet.").font(W.xs).foregroundStyle(W.mutedForeground).padding(.leading, 24).padding(.trailing, 8).padding(.vertical, 6)
                } else {
                    ForEach(calendars) { c in CalendarSourceRow(source: c, last: c.id == calendars.last?.id, onChange: onChange).padding(.leading, 24).padding(.trailing, 8) }
                }
            }
        }
        .padding(.bottom, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(account.email).font(W.font(13, 500)).lineLimit(1)
                Text(account.calendar ? calendarCount(calendars.count) : account.mail ? "mail only" : "not connected").font(W.xs).foregroundStyle(W.mutedForeground)
                Spacer()
                HStack(spacing: 4) {
                    Button(action: onConnect) {
                        HStack(spacing: 4) {
                            Icon(account.calendar ? "refreshCw" : "calendarPlus", size: 14)
                            Text(busy ? "Opening…" : account.calendar ? "Reconnect" : "Connect calendar")
                        }
                    }
                    .buttonStyle(.web(.outline, .sm)).disabled(busy)
                    .help(account.calendar ? "Runs Google's consent screen again — fixes an expired or revoked grant" : "")
                    if account.calendar {
                        WButton("Disconnect", icon: "calendarX2", variant: .ghost, size: .sm, muted: true) { confirmDisconnect() }.disabled(disconnecting)
                    }
                }
            }
            if let err = account.syncError, !err.isEmpty { Text("Last sync failed: \(err)").font(W.xs).padding(.top, 4) }
            if let err = account.calendarError, !err.isEmpty { CalendarErrorNote(message: err) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6).edgeLine(.bottom)
    }

    private func calendarCount(_ n: Int) -> String { n == 1 ? "1 calendar" : "\(n) calendars" }

    private func confirmDisconnect() {
        let count = calendars.count
        dialogs.confirm("cal-disconnect-\(account.id)", title: "Disconnect \(account.email)'s calendar?", description: "Removes \(count > 0 ? calendarCount(count) : "this account's calendars") and every event on them from heyflare. Nothing changes in Google, its mail stays connected, and you can connect the calendar again later.", action: "Disconnect calendar") {
            disconnecting = true
            Task {
                defer { disconnecting = false }
                do { try await CalendarAPI.disconnectGoogle(accountID: account.id); Toasts.shared.show("\(account.email)'s calendar disconnected"); CalendarBus.shared.changed() }
                catch { Toasts.shared.error(friendly(error)) }
            }
        }
    }
}

/// Why an account has the calendar scope but no calendars. Google's most common answer by far
/// is that the Calendar API is switched off in the Cloud project, and it puts the exact enable
/// link in the message — so pull that out and make it a link rather than leaving a wall of JSON.
private struct CalendarErrorNote: View {
    let message: String

    private var disabled: Bool { message.range(of: "has not been used in project|is disabled", options: [.regularExpression, .caseInsensitive]) != nil }
    private var link: URL? {
        guard let r = message.range(of: #"https://console\.(?:developers|cloud)\.google\.com/[^\s"\\)]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(message[r]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if disabled {
                Text("The Calendar API is off for this Google Cloud project. Turn it on and the calendars appear on the next pass.")
                if let link {
                    Button("Enable the Google Calendar API") { NSWorkspace.shared.open(link) }.buttonStyle(.plain).underline().padding(.top, 4)
                }
            } else {
                Text("Couldn't read this account's calendars.")
                Text(String(message.prefix(300))).foregroundStyle(W.mutedForeground).padding(.top, 2)
            }
        }
        .font(W.xs).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(W.muted40).border1(W.border, radius: W.radiusMd).rounded(W.radiusMd)
        .padding(.top, 4)
    }
}

/// A plain heading over a list of calendars, for the groups no Google account owns.
private struct CalendarGroupBlock<Trailing: View>: View {
    let title: String
    var hint: String? = nil
    let calendars: [CalSource]
    let onChange: (CalSource) -> Void
    var empty: String = ""
    var last = false
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, hint: String? = nil, calendars: [CalSource], onChange: @escaping (CalSource) -> Void, empty: String = "", last: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title; self.hint = hint; self.calendars = calendars; self.onChange = onChange; self.empty = empty; self.last = last; self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
                if let hint { Text(hint).font(W.xs).foregroundStyle(W.mutedForeground.opacity(0.8)).lineLimit(1) }
                Spacer()
                trailing()
            }
            .padding(.horizontal, 8).padding(.vertical, 6).edgeLine(.bottom)
            if calendars.isEmpty {
                if !empty.isEmpty { Text(empty).font(W.xs).foregroundStyle(W.mutedForeground).padding(.leading, 24).padding(.trailing, 8).padding(.vertical, 6) }
            } else {
                ForEach(calendars) { c in CalendarSourceRow(source: c, last: c.id == calendars.last?.id, onChange: onChange).padding(.leading, 24).padding(.trailing, 8) }
            }
        }
        .padding(.bottom, last ? 0 : 12)
    }
}

/// The calendar's name, drawn as the web's quiet input: `h-7`, no border, transparent until
/// hovered (`hover:bg-input`) or focused (`focus-visible:bg-background`), Enter blurs, Escape
/// puts the old name back.
private struct QuietTextField: View {
    @Binding var text: String
    var onCommit: () -> Void
    var onEscape: () -> Void
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(W.sm)
            .foregroundStyle(W.foreground)
            .focused($focused)
            .onSubmit { focused = false }
            .onExitCommand { onEscape(); focused = false }
            .onChange(of: focused) { was, now in if was && !now { onCommit() } }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(focused ? W.background : (hovering ? W.input : Color.clear))
            .rounded(W.radiusMd)
            .onHover { hovering = $0 }
    }
}

/// One calendar: visible, coloured, named, made default, synced, removed — the tick is
/// visibility, not existence, exactly as the web's row explains it.
private struct CalendarSourceRow: View {
    let source: CalSource
    var last = false
    let onChange: (CalSource) -> Void

    @State private var name = ""
    @State private var syncing = false
    @State private var swatchHover = false
    @Environment(DialogState.self) private var dialogs
    @Environment(PopLayerState.self) private var pops

    // The account's email is on the group header, so a row only carries what tells it apart: a
    // feed's address, a local calendar's size, and when a synced one last came down.
    private var note: String {
        let where_ = source.source == "ics" ? (source.url ?? "") : (source.source == "local" ? (source.eventCount.map { "\($0) event\($0 == 1 ? "" : "s")" } ?? "") : "")
        let synced = source.source != "local" ? source.lastSyncedAt.map { Fmt.relative($0) } ?? "" : ""
        return [where_, synced].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                WCheckbox(checked: source.visible) { apply(visible: !source.visible) }
                    .help("Shown in the calendar")
                swatch
                HStack(spacing: 8) {
                    QuietTextField(text: $name, onCommit: { rename() }, onEscape: { name = source.name })
                        .frame(minWidth: 128, maxWidth: .infinity)
                    if !note.isEmpty { Text(note).font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground).lineLimit(1).layoutPriority(1).help(source.source == "ics" ? (source.url ?? "") : "") }
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 4) {
                    if source.writable {
                        Button { apply(isDefault: true) } label: {
                            HStack(spacing: 6) {
                                Circle().strokeBorder(W.mutedForeground, lineWidth: 1).background(Circle().fill(source.isDefault ? W.foreground : .clear).padding(3)).frame(width: 14, height: 14)
                                Text("Default").font(W.xs).foregroundStyle(W.mutedForeground)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("New events go here")
                        .padding(.trailing, 4)
                    }
                    if source.source != "local" {
                        Button { sync() } label: { SpinIcon(name: "refreshCw", size: 16, spinning: syncing) }
                            .buttonStyle(.web(.ghost, .iconSm, muted: true)).help("Sync").disabled(syncing)
                    }
                    WButton(icon: "trash2", variant: .ghost, size: .iconSm, muted: true, help: "Remove") {
                        dialogs.confirm("remove-cal-\(source.id)", title: "Remove \(source.name)?", description: removeCopy, action: "Remove calendar") {
                            Task {
                                do { try await CalendarAPI.removeSource(id: source.id); CalendarBus.shared.changed(); Toasts.shared.show("\(source.name) removed") }
                                catch { Toasts.shared.error(friendly(error)) }
                            }
                        }
                    }
                }
            }
            if let err = source.syncError, !err.isEmpty { Text("Last sync failed: \(err)").font(W.xs).padding(.leading, 24) }
        }
        .padding(.vertical, 6).edgeLine(.bottom, last ? Color.clear : W.border)
        .onAppear { name = source.name }
        .onChange(of: source.name) { _, n in name = n }
    }

    /// `size-4 rounded-full border border-border hover:ring-2 hover:ring-ring ring-offset-1`.
    private var swatch: some View {
        Button {
            pops.toggle("cal-color-\(source.id)", side: .bottom, align: .start) {
                PopCard(width: 240, padding: 10) { ColorRamp(current: source.color) { hex in apply(color: hex) } }
            }
        } label: {
            Circle().fill(Color(hex: source.color)).frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(W.border, lineWidth: 1))
                .overlay(Circle().strokeBorder(W.ring, lineWidth: 2).padding(-3).opacity(swatchHover ? 1 : 0))
                .animation(.easeOut(duration: 0.15), value: swatchHover)
        }
        .buttonStyle(.plain)
        .onHover { swatchHover = $0 }
        .popAnchor("cal-color-\(source.id)")
        .help("Colour")
    }

    private var removeCopy: String {
        switch source.source {
        case "google": return "Removes it and its events from heyflare for good. Google Calendar is untouched; to see it here again, reconnect the account’s calendar access."
        case "ics": return "Stops following the link and deletes the events it brought in. The feed is untouched."
        default: return "Deletes the calendar and every event on it. There's no undo."
        }
    }

    private func rename() {
        let v = name.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != source.name else { name = source.name; return }
        Task {
            do { onChange(try await CalendarAPI.updateSource(id: source.id, name: v)) }
            catch { name = source.name; Toasts.shared.error(friendly(error)) }
        }
    }

    private func sync() {
        syncing = true
        Task {
            defer { syncing = false }
            do {
                let r = try await CalendarAPI.syncSource(id: source.id)
                if let err = r.error { Toasts.shared.error(err) } else { Toasts.shared.show("\(source.name) is up to date") }
                if let fresh = try? await CalendarAPI.sources().first(where: { $0.id == source.id }) { onChange(fresh) }
                CalendarBus.shared.changed()
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func apply(color: String) {
        pops.closeAll()
        Task {
            do { onChange(try await CalendarAPI.updateSource(id: source.id, color: color)) }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func apply(visible: Bool) {
        Task {
            do { onChange(try await CalendarAPI.updateSource(id: source.id, visible: visible)); CalendarBus.shared.changed() }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func apply(isDefault: Bool) {
        Task {
            // The worker clears the old default; the bus makes the list re-read so only one
            // row says Default.
            do { onChange(try await CalendarAPI.updateSource(id: source.id, isDefault: isDefault)); CalendarBus.shared.changed() }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }
}

/// The web's 12-swatch ramp: muted, saturated hues built to carry white text, greys on the
/// first row for anyone who wants the calendar to stay monochrome. `w-60 p-2.5`; the padding
/// is the popover's.
private struct ColorRamp: View {
    static let ramp = ["#111111", "#3d3d3d", "#5c5c5c", "#8a8a8a", "#3d6c56", "#3d5a6c", "#3d3e6c", "#613d6c", "#6c3d47", "#6c4b3d", "#6c633d", "#3d686c"]
    let current: String
    let onPick: (String) -> Void
    @State private var hex = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Self.ramp, id: \.self) { c in
                    Button { onPick(c) } label: {
                        Circle().fill(Color(hex: c))
                            .overlay(Circle().strokeBorder(W.border, lineWidth: 1))
                            .overlay(Circle().strokeBorder(W.ring, lineWidth: 2).padding(-3).opacity(current.lowercased() == c ? 1 : 0))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                WTextField(placeholder: "#767676", text: $hex, mono: true, height: 28, fontSize: 12, onSubmit: { if isValid { onPick(hex.lowercased()) } })
                WButton("Use", variant: .outline, size: .sm) { if isValid { onPick(hex.lowercased()) } }.disabled(!isValid)
            }
            .padding(.top, 10)
            if !isValid { Text("Six hex digits, like #767676.").font(W.font(11)).foregroundStyle(W.mutedForeground).padding(.top, 6) }
        }
        .onAppear { hex = current }
        .onChange(of: current) { _, c in hex = c }
    }

    private var isValid: Bool { hex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }
}

/// `SubscribeBlock`: follow an `.ics` link, or bring a file's events into a calendar of your own.
private struct SubscribeSection: View {
    let calendars: [CalSource]
    @State private var url = ""
    @State private var name = ""
    @State private var err = ""
    @State private var dest = ""
    @State private var subscribing = false
    @State private var importing = false
    @State private var creating = false

    private var writable: [CalSource] { calendars.filter(\.writable) }

    var body: some View {
        SettingsSection(title: "Subscribe to a calendar link") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    WTextField(placeholder: "https://example.com/calendar.ics", text: $url, onSubmit: { submit() })
                        .onChange(of: url) { _, _ in err = "" }
                    WTextField(placeholder: "Name (optional)", text: $name).frame(width: 176)
                    WButton("Subscribe", icon: "link2", variant: .outline, size: .sm) { submit() }.disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || subscribing)
                }
                if !err.isEmpty { Text(err).font(W.s13).fixedSize(horizontal: false, vertical: true).padding(.top, 6) }
                Text("Read-only, refreshed about once an hour.").font(W.xs).foregroundStyle(W.mutedForeground).padding(.top, 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Import an .ics file into a calendar").font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
                    HStack(spacing: 8) {
                        WSelect(id: "ics-dest", options: writable.map { WSelectOption($0.id, $0.name) }, value: $dest, size: .sm, width: 224, placeholder: "No calendar to import into", disabled: writable.isEmpty)
                        WButton(importing ? "Importing…" : "Choose a file", icon: "upload", variant: .outline, size: .sm) { pick() }.disabled(dest.isEmpty || importing)
                        WButton("New calendar", icon: "plus", variant: .ghost, size: .sm, muted: true) { create() }.disabled(creating)
                    }
                    .padding(.top, 8)
                }
                .padding(.top, 12)
                .edgeLine(.top)
                .padding(.top, 16)
            }
            .padding(.horizontal, 8)
        }
        .onAppear { keepDest() }
        .onChange(of: writable.map(\.id)) { _, _ in keepDest() }
    }

    /// Keep the destination pointing at a calendar that still exists; default to the default one.
    private func keepDest() {
        if writable.contains(where: { $0.id == dest }) { return }
        dest = writable.isEmpty ? "" : (writable.first { $0.isDefault } ?? writable[0]).id
    }

    private func submit() {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, !subscribing else { return }
        err = ""
        subscribing = true
        Task {
            defer { subscribing = false }
            do {
                let n = name.trimmingCharacters(in: .whitespaces)
                let c = try await CalendarAPI.subscribe(url: u, name: n.isEmpty ? nil : n)
                Toasts.shared.show("Subscribed to \(c.name)"); url = ""; name = ""
                CalendarBus.shared.changed()
            } catch { err = feedMessage(error) }
        }
    }

    /// `bad_feed`/`bad_url` reach the client as the bare code; say what actually went wrong.
    private func feedMessage(_ e: Error) -> String {
        if let api = e as? APIError, case .server(let code, _) = api {
            if code == "bad_url" { return "That link should start with https:// or webcal://." }
            if code == "bad_feed" { return "That link didn't return a calendar. Open it in a browser to check it's an .ics feed." }
        }
        let m = friendly(e)
        return m.isEmpty ? "That link couldn't be subscribed to." : m
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .calendarEvent, .calendarEvent]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        importing = true
        Task {
            defer { importing = false }
            guard let text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) else {
                Toasts.shared.error("That file couldn't be read."); return
            }
            do {
                let n = try await CalendarAPI.importICS(text, calendarID: dest.isEmpty ? nil : dest)
                Toasts.shared.show("Imported \(n) event\(n == 1 ? "" : "s")")
                CalendarBus.shared.changed()
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func create() {
        creating = true
        Task {
            defer { creating = false }
            do { let c = try await CalendarAPI.createSource(name: "New calendar", color: "#111111"); dest = c.id; Toasts.shared.show("Calendar added"); CalendarBus.shared.changed() }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }
}

/// `CalendarPreferences` from the web: week start, time format, default view, the night
/// collapse and its hours, declined events, timezone. Each change lands on screen at once and
/// is put back if the server refuses it.
private struct CalendarPreferencesSection: View {
    @State private var prefs: CalPrefs?
    @State private var loadError: String?

    private static let device = "__device__"

    var body: some View {
        SettingsSection(title: "Calendar preferences") {
            if let s = prefs {
                SettingsRow(label: "Week starts on") {
                    WToggleGroup(options: [ToggleOption(id: "0", label: "Sunday"), ToggleOption(id: "1", label: "Monday")], value: Binding(get: { String(s.weekStart < 0 ? 0 : s.weekStart) }, set: { v in save(["week_start": Int(v) ?? 0]) { $0.weekStart = Int(v) ?? 0 } }))
                }
                SettingsRow(label: "Time format") {
                    WToggleGroup(options: [ToggleOption(id: "12", label: "12-hour"), ToggleOption(id: "24", label: "24-hour")], value: Binding(get: { s.timeFormat.isEmpty ? "12" : s.timeFormat }, set: { v in save(["time_format": v]) { $0.timeFormat = v } }))
                }
                SettingsRow(label: "Default view") {
                    WSelect(id: "cal-view", options: [WSelectOption("days", "Day"), WSelectOption("week", "Week"), WSelectOption("month", "Month"), WSelectOption("year", "Year")], value: Binding(get: { s.defaultView }, set: { v in save(["default_view": v]) { $0.defaultView = v } }), size: .sm, minWidth: 144, align: .end)
                }
                SettingsRow(label: "Collapse the night", hint: "Folds the sleeping hours into one band you can click open.") {
                    WSwitch(on: Binding(get: { s.collapseNight }, set: { v in save(["collapse_night": v]) { $0.collapseNight = v } }))
                }
                SettingsRow(label: "Night runs from") {
                    HStack(spacing: 8) {
                        hourPicker("night-start", s.nightStart, disabled: !s.collapseNight, format: s.timeFormat) { h in save(["night_start": h]) { $0.nightStart = h } }
                        Text("to").font(W.s13).foregroundStyle(W.mutedForeground)
                        hourPicker("night-end", s.nightEnd, disabled: !s.collapseNight, format: s.timeFormat) { h in save(["night_end": h]) { $0.nightEnd = h } }
                    }
                }
                SettingsRow(label: "Show events you've declined") {
                    WSwitch(on: Binding(get: { s.showDeclined }, set: { v in save(["show_declined": v]) { $0.showDeclined = v } }))
                }
                SettingsRow(label: "Timezone", last: true) {
                    WSelect(id: "cal-tz", options: zones(current: s.timezone), value: Binding(get: { s.timezone.isEmpty ? Self.device : s.timezone }, set: { v in
                        let tz = v == Self.device ? "" : v
                        save(["timezone": tz]) { $0.timezone = tz }
                    }), size: .sm, minWidth: 224, align: .end, maxHeight: 288)
                }
            } else {
                if let loadError { Text(loadError).font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 8) }
                else { VStack(spacing: 8) { SkeletonBlock(height: 32); SkeletonBlock(width: 376, height: 32).frame(maxWidth: .infinity, alignment: .leading) }.padding(.horizontal, 8) }
            }
        }
        .task {
            do { prefs = try await CalendarAPI.settings() }
            catch { loadError = friendly(error) }
        }
    }

    /// "Same as this device (…)" first, then every zone the system knows, underscores as
    /// spaces; a stored zone the system does not list still shows up, so it can be seen and changed.
    private func zones(current: String) -> [WSelectOption] {
        var all = TimeZone.knownTimeZoneIdentifiers
        if !current.isEmpty, !all.contains(current) { all.insert(current, at: 0) }
        return [WSelectOption(Self.device, "Same as this device (\(TimeZone.current.identifier))")] + all.map { WSelectOption($0, $0.replacingOccurrences(of: "_", with: " ")) }
    }

    private func hourPicker(_ id: String, _ hour: Int, disabled: Bool, format: String, onPick: @escaping (Int) -> Void) -> some View {
        WSelect(id: id, options: (0..<24).map { WSelectOption(String($0), hourLabel($0, format)) }, value: Binding(get: { String(hour) }, set: { onPick(Int($0) ?? 0) }), size: .sm, width: 96, align: .end, disabled: disabled)
    }

    private func hourLabel(_ h: Int, _ format: String) -> String {
        if format == "24" { return String(format: "%02d:00", h) }
        let suffix = h < 12 ? "AM" : "PM"
        return "\(h % 12 == 0 ? 12 : h % 12) \(suffix)"
    }

    /// Optimistic: the row shows the new value at once and reverts if the server says no.
    private func save(_ patch: [String: Any], _ mutate: (inout CalPrefs) -> Void) {
        guard var next = prefs else { return }
        let before = prefs
        mutate(&next)
        prefs = next
        Task {
            do { prefs = try await CalendarAPI.applySettings(patch); CalendarBus.shared.changed() }
            catch { prefs = before; Toasts.shared.error(friendly(error)) }
        }
    }
}

// MARK: - AI

/// `AiSettingsSection.tsx`: provider, key and model as a vertical form; the two behaviour
/// switches; then everything the assistant remembers.
struct AiSection: View {
    @State private var store = AiSettingsStore()
    @State private var preset = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var model = ""
    @State private var saving = false
    @State private var testing = false
    @State private var memory: [AiMemoryEntry] = []
    @Environment(PopLayerState.self) private var pops
    @Environment(DialogState.self) private var dialogs
    @Environment(UIState.self) private var ui

    private var chosen: AiPreset? { store.settings?.presets.first { $0.id == preset } ?? store.settings?.presets.first }
    /// The web's `dirty`: anything typed since the last save or load. Read against the stored
    /// settings so a reload never marks its own values as edits.
    private var dirty: Bool {
        guard let s = store.settings else { return false }
        return !key.isEmpty || preset != s.preset || model != s.model || (preset == "custom" && baseURL != s.baseURL)
    }

    var body: some View {
        if let s = store.settings {
            SettingsSection(title: "AI assistant", description: "Bring your own key. Mail is only sent to the provider when you use an AI feature.") {
                if !s.serverReady {
                    Text("SESSION_SECRET isn't set on the server, so keys can't be stored yet.")
                        .font(W.s13).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(W.muted60).rounded(W.radiusMd)
                        .padding(.horizontal, 8).padding(.bottom, 12)
                }
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel("Provider")
                            WSelect(id: "ai-preset", options: s.presets.map { WSelectOption($0.id, $0.label) }, value: Binding(get: { preset }, set: { choosePreset($0) }), fullWidth: true)
                            if let p = chosen, p.id != "custom" { FieldDesc("Endpoint: \(p.baseURL)") }
                        }
                        if preset == "custom" {
                            VStack(alignment: .leading, spacing: 8) {
                                FieldLabel("Base URL")
                                WTextField(placeholder: "http://localhost:11434/v1", text: $baseURL)
                                FieldDesc("Any OpenAI-compatible server: Ollama, LM Studio, Groq, Mistral, Together…")
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel("API key")
                            WTextField(placeholder: s.keyHint.isEmpty ? (chosen?.keyPlaceholder.isEmpty == false ? chosen!.keyPlaceholder : "API key") : "Stored · \(s.keyHint)", text: $key, secure: true)
                            HStack(spacing: 8) {
                                FieldDesc("Stored encrypted on your server and never shown again.")
                                if let u = chosen?.keyURL, let url = URL(string: u) {
                                    Button { NSWorkspace.shared.open(url) } label: { HStack(spacing: 4) { Text("Get a key").underline(); Icon("externalLink", size: 12) } }
                                        .buttonStyle(.plain).font(W.sm).foregroundStyle(W.mutedForeground)
                                }
                                if !s.keyHint.isEmpty {
                                    Button("Remove key") { removeKey() }.buttonStyle(.plain).underline().font(W.sm).foregroundStyle(W.mutedForeground)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            FieldLabel("Model")
                            modelField(chosen?.models ?? [])
                            FieldDesc("Type any model id the provider supports.")
                        }
                    }
                    HStack(spacing: 8) {
                        Button { save() } label: { HStack(spacing: 4) { if saving { Spinner(size: 14) } else { Icon("check", size: 14) }; Text("Save") } }
                            .buttonStyle(.web(.default, .sm)).disabled(saving || (!dirty && key.isEmpty))
                        Button { test() } label: { HStack(spacing: 4) { if testing { Spinner(size: 14) } else { Icon("sparkles", size: 14) }; Text("Test connection") } }
                            .buttonStyle(.web(.outline, .sm)).disabled(testing || !s.configured || dirty)
                        if s.configured && !dirty {
                            HStack(spacing: 0) {
                                Text("Ready · ")
                                Button("open the assistant") { ui.openAssistant() }.buttonStyle(.plain).underline()
                            }
                            .font(W.xs).foregroundStyle(W.mutedForeground)
                        }
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: 512, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsSection(title: "Behaviour") {
                SettingsRow(label: "Learn from my mail", hint: "Reads what you send to learn your tone, sign-offs and recurring facts. Runs in the background, at most twice a day.") {
                    WSwitch(on: Binding(get: { s.learn }, set: { v in toggle(["learn": v]) }))
                }
                SettingsRow(label: "Send mail without asking", hint: "Off: the assistant only prepares drafts and you press Send. On: it may send when you clearly ask it to.", last: true) {
                    WSwitch(on: Binding(get: { s.autoSend }, set: { v in toggle(["auto_send": v]) }))
                }
            }
            MemorySection(memory: $memory, lastLearned: s.lastLearnedAt, onLearned: { await store.load() })
            .onChange(of: s.preset) { _, _ in resync(s) }
            .onChange(of: s.model) { _, _ in resync(s) }
        } else if let error = store.error {
            Text(error).font(W.s13).foregroundStyle(W.mutedForeground)
        } else {
            // Loading lives on the container: this branch leaves the moment settings land,
            // which would cancel the memory fetch mid-flight.
            SkeletonRows(rows: 4)
        }
        Color.clear.frame(height: 0).task { await store.load(); if let s = store.settings { resync(s) }; await loadMemory() }
    }

    /// A free-text model id with the preset's known models a click away, the web's `datalist`.
    @ViewBuilder
    private func modelField(_ models: [String]) -> some View {
        ZStack(alignment: .trailing) {
            WTextField(placeholder: chosen?.defaultModel ?? "", text: $model)
            if !models.isEmpty {
                WButton(icon: "chevronDown", variant: .ghost, size: .iconXs, muted: true, help: "Suggestions") {
                    pops.toggle("ai-models", side: .bottom, align: .end) {
                        PopCard(width: 256) { ForEach(models, id: \.self) { m in MenuItem(m, checked: m == model) { model = m } } }
                    }
                }
                .popAnchor("ai-models")
                .padding(.trailing, 4)
            }
        }
    }

    /// The web's effect: while nothing is being edited, the form shows what the server holds.
    private func resync(_ s: AiSettings) {
        guard !dirty || preset.isEmpty else { return }
        preset = s.preset.isEmpty ? (s.presets.first?.id ?? "") : s.preset
        baseURL = preset == "custom" ? s.baseURL : ""
        model = s.model
    }

    private func choosePreset(_ id: String) {
        let p = store.settings?.presets.first { $0.id == id }
        preset = id
        model = p?.defaultModel ?? ""
        if id != "custom" { baseURL = "" }
    }

    private func loadMemory() async { memory = (try? await APIClient.shared.aiMemory()) ?? [] }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            var patch: [String: Any] = ["preset": preset, "model": model]
            if preset == "custom" { patch["base_url"] = baseURL }
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { patch["api_key"] = k }
            do { try await store.apply(patch); key = ""; if let s = store.settings { resync(s) }; Toasts.shared.show("AI settings saved") }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func removeKey() {
        Task {
            do { try await store.apply(["api_key": NSNull()]); Toasts.shared.show("Key removed") }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func test() {
        testing = true
        Task {
            defer { testing = false }
            do {
                let r = try await APIClient.shared.testAiSettings()
                if r.ok { Toasts.shared.show("Connected · \(r.model ?? "") said “\(r.reply ?? "")”") } else { Toasts.shared.error(r.error ?? "Failed") }
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }

    /// A refused switch snaps back: the settings are re-read either way, and the refusal is said.
    private func toggle(_ patch: [String: Any]) {
        Task {
            do { try await store.apply(patch) }
            catch { Toasts.shared.error(friendly(error)); await store.load() }
        }
    }
}

/// `MemorySection`: what the assistant knows, by kind, each line editable in place.
private struct MemorySection: View {
    @Binding var memory: [AiMemoryEntry]
    let lastLearned: Double?
    var onLearned: () async -> Void
    @State private var learning = false
    @State private var adding = ""
    @State private var addKind: AiMemoryKind = .preference
    @State private var addBusy = false
    @Environment(DialogState.self) private var dialogs

    private var description: String {
        "What the assistant knows about you. \(memory.count) \(memory.count == 1 ? "entry" : "entries")\(lastLearned.map { " · learned \(Fmt.relative($0))" } ?? "")."
    }

    var body: some View {
        SettingsSection(title: "Memory", description: description, actions: {
            HStack(spacing: 4) {
                Button { learn() } label: { HStack(spacing: 4) { SpinIcon(name: "refreshCw", spinning: learning); Text("Learn now") } }
                    .buttonStyle(.web(.ghost, .sm, muted: true)).disabled(learning)
                if !memory.isEmpty { WButton("Forget everything", icon: "trash2", variant: .ghost, size: .sm, muted: true) { forget() } }
            }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AiMemoryKind.allCases, id: \.self) { k in
                    let rows = memory.filter { $0.kind == k }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(k.label).font(W.font(12, 500)).foregroundStyle(W.mutedForeground).padding(.bottom, 4)
                            ForEach(rows) { e in
                                MemoryRow(entry: e, last: e.id == rows.last?.id, onUpdate: { updated in if let i = memory.firstIndex(where: { $0.id == updated.id }) { memory[i] = updated } }, onDelete: { memory.removeAll { $0.id == e.id } })
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
                if memory.isEmpty { Text("Nothing yet. Chat with the assistant, send some mail, or add a note below.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.bottom, 12) }
                HStack(spacing: 8) {
                    WSelect(id: "mem-kind", options: AiMemoryKind.allCases.map { WSelectOption($0.rawValue, $0.label) }, value: Binding(get: { addKind.rawValue }, set: { addKind = AiMemoryKind(rawValue: $0) ?? .preference }), width: 144)
                    WTextField(placeholder: "Add a note, e.g. “Sign replies with just Farhan”", text: $adding, onSubmit: { add() })
                    WButton("Add", icon: "plus", variant: .outline, size: .sm) { add() }.disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty || addBusy)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    private func learn() {
        learning = true
        Task {
            defer { learning = false }
            do {
                let r = try await APIClient.shared.aiLearnNow()
                Toasts.shared.show(r.skipped == "nothing_new" ? "Nothing new to learn from" : r.skipped == "no_key" ? "Add an API key first" : "Learned · \(r.changed) update\(r.changed == 1 ? "" : "s")")
                memory = (try? await APIClient.shared.aiMemory()) ?? memory
                await onLearned()
            } catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func forget() {
        dialogs.confirm(title: "Forget everything?", description: "Deletes every memory entry and the learning history. The assistant starts from scratch.", action: "Forget everything") {
            Task {
                do { try await APIClient.shared.clearAiMemory(); memory = []; Toasts.shared.show("Memory cleared"); await onLearned() }
                catch { Toasts.shared.error(friendly(error)) }
            }
        }
    }

    private func add() {
        let t = adding.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !addBusy else { return }
        addBusy = true
        Task {
            defer { addBusy = false }
            do { let e = try await APIClient.shared.addAiMemory(kind: addKind, content: t); memory.insert(e, at: 0); adding = "" }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }
}

/// One memory line: the text, who put it there, and — on hover — a pencil and a bin. Editing
/// swaps in an input; Enter or the tick saves, Escape or the cross puts it back.
private struct MemoryRow: View {
    let entry: AiMemoryEntry
    var last = false
    var onUpdate: (AiMemoryEntry) -> Void
    var onDelete: () -> Void
    @State private var hovering = false
    @State private var editing: String?

    private var sourceLabel: String { entry.source == "learned" ? "learned" : entry.source == "assistant" ? "assistant" : "you" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let draft = editing {
                WTextField(placeholder: "", text: Binding(get: { draft }, set: { editing = $0 }), onSubmit: { commit() }, autofocus: true)
                    .onExitCommand { editing = nil }
                WButton(icon: "check", variant: .ghost, size: .iconXs, help: "Save") { commit() }
                WButton(icon: "x", variant: .ghost, size: .iconXs, help: "Cancel") { editing = nil }
            } else {
                Text(entry.content).font(W.s13).webLine(13, 20).foregroundStyle(W.foreground).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text(sourceLabel).font(W.font(11)).foregroundStyle(W.mutedForeground).padding(.top, 2)
                HStack(spacing: 0) {
                    WButton(icon: "pencil", variant: .ghost, size: .iconXs, muted: true, help: "Edit") { editing = entry.content }
                    WButton(icon: "trash2", variant: .ghost, size: .iconXs, muted: true, help: "Delete") { delete() }
                }
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.vertical, 8)
        .edgeLine(.bottom, last ? Color.clear : W.border)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func commit() {
        guard let draft = editing else { return }
        editing = nil
        Task {
            do { onUpdate(try await APIClient.shared.updateAiMemory(entry.id, content: draft)) }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }

    private func delete() {
        Task {
            do { try await APIClient.shared.deleteAiMemory(entry.id); onDelete() }
            catch { Toasts.shared.error(friendly(error)) }
        }
    }
}

// MARK: - Security

struct SecuritySection: View {
    @Environment(DialogState.self) private var dialogs
    @State private var current = ""
    @State private var next = ""
    @State private var busy = false
    @State private var status: TwoFactorStatus?

    /// The form's submit rule: both fields filled, the new one long enough, nothing in flight.
    private var canChange: Bool { !current.isEmpty && next.count >= 8 && !busy }

    var body: some View {
        SettingsSection(title: "Password", description: "Use at least 8 characters. Sessions on other devices stay signed in.") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) { FieldLabel("Current password"); WTextField(placeholder: "", text: $current, secure: true, onSubmit: { if canChange { change() } }) }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("New password"); WTextField(placeholder: "", text: $next, secure: true, onSubmit: { if canChange { change() } })
                    if !next.isEmpty && next.count < 8 { Text("\(8 - next.count) more character\(8 - next.count == 1 ? "" : "s")").font(W.xs).foregroundStyle(W.mutedForeground) }
                }
                WButton("Change password", icon: "keyRound", size: .sm) { change() }.disabled(!canChange)
            }
            .frame(maxWidth: 384).padding(.horizontal, 8)
        }
        SettingsSection(title: "Two-factor authentication", description: "A second step at login using an authenticator app (Google Authenticator, 1Password, Authy…). Nothing leaves this server.") {
            let enabled = status?.enabled ?? false
            let left = status?.recoveryLeft ?? 0
            HStack(spacing: 12) {
                Icon("shieldCheck", size: 16).foregroundStyle(enabled ? W.primaryForeground : W.mutedForeground).frame(width: 32, height: 32).background(enabled ? W.foreground : W.muted).rounded(W.radiusMd)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status == nil ? "…" : enabled ? "On" : "Off").font(W.font(14, 500))
                    Text(enabled ? "\(left) recovery code\(left == 1 ? "" : "s") left" : "Protect your login with a one-time code.").font(W.xs).foregroundStyle(W.mutedForeground)
                }
                Spacer()
                if enabled {
                    WButton("Regenerate recovery codes", variant: .outline, size: .sm) { regenerate() }
                    WButton("Turn off", variant: .ghost, size: .sm, muted: true) { disable() }
                } else {
                    WButton("Turn on", size: .sm) { enable() }.disabled(status == nil)
                }
            }
            .padding(.horizontal, 8)
        }
        .task { await reloadStatus() }
    }

    private func reloadStatus() async { status = try? await APIClient.shared.twoFactorStatus() }

    private func change() {
        busy = true
        Task { defer { busy = false }; do { try await APIClient.shared.changePassword(current: current, next: next); Toasts.shared.show("Password changed"); current = ""; next = "" } catch { Toasts.shared.error(friendly(error)) } }
    }

    /// The QR step can be clicked away; the recovery codes cannot, so they get a dialog of their
    /// own that only "I've saved these" closes.
    private func enable() {
        dialogs.present("tfa-enable", width: 448) {
            TwoFactorEnableForm(onCodes: { codes in
                dialogs.dismiss("tfa-enable")
                Task { await reloadStatus() }
                dialogs.present("tfa-codes", width: 448, dismissible: false) {
                    FormDialog(title: "Save your recovery codes", description: "Each code works once if you lose your authenticator. Keep them somewhere safe — they won't be shown again.") {
                        RecoveryCodesView(codes: codes)
                    } footer: {
                        WButton("I've saved these") { dialogs.dismiss("tfa-codes"); Task { await reloadStatus() } }
                    }
                }
            }, onCancel: { dialogs.dismiss("tfa-enable") })
        }
    }
    private func regenerate() {
        dialogs.present("tfa-regen", width: 448) { TwoFactorCodeForm(title: "Regenerate recovery codes", description: "Enter a code from your authenticator to confirm. Your old codes stop working.", action: "Regenerate", run: { code in try await APIClient.shared.twoFactorRegenerate(code: code) }, onDone: { dialogs.dismiss("tfa-regen"); Task { await reloadStatus() } }, onCancel: { dialogs.dismiss("tfa-regen") }) }
    }
    private func disable() {
        dialogs.present("tfa-disable", width: 448) { TwoFactorDisableForm(onDone: { dialogs.dismiss("tfa-disable"); Task { await reloadStatus() } }, onCancel: { dialogs.dismiss("tfa-disable") }) }
    }
}

struct RecoveryCodesView: View {
    let codes: [String]
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) { ForEach(codes, id: \.self) { Text($0).font(W.mono(13)).monospacedDigit() } }
                .padding(.horizontal, 16).padding(.vertical, 12).background(W.muted).rounded(W.radiusMd)
            WButton(copied ? "Copied" : "Copy all", icon: copied ? "check" : "copy", variant: .ghost, size: .sm, muted: true) {
                Platform.copy(codes.joined(separator: "\n"))
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
        }
    }
}

/// `tracking-[0.3em]` on the one-time-code inputs.
private let codeTracking: CGFloat = 0.3 * 14

private struct TwoFactorEnableForm: View {
    var onCodes: ([String]) -> Void
    var onCancel: () -> Void
    @State private var setup: TwoFactorSetup?
    @State private var code = ""
    @State private var busy = false
    @State private var copied = false

    var body: some View {
        FormDialog(title: "Set up your authenticator", description: "Scan the code with your authenticator app, then enter the 6-digit code it shows.") {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Spacer(); if let s = setup, let img = QRCodeImage.make(s.otpauthURL) { Image(nsImage: img).interpolation(.none).resizable().frame(width: 192, height: 192).padding(4).background(Color.white).rounded(W.radiusMd) } else { SkeletonBlock(width: 192, height: 192) }; Spacer() }
                Text("Can't scan? Enter this key manually:").font(W.xs).foregroundStyle(W.mutedForeground)
                HStack(spacing: 8) {
                    Text(setup.map { $0.secret.chunked(4).joined(separator: " ") } ?? "…").font(W.mono(12)).tracking(1).lineLimit(1).padding(.horizontal, 10).frame(height: 32).frame(maxWidth: .infinity, alignment: .leading).background(W.muted).rounded(W.radiusMd)
                    WButton(icon: copied ? "check" : "copy", variant: .ghost, size: .iconSm, help: "Copy key") {
                        if let s = setup { Platform.copy(s.secret); copied = true; Task { try? await Task.sleep(for: .seconds(1.5)); copied = false } }
                    }
                    .disabled(setup == nil)
                }
                VStack(alignment: .leading, spacing: 6) { FieldLabel("6-digit code"); WTextField(placeholder: "123456", text: $code, mono: true, onSubmit: { verify() }, autofocus: true).tracking(codeTracking) }
            }
        } footer: {
            WButton("Cancel", variant: .ghost, action: onCancel)
            WButton("Verify & turn on") { verify() }.disabled(setup == nil || code.filter { !$0.isWhitespace }.count != 6 || busy)
        }
        .task { do { setup = try await APIClient.shared.twoFactorSetup() } catch { Toasts.shared.error(friendly(error)); onCancel() } }
    }

    private func verify() {
        busy = true
        Task {
            defer { busy = false }
            do { let codes = try await APIClient.shared.twoFactorEnable(code: code); Toasts.shared.show("Two-factor authentication is on"); onCodes(codes) }
            catch { Toasts.shared.error(isInvalidCode(error) ? "That code isn't right. Try the next one." : friendly(error)) }
        }
    }
}

/// The worker's `invalid_code`, which the web matches as "invalid code" in the message.
private func isInvalidCode(_ error: Error) -> Bool {
    if let e = error as? APIError, case .server(let code, _) = e { return code == "invalid_code" }
    return false
}

private struct TwoFactorCodeForm: View {
    let title: String
    let description: String
    let action: String
    var run: (String) async throws -> [String]
    var onDone: () -> Void
    var onCancel: () -> Void
    @State private var code = ""
    @State private var codes: [String]?
    @State private var busy = false
    var body: some View {
        FormDialog(title: codes != nil ? "Your new recovery codes" : title, description: codes != nil ? "The old codes no longer work." : description) {
            if let codes { RecoveryCodesView(codes: codes) } else { VStack(alignment: .leading, spacing: 6) { FieldLabel("Authenticator code"); WTextField(placeholder: "123456", text: $code, mono: true, autofocus: true).tracking(codeTracking) } }
        } footer: {
            if codes != nil { WButton("I've saved these", action: onDone) } else {
                WButton("Cancel", variant: .ghost, action: onCancel)
                WButton(action) { busy = true; Task { defer { busy = false }; do { codes = try await run(code) } catch { Toasts.shared.error(isInvalidCode(error) ? "That code isn't right." : friendly(error)) } } }.disabled(code.filter { !$0.isWhitespace }.count != 6 || busy)
            }
        }
    }
}

private struct TwoFactorDisableForm: View {
    var onDone: () -> Void
    var onCancel: () -> Void
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    var body: some View {
        FormDialog(title: "Turn off two-factor authentication", description: "Confirm with your password and a code from your authenticator (or a recovery code).") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) { FieldLabel("Password"); WTextField(placeholder: "", text: $password, secure: true, autofocus: true) }
                VStack(alignment: .leading, spacing: 6) { FieldLabel("Authenticator or recovery code"); WTextField(placeholder: "123456 or xxxx-xxxx", text: $code, mono: true) }
            }
        } footer: {
            WButton("Cancel", variant: .ghost, action: onCancel)
            WButton("Turn off", variant: .outline) { busy = true; Task { defer { busy = false }; do { try await APIClient.shared.twoFactorDisable(password: password, code: code); Toasts.shared.show("Two-factor authentication is off"); onDone() } catch { Toasts.shared.error(friendly(error)) } } }.disabled(password.isEmpty || code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
    }
}

enum QRCodeImage {
    static func make(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = []; var s = Substring(self)
        while !s.isEmpty { out.append(String(s.prefix(n))); s = s.dropFirst(n) }
        return out
    }
}
