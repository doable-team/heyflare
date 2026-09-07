import SwiftUI
import AppKit
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
            HStack(spacing: 0) {
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

struct SettingsRow<Content: View>: View {
    let label: String
    var hint: String? = nil
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
        .edgeLine(.bottom)
    }
}

struct SavedMark: View {
    let show: Bool
    var body: some View { HStack(spacing: 4) { Icon("check", size: 12); Text("Saved") }.font(W.xs).foregroundStyle(W.mutedForeground).opacity(show ? 1 : 0) }
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
                SettingsRow(label: "Name") {
                    HStack(spacing: 8) {
                        WTextField(placeholder: "", text: $name, onSubmit: { save(user) }).frame(width: 224)
                        SavedMark(show: saved)
                    }
                }
                SettingsRow(label: "Email", hint: "Used to log in. Can't be changed here.") {
                    Text(user.email).font(W.sm).foregroundStyle(W.mutedForeground).padding(.horizontal, 10).frame(width: 224, height: 32, alignment: .leading).background(W.input.opacity(0.5)).rounded(W.radiusMd)
                }
            }
            .onAppear { name = user.name }
        }
    }

    private func save(_ user: User) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n != user.name else { return }
        Task {
            do { let u = try await APIClient.shared.updateMe(name: n); await app.adopt(user: u); saved = true; try? await Task.sleep(for: .seconds(2)); saved = false }
            catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
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
            SettingsRow(label: "Show previews in lists", hint: "The first line of each message next to the subject.") {
                WSwitch(on: Binding(get: { settings.showPreviews != false }, set: { patch(["showPreviews": $0]) }))
            }
        }
        SettingsSection(title: "Mail", actions: { SavedMark(show: saved) }) {
            SettingsRow(label: "Default place for new senders", hint: "Pre-selected when you say yes in the Screener.") {
                WToggleGroup(options: [ToggleOption(id: "imbox", label: "Imbox", icon: "inbox"), ToggleOption(id: "feed", label: "The Feed", icon: "rss"), ToggleOption(id: "paper_trail", label: "Paper Trail", icon: "fileText")], value: Binding(get: { settings.defaultScreenTarget ?? "imbox" }, set: { patch(["defaultScreenTarget": $0]) }))
            }
            SettingsRow(label: "Undo send window", hint: "Seconds to change your mind after hitting Send. 0 turns it off.") {
                HStack(spacing: 8) {
                    WTextField(placeholder: "10", text: $undo, onSubmit: { saveUndo() }).frame(width: 80).multilineTextAlignment(.trailing)
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
            } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
}

// MARK: - Accounts

struct AccountsSection: View {
    @Environment(AppState.self) private var app
    @Environment(Router.self) private var router
    @Environment(Toasts.self) private var toasts

    var body: some View {
        let gmail = app.accounts.filter { !$0.isDomain }
        let boxes = app.accounts.filter(\.isDomain)
        SettingsSection(title: "Gmail accounts", description: "What's connected, and how it signs off.", actions: {
            WButton("Connect Gmail", icon: "plus", variant: .ghost, size: .sm, muted: true) { GoogleConnect.start(toasts: toasts) }
        }) {
            if gmail.isEmpty { Text("No Gmail connected yet.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 8) }
            ForEach(gmail) { AccountBlock(account: $0) }
        }
        SettingsSection(title: "Domain mailboxes", description: "Addresses on your own domains.", actions: {
            WButton("New mailbox", icon: "plus", variant: .ghost, size: .sm, muted: true) { router.replace(.settings("domains")) }
        }) {
            if boxes.isEmpty { Text("No mailboxes yet. Add a domain first.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 8) }
            ForEach(boxes) { AccountBlock(account: $0) }
        }
    }
}

struct AccountBlock: View {
    let account: Account
    @Environment(AppState.self) private var app
    @Environment(DialogState.self) private var dialogs
    @Environment(Toasts.self) private var toasts
    @State private var open = false
    @State private var displayName = ""
    @State private var signature = ""
    @State private var saved = false
    @State private var syncing = false

    private var status: (label: String, spin: Bool) {
        if account.isDomain { return ("Mailbox · receives via Cloudflare", false) }
        if account.syncStatus == "disconnected" { return ("Disconnected", false) }
        if account.syncStatus == "error" { return ("Sync error", false) }
        if !account.initialSyncDone { return ("Connecting", true) }
        if account.syncStatus == "syncing" { return ("Syncing", true) }
        return ("Synced", false)
    }
    private var dirty: Bool { signature != account.signature || displayName != account.displayName }
    private var isGmail: Bool { account.provider == "gmail" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WAvatar(email: account.email, name: account.displayName, src: account.avatarURL, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        if app.accounts.count > 1 { AccountGlyph(glyph: app.glyph(for: account.id)) }
                        Text(account.email).font(W.font(14, 500)).lineLimit(1)
                        WBadge(isGmail ? "Gmail" : "Mailbox", variant: .outline, muted: true)
                    }
                    HStack(spacing: 6) {
                        if status.spin { Spinner(size: 11) }
                        Text(status.label)
                        if isGmail, let at = account.lastSyncedAt { Text("· \(Fmt.relative(at))") }
                        if let e = account.syncError, !e.isEmpty { Text("· \(e)") }
                        if account.syncStatus == "disconnected" { Button("Reconnect") { GoogleConnect.start(toasts: toasts, loginHint: account.email) }.buttonStyle(.plain).underline() }
                    }
                    .font(W.xs).monospacedDigit().foregroundStyle(W.mutedForeground)
                }
                Spacer()
                if isGmail {
                    WButton("Sync", icon: "refreshCw", variant: .ghost, size: .sm, muted: true) {
                        syncing = true
                        Task { defer { syncing = false }; do { let n = try await APIClient.shared.syncNow(accountID: account.id); toasts.show("Synced\(n.map { " · \($0) new" } ?? "")"); Mail.invalidate() } catch { toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription) } }
                    }
                    .disabled(syncing)
                }
                WButton("Edit", trailingIcon: "chevronDown", variant: .ghost, size: .sm, muted: true) { open.toggle() }
            }
            .padding(.horizontal, 8).frame(height: 48)
            if open {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) { FieldLabel("Display name"); WTextField(placeholder: "Shown as the sender name", text: $displayName).frame(maxWidth: 384) }
                    VStack(alignment: .leading, spacing: 6) { FieldLabel("Signature"); WTextArea(placeholder: "HTML allowed. Added under new messages.", text: $signature, minHeight: 72, fontSize: 12, mono: true) }
                    HStack(spacing: 8) {
                        WButton("Save", size: .sm) { save() }.disabled(!dirty)
                        SavedMark(show: saved && !dirty)
                        Spacer()
                        if isGmail {
                            WButton("Start fresh", icon: "refreshCw", variant: .ghost, size: .sm, muted: true) {
                                dialogs.confirm(title: "Start fresh with \(account.email)?", description: "This deletes everything heyflare has synced for this account — threads, contacts, screener decisions, clips, drafts. Gmail itself is untouched. New mail from now on will go through the Screener.", action: "Start fresh") {
                                    Task { do { let e = try await APIClient.shared.resetAccount(account.id); if let e { toasts.error("Reset done, but the first sync failed: \(e)") } else { toasts.show("Starting fresh — watching for new mail from now on") }; await app.refreshAccounts(); Mail.invalidate() } catch { toasts.error(error.localizedDescription) } }
                                }
                            }
                        }
                        WButton(isGmail ? "Disconnect" : "Delete mailbox", icon: isGmail ? "unplug" : "trash2", variant: .ghost, size: .sm, muted: true) {
                            dialogs.confirm(title: isGmail ? "Disconnect \(account.email)?" : "Delete \(account.email)?", description: isGmail ? "This removes the account and all of its synced mail from heyflare. Nothing changes in Gmail." : "This deletes the mailbox and every message stored in it. Mail sent to this address will bounce (or land in the domain's catch-all).", action: isGmail ? "Disconnect" : "Delete mailbox") {
                                Task { do { try await APIClient.shared.deleteAccount(account.id); await app.refreshAccounts(); Mail.invalidate() } catch { toasts.error(error.localizedDescription) } }
                            }
                        }
                    }
                }
                .padding(.leading, 44).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 16)
            }
        }
        .edgeLine(.bottom)
        .onAppear { displayName = account.displayName; signature = account.signature }
    }

    private func save() {
        Task {
            do { _ = try await APIClient.shared.updateAccount(account.id, displayName: displayName, signature: signature); await app.refreshAccounts(); saved = true; try? await Task.sleep(for: .seconds(2)); saved = false }
            catch { toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
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
                Text("No domains yet. Add one that lives on your Cloudflare account, then create mailboxes like you@yourdomain.com.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 8)
            }
            ForEach(domains) { d in DomainBlock(domain: d, reload: load) }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { domains = try await APIClient.shared.domains(); error = nil } catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
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
    /// The worker answers 409 `mx_in_use` when the domain's mail goes elsewhere; then the
    /// takeover has to be spelled out and ticked, as on the web.
    @State private var mxInUse = false
    @State private var confirm = false
    var body: some View {
        FormDialog(title: "Add a domain", description: "The domain must be on your Cloudflare account with Cloudflare nameservers.") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Domain")
                    WTextField(placeholder: "example.com", text: $name, onSubmit: { submit() }, autofocus: true)
                        .onChange(of: name) { _, _ in mxInUse = false; confirm = false }
                    if let error { Text(error).font(W.xs) }
                }
                if mxInUse {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Icon("triangleAlert", size: 16).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("This will take over ALL mail for \(name.trimmingCharacters(in: .whitespaces).lowercased()).").font(W.font(14, 500))
                                Text("It currently goes to another provider. Enabling Cloudflare Email Routing replaces those MX records, so mail stops arriving there.").font(W.s13).foregroundStyle(W.mutedForeground)
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
            WButton(mxInUse ? "Take over domain" : "Add domain") { submit() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy || (mxInUse && !confirm))
        }
    }
    private func submit() {
        guard !(mxInUse && !confirm) else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                var body: [String: Any] = ["name": name.trimmingCharacters(in: .whitespaces).lowercased()]
                if mxInUse { body["confirm"] = true }
                let d = try await APIClient.shared.post("/api/domains", body: body, as: MailDomain.self, scoped: false)
                Toasts.shared.show(d.status == "active" ? "\(d.name) is receiving mail" : "\(d.name) added — finish the setup steps")
                onDone()
            } catch let e as APIError {
                if case .server(let code, _) = e, code == "mx_in_use" { mxInUse = true; confirm = false; error = nil }
                else { self.error = e.errorDescription }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DomainBlock: View {
    let domain: MailDomain
    var reload: () async -> Void
    @Environment(DialogState.self) private var dialogs
    @Environment(AppState.self) private var app
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
                WButton("Verify", icon: "refreshCw", variant: .ghost, size: .sm, muted: true) {
                    verifying = true
                    Task { defer { verifying = false }; do { let r = try await APIClient.shared.verifyDomain(domain.id); Toasts.shared.show(r.status == "active" ? "\(domain.name) is receiving mail" : "\(domain.name): \(r.error ?? "still pending")"); await reload() } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) } }
                }
                .disabled(verifying)
                WButton("Details", trailingIcon: "chevronDown", variant: .ghost, size: .sm, muted: true) { open.toggle() }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            if open {
                VStack(alignment: .leading, spacing: 20) {
                    if domain.routing != "enabled", !domain.instructions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Set up receiving").font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
                            ForEach(Array(domain.instructions.filter { !$0.hasPrefix("Outbound") }.enumerated()), id: \.offset) { i, s in
                                HStack(alignment: .top, spacing: 8) { Text("\(i + 1).").monospacedDigit(); Text(s) }.font(W.s13).foregroundStyle(W.foreground90)
                            }
                        }
                    }
                    if domain.routing != "enabled", !domain.dns.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DNS records Cloudflare adds when Email Routing is enabled").font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
                            VStack(spacing: 0) {
                                ForEach(Array(domain.dns.enumerated()), id: \.offset) { _, r in
                                    HStack(spacing: 12) {
                                        Text(r.type).frame(width: 56, alignment: .leading)
                                        Text(r.name).lineLimit(1).frame(width: 160, alignment: .leading)
                                        Text(r.content).lineLimit(1).help(r.content)
                                        Spacer()
                                        Text(r.priority.map { "\($0)" } ?? "").frame(width: 40)
                                        WButton(icon: "copy", variant: .ghost, size: .iconXs, muted: true, help: "Copy") { Platform.copy(r.content) }
                                    }
                                    .font(W.mono(12)).padding(.horizontal, 8).frame(height: 28)
                                }
                            }
                            .padding(.vertical, 4).background(W.muted40).rounded(W.radiusMd)
                        }
                    }
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
                    Text(domain.sending == "cloudflare" ? "Outbound mail from these mailboxes goes through Cloudflare Email Sending." : domain.sending == "resend" ? "Outbound mail from these mailboxes goes through Resend. Make sure \(domain.name) is verified there." : "Outbound isn't configured yet, so these mailboxes can receive but not send. Enable Cloudflare Email Sending (Workers Paid) and add the send_email binding, or set a RESEND_API_KEY secret — see README → Custom domain mailboxes.")
                        .font(W.s13).foregroundStyle(W.mutedForeground)
                    HStack { Spacer(); WButton("Remove domain", icon: "trash2", variant: .ghost, size: .sm, muted: true) {
                        dialogs.confirm(title: "Remove \(domain.name)?", description: "Deletes every mailbox on it and all of their mail from heyflare. Email Routing on Cloudflare is left as it is.", action: "Remove domain") {
                            Task { try? await APIClient.shared.delete("/api/domains/\(domain.id)", scoped: false); await reload(); await app.refreshAccounts() }
                        }
                    } }
                }
                .padding(.leading, 36).padding(.trailing, 8).padding(.bottom, 20)
            }
        }
        .edgeLine(.bottom)
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
    @State private var busy = false
    var body: some View {
        FormDialog(title: "New mailbox on \(domain.name)", description: "Mail to this address lands in your unified Imbox like any other account.") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Address")
                    HStack(spacing: 0) {
                        WTextFieldPlain(placeholder: "hello", text: $local, autofocus: true).padding(.leading, 10)
                        Text("@\(domain.name)").font(W.sm).foregroundStyle(W.mutedForeground).padding(.trailing, 10)
                    }
                    .frame(height: 32).background(W.input).rounded(W.radiusMd)
                    Text("Letters, numbers, dots, dashes, plus or underscores.").font(W.xs).foregroundStyle(W.mutedForeground)
                }
                VStack(alignment: .leading, spacing: 6) { FieldLabel("Display name"); WTextField(placeholder: "Farhan", text: $name) }
            }
        } footer: {
            WButton("Cancel", variant: .ghost, action: onCancel)
            WButton("Create mailbox") {
                busy = true
                Task { defer { busy = false }; do { let a = try await APIClient.shared.createMailbox(domainID: domain.id, localPart: local.trimmingCharacters(in: .whitespaces).lowercased(), displayName: name.trimmingCharacters(in: .whitespaces)); Toasts.shared.show("\(a.email) is ready"); onDone() } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) } }
            }
            .disabled(local.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
    }
}

