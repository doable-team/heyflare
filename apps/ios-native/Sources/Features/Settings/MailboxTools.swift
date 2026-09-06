import SwiftUI
import SafariServices

// The pieces the Mailboxes section reaches for beyond "edit the signature": connecting a
// Gmail account, and reading why one stopped syncing.

// MARK: - Gmail connect

/// Google's consent page, in Safari's own view controller.
///
/// Google refuses to sign people in inside an embedded web view, and the worker's
/// `/auth/google/handoff` was built for exactly this: the app, which holds the session,
/// mints a one-time state and hands it to a real browser, which carries the person's
/// Google login already. `SFSafariViewController` *is* Safari — shared cookies, no
/// embedding — so the flow works, and the person never leaves the app to do it.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: config)
        controller.preferredControlTintColor = UIColor.label
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// A sheet-sized wrapper so `.sheet(item:)` can present a URL.
struct ConnectTarget: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Sync log

/// `GET /api/accounts/:id/logs`, newest first: what the sync did and where it stopped.
struct SyncLogSheet: View {
    let account: Account

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [SyncLogRow] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Sync log", leading: {
                BarButton(icon: "chevron.down", label: "Close") { dismiss() }
            }, trailing: { EmptyView() })

            if loading && rows.isEmpty {
                ProgressView().tint(Theme.Colors.mutedForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, rows.isEmpty {
                EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                    Task { await load() }
                }
                Spacer()
            } else if rows.isEmpty {
                EmptyState(icon: "text.alignleft", message: "Nothing logged for \(account.email) yet.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text(account.email)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .padding(.horizontal, Theme.Metrics.hPadding)
                            .padding(.vertical, 10)
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(row.isError ? "Error" : row.level.capitalized)
                                        .font(Theme.Typography.caps)
                                        .tracking(0.4)
                                        .foregroundStyle(row.isError ? Theme.Colors.foreground : Theme.Colors.mutedForeground)
                                    Spacer(minLength: 8)
                                    Text(RelativeTime.long(row.date))
                                        .font(Theme.Typography.micro)
                                        .foregroundStyle(Theme.Colors.mutedForeground)
                                }
                                Text(row.message)
                                    .font(row.isError ? Theme.Typography.bodyMedium : Theme.Typography.small)
                                    .foregroundStyle(Theme.Colors.foreground)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, Theme.Metrics.hPadding)
                            .padding(.vertical, 10)
                            .hairline()
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
            }
        }
        .screenBackground()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            rows = try await APIClient.shared.accountLogs(account.id)
            error = nil
        } catch {
            guard !(error is CancellationError) else { return }
            self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
