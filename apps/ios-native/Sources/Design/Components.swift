import SwiftUI

// MARK: - Avatar

/// A photo when the server has one, initials when it does not. Square with a small
/// radius, per DESIGN.md — not a circle, which is what makes heyflare's lists read
/// differently from every other mail app.
struct AvatarView: View {
    let address: Address
    var size: CGFloat = Theme.Metrics.avatar
    /// Unread rows invert, which is the only weight avatars carry.
    var emphasised: Bool = false

    private var url: URL? {
        guard let raw = address.avatarURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var body: some View {
        CachedImage(url: url, size: size) {
            ZStack {
                (emphasised ? Theme.Colors.foreground : Theme.Colors.muted)
                Text(address.initials)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(emphasised ? Theme.Colors.background : Theme.Colors.foreground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                .strokeBorder(Theme.Colors.border, lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }
}

/// The stacked faces on the Screener banner.
struct AvatarStack: View {
    let addresses: [Address]
    var size: CGFloat = 28
    var max: Int = 4

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(addresses.prefix(max)) { address in
                AvatarView(address: address, size: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous)
                            .strokeBorder(Theme.Colors.background, lineWidth: 2)
                    )
            }
        }
    }
}

// MARK: - Small pieces

/// The 6px unread mark.
struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(Theme.Colors.foreground)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Unread")
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.Colors.mutedForeground)
    }
}

/// Section headers: 11px, caps, wide tracking.
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(Theme.Typography.caps)
                .tracking(0.6)
                .foregroundStyle(Theme.Colors.mutedForeground)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Theme.Typography.caps)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

/// Icon, one line, one ghost button. No illustrations, per the spec.
struct EmptyState: View {
    let icon: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Colors.mutedForeground)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(Theme.Colors.foreground)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 56)
    }
}

/// Full-bleed primary button: black on white, inverted in dark mode.
struct FilledButtonStyle: ButtonStyle {
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.bodyStrong)
            .foregroundStyle(Theme.Colors.background)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Theme.Colors.foreground.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.bodyMedium)
            .foregroundStyle(Theme.Colors.foreground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(configuration.isPressed ? Theme.Colors.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

/// Rows highlight on touch-down rather than on release, which is what makes a list
/// feel attached to the finger.
struct PressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.Colors.accent : Color.clear)
            .contentShape(Rectangle())
    }
}

// MARK: - Bars

/// The 44pt top bar. Large titles are drawn by the screen itself so they can
/// collapse on scroll; this is the fixed chrome above them.
struct TopBar<Leading: View, Trailing: View>: View {
    let title: String
    /// Fades in as the large title scrolls away.
    var titleVisible: Bool = true
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(Theme.Typography.compactTitle)
                .foregroundStyle(Theme.Colors.foreground)
                .lineLimit(1)
                .opacity(titleVisible ? 1 : 0)
                .animation(Theme.Motion.quick, value: titleVisible)

            HStack(spacing: 4) {
                leading()
                Spacer(minLength: 0)
                trailing()
            }
        }
        .frame(height: Theme.Metrics.topBarHeight)
        .padding(.horizontal, 8)
        .background(Theme.Colors.chrome)
        .background(.ultraThinMaterial)
        .hairline(.bottom)
    }
}

extension TopBar where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, titleVisible: Bool = true) {
        self.init(title: title, titleVisible: titleVisible, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A 44pt tappable bar button, so every target clears the minimum.
struct BarButton: View {
    let icon: String
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.Colors.foreground)
                .frame(width: Theme.Metrics.minTouchTarget, height: Theme.Metrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

/// The compose FAB: 52pt, inverted, sitting above the tab bar.
struct ComposeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.Colors.background)
                .frame(width: 52, height: 52)
                .background(Theme.Colors.foreground)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .accessibilityLabel("New message")
        .padding(.trailing, Theme.Metrics.hPadding)
        .padding(.bottom, 12)
    }
}

// MARK: - Time

enum RelativeTime {
    private static let calendar = Calendar.current

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jm")
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f
    }()

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM"); return f
    }()

    private static let withYear: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM yyyy"); return f
    }()

    /// What a list row shows on the right: time today, weekday this week, then dates.
    static func short(_ date: Date, now: Date = Date()) -> String {
        // Counted from start-of-day to start-of-day, so this is calendar days rather than
        // elapsed 24-hour spans. Measured between the instants, last Monday 10:00 is 6 days
        // before this Monday 09:00, and the row would stamp it "Mon" — the same thing a
        // message from this morning shows.
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0

        if days == 0 { return timeOnly.string(from: date) }
        if days == 1 { return "Yesterday" }
        // Weekday names only stay unambiguous for the six calendar days behind today; at
        // seven the name comes round again.
        if days > 1 && days < 7 { return weekday.string(from: date) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return dayMonth.string(from: date) }
        return withYear.string(from: date)
    }

    /// The fuller stamp on a message header inside a thread.
    static func long(_ date: Date, now: Date = Date()) -> String {
        if calendar.isDateInToday(date) { return "Today at " + timeOnly.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday at " + timeOnly.string(from: date) }
        let day = calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? dayMonth.string(from: date) : withYear.string(from: date)
        return day + " at " + timeOnly.string(from: date)
    }

    /// Sticky month captions in long lists.
    static func monthCaption(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMM" : "MMMM yyyy")
        return f.string(from: date)
    }
}