// MARK: - Calendar

struct CalendarSettingsSection: View {
    @State private var sources: [CalSource] = []
    @State private var syncing = false
    var body: some View {
        SettingsSection(title: "Calendars", description: "What's shown on the calendar, and where it comes from.", actions: {
            WButton("Sync all", icon: "refreshCw", variant: .ghost, size: .sm, muted: true) { syncing = true; Task { defer { syncing = false }; try? await CalendarAPI.syncSources(); sources = (try? await CalendarAPI.sources()) ?? sources; CalendarBus.shared.changed() } }.disabled(syncing)
        }) {
            if sources.isEmpty { Text("No calendars yet.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 8) }
            ForEach(sources) { s in
                SettingsRow(label: s.name, hint: s.source) {
                    HStack(spacing: 8) {
                        if s.isDefault { WBadge("Default", variant: .secondary, muted: true) }
                        if !s.writable { WBadge("Read only", variant: .outline, muted: true) }
                    }
                }
            }
            Text("Subscriptions and colours are managed on the web for now.").font(W.xs).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.top, 12)
        }
        .task { sources = (try? await CalendarAPI.sources()) ?? [] }
    }
}

// MARK: - AI

struct AiSection: View {
    @State private var store = AiSettingsStore()
    @State private var preset = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var model = ""
    @State private var testing = false
    @State private var result: String?
    @State private var memory: [AiMemoryEntry] = []
    @State private var memoryKind: AiMemoryKind = .fact
    @State private var memoryDraft = ""
    @Environment(PopLayerState.self) private var pops
    @Environment(DialogState.self) private var dialogs

