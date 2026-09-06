import Foundation
import SwiftUI
import Observation

/// The Screener: one full-width card per first-time sender, decided with a thumb.
///
/// DESIGN.md §8 asks for cards rather than rows here because a screening decision is not a
/// filing action — it is a judgement about a person, and it needs their face, what they
/// actually sent, and the destination all visible at once. The card is therefore the whole
/// unit: avatar 48, previews, a full-width destination selector and two 48pt buttons, with
/// the same decision also reachable by throwing the card off the side.
///
/// The swipe is written by hand instead of reusing `SwipeRow` on purpose. `SwipeRow` reveals
/// a panel and snaps back; this card *leaves* — it rotates, fades and flies past the edge —
/// which is a different gesture with a different commit distance and a different ending.
struct ScreenerView: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts

    @State private var store = ScreenerStore()
    /// How far the content has scrolled, so the large title can hand over to the bar's.
    @State private var offset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Screener", titleVisible: offset < -30) {
                EmptyView()
            } trailing: {
                // The people, not their mail: this button is here for the moment you
                // realise you turned away someone you meant to keep.
                BarButton(icon: "shield.slash", label: "Screened out") {
                    nav.push(.screenedOutPeople)
                }
            }

            RefreshableScroll(onRefresh: { await store.load(force: true) }, offset: $offset) {
                VStack(alignment: .leading, spacing: 0) {
                    LargeTitle(title: "Screener", subtitle: countLine)
                    if !store.entries.isEmpty {
                        Text("Swipe right to let in, left to screen out.")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .padding(.horizontal, Theme.Metrics.hPadding)
                            .padding(.bottom, 14)
                    }
                    content
                }
            }
        }
        .screenBackground()
        .task { await store.loadIfNeeded() }
        // A sender screened out from a thread's page, or a mailbox switch (which is a
        // different queue entirely), both arrive through the bus.
        .syncsWithMail { await store.load(force: true) }
    }

    /// The count lives in the header rather than on a badge: how many people are waiting is
    /// the only number on this screen, and it is what tells you whether to open it at all.
    private var countLine: String {
        guard !app.accounts.isEmpty else { return "Connect a mailbox to start screening." }
        let n = store.entries.count
        // The empty state below says "Nobody is waiting."; the subtitle says what the screen
        // is for instead of repeating it two lines above itself.
        guard n > 0 else { return "First-time senders wait here" }
        return "\(n) \(n == 1 ? "sender" : "senders") waiting"
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if app.accounts.isEmpty {
            EmptyState(icon: "tray", message: "No mailbox is connected yet.", actionTitle: "Open Settings") {
                nav.push(.settings)
            }
        } else if let error = store.error, store.entries.isEmpty {
            EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                Task { await store.load(force: true) }
            }
        } else if store.loading && store.entries.isEmpty {
            ProgressView()
                .tint(Theme.Colors.mutedForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if store.entries.isEmpty {
            EmptyState(icon: "shield", message: "Nobody is waiting.")
        } else {
            LazyVStack(spacing: 12) {
                ForEach(store.entries) { entry in
                    ScreenerCard(
                        entry: entry,
                        target: store.target(for: entry, defaultTarget: preferredDefault),
                        glyph: app.glyph(for: entry.contact.accountID),
                        accountEmail: accountEmail(for: entry),
                        onTarget: { store.setTarget($0, for: entry) },
                        onOpen: { nav.push(.peekThread($0)) },
                        onDecide: { decision, scope in decide(entry, decision, scope: scope) }
                    )
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    // A card that left by button rather than by swipe still has to leave;
                    // it shrinks and fades from its top edge so the stack closes over it.
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// Only worth naming the mailbox when there is more than one to confuse it with.
    private func accountEmail(for entry: ScreenerEntry) -> String? {
        guard app.showsAccountGlyphs, let account = app.account(entry.contact.accountID) else { return nil }
        return account.email
    }

    /// The owner's "where should people land by default" preference, used only when the
    /// server's own suggestion is the neutral one.
    private var preferredDefault: ScreenStatus? {
        switch app.user?.settings.defaultScreenTarget {
        case "feed": return .feed
        case "paper_trail": return .paperTrail
        case "imbox": return .imbox
        default: return nil
        }
    }

    // MARK: - Deciding

    /// Removes the card first and posts second: the decision is the user's, and a queue that
    /// stalls on the network reads as a broken gesture. A failure puts the card back where it was.
    private func decide(_ entry: ScreenerEntry, _ decision: ScreenStatus, scope: String) {
        let store = self.store
        let app = self.app
        let toasts = self.toasts
        guard let index = store.index(of: entry.id) else { return }

        withAnimation(Theme.Motion.rowExit) { store.remove(entry.id) }

        Task { @MainActor in
            do {
                try await APIClient.shared.decide(contactID: entry.contact.id, decision: decision, scope: scope)
                store.persist()
                Haptics.success()
                app.didMutate()
                toasts.show(Self.confirmation(for: decision, name: entry.contact.address.display),
                            undo: Self.undo(entry, at: index, store: store, app: app, toasts: toasts))
            } catch is CancellationError {
                withAnimation(Theme.Motion.rowExit) { store.insert(entry, at: index) }
            } catch {
                withAnimation(Theme.Motion.rowExit) { store.insert(entry, at: index) }
                toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private static func confirmation(for decision: ScreenStatus, name: String) -> String {
        switch decision {
        case .screenedOut: return "Screened out \(name)"
        default: return "\(name) → \(decision.title)"
        }
    }

    /// Undo puts the sender's mail back in the queue by moving their threads to the `screener`
    /// bucket — the only reversal the worker exposes. `POST /api/screener/decide` refuses a
    /// `pending` decision, so the contact's own `screen_status` keeps the value just written
    /// and *future* mail from them will not be screened again; deciding them a second time
    /// from the restored card is what settles that. An entry with no threads has nothing to
    /// move, so it gets a plain toast with no Undo rather than a button that would do nothing.
    private static func undo(_ entry: ScreenerEntry,
                             at index: Int,
                             store: ScreenerStore,
                             app: AppState,
                             toasts: ToastCenter) -> (@MainActor () async -> Void)? {
        let ids = entry.threads.map(\.id)
        guard !ids.isEmpty else { return nil }
        return { @MainActor in
            do {
                try await APIClient.shared.bulk(ids, .move(.screener))
                withAnimation(Theme.Motion.rowExit) { store.insert(entry, at: index) }
                store.persist()
                app.didMutate()
                Haptics.select()
            } catch {
                toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

// MARK: - Store

// MARK: - The card

private struct ScreenerCard: View {
    let entry: ScreenerEntry
    let target: ScreenStatus
    let glyph: String?
    /// Set only in a unified inbox, where "just for this mailbox" is a meaningful narrower decision.
    let accountEmail: String?
    let onTarget: (ScreenStatus) -> Void
    let onOpen: (String) -> Void
    let onDecide: (ScreenStatus, String) -> Void

    @State private var dx: CGFloat = 0
    @State private var armed = false
    @State private var flying = false
    @State private var dragging = false

    /// Longer than a row swipe (96pt): throwing a card away should take more intent than
    /// filing a thread, because it is a decision about a person and not about a message.
    private static let commit: CGFloat = 110

    private var lettingIn: Bool { dx > 0 }

    var body: some View {
        ZStack {
            hint
            card
                .background(Theme.Colors.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
                .offset(x: dx)
                // A card that is leaving tips and dims; a card being nudged barely moves at all,
                // which is what makes the threshold legible without a label.
                .rotationEffect(.degrees(Double(max(-10, min(10, dx / 22)))), anchor: .bottom)
                .opacity(Double(1 - min(abs(dx) / 520, 0.8)))
                // A UIKit pan, not a `DragGesture`: the SwiftUI drag stole vertical
                // scrolling from the queue wherever a finger landed on a card, and never
                // engaged at all over the card's own buttons. See `HorizontalPan`.
                .background(HorizontalPan(onChange: moved(to:), onEnd: released(at:cancelled:)))
        }
        .animation(dragging ? nil : Theme.Motion.rowExit, value: dx)
    }

    // MARK: Layers

    /// What the swipe is about to do, drawn under the card so it is revealed rather than announced.
    @ViewBuilder
    private var hint: some View {
        if dx != 0 {
            HStack(spacing: 8) {
                if lettingIn {
                    Image(systemName: "checkmark")
                    Text("Let in · \(target.title)")
                } else {
                    Text("Screen out")
                    Image(systemName: "xmark")
                }
            }
            .font(Theme.Typography.bodyMedium)
            .foregroundStyle(Theme.Colors.foreground)
            .scaleEffect(armed ? 1.1 : 1)
            .animation(Theme.Motion.quick, value: armed)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: lettingIn ? .leading : .trailing)
            .padding(.horizontal, 22)
            .background(Theme.Colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .accessibilityHidden(true)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            identity
            previews
            destinations
            actions
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(address: entry.contact.address, size: 48)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.contact.address.display)
                        .font(Theme.Typography.compactTitle)
                        .foregroundStyle(Theme.Colors.foreground)
                        .lineLimit(1)
                    if let glyph {
                        Text(glyph)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                }
                Text(entry.contact.email)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Chip(icon: reason.icon, text: reason.text)
                    if let domain = entry.contact.email.split(separator: "@").last, !domain.isEmpty {
                        Chip(icon: nil, text: "@\(domain)")
                    }
                }
                .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.contact.address.display), \(entry.contact.email). \(reason.text).")
    }

    /// The first two things they sent, which is the whole basis for the decision.
    private var previews: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entry.threads.prefix(2))) { thread in
                Button {
                    onOpen(thread.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(thread.displaySubject)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.foreground)
                                .lineLimit(1)
                            if thread.hasAttachments {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Colors.mutedForeground)
                            }
                            Spacer(minLength: 6)
                            Text(RelativeTime.short(thread.lastDate))
                                .font(Theme.Typography.micro)
                                .monospacedDigit()
                                .foregroundStyle(Theme.Colors.mutedForeground)
                                .layoutPriority(1)
                        }
                        if !thread.snippet.isEmpty {
                            Text(thread.snippet)
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: Theme.Metrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableRowStyle())
                .hairline(.top)
            }

            if entry.threads.count > 2 {
                Text("+\(entry.threads.count - 2) more")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .padding(.top, 6)
            }
        }
    }

    private var destinations: some View {
        HStack(spacing: 0) {
            ForEach(ScreenerCard.targets, id: \.self) { option in
                let selected = option == target
                Button {
                    onTarget(option)
                } label: {
                    Text(option.title)
                        .font(selected ? Theme.Typography.small.weight(.semibold) : Theme.Typography.small)
                        .foregroundStyle(selected ? Theme.Colors.background : Theme.Colors.mutedForeground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .background(selected ? Theme.Colors.foreground : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Deliver to \(option.title)")
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)

                if option != ScreenerCard.targets.last {
                    Rectangle()
                        .fill(Theme.Colors.border)
                        .frame(width: 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onDecide(.screenedOut, "all")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                        Text("Screen out")
                    }
                }
                .buttonStyle(OutlineButtonStyle(height: 48))

                Button {
                    onDecide(target, "all")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text("Let them in")
                    }
                }
                .buttonStyle(FilledButtonStyle(height: 48))
            }

            if let accountEmail {
                Button {
                    onDecide(target, "account")
                } label: {
                    Text("Just for \(accountEmail)")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Gesture

    private func moved(to translation: CGFloat) {
        guard !flying else { return }
        dragging = true
        dx = translation
        let past = abs(dx) >= Self.commit
        if past != armed {
            armed = past
            if past { Haptics.threshold() }
        }
    }

    private func released(at translation: CGFloat, cancelled: Bool) {
        dragging = false
        armed = false
        // `dx != 0` proves the card actually followed the finger; a cancelled pan — the
        // scroll view took the touch after all — must not screen a real person in or out.
        guard !flying, !cancelled, dx != 0, abs(translation) >= Self.commit else {
            dx = 0
            return
        }
        let toRight = translation > 0
        flying = true
        // Let the card clear the edge before the list drops it, so the decision reads
        // as one movement instead of a throw followed by a separate collapse.
        dx = toRight ? 700 : -700
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            onDecide(toRight ? target : .screenedOut, "all")
        }
    }

    // MARK: Copy

    private static let targets: [ScreenStatus] = [.imbox, .feed, .paperTrail]

    /// The address shapes the worker treats as machine senders. Mirrors
    /// `PAPER_SENDER_RE` in src/worker/sync.ts.
    private static let automatedSender = try? NSRegularExpression(
        pattern: "^(noreply|no-reply|no_reply|donotreply|do-not-reply|billing|receipts?|invoices?|orders?|payments?|notifications?)@",
        options: .caseInsensitive
    )

    /// The subject words that mean paperwork. Mirrors `PAPER_TRAIL_RE` in the same file.
    private static let paperworkSubject = try? NSRegularExpression(
        pattern: "\\b(receipt|invoice|order|payment|confirmation|confirmed|shipped|shipping|delivery|delivered|statement|booking|reservation|ticket|itinerary|purchase|transaction|renewal|refund|billing)\\b",
        options: .caseInsensitive
    )

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex, !text.isEmpty else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Why the server suggested what it suggested, in the reader's words.
    ///
    /// The worker reaches Paper Trail by two different routes — a subject full of
    /// paperwork words, or an address that is plainly a machine — and saying "looks like a
    /// receipt" for both overclaims. A newsletter whose subject happens to contain
    /// "shipped" is suggested for the Paper Trail, and calling that a receipt reads as a
    /// mistake even though the suggestion itself is sound.
    private var reason: (icon: String, text: String) {
        switch entry.suggestion {
        case .feed:
            let unsubscribable = entry.threads.contains {
                $0.snippet.range(of: "unsubscribe", options: .caseInsensitive) != nil
            }
            return ("dot.radiowaves.up.forward", unsubscribable ? "Has an unsubscribe link" : "Looks like a newsletter")
        case .paperTrail:
            if Self.matches(Self.automatedSender, entry.contact.email) {
                return ("doc.plaintext", "Automated sender")
            }
            if entry.threads.contains(where: { Self.matches(Self.paperworkSubject, $0.displaySubject) }) {
                return ("doc.plaintext", "Reads like paperwork")
            }
            return ("doc.plaintext", "Looks like paperwork")
        default:
            return ("person", "Probably a person")
        }
    }
}

/// A hairline-outlined caption. Monochrome, like every other mark in the app.
private struct Chip: View {
    let icon: String?
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
            }
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.Colors.mutedForeground)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }
}
