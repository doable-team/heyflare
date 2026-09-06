import SwiftUI

// MARK: - Message body

private struct BodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One message's body, clipped to a readable height with a way out.
///
/// HTML goes through `MessageWebView`, which is the only thing in the app allowed to
/// render sender-supplied markup. A message with no HTML part draws as `Text` instead:
/// a web view per card is expensive, and plain mail gains nothing from one.
///
/// Feed cards are unbounded in principle — a newsletter can be metres long — so the body
/// is cut off at `cap` behind a fade. `expandable` decides what the way out is: in a
/// scrolling feed the rest unfolds in place, while on a fixed-height pager the caller
/// offers the full thread instead.
struct MessageBody: View {
    let message: Message
    /// Height at which the body is clipped. `nil` draws the whole thing.
    var cap: CGFloat?
    var expandable: Bool = true
    var onLink: (URL) -> Void

    /// Seeded rather than zero: a `WKWebView` needs a box with height to lay out in
    /// before it can report what height it actually wanted.
    /// Zero, not a comfortable guess: a web view's scroll view never reports a content
    /// size below its own bounds, so any seed becomes a floor the measurement cannot
    /// go under, and short mail would sit in a tall empty box.
    @State private var webHeight: CGFloat = 0
    @State private var textHeight: CGFloat = 0
    @State private var expanded = false
    @State private var showRemoteImages = false

    /// A few points of slack, so a body that only just overflows is shown whole rather
    /// than cut for the sake of a line.
    private static let slack: CGFloat = 24

    private var usesHTML: Bool { !message.htmlBody.isEmpty }

    private var plain: String {
        message.textBody.isEmpty ? HTMLText.plain(from: message.htmlBody) : message.textBody
    }

    private var contentHeight: CGFloat { usesHTML ? webHeight : textHeight }

    /// Remote images are held back by default, exactly as in the thread view: loading them
    /// tells the sender the mail was opened, which is what the Settings toggle promises it
    /// will not do. A card that has something to load offers the way to load it.
    private var blockingImages: Bool { ReadingPrefs.blockRemoteImages && !showRemoteImages }

    private var mentionsRemoteImages: Bool {
        message.htmlBody.range(of: "<img[^>]+src=[\"']?https?:", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var isClipped: Bool {
        guard let cap, !expanded else { return false }
        return contentHeight > cap + Self.slack
    }

    /// `nil` means "take your natural height"; the web view has none, so it is always given one.
    ///
    /// The cap is applied on exactly the condition `isClipped` tests, not with a plain
    /// `min`: a body between `cap` and `cap + slack` counts as unclipped, so cutting it here
    /// would take the last lines away with no fade over them and no "Read more" to get them back.
    private var shownHeight: CGFloat? {
        if usesHTML {
            guard let cap, !expanded, webHeight > cap + Self.slack else { return webHeight }
            return cap
        }
        guard let cap, !expanded, textHeight > 0, textHeight > cap + Self.slack else { return nil }
        return cap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if usesHTML && blockingImages && mentionsRemoteImages { imageNotice }

            ZStack(alignment: .top) {
                if usesHTML {
                    MessageWebView(
                        html: message.htmlBody,
                        blockRemoteImages: blockingImages,
                        height: $webHeight,
                        onLink: onLink
                    )
                } else {
                    Text(plain)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.foreground)
                        .textSelection(.enabled)
                        // `fixedSize` is what keeps the measurement honest: the text takes
                        // its full ideal height even inside a frame that will clip it.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: BodyHeightKey.self, value: proxy.size.height)
                            }
                        )
                        .onPreferenceChange(BodyHeightKey.self) { [textHeight = $textHeight] height in
                            textHeight.wrappedValue = height
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: shownHeight, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                if isClipped {
                    LinearGradient(
                        colors: [Theme.Colors.background.opacity(0), Theme.Colors.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 64)
                    .allowsHitTesting(false)
                }
            }

            if isClipped && expandable {
                Button {
                    withAnimation(Theme.Motion.quick) { expanded = true }
                } label: {
                    HStack(spacing: 6) {
                        Text("Read more")
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))
            }
        }
    }

    /// The same affordance the thread view offers, so a newsletter is still one tap away
    /// from being a newsletter.
    private var imageNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").font(.system(size: 12))
            Text("Images are blocked")
                .font(Theme.Typography.small)
            Spacer(minLength: 8)
            Button("Load") { withAnimation(Theme.Motion.quick) { showRemoteImages = true } }
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Theme.Colors.mutedForeground)
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.minTouchTarget)
        .background(Theme.Colors.muted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
    }
}