    private var chosen: AiPreset? { store.settings?.presets.first { $0.id == preset } }

    var body: some View {
        if let s = store.settings {
            SettingsSection(title: "Assistant", description: "Bring your own key. It is stored on your server, never on this Mac.") {
                SettingsRow(label: "Provider") {
                    Button {
                        pops.toggle("ai-preset", side: .bottom, align: .end) {
                            PopCard(width: 224) { ForEach(s.presets) { p in MenuItem(p.label, checked: p.id == preset) { preset = p.id; baseURL = p.baseURL; if !p.models.contains(model) { model = p.defaultModel } } } }
                        }
                    } label: { HStack(spacing: 6) { Text(chosen?.label ?? preset).font(W.sm); Icon("chevronDown", size: 14).foregroundStyle(W.mutedForeground) }.padding(.horizontal, 10).frame(height: 32).background(W.input).rounded(W.radiusMd).contentShape(Rectangle()) }
                    .buttonStyle(.plain).popAnchor("ai-preset")
                }
                SettingsRow(label: "Base URL") { WTextField(placeholder: "https://", text: $baseURL).frame(width: 320) }
                SettingsRow(label: "API key", hint: s.keyHint.isEmpty ? nil : "Ends in \(s.keyHint). Paste a new one to replace it.") { WTextField(placeholder: chosen?.keyPlaceholder ?? "sk-…", text: $key, secure: true).frame(width: 320) }
                SettingsRow(label: "Model") {
                    if let models = chosen?.models, !models.isEmpty {
                        Button {
                            pops.toggle("ai-model", side: .bottom, align: .end) { PopCard(width: 256) { ForEach(models, id: \.self) { m in MenuItem(m, checked: m == model) { model = m } } } }
                        } label: { HStack(spacing: 6) { Text(model).font(W.sm); Icon("chevronDown", size: 14).foregroundStyle(W.mutedForeground) }.padding(.horizontal, 10).frame(height: 32).background(W.input).rounded(W.radiusMd).contentShape(Rectangle()) }
                        .buttonStyle(.plain).popAnchor("ai-model")
                    } else { WTextField(placeholder: "model", text: $model).frame(width: 320) }
                }
                HStack(spacing: 8) {
                    if let result { Text(result).font(W.s13).foregroundStyle(W.mutedForeground).lineLimit(2) }
                    Spacer()
                    WButton(testing ? "Testing…" : "Test", variant: .outline, size: .sm) { test() }.disabled(testing || !s.configured)
                    WButton("Save", size: .sm) { save() }
                }
                .padding(.horizontal, 8).padding(.top, 12)
                if !s.serverReady { Text("The server has no AI secret configured; keys cannot be stored until it does.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.top, 8) }
            }
            SettingsSection(title: "Behaviour") {
                SettingsRow(label: "Learn my writing style from sent mail", hint: s.lastLearnedAt.map { "Last learned \(Fmt.relative($0))" }) {
                    HStack(spacing: 8) {
                        WButton("Learn now", variant: .ghost, size: .sm, muted: true) { Task { do { let n = try await APIClient.shared.aiLearnNow(); Toasts.shared.show(n == 0 ? "Nothing new to learn" : "Learned \(n) thing\(n == 1 ? "" : "s")"); await store.load(); await loadMemory() } catch { Toasts.shared.error(error.localizedDescription) } } }
                        WSwitch(on: Binding(get: { s.learn }, set: { v in Task { try? await store.apply(["learn": v]) } }))
                    }
                }
                SettingsRow(label: "Let the assistant send mail without asking") { WSwitch(on: Binding(get: { s.autoSend }, set: { v in Task { try? await store.apply(["auto_send": v]) } })) }
            }
            SettingsSection(title: "Memory", description: "What the assistant knows about you and how you write.", actions: {
                WButton("Forget everything", variant: .ghost, size: .sm, muted: true) { dialogs.confirm(title: "Forget everything the assistant learned?", action: "Forget") { Task { try? await APIClient.shared.clearAiMemory(); memory = [] } } }.disabled(memory.isEmpty)
            }) {
                ForEach(AiMemoryKind.allCases, id: \.self) { k in
                    let rows = memory.filter { $0.kind == k }
                    if !rows.isEmpty {
                        Text(k.label).font(W.font(12, 500)).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).frame(height: 32)
                        ForEach(rows) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Text(e.content).font(W.s13).textSelection(.enabled)
                                Spacer()
                                WButton(icon: "x", variant: .ghost, size: .iconXs, muted: true) { Task { try? await APIClient.shared.deleteAiMemory(e.id); memory.removeAll { $0.id == e.id } } }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6).edgeLine(.bottom)
                        }
                    }
                }
                if memory.isEmpty { Text("Nothing remembered yet. Turn on learning, or add something below.").font(W.s13).foregroundStyle(W.mutedForeground).padding(.horizontal, 8).padding(.vertical, 8) }
                HStack(spacing: 8) {
                    Button { pops.toggle("mem-kind", side: .bottom, align: .start) { PopCard(width: 176) { ForEach(AiMemoryKind.allCases, id: \.self) { k in MenuItem(k.label, checked: k == memoryKind) { memoryKind = k } } } } } label: { HStack(spacing: 6) { Text(memoryKind.label).font(W.sm); Icon("chevronDown", size: 14).foregroundStyle(W.mutedForeground) }.padding(.horizontal, 10).frame(height: 32).background(W.input).rounded(W.radiusMd).contentShape(Rectangle()) }.buttonStyle(.plain).popAnchor("mem-kind")
                    WTextField(placeholder: "Something the assistant should know", text: $memoryDraft, onSubmit: { addMemory() })
                    WButton("Add", size: .sm) { addMemory() }.disabled(memoryDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 8).padding(.top, 12)
            }
            .onAppear { seed(s) }
        } else if let error = store.error {
            Text(error).font(W.s13).foregroundStyle(W.mutedForeground)
        } else {
            // Loading lives on the container: this branch leaves the moment settings land,
            // which would cancel the memory fetch mid-flight.
            SkeletonRows(rows: 4)
        }
        Color.clear.frame(height: 0).task { await store.load(); if let s = store.settings { seed(s) }; await loadMemory() }
    }

