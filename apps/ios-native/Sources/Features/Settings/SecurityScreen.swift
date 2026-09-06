import SwiftUI
import CoreImage.CIFilterBuiltins

/// Password and second factor, ported from the web's Security tab.
///
/// These were left to the browser on the reasoning that they are done once. They are here
/// because the phone is the authenticator: setting up a second factor on the device that
/// will hold the codes is the only order in which it is not a two-machine job.
struct SecurityScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(ToastCenter.self) private var toasts

    @State private var status: TwoFactorStatus?
    @State private var loading = true

    // Password
    @State private var current = ""
    @State private var next = ""
    @State private var confirm = ""
    @State private var changing = false
    @FocusState private var field: Field?

    // Second factor
    @State private var enrolling: TwoFactorSetup?
    @State private var regenerating = false
    @State private var disabling = false
    @State private var codes: [String]?

    private enum Field: Hashable { case current, next, confirm }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Security") {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                EmptyView()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    password
                    twoFactor
                }
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .screenBackground()
        .tint(Theme.Colors.foreground)
        .task { await load() }
        .sheet(item: $enrolling) { setup in
            TwoFactorEnrolSheet(setup: setup, email: app.user?.email ?? "") { recovery in
                codes = recovery
                Task { await load() }
            }
        }
        .sheet(isPresented: $regenerating) {
            CodeConfirmSheet(
                title: "New recovery codes",
                message: "Enter a code from your authenticator. The codes you have now stop working.",
                action: "Regenerate"
            ) { code in
                try await APIClient.shared.twoFactorRegenerate(code: code)
            } onDone: { fresh in
                codes = fresh
                Task { await load() }
            }
        }
        .sheet(isPresented: $disabling) {
            TwoFactorDisableSheet {
                toasts.show("Two-factor turned off")
                Task { await load() }
            }
        }
        .sheet(isPresented: Binding(get: { codes != nil }, set: { if !$0 { codes = nil } })) {
            if let codes { RecoveryCodesSheet(codes: codes) }
        }
    }

    // MARK: Password

    private var password: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Password")
            Text("At least 8 characters. Other devices stay signed in.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.bottom, 10)

            VStack(spacing: 10) {
                SecureField("Current password", text: $current)
                    .textContentType(.password)
                    .focused($field, equals: .current)
                    .submitLabel(.next)
                    .onSubmit { field = .next }
                    .modifier(SecurityField())
                SecureField("New password", text: $next)
                    .textContentType(.newPassword)
                    .focused($field, equals: .next)
                    .submitLabel(.next)
                    .onSubmit { field = .confirm }
                    .modifier(SecurityField())
                SecureField("New password, again", text: $confirm)
                    .textContentType(.newPassword)
                    .focused($field, equals: .confirm)
                    .submitLabel(.done)
                    .onSubmit { Task { await changePassword() } }
                    .modifier(SecurityField())

                if !confirm.isEmpty && next != confirm {
                    Text("Those two do not match.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await changePassword() }
                } label: {
                    if changing { ProgressView().tint(Theme.Colors.background) } else { Text("Change password") }
                }
                .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
                .disabled(!canChange || changing)
                .opacity(canChange ? 1 : 0.5)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
        }
    }

    private var canChange: Bool {
        !current.isEmpty && next.count >= 8 && next == confirm
    }

    private func changePassword() async {
        guard canChange, !changing else { return }
        changing = true
        field = nil
        defer { changing = false }
        do {
            try await APIClient.shared.changePassword(current: current, next: next)
            current = ""; next = ""; confirm = ""
            Haptics.success()
            toasts.show("Password changed")
        } catch let error as APIError {
            Haptics.warning()
            toasts.error(error == .server("invalid_credentials", 401) ? "That is not your current password." : (error.errorDescription ?? "Could not change the password."))
        } catch {
            toasts.error(error.localizedDescription)
        }
    }

    // MARK: Second factor

    private var twoFactor: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Two-factor authentication")
            Text("A second step at sign-in, from an authenticator app. Nothing leaves your server.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.bottom, 10)

            if loading && status == nil {
                ProgressView().tint(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if let status, status.enabled {
                statusRow("On", detail: status.recoveryLeft == 1 ? "1 recovery code left" : "\(status.recoveryLeft) recovery codes left")
                actionRow("New recovery codes", detail: "Replaces the ones you have") { regenerating = true }
                // Named for what it does, never tinted; the sheet asks for the password.
                actionRow("Turn off two-factor", detail: "Signing in goes back to password only", divider: false) { disabling = true }
            } else {
                statusRow("Off", detail: "Password only")
                actionRow("Set up an authenticator", detail: "Scan a code, then confirm with one from the app", divider: false) {
                    Task { await beginEnrol() }
                }
            }
        }
    }

    private func statusRow(_ value: String, detail: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Two-factor is \(value.lowercased())")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                Text(detail)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
            }
            Spacer(minLength: 12)
            Image(systemName: value == "On" ? "checkmark.shield" : "shield")
                .font(.system(size: 17))
                .foregroundStyle(Theme.Colors.mutedForeground)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .frame(minHeight: Theme.Metrics.denseRowHeight)
        .hairline()
    }

    private func actionRow(_ title: String, detail: String, divider: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.foreground)
                    Text(detail)
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.mutedForeground.opacity(0.5))
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(minHeight: Theme.Metrics.denseRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .overlay(alignment: .bottom) {
            if divider {
                Rectangle().fill(Theme.Colors.border).frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, Theme.Metrics.hPadding)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            status = try await APIClient.shared.twoFactorStatus()
        } catch {
            guard !(error is CancellationError) else { return }
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func beginEnrol() async {
        do {
            enrolling = try await APIClient.shared.twoFactorSetup()
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// The plain field this screen uses, matching the sign-in page.
private struct SecurityField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.foreground)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Theme.Colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
    }
}

// MARK: - Enrolment

/// Scan, then prove it: the code the authenticator now shows is what turns it on.
private struct TwoFactorEnrolSheet: View {
    let setup: TwoFactorSetup
    let email: String
    let onEnabled: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Set up authenticator") {
                Button("Cancel") { dismiss() }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .padding(.horizontal, 8)
            } trailing: {
                EmptyView()
            }

            ScrollView {
                VStack(spacing: 16) {
                    Text("Scan this with Google Authenticator, 1Password, Authy or any TOTP app. If the app is on this phone, copy the key instead.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let qr = QRCode.image(for: setup.otpauthURL) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
                            .accessibilityLabel("QR code for the authenticator")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Key")
                            .font(Theme.Typography.caps)
                            .tracking(0.6)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                        HStack(spacing: 10) {
                            Text(spaced(setup.secret))
                                .font(Theme.Typography.mono)
                                .foregroundStyle(Theme.Colors.foreground)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button {
                                UIPasteboard.general.string = setup.secret
                                Haptics.select()
                                toasts.show("Key copied")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.Colors.foreground)
                                    .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                            }
                            .accessibilityLabel("Copy key")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.Colors.muted)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Then enter the six digits it shows")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                        TextField("000000", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(Theme.Typography.large.monospacedDigit())
                            .focused($focused)
                            .modifier(SecurityField())
                        if let error {
                            Text(error)
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.foreground)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task { await enable() }
                    } label: {
                        if busy { ProgressView().tint(Theme.Colors.background) } else { Text("Turn on two-factor") }
                    }
                    .buttonStyle(FilledButtonStyle())
                    .disabled(busy || code.count < 6)
                    .opacity(code.count < 6 ? 0.4 : 1)
                }
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .screenBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func spaced(_ secret: String) -> String {
        stride(from: 0, to: secret.count, by: 4).map { i -> String in
            let start = secret.index(secret.startIndex, offsetBy: i)
            let end = secret.index(start, offsetBy: min(4, secret.count - i))
            return String(secret[start..<end])
        }.joined(separator: " ")
    }

    private func enable() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let recovery = try await APIClient.shared.twoFactorEnable(code: code.trimmingCharacters(in: .whitespaces))
            Haptics.success()
            dismiss()
            onEnabled(recovery)
        } catch let e as APIError {
            Haptics.warning()
            error = e == .server("invalid_code", 400) ? "That code was not accepted. Codes change every 30 seconds." : e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One code, one action: used for regenerating recovery codes.
private struct CodeConfirmSheet: View {
    let title: String
    let message: String
    let action: String
    let perform: (String) async throws -> [String]
    let onDone: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThreadSheetHeader(title: title, subtitle: message)
            TextField("Authenticator code", text: $code)
                .keyboardType(.numbersAndPunctuation)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .font(Theme.Typography.large.monospacedDigit())
                .focused($focused)
                .modifier(SecurityField())
            if let error {
                Text(error).font(Theme.Typography.small).foregroundStyle(Theme.Colors.foreground)
            }
            Button {
                Task { await run() }
            } label: {
                if busy { ProgressView().tint(Theme.Colors.background) } else { Text(action) }
            }
            .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
            .disabled(busy || code.isEmpty)
            .opacity(code.isEmpty ? 0.4 : 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 16)
        .screenBackground()
        .presentationDetents([.medium])
        .task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            focused = true
        }
    }

    private func run() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await perform(code.trimmingCharacters(in: .whitespaces))
            Haptics.success()
            dismiss()
            onDone(result)
        } catch let e as APIError {
            Haptics.warning()
            error = e == .server("invalid_code", 400) ? "That code was not accepted." : e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TwoFactorDisableSheet: View {
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThreadSheetHeader(title: "Turn off two-factor", subtitle: "Your password, and one last code from the authenticator or a recovery code.")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .modifier(SecurityField())
            TextField("Authenticator or recovery code", text: $code)
                .keyboardType(.numbersAndPunctuation)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .font(Theme.Typography.body.monospacedDigit())
                .modifier(SecurityField())
            if let error {
                Text(error).font(Theme.Typography.small).foregroundStyle(Theme.Colors.foreground)
            }
            Button {
                Task { await run() }
            } label: {
                if busy { ProgressView().tint(Theme.Colors.background) } else { Text("Turn off two-factor") }
            }
            .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
            .disabled(busy || password.isEmpty)
            .opacity(password.isEmpty ? 0.4 : 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 16)
        .screenBackground()
        .presentationDetents([.medium])
    }

    private func run() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await APIClient.shared.twoFactorDisable(password: password, code: code.trimmingCharacters(in: .whitespaces))
            Haptics.success()
            dismiss()
            onDone()
        } catch let e as APIError {
            Haptics.warning()
            switch e {
            case .server("invalid_credentials", _): error = "That is not your password."
            case .server("invalid_code", _): error = "That code was not accepted."
            default: error = e.errorDescription
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Shown once, right after they are made. They are not stored anywhere the app can show
/// again, which is why the sheet insists on being read.
private struct RecoveryCodesSheet: View {
    let codes: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThreadSheetHeader(title: "Your recovery codes", subtitle: "Each works once, if you ever lose the authenticator. Keep them somewhere that is not this phone.")

            VStack(alignment: .leading, spacing: 6) {
                ForEach(codes, id: \.self) { code in
                    Text(code)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Colors.foreground)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.Colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))

            HStack(spacing: 10) {
                Button("Copy all") {
                    UIPasteboard.general.string = codes.joined(separator: "\n")
                    Haptics.select()
                    toasts.show("Codes copied")
                }
                .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))
                Button("I have saved them") { dismiss() }
                    .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.bottom, 16)
        .screenBackground()
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }
}

// MARK: - QR

enum QRCode {
    /// A crisp code, drawn at a size that survives being scaled up without smoothing.
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
