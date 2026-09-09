import SwiftUI

/// `AuthLayout`: wordmark, a 360pt form, no card.
struct AuthLayout<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // `min-h-12` on the Mac: the strip that clears the traffic lights.
            Color.clear.frame(height: 48)
            // `flex-1 items-center justify-center px-5 pb-16` around a `max-w-[360px]` block.
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Mark(size: 22)
                        Text("heyflare").font(W.font(14, 600)).webLine(14, weight: 600)
                    }
                    .padding(.bottom, 24)
                    Text(title).font(W.font(22, 600)).webLine(22, 28, weight: 600).tracking(-0.22)
                    if let subtitle { Text(subtitle).font(W.sm).webLine(14).foregroundStyle(W.mutedForeground).padding(.top, 6) }
                    content().padding(.top, 28)
                }
                .frame(width: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 64)
        }
        .background(W.background)
    }
}

/// `<Button type="submit" className="w-full" disabled={busy}>{busy && <Loader2 className="animate-spin" />}Label</Button>`:
/// the label stays while a spinner joins it.
private struct SubmitButton: View {
    let label: String
    var busy = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { Spinner(size: 16) }
                Text(label)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.web(.default))
    }
}

/// `text-xs text-muted-foreground hover:text-foreground`, optionally underlined.
private struct AuthLink: View {
    let label: String
    var underline = false
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(label).font(W.xs).underline(underline).foregroundStyle(hovering ? W.foreground : W.mutedForeground).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The browser's own validation bubbles, in words: `required`, `type="email"`, `minLength`.
private enum FormValidation {
    static func required(_ value: String) -> String? { value.isEmpty ? "Please fill out this field." : nil }
    static func email(_ value: String) -> String? {
        if let r = required(value) { return r }
        return value.contains("@") ? nil : "Please include an '@' in the email address. '\(value)' is missing an '@'."
    }
    static func minLength(_ value: String, _ n: Int) -> String? {
        if let r = required(value) { return r }
        return value.count < n ? "Please lengthen this text to \(n) characters or more (you are currently using \(value.count) character\(value.count == 1 ? "" : "s"))." : nil
    }
}

/// First run: point the app at a heyflare server.
struct ServerSetupPage: View {
    @Environment(AppState.self) private var app
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        AuthLayout(title: "Your server", subtitle: "heyflare runs on your own Cloudflare Worker. Enter the address you deployed it to.") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Address")
                    WTextField(placeholder: "mail.example.com", text: $address, onSubmit: { Task { await connect() } }, autofocus: true)
                    if let error { Text(error).font(W.xs) }
                }
                SubmitButton(label: "Continue", busy: checking) { Task { await connect() } }
                    .disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func connect() async {
        guard let url = ServerConfig.normalize(address) else { error = "That does not look like a web address."; return }
        checking = true; defer { checking = false }
        error = nil
        // Probe first, commit after: `setServer` swaps this page out for the login page at
        // once, so a bad address must be caught while this view is still on screen.
        let previous = ServerConfig.shared.baseURL
        ServerConfig.shared.baseURL = url
        await APIClient.shared.clearCookies()
        do {
            _ = try await APIClient.shared.me()
        } catch let e as APIError where !e.isAuthFailure {
            ServerConfig.shared.baseURL = previous
            error = e.errorDescription
            return
        } catch let e as APIError where e.isAuthFailure {
            // Reachable, just signed out: that is a server.
        } catch {
            ServerConfig.shared.baseURL = previous
            self.error = error.localizedDescription
            return
        }
        await app.setServer(url)
        await app.loadSession()
    }
}

/// The server this window points at, and the way back to the server screen.
private struct ServerFooter: View {
    @Environment(AppState.self) private var app
    @State private var hovering = false