    private func seed(_ s: AiSettings) {
        if preset.isEmpty {
            preset = s.preset.isEmpty ? (s.presets.first?.id ?? "") : s.preset
            baseURL = s.baseURL.isEmpty ? (chosen?.baseURL ?? "") : s.baseURL
            model = s.model.isEmpty ? (chosen?.defaultModel ?? "") : s.model
        }
    }
    private func loadMemory() async { memory = (try? await APIClient.shared.aiMemory()) ?? [] }
    private func save() {
        Task {
            var patch: [String: Any] = ["preset": preset, "base_url": baseURL, "model": model]
            if !key.isEmpty { patch["api_key"] = key }
            do { try await store.apply(patch); key = ""; Toasts.shared.success("AI settings saved") } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) }
        }
    }
    private func test() {
        testing = true
        Task { defer { testing = false }; do { let r = try await APIClient.shared.testAiSettings(); result = r.ok ? "OK — \(r.model ?? "") replied: \(r.reply ?? "")" : (r.error ?? "The provider did not answer.") } catch { result = (error as? APIError)?.errorDescription ?? error.localizedDescription } }
    }
    private func addMemory() {
        let t = memoryDraft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        Task { do { let e = try await APIClient.shared.addAiMemory(kind: memoryKind, content: t); memory.insert(e, at: 0); memoryDraft = "" } catch { Toasts.shared.error(error.localizedDescription) } }
    }
}

