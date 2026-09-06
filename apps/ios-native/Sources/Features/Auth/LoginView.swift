import SwiftUI

/// heyflare is self-hosted, so the first thing the app needs is an address.
/// Plain page, wordmark, one field, per the auth-page rule in DESIGN.md.
struct ServerSetupView: View {
    @Environment(AppState.self) private var app
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(size: 20)
                .padding(.bottom, 28)

            Text("Your server")
                .font(Theme.Typography.section)
                .foregroundStyle(Theme.Colors.foreground)
            Text("heyflare runs on your own Cloudflare Worker. Enter the address you deployed it to.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .padding(.top, 6)
                .padding(.bottom, 20)

            TextField("mail.example.com", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit { Task { await connect() } }
                .font(Theme.Typography.body)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Theme.Colors.muted)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))

            if let error {
                Text(error)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.foreground)
                    .padding(.top, 10)
            }

            Button {
                Task { await connect() }
            } label: {
                if checking { ProgressView().tint(Theme.Colors.background) } else { Text("Continue") }
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(address.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            .padding(.top, 16)

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenBackground()
        .onAppear { focused = true }
    }

    private func connect() async {
        guard let url = ServerConfig.normalize(address) else {
            error = "That does not look like a web address."
            return
        }
        checking = true
        defer { checking = false }
        error = nil
        await app.setServer(url)
        // Confirm something heyflare-shaped is actually there before moving on.
        do {
            _ = try await APIClient.shared.me()
            await app.loadSession()
        } catch let e as APIError {
            if e.isAuthFailure {
                await app.loadSession()   // reachable, just not signed in
            } else {
                error = e.errorDescription
                ServerConfig.shared.baseURL = nil
                await app.start()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Sign in

struct LoginView: View {
    var initialMessage: String?

    @Environment(AppState.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var ticket: String?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var field: Field?

    private enum Field { case email, password, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(size: 20)
                .padding(.bottom, 28)

            if ticket == nil { signInForm } else { twoFactorForm }

            if let message = error ?? initialMessage {
                Text(message)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.foreground)
                    .padding(.top, 12)
            }

            Spacer()

            Button {
                Task { await app.clearServer() }
            } label: {
                Text(app.serverHost.isEmpty ? "Change server" : app.serverHost)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .screenBackground()
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in")
                .font(Theme.Typography.section)
                .foregroundStyle(Theme.Colors.foreground)
                .padding(.bottom, 8)

            TextField("Email", text: $email)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .focused($field, equals: .email)
                .submitLabel(.next)
                .onSubmit { field = .password }
                .fieldStyle()

            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($field, equals: .password)
                .submitLabel(.go)
                .onSubmit { Task { await signIn() } }
                .fieldStyle()

            Button {
                Task { await signIn() }
            } label: {
                if busy { ProgressView().tint(Theme.Colors.background) } else { Text("Sign in") }
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(busy || email.isEmpty || password.isEmpty)
            .opacity(email.isEmpty || password.isEmpty ? 0.4 : 1)
            .padding(.top, 4)
        }
        .onAppear { field = .email }
    }

    private var twoFactorForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two-factor")
                .font(Theme.Typography.section)
                .foregroundStyle(Theme.Colors.foreground)
            Text("Enter the six-digit code from your authenticator, or one recovery code.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .padding(.bottom, 8)

            TextField("000000", text: $code)
                .keyboardType(.numbersAndPunctuation)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .focused($field, equals: .code)
                .submitLabel(.go)
                .onSubmit { Task { await verify() } }
                .font(Theme.Typography.large.monospacedDigit())
                .fieldStyle()

            Button {
                Task { await verify() }
            } label: {
                if busy { ProgressView().tint(Theme.Colors.background) } else { Text("Verify") }
            }
            .buttonStyle(FilledButtonStyle())
            .disabled(busy || code.count < 6)
            .opacity(code.count < 6 ? 0.4 : 1)

            Button("Back") {
                ticket = nil; code = ""; error = nil
            }
            .font(Theme.Typography.small)
            .foregroundStyle(Theme.Colors.mutedForeground)
            .padding(.top, 4)
        }
        .onAppear { field = .code }
    }

    private func signIn() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await APIClient.shared.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
            if result.mfaRequired == true, let t = result.ticket {
                ticket = t
                Haptics.select()
            } else if let user = result.user {
                Haptics.success()
                await app.adopt(user: user)
            } else {
                error = "The server did not sign us in."
            }
        } catch let e as APIError {
            Haptics.warning()
            error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func verify() async {
        guard let ticket else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await APIClient.shared.loginTwoFactor(ticket: ticket, code: code)
            if let user = result.user {
                Haptics.success()
                await app.adopt(user: user)
            } else {
                error = "That code was not accepted."
            }
        } catch let e as APIError {
            Haptics.warning()
            error = e.errorDescription
            if e == .server("mfa_ticket_expired", 401) || e == .server("mfa_too_many_attempts", 429) {
                self.ticket = nil
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension View {
    func fieldStyle() -> some View {
        self
            .font(Theme.Typography.body)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Theme.Colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
    }
}
