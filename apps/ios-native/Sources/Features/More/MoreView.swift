import SwiftUI

/// The More tab: everything that did not earn a slot in the tab bar, as one scrolling
/// list of 48pt rows.
///
/// DESIGN.md §8 asks for "a list screen with 48px rows + icons + counts", so this screen
/// deliberately owns no content of its own — every row is a `nav.push`, which keeps the
/// whole tab a single `Route` table that deep links and the back gesture get for free.
/// Counts come from `app.counts` rather than from a fetch here: the tab bar already keeps
/// that value warm, and a second request would only make the two disagree.
struct MoreView: View {
    @Environment(AppState.self) private var app
    @Environment(Navigator.self) private var nav

    /// Drives the hand-off from the large title to the compact one in the bar.
    @State private var offset: CGFloat = 0

    /// The large title is ~44pt tall including its padding, so the compact title takes
    /// over a little before it has fully left, which reads as one movement rather than two.
    private var compactTitleVisible: Bool { offset < -34 }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "More", titleVisible: compactTitleVisible)

            RefreshableScroll(onRefresh: { await refresh() }, offset: $offset) {
                LargeTitle(title: "More", subtitle: app.scopeLabel)

                trays
                mail
                library
                footer
            }
        }
        .screenBackground()
    }

    // MARK: - Sections

    /// The three holding pens. Reply Later and Set Aside carry counts because those are
    /// the two the Imbox also badges; Bubble Up is a schedule, not a backlog, so it does not.
    private var trays: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Trays")
            MoreRow(icon: "clock", title: "Reply Later", count: app.counts.replyLater) {
                nav.push(.list(.replyLater))
            }
            MoreRow(icon: "bookmark", title: "Set Aside", count: app.counts.setAside) {
                nav.push(.list(.setAside))
            }
            MoreRow(icon: "arrow.up.circle", title: "Bubble Up", divider: false) {
                nav.push(.list(.bubbleUp))
            }
        }
    }

    /// The Feed gave up its tab-bar slot to the Assistant and the Paper Trail gave up its
    /// slot to the calendar, so both lead this group.
    /// "Previously seen" is the `everything` list under a friendlier name — that is what
    /// the web build calls it, and the two clients should read the same.
    private var mail: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Calendar")
            MoreRow(icon: "checklist", title: "This week") { nav.push(.week) }
            MoreRow(icon: "book", title: "Journal") { nav.push(.journal) }
            MoreRow(icon: "flame", title: "Habits", divider: false) { nav.push(.habits) }
            SectionHeader(title: "Mail")
            MoreRow(icon: "dot.radiowaves.up.forward", title: "The Feed", count: app.counts.feedNew) { nav.push(.feed) }
            MoreRow(icon: "doc.text", title: "Paper Trail", count: app.counts.paperTrailNew) { nav.push(.list(.paperTrail)) }
            MoreRow(icon: "eye", title: "Previously seen") { nav.push(.list(.everything)) }
            MoreRow(icon: "paperplane", title: "Sent") { nav.push(.list(.sent)) }
            MoreRow(icon: "trash", title: "Trash") { nav.push(.list(.trash)) }
            // Two rows, because they answer two different questions. "Screened out" is a
            // list of people and the only place a decision can be reversed, which is what
            // someone opening it almost always wants. "Screened-out mail" is the messages
            // themselves, kept because the other honest reason to come here is checking
            // whether something you were expecting got turned away.
            MoreRow(icon: "shield.slash", title: "Screened out") { nav.push(.screenedOutPeople) }
            MoreRow(icon: "envelope.badge.shield.half.filled", title: "Screened-out mail") { nav.push(.list(.screenedOut)) }
            MoreRow(icon: "magnifyingglass", title: "Search") { nav.push(.search) }
            MoreRow(icon: "bolt", title: "Power through", divider: false) { nav.push(.powerThrough) }
        }
    }

    private var library: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Library")
            MoreRow(icon: "person.2", title: "Contacts") { nav.push(.contacts) }
            MoreRow(icon: "scissors", title: "Clips") { nav.push(.clips) }
            MoreRow(icon: "folder", title: "Collections") { nav.push(.collections) }
            MoreRow(icon: "tag", title: "Labels") { nav.push(.labels) }
            MoreRow(icon: "paperclip", title: "Files") { nav.push(.files) }
            MoreRow(icon: "square.and.pencil", title: "Drafts") { nav.push(.drafts) }
            // Scheduled sits next to Drafts rather than under Mail: both are things you
            // wrote and have not finished with, and this is the one that can still be
            // called back.
            MoreRow(icon: "clock.badge.checkmark", title: "Scheduled", divider: false) { nav.push(.scheduled) }
        }
    }

    /// Settings sits on its own, below everything, the way system apps place it.
    private var footer: some View {
        VStack(spacing: 0) {
            MoreRow(icon: "gearshape", title: "Settings", divider: false) { nav.push(.settings) }
                .padding(.top, 20)

            Text(signature)
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
    }

    private var signature: String {
        guard let email = app.user?.email, !email.isEmpty else { return "heyflare" }
        return "heyflare · \(email)"
    }

    /// Pull-to-refresh here means "make the numbers on this screen true again".
    private func refresh() async {
        await app.refreshAccounts()
        app.refreshCounts()
    }
}

// MARK: - Row

/// One 48pt row: icon, label, optional count, chevron. Tappable across its full width,
/// and highlighted on touch-down by `PressableRowStyle` rather than on release.
private struct MoreRow: View {
    let icon: String
    let title: String
    var count: Int = 0
    /// The last row of a group drops its hairline so the group ends cleanly.
    var divider: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .frame(width: 22)

                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if count > 0 { CountBadge(count: count) }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.mutedForeground.opacity(0.5))
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableRowStyle())
        .modifier(RowDivider(active: divider))
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityAddTraits(.isButton)
    }
}

/// A hairline under a row, applied conditionally without changing the view's identity
/// (an `if` in the body would rebuild the row when the flag flips).
private struct RowDivider: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.leading, Theme.Metrics.hPadding + 36)
                .opacity(active ? 1 : 0)
        }
    }
}