// MARK: - Security

struct SecuritySection: View {
    @Environment(DialogState.self) private var dialogs
    @State private var current = ""
    @State private var next = ""
    @State private var busy = false
    @State private var status: TwoFactorStatus?

    var body: some View {
        SettingsSection(title: "Password", description: "Use at least 8 characters. Sessions on other devices stay signed in.") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) { FieldLabel("Current password"); WTextField(placeholder: "", text: $current, secure: true) }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("New password"); WTextField(placeholder: "", text: $next, secure: true, onSubmit: { change() })
                    if !next.isEmpty && next.count < 8 { Text("\(8 - next.count) more character\(8 - next.count == 1 ? "" : "s")").font(W.xs).foregroundStyle(W.mutedForeground) }
                }
                WButton("Change password", icon: "keyRound", size: .sm) { change() }.disabled(current.isEmpty || next.count < 8 || busy)
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
        .task { status = try? await APIClient.shared.twoFactorStatus() }
    }

    private func change() {
        busy = true
        Task { defer { busy = false }; do { try await APIClient.shared.changePassword(current: current, next: next); Toasts.shared.show("Password changed"); current = ""; next = "" } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) } }
    }

    private func enable() {
        dialogs.present("tfa-enable", width: 448, dismissible: false) {
            TwoFactorEnableForm(onDone: { dialogs.dismiss("tfa-enable"); Task { status = try? await APIClient.shared.twoFactorStatus() } }, onCancel: { dialogs.dismiss("tfa-enable") })
        }
    }
    private func regenerate() {
        dialogs.present("tfa-regen", width: 448) { TwoFactorCodeForm(title: "Regenerate recovery codes", description: "Enter a code from your authenticator to confirm. Your old codes stop working.", action: "Regenerate", run: { code in try await APIClient.shared.twoFactorRegenerate(code: code) }, onDone: { dialogs.dismiss("tfa-regen") }, onCancel: { dialogs.dismiss("tfa-regen") }) }
    }
    private func disable() {
        dialogs.present("tfa-disable", width: 448) { TwoFactorDisableForm(onDone: { dialogs.dismiss("tfa-disable"); Task { status = try? await APIClient.shared.twoFactorStatus() } }, onCancel: { dialogs.dismiss("tfa-disable") }) }
    }
}