    var body: some View {
        Button { Task { await app.clearServer() } } label: {
            Text(app.serverHost.isEmpty ? "Change server" : app.serverHost)
                .font(W.xs).webLine(12)
                .foregroundStyle(hovering ? W.foreground : W.mutedForeground)
                .underline(hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Point this app at a different heyflare server")
        .onHover { hovering = $0 }
        .padding(.bottom, 20)
    }
}

/// `Setup.tsx`: first run only, creates the single owner of this heyflare.
struct SetupPage: View {
    @Environment(AppState.self) private var app
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        AuthLayout(title: "Set up your login", subtitle: "This is a private, single-owner heyflare. You only do this once.") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) { FieldLabel("Your name"); WTextField(placeholder: "Farhan", text: $name, onSubmit: { Task { await submit() } }, autofocus: true) }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Email"); WTextField(placeholder: "you@example.com", text: $email, onSubmit: { Task { await submit() } })
                    Text("Used to log in. It doesn't have to be a Gmail address.").font(W.xs).foregroundStyle(W.mutedForeground)
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Password"); WTextField(placeholder: "At least 8 characters", text: $password, secure: true, onSubmit: { Task { await submit() } })
                    if !error.isEmpty { Text(error).font(W.xs) }
                }
                SubmitButton(label: "Create my login", busy: busy) { Task { await submit() } }.disabled(busy)
                Text("Next, you'll connect one or more Gmail accounts from the Imbox.").font(W.xs).foregroundStyle(W.mutedForeground)
            }
        }
        .overlay(alignment: .bottom) { ServerFooter() }
    }

    private func submit() async {
        // `required`, `type="email"`, `minLength={8}`: the form validates on submit.
        if let v = FormValidation.email(email) ?? FormValidation.minLength(password, 8) { error = v; return }
        busy = true; error = ""
        defer { busy = false }
        do {
            try await APIClient.shared.setup(email: email.trimmingCharacters(in: .whitespaces), name: name.trimmingCharacters(in: .whitespaces), password: password)
            await app.loadSession()
        } catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }
}

/// `Login.tsx`, with the two-factor step.
struct LoginPage: View {
    let initialMessage: String?
    @Environment(AppState.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false
    @State private var ticket: String?
    @State private var code = ""
    @State private var recoveryMode = false

    var body: some View {
        Group {
            if let ticket {
                AuthLayout(title: "Two-factor code", subtitle: recoveryMode ? "Enter one of your recovery codes." : "Enter the 6-digit code from your authenticator app.") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(recoveryMode ? "Recovery code" : "Code")
                            // `text-[18px] tracking-[0.3em] font-mono` for the 6-digit code.
                            WTextField(placeholder: recoveryMode ? "xxxx-xxxx" : "123456", text: $code, mono: true, fontSize: recoveryMode ? 14 : 18, onSubmit: { Task { await verify(ticket) } }, autofocus: true)
                                .tracking(recoveryMode ? 0 : 18 * 0.3)
                            if !error.isEmpty { Text(error).font(W.xs) }
                        }
                        SubmitButton(label: "Continue", busy: busy) { Task { await verify(ticket) } }.disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                        HStack {
                            AuthLink(label: recoveryMode ? "Use authenticator code" : "Use a recovery code", underline: true) { recoveryMode.toggle(); code = ""; error = "" }
                            Spacer()
                            AuthLink(label: "← Back") { self.ticket = nil; code = ""; error = "" }
                        }
                    }
                }
            } else {
                AuthLayout(title: "Log in", subtitle: "Welcome back to your Imbox.") {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) { FieldLabel("Email"); WTextField(placeholder: "you@example.com", text: $email, onSubmit: { Task { await signIn() } }, autofocus: true) }
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel("Password"); WTextField(placeholder: "••••••••", text: $password, secure: true, onSubmit: { Task { await signIn() } })
                            if !error.isEmpty { Text(error).font(W.xs) }
                        }
                        SubmitButton(label: "Continue", busy: busy) { Task { await signIn() } }.disabled(busy)
                    }
                }
                .onAppear { error = initialMessage ?? "" }
            }
        }
        // The web is served by the server it talks to, so it needs no such control.
        // A native window does: it sits in the floor, leaving the form the web's.
        .overlay(alignment: .bottom) { ServerFooter() }
    }

    private func signIn() async {
        if let v = FormValidation.email(email) ?? FormValidation.required(password) { error = v; return }
        busy = true; error = ""
        defer { busy = false }
        do {
            let r = try await APIClient.shared.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
            if r.mfaRequired == true, let t = r.ticket { ticket = t; code = "" } else if let u = r.user { await app.adopt(user: u) } else { error = "The server did not sign us in." }
        } catch { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
    }

    private func verify(_ ticket: String) async {
        busy = true; error = ""
        defer { busy = false }
        do {
            let r = try await APIClient.shared.loginTwoFactor(ticket: ticket, code: code)
            if let u = r.user { await app.adopt(user: u) } else { error = "That code isn't right." }
        } catch {
            // The worker answers with codes; the friendly text they map to is not stable enough
            // to match on, and an expired ticket must be dropped or every retry fails.
            var codeName = ""
            if case .server(let c, _)? = error as? APIError { codeName = c }
            switch codeName {
            case "mfa_ticket_expired": self.error = "That took too long. Log in again."; self.ticket = nil
            case "mfa_too_many_attempts": self.error = "Too many attempts. Log in again."; self.ticket = nil
            default: self.error = "That code isn't right."
            }
            code = ""
        }
    }
}
