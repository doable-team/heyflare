import SwiftUI

// Mail that is queued to go out, and the one action that matters about it: pulling it
// back. Mirrors src/web/pages/Drafts.tsx with `mode="scheduled"`.
//
// This screen exists because Drafts already lists scheduled mail but only offers Delete,
// which destroys the message. "I want this to stop going out at 6am" and "I never want to
// see these words again" are different intentions, and until now the phone could only
// express the second one.

// MARK: - Endpoint

// MARK: - Store

// MARK: - Screen

/// Everything waiting to be sent, soonest first.
///
/// Cancel is a plain named button on the row rather than a swipe: it is the reason to open
/// this screen, and a reversal you might want in a hurry should not be hidden behind a
/// gesture you have to remember. Delete keeps the swipe it has on the Drafts list, and
/// still asks first — the two actions are next to each other and only one is recoverable.
struct ScheduledScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts
    @State private var store = ScheduledStore()
    @State private var pendingDelete: Draft?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Scheduled", titleVisible: true, leading: {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            }, trailing: { EmptyView() })

            ScrollView {
                LazyVStack(spacing: 0) {
                    content
                }
                .padding(.bottom, 24)
            }
            .refreshable { await store.load() }
            .overlay(alignment: .top) {
                if store.loading && store.queued.isEmpty {
                    ProgressView().tint(Theme.Colors.mutedForeground).padding(.top, 24)
                }
            }
        }
        .screenBackground()
        .task { await store.load() }
        .syncsWithMail { await store.load() }
        .confirmationDialog(
            "Delete this message?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { draft in
            Button("Delete message") {
                pendingDelete = nil
                Task {
                    if let failure = await store.delete(draft) { toasts.error(failure) }
                    else { toasts.show("Message deleted") }
                }
            }
            Button("Keep", role: .cancel) { pendingDelete = nil }
        } message: { draft in
            // Named plainly rather than tinted, and worded to separate it from Cancel,
            // which is the other thing you might have meant to press.
            Text(draft.subject.isEmpty
                 ? "This deletes the message itself. Cancel only takes it off the queue."
                 : "“\(draft.subject)” cannot be recovered. Cancel only takes it off the queue.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.queued.isEmpty {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.load() }
            }
        } else if store.queued.isEmpty && !store.loading {
            EmptyState(icon: "clock", message: "Nothing is waiting to go out. Schedule a send from the composer.")
        } else {
            ForEach(store.queued) { draft in
                ScheduledSwipe(
                    trailing: ScheduledSwipe.Action(icon: "trash", label: "Delete") {
                        pendingDelete = draft
                    }
                ) {
                    ScheduledRowContent(
                        draft: draft,
                        onOpen: { open(draft) },
                        onCancel: { cancel(draft) }
                    )
                }
                .hairline()
            }
        }
    }

    private func cancel(_ draft: Draft) {
        Task {
            if let failure = await store.cancel(draft) { toasts.error(failure) }
            else {
                Haptics.success()
                toasts.show("Moved back to Drafts")
            }
        }
    }

    /// Same reconstruction the Drafts list does: the composer stays the single place that
    /// knows how to edit mail, and it is handed the scheduled time so the row can be
    /// rescheduled rather than only cancelled.
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
        if let sendAt = draft.sendAt { nav.composing?.scheduledAt = Date(timeIntervalSince1970: sendAt / 1000) }
    }
}

/// Naming the swiped content concretely lets `SwipeRow`'s nested `Action` be spelled
/// without inferring the generic from the closure, which keeps the call site readable.
private typealias ScheduledSwipe = SwipeRow<ScheduledRowContent>

/// The row and its Cancel button, side by side rather than nested, so a tap is never
/// ambiguous and both targets clear 44pt.
private struct ScheduledRowContent: View {
    let draft: Draft
    let onOpen: () -> Void
    let onCancel: () -> Void

    private var cancellable: Bool { draft.status == "scheduled" }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                ScheduledRow(draft: draft)
            }
            .buttonStyle(PressableRowStyle())

            if cancellable {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(Theme.Typography.small.weight(.medium))
                        .foregroundStyle(Theme.Colors.foreground)
                        .padding(.horizontal, 12)
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                                .strokeBorder(Theme.Colors.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel this scheduled send")
                .accessibilityHint("Keeps the message and moves it back to Drafts")
                .padding(.trailing, Theme.Metrics.hPadding)
                .padding(.leading, 8)
            }
        }
    }
}

/// Recipients, subject, when it goes out, and — when the worker has had trouble with it —
/// what state it is actually in. The badges are outlined rather than coloured: "Failed" is
/// a word, and in a grayscale app the word is the signal.
private struct ScheduledRow: View {
    let draft: Draft

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(recipients)
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)

                if let badge = statusBadge { StatusBadge(text: badge) }

                Spacer(minLength: 4)
            }

            Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.foreground)
                .lineLimit(1)

            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                Text(timing)
                    .font(Theme.Typography.small)
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Colors.mutedForeground)
            .padding(.top, 1)
        }
        .padding(.leading, Theme.Metrics.hPadding)
        .padding(.vertical, 12)
        .frame(minHeight: Theme.Metrics.denseRowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var recipients: String {
        let people = draft.to.isEmpty ? draft.cc : draft.to
        let names = people.map(\.display)
        if names.isEmpty { return "No recipients" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names[0]), \(names[1]) +\(names.count - 2)"
    }

    private var statusBadge: String? {
        switch draft.status {
        case "failed": return "Failed"
        case "sending": return "Sending"
        default: return nil
        }
    }

    /// A time that has already passed is not a promise about the future, so it is not
    /// phrased as one — the worker sweeps the queue on a schedule, and a minute either
    /// side of the mark is normal.
    private var timing: String {
        guard let sendAt = draft.sendAt else {
            return draft.status == "failed" ? "Could not be sent" : "Waiting to go out"
        }
        let date = Date(timeIntervalSince1970: sendAt / 1000)
        if draft.status == "failed" { return "Failed · was due \(RelativeTime.long(date))" }
        if date < Date() { return "Going out now · was due \(RelativeTime.long(date))" }
        return "Goes out \(RelativeTime.long(date))"
    }

    private var accessibilityText: String {
        var parts = [recipients, draft.subject.isEmpty ? "No subject" : draft.subject]
        if let statusBadge { parts.append(statusBadge) }
        parts.append(timing)
        return parts.joined(separator: ", ")
    }
}

/// A hairline-outlined word. The only badge shape in the app, matching the Screener's chip.
private struct StatusBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.Colors.mutedForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
    }
}