struct RecoveryCodesView: View {
    let codes: [String]
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) { ForEach(codes, id: \.self) { Text($0).font(W.mono(13)).monospacedDigit() } }
                .padding(.horizontal, 16).padding(.vertical, 12).background(W.muted).rounded(W.radiusMd)
            WButton(copied ? "Copied" : "Copy all", icon: copied ? "check" : "copy", variant: .ghost, size: .sm, muted: true) { Platform.copy(codes.joined(separator: "\n")); copied = true }
        }
    }
}

private struct TwoFactorEnableForm: View {
    var onDone: () -> Void
    var onCancel: () -> Void
    @State private var setup: TwoFactorSetup?
    @State private var code = ""
    @State private var codes: [String]?
    @State private var busy = false
    @State private var copied = false

    var body: some View {
        FormDialog(title: codes != nil ? "Save your recovery codes" : "Set up your authenticator", description: codes != nil ? "Each code works once if you lose your authenticator. Keep them somewhere safe — they won't be shown again." : "Scan the code with your authenticator app, then enter the 6-digit code it shows.") {
            if let codes { RecoveryCodesView(codes: codes) } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Spacer(); if let s = setup, let img = QRCodeImage.make(s.otpauthURL) { Image(nsImage: img).interpolation(.none).resizable().frame(width: 192, height: 192).padding(4).background(Color.white).rounded(W.radiusMd) } else { SkeletonBlock(width: 192, height: 192) }; Spacer() }
                    Text("Can't scan? Enter this key manually:").font(W.xs).foregroundStyle(W.mutedForeground)
                    HStack(spacing: 8) {
                        Text(setup.map { $0.secret.chunked(4).joined(separator: " ") } ?? "…").font(W.mono(12)).tracking(1).lineLimit(1).padding(.horizontal, 10).frame(height: 32).frame(maxWidth: .infinity, alignment: .leading).background(W.muted).rounded(W.radiusMd)
                        WButton(icon: copied ? "check" : "copy", variant: .ghost, size: .iconSm, help: "Copy key") { if let s = setup { Platform.copy(s.secret); copied = true } }.disabled(setup == nil)
                    }
                    VStack(alignment: .leading, spacing: 6) { FieldLabel("6-digit code"); WTextField(placeholder: "123456", text: $code, mono: true, onSubmit: { verify() }, autofocus: true) }
                }
            }
        } footer: {
            if codes != nil { WButton("I've saved these", action: onDone) } else {
                WButton("Cancel", variant: .ghost, action: onCancel)
                WButton("Verify & turn on") { verify() }.disabled(setup == nil || code.filter(\.isNumber).count != 6 || busy)
            }
        }
        .task { do { setup = try await APIClient.shared.twoFactorSetup() } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription); onCancel() } }
    }

    private func verify() {
        busy = true
        Task { defer { busy = false }; do { codes = try await APIClient.shared.twoFactorEnable(code: code); Toasts.shared.show("Two-factor authentication is on") } catch { let m = (error as? APIError)?.errorDescription ?? error.localizedDescription; Toasts.shared.error(m.range(of: "invalid code", options: .caseInsensitive) != nil ? "That code isn't right. Try the next one." : m) } }
    }
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
            if let codes { RecoveryCodesView(codes: codes) } else { VStack(alignment: .leading, spacing: 6) { FieldLabel("Authenticator code"); WTextField(placeholder: "123456", text: $code, mono: true, autofocus: true) } }
        } footer: {
            if codes != nil { WButton("I've saved these", action: onDone) } else {
                WButton("Cancel", variant: .ghost, action: onCancel)
                WButton(action) { busy = true; Task { defer { busy = false }; do { codes = try await run(code) } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) } } }.disabled(code.filter(\.isNumber).count != 6 || busy)
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
            WButton("Turn off", variant: .outline) { busy = true; Task { defer { busy = false }; do { try await APIClient.shared.twoFactorDisable(password: password, code: code); Toasts.shared.show("Two-factor authentication is off"); onDone() } catch { Toasts.shared.error((error as? APIError)?.errorDescription ?? error.localizedDescription) } } }.disabled(password.isEmpty || code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
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