// MARK: - Feed card

/// One thread drawn as a card: who it is from, the subject, the message itself, and a
/// footer of actions that stays reachable while the card is on screen.
///
/// The footer is genuinely sticky rather than merely pinned to the card's bottom edge.
/// A newsletter can be several screens tall, and filing it should not require scrolling
/// to the end first, so the footer rides the bottom of the viewport for as long as any
/// part of the card is visible and settles onto the card's own bottom edge once the card
/// fits. That is arithmetic on the card's frame inside the scroll view, which is why the
/// enclosing screen has to name its coordinate space and pass its own height down.
struct FeedCard<Footer: View>: View {
    let thread: ThreadSummary
    var glyph: String?
    /// The coordinate space of the enclosing `ScrollView`.
    let scrollSpace: String
    /// That scroll view's visible height, in the same space.
    let viewportHeight: CGFloat
    var bodyCap: CGFloat? = 360
    var footerHeight: CGFloat = 52
    var onOpen: () -> Void
    var onLink: (URL) -> Void
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Button(action: onOpen) {
                Text(thread.displaySubject)
                    .font(Theme.Typography.compactTitle)
                    .foregroundStyle(Theme.Colors.foreground)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the thread")

            bodyView
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.top, 8)

            // The footer is an overlay, so the card reserves its own room for it here.
            Color.clear.frame(height: footerHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { pinnedFooter }
        .hairline(.bottom)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(address: thread.lastFrom, size: Theme.Metrics.smallAvatar, emphasised: !thread.seen)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(thread.lastFrom.display)
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.Colors.foreground)
                        .lineLimit(1)
                    if let glyph {
                        Text(glyph)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                }
                Text(thread.lastFrom.email)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(RelativeTime.short(thread.lastDate))
                .font(Theme.Typography.micro)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.mutedForeground)
                .layoutPriority(1)
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var bodyView: some View {
        if let message = thread.latestMessage {
            MessageBody(message: message, cap: bodyCap, onLink: onLink)
        } else {
            // The Feed sends `latest_message`; a list that does not still renders.
            Text(thread.snippet)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pinnedFooter: some View {
        GeometryReader { proxy in
            let cardHeight = proxy.size.height
            let bottomInScroll = proxy.frame(in: .named(scrollSpace)).maxY
            // How far the card hangs below the fold, clamped so the footer never climbs
            // above the strip the card set aside for it.
            let overhang = max(0, bottomInScroll - viewportHeight)
            let lift = min(overhang, max(0, cardHeight - footerHeight))

            footer()
                .frame(width: proxy.size.width, height: footerHeight)
                .background(Theme.Colors.background)
                .offset(y: cardHeight - footerHeight - lift)
        }
    }
}

/// A footer action. Icon-only by default so four of them fit a 360pt screen at 44pt each;
/// the label still reaches VoiceOver.
///
/// `fills` shares the footer's width out evenly instead. Once a footer carries six or
/// seven actions there is no room left for written labels, and an even share is what
/// keeps every one of them at or above the 44pt target on the narrowest phone rather
/// than letting a spacer decide.
struct CardAction: View {
    let icon: String
    let label: String
    var showsLabel: Bool = false
    var fills: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                if showsLabel {
                    Text(label).font(Theme.Typography.small)
                }
            }
            .foregroundStyle(Theme.Colors.mutedForeground)
            .padding(.horizontal, showsLabel ? 10 : 0)
            .frame(minWidth: Theme.Metrics.minTouchTarget, minHeight: Theme.Metrics.minTouchTarget)
            .frame(maxWidth: fills ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}
