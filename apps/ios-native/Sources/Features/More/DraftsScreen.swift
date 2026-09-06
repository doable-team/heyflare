import SwiftUI

/// Unsent mail: everything half-written. Anything already queued is under Scheduled.
///
/// A draft row does not open a reader — there is nothing to read — so a tap goes straight
/// back into the composer with the draft's own fields, by handing `Navigator` a
/// `ComposeIntent`. That keeps the composer the single place that knows how to edit mail.
struct DraftsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts
    @State private var store = DraftsStore()
    /// A swipe arms the delete; the dialog is what commits it. Destructive work is named
    /// and confirmed rather than coloured, per DESIGN.md.
    @State private var pendingDelete: Draft?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Drafts", titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = store.error {
                        EmptyState(icon: "exclamationmark.triangle", message: error)
                    } else if store.unsent.isEmpty && !store.loading {
                        EmptyState(icon: "square.and.pencil", message: "Nothing half-written. Mail waiting to go out is under Scheduled.")
                    } else {
                        ForEach(store.unsent) { draft in
                            DraftSwipe(
                                trailing: DraftSwipe.Action(icon: "trash", label: "Delete") {
                                    pendingDelete = draft
                                }
                            ) {
                                DraftSwipeContent(draft: draft) { open(draft) }
                            }
                            .hairline()
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .overlay(alignment: .top) {
                if store.loading && store.unsent.isEmpty {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .task { await store.load() }
        // A draft saved or sent from the composer changes this list from behind a sheet.
        .syncsWithMail { await store.load() }
        .confirmationDialog(
            "Delete this draft?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { draft in
            Button("Delete draft") {
                pendingDelete = nil
                Task {
                    if let failure = await store.delete(draft) { toasts.error(failure) }
                    else { toasts.show("Draft deleted") }
                }
            }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: { draft in
            Text(draft.subject.isEmpty ? "This cannot be undone." : "“\(draft.subject)” cannot be recovered.")
        }
    }

    /// Rebuilds the composer's starting state from the stored draft. A draft that names
    /// both a thread and the message it answers is a reply and reopens as one; anything
    /// else is a fresh message, whatever it is addressed to.
    private func open(_ draft: Draft) {
        let split = HTMLText.splitQuoted(HTMLText.plain(from: draft.bodyHTML))
        let kind: ComposeIntent.Kind
        if let threadID = draft.threadID, let messageID = draft.replyToMessageID {
            kind = .reply(threadID: threadID, messageID: messageID, all: draft.cc.isEmpty == false)
        } else {
            kind = .new
        }
        nav.composing = ComposeIntent(
            kind: kind,
            accountID: draft.accountID,
            to: draft.to,
            cc: draft.cc,
            subject: draft.subject,
            body: split.body,
            quoted: split.quoted ?? ""
        )
        nav.composing?.draftID = draft.id
        if let sendAt = draft.sendAt, draft.status == "scheduled" {
            nav.composing?.scheduledAt = Date(timeIntervalSince1970: sendAt / 1000)
        }
    }
}

/// Naming the swiped content concretely lets `SwipeRow`'s nested `Action` be spelled
/// without inferring the generic from the closure, which keeps the call site readable.
private typealias DraftSwipe = SwipeRow<DraftSwipeContent>

private struct DraftSwipeContent: View {
    let draft: Draft
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            DraftRow(draft: draft)
        }
        .buttonStyle(PressableRowStyle())
    }
}

/// Recipients, subject, when it was last touched, and — when it is queued — the word
/// "Scheduled" with the time it goes out. Same reading order as a thread row, so the two
/// lists scan the same way even though only one of them has a sender.
private struct DraftRow: View {
    let draft: Draft

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(recipients)
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(RelativeTime.short(Date(timeIntervalSince1970: draft.updatedAt / 1000)))
                    .font(Theme.Typography.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .layoutPriority(1)
            }

            Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .lineLimit(1)

            if let sendAt = draft.sendAt {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                    Text("Scheduled · \(RelativeTime.long(Date(timeIntervalSince1970: sendAt / 1000)))")
                        .font(Theme.Typography.small)
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.Colors.mutedForeground)
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.vertical, 12)
        .frame(minHeight: Theme.Metrics.denseRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var recipients: String {
        let names = draft.to.map(\.display)
        if names.isEmpty { return "No recipients" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names[0]), \(names[1]) +\(names.count - 2)"
    }

    private var accessibilityText: String {
        var parts = [recipients, draft.subject.isEmpty ? "No subject" : draft.subject]
        if draft.sendAt != nil { parts.append("Scheduled") }
        return parts.joined(separator: ", ")
    }
}
