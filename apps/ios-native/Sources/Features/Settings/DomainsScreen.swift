import SwiftUI

/// Custom domains and the mailboxes on them, ported from the web's Domains tab.
///
/// Adding a domain stays in the browser: it needs a zone in Cloudflare and DNS records
/// pasted somewhere, which is desk work. What a phone is for is the moment after — seeing
/// whether the records have taken, and making a mailbox on a domain that is already live
/// so you can reply from it before you get back to the desk.
struct DomainsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(ToastCenter.self) private var toasts

    @State private var domains: [MailDomain] = []
    @State private var loading = true
    @State private var error: String?
    @State private var verifying: Set<String> = []
    @State private var creatingOn: MailDomain?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Domains") {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                EmptyView()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Mail to these domains lands here through Cloudflare Email Routing. Add a domain from the web app; check it and make mailboxes from here.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Metrics.hPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    if loading && domains.isEmpty {
                        ProgressView().tint(Theme.Colors.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                    } else if let error, domains.isEmpty {
                        EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                            Task { await load() }
                        }
                    } else if domains.isEmpty {
                        EmptyState(icon: "globe", message: "No custom domains yet. Add one in the web app under Settings, Domains.")
                    } else {
                        ForEach(domains) { domain in
                            DomainBlock(
                                domain: domain,
                                verifying: verifying.contains(domain.id),
                                onVerify: { Task { await verify(domain) } },
                                onNewMailbox: { creatingOn = domain }
                            )
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
        }
        .screenBackground()
        .task { await load() }
        .sheet(item: $creatingOn) { domain in
            NewMailboxSheet(domain: domain) { account in
                Task {
                    await load()
                    await app.refreshAccounts()
                    toasts.show("Made \(account.email)")
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            domains = try await APIClient.shared.domains()
            error = nil
        } catch {
            guard !(error is CancellationError) else { return }
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func verify(_ domain: MailDomain) async {
        guard !verifying.contains(domain.id) else { return }
        verifying.insert(domain.id)
        defer { verifying.remove(domain.id) }
        do {
            let fresh = try await APIClient.shared.verifyDomain(domain.id)
            if let index = domains.firstIndex(where: { $0.id == fresh.id }) { domains[index] = fresh }
            Haptics.select()
            toasts.show(fresh.isActive ? "\(fresh.name) is active" : "\(fresh.name) is still \(fresh.statusLabel.lowercased())")
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

private struct DomainBlock: View {
    let domain: MailDomain
    let verifying: Bool
    let onVerify: () -> Void
    let onNewMailbox: () -> Void

    @State private var showingDNS = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: domain.name, trailing: domain.statusLabel)

            if let error = domain.error, !error.isEmpty {
                Text(error)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.bottom, 8)
            }

            ForEach(domain.instructions, id: \.self) { line in
                Text(line)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.bottom, 6)
            }

            if domain.mailboxes.isEmpty {
                Text("No mailboxes yet.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
            } else {
                ForEach(domain.mailboxes) { box in
                    HStack(spacing: 12) {
                        AvatarView(address: Address(email: box.email, name: box.displayName, avatarURL: box.avatarURL), size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(box.email)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.foreground)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if domain.catchAllAccountID == box.id {
                                Text("Catch-all")
                                    .font(Theme.Typography.small)
                                    .foregroundStyle(Theme.Colors.mutedForeground)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .frame(minHeight: Theme.Metrics.denseRowHeight)
                    .hairline()
                }
            }

            HStack(spacing: 10) {
                Button {
                    onNewMailbox()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("New mailbox")
                    }
                }
                .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))

                Button {
                    onVerify()
                } label: {
                    if verifying {
                        ProgressView().tint(Theme.Colors.foreground)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text(domain.isActive ? "Re-check" : "Check DNS")
                        }
                    }
                }
                .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))
                .disabled(verifying)
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.top, 12)

            if !domain.dns.isEmpty {
                Button {
                    withAnimation(Theme.Motion.quick) { showingDNS.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(showingDNS ? "Hide DNS records" : "DNS records")
                            .font(Theme.Typography.small)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showingDNS ? 180 : 0))
                    }
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(height: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Theme.Metrics.hPadding)

                if showingDNS {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(domain.dns.enumerated()), id: \.offset) { _, record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(record.type)  \(record.name)\(record.priority.map { "  priority \($0)" } ?? "")")
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(Theme.Colors.mutedForeground)
                                Text(record.content)
                                    .font(Theme.Typography.mono)
                                    .foregroundStyle(Theme.Colors.foreground)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.Colors.muted)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                    .padding(.horizontal, Theme.Metrics.hPadding)
                }
            }
        }
    }
}

/// `POST /api/domains/:id/mailboxes`: an address that exists the moment it is saved.
private struct NewMailboxSheet: View {
    let domain: MailDomain
    let onCreated: (Account) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var local = ""
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var valid: Bool {
        let value = local.trimmingCharacters(in: .whitespaces).lowercased()
        return !value.isEmpty && value.range(of: "^[a-z0-9._+-]+$", options: .regularExpression) != nil
            && !value.hasPrefix(".") && !value.hasSuffix(".")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThreadSheetHeader(title: "New mailbox on \(domain.name)", subtitle: "Letters, numbers, dots, dashes, plus or underscores.")

            HStack(spacing: 0) {
                TextField("name", text: $local)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .focused($focused)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                Text("@\(domain.name)")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Theme.Colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))

            TextField("Display name (optional)", text: $name)
                .textInputAutocapitalization(.words)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Theme.Colors.muted)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))

            if let error {
                Text(error).font(Theme.Typography.small).foregroundStyle(Theme.Colors.foreground)
            }

            Button {
                Task { await create() }
            } label: {
                if busy { ProgressView().tint(Theme.Colors.background) } else { Text("Make mailbox") }
            }
            .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
            .disabled(busy || !valid)
            .opacity(valid ? 1 : 0.4)

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

    private func create() async {
        guard valid, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let account = try await APIClient.shared.createMailbox(
                domainID: domain.id,
                localPart: local.trimmingCharacters(in: .whitespaces).lowercased(),
                displayName: name.trimmingCharacters(in: .whitespaces)
            )
            Haptics.success()
            dismiss()
            onCreated(account)
        } catch let e as APIError {
            Haptics.warning()
            switch e {
            case .server("mailbox_exists", _): error = "That mailbox already exists."
            case .server("invalid_local_part", _): error = "Use letters, numbers, dots, dashes, plus or underscores."
            default: error = e.errorDescription
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
