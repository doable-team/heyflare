import SwiftUI

// The people you turned away, and the way back in. Mirrors src/web/pages/ScreenedOut.tsx.
//
// The phone used to answer "screened out" with `GET /api/threads?bucket=screened_out` — a
// list of *messages* nobody asked to see, with no way to change the decision that put them
// there. But screening is a judgement about a person, so the list that reviews it has to be
// a list of people: one row each, however much they sent, with the reversal on the row.

// MARK: - Endpoint

// MARK: - Store

// MARK: - Screen

/// One row per person you said no to, with "Let them in" on each.
///
/// The three destinations are offered in a confirmation dialog rather than a menu: it is
/// the same set the Screener card shows, the choice is consequential, and a sheet of three
/// full-width 44pt targets is easier to hit with a thumb than a popover of small ones.
struct ScreenedOutPeopleScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Environment(ToastCenter.self) private var toasts

    @State private var store = ScreenedOutStore()
    @State private var admitting: Contact?
    @State private var inspecting: Contact?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Screened out", titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            ScrollView {
                LazyVStack(spacing: 0) {
                    subtitle
                    content
                }
                .padding(.bottom, 24)
            }
            .refreshable { await store.load() }
            .overlay(alignment: .top) {
                if store.loading && store.contacts.isEmpty {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .task { await store.load() }
        .sheet(item: $inspecting) { contact in
            ContactSheet(contact: contact) { updated in store.reconcile(updated) }
        }
        .confirmationDialog(
            admitting.map { "Let \($0.address.display) in?" } ?? "",
            isPresented: Binding(get: { admitting != nil }, set: { if !$0 { admitting = nil } }),
            titleVisibility: .visible,
            presenting: admitting
        ) { contact in
            ForEach(Self.destinations, id: \.self) { status in
                Button("Deliver to \(status.title)") { admit(contact, to: status, scope: "all") }
            }
            // Offered only where it means something narrower than the button above it.
            if app.showsAccountGlyphs, let account = app.account(contact.accountID) {
                Button("Imbox, just for \(account.email)") { admit(contact, to: .imbox, scope: "account") }
            }
            Button("Leave them out", role: .cancel) { admitting = nil }
        } message: { contact in
            Text("Their mail starts arriving again, and everything they already sent moves out of Screened out.\n\n\(contact.email)")
        }
    }

    private static let destinations: [ScreenStatus] = [.imbox, .feed, .paperTrail]

    private var subtitle: some View {
        Text(store.contacts.isEmpty
             ? "People you said no to. Change your mind any time."
             : "\(store.contacts.count) sender\(store.contacts.count == 1 ? "" : "s") you said no to. Change your mind any time.")
            .font(Theme.Typography.small)
            .foregroundStyle(Theme.Colors.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Metrics.hPadding)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.contacts.isEmpty {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.load() }
            }
        } else if store.contacts.isEmpty && !store.loading {
            EmptyState(icon: "shield.slash", message: "Nobody is screened out. Say no in the Screener and they will be listed here.")
        } else {
            ForEach(store.contacts) { contact in
                ScreenedOutRow(
                    contact: contact,
                    glyph: app.glyph(for: contact.accountID),
                    busy: store.working.contains(contact.id),
                    onOpen: { inspecting = contact },
                    onAdmit: { admitting = contact }
                )
                .hairline()
            }
        }
    }

    private func admit(_ contact: Contact, to status: ScreenStatus, scope: String) {
        admitting = nil
        Task {
            if let failure = await store.admit(contact, to: status, scope: scope) {
                toasts.error(failure)
            } else {
                Haptics.success()
                app.didMutate()
                toasts.show("\(contact.address.display) → \(status.title)")
            }
        }
    }
}

// MARK: - Row

/// Avatar, who they are, how much they sent, and the way back. Two sibling buttons: the
/// left opens them, the right reverses the decision.
private struct ScreenedOutRow: View {
    let contact: Contact
    let glyph: String?
    let busy: Bool
    let onOpen: () -> Void
    let onAdmit: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    AvatarView(address: contact.address, size: Theme.Metrics.smallAvatar + 4)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(contact.address.display)
                                .font(Theme.Typography.bodyMedium)
                                .foregroundStyle(Theme.Colors.foreground)
                                .lineLimit(1)
                            if let glyph {
                                Text(glyph)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.Colors.mutedForeground)
                            }
                        }
                        Text(detail)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)
                }
                .padding(.leading, Theme.Metrics.hPadding)
                .frame(minHeight: Theme.Metrics.denseRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .accessibilityLabel("\(contact.address.display), \(detail)")

            Button(action: onAdmit) {
                Group {
                    if busy {
                        ProgressView().tint(Theme.Colors.mutedForeground)
                    } else {
                        Text("Let in")
                            .font(Theme.Typography.small.weight(.medium))
                            .foregroundStyle(Theme.Colors.foreground)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: Theme.Metrics.minTouchTarget)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel("Let \(contact.address.display) in")
            .accessibilityHint("Choose where their mail should go")
            .padding(.horizontal, 8)
        }
    }

    /// Their address and how much of it you turned away — the two facts that decide
    /// whether letting them back in is a good idea.
    private var detail: String {
        var parts = [contact.email]
        if contact.messageCount > 0 {
            parts.append("\(contact.messageCount) message\(contact.messageCount == 1 ? "" : "s")")
        }
        if contact.lastSeenAt > 0 {
            parts.append("last \(RelativeTime.short(Date(timeIntervalSince1970: contact.lastSeenAt / 1000)))")
        }
        return parts.joined(separator: " · ")
    }
}
