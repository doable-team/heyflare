import SwiftUI

/// `AuthLayout`: wordmark, a 360pt form, no card.
struct AuthLayout<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) { Mark(size: 22); Text("heyflare").font(W.font(14, 600)) }.padding(.bottom, 24)
            Text(title).font(W.font(22, 600)).tracking(-0.22)
            if let subtitle { Text(subtitle).font(W.sm).foregroundStyle(W.mutedForeground).padding(.top, 6) }
            content().padding(.top, 28)
        }
        .frame(width: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(W.background)
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
                WButton(checking ? "Connecting…" : "Continue") { Task { await connect() } }
                    .frame(maxWidth: .infinity)
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
        if let ticket {
            AuthLayout(title: "Two-factor code", subtitle: recoveryMode ? "Enter one of your recovery codes." : "Enter the 6-digit code from your authenticator app.") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(recoveryMode ? "Recovery code" : "Code")
                        WTextField(placeholder: recoveryMode ? "xxxx-xxxx" : "123456", text: $code, mono: true, fontSize: recoveryMode ? 14 : 18, onSubmit: { Task { await verify(ticket) } }, autofocus: true)
                        if !error.isEmpty { Text(error).font(W.xs) }
                    }
                    WButton(busy ? "Checking…" : "Continue") { Task { await verify(ticket) } }.frame(maxWidth: .infinity).disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    HStack {
                        Button(recoveryMode ? "Use authenticator code" : "Use a recovery code") { recoveryMode.toggle(); code = ""; error = "" }.buttonStyle(.plain).underline()
                        Spacer()
                        Button("← Back") { self.ticket = nil; code = ""; error = "" }.buttonStyle(.plain)
                    }
                    .font(W.xs).foregroundStyle(W.mutedForeground)
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
                    WButton(busy ? "Signing in…" : "Continue") { Task { await signIn() } }.frame(maxWidth: .infinity).disabled(busy)
                    Text(app.serverHost).font(W.xs).foregroundStyle(W.mutedForeground).padding(.top, 8)
                }
            }
            .onAppear { error = initialMessage ?? "" }
        }
    }

    private func signIn() async {
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
            let m = (error as? APIError)?.errorDescription ?? error.localizedDescription
            if m.range(of: "expired", options: .caseInsensitive) != nil { self.error = "That took too long. Log in again."; self.ticket = nil }
            else if m.range(of: "too many", options: .caseInsensitive) != nil { self.error = "Too many attempts. Log in again."; self.ticket = nil }
            else { self.error = "That code isn't right." }
            code = ""
        }
    }
}
