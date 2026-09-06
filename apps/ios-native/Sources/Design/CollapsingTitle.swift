import SwiftUI

/// Reports how far a scroll view has travelled, so a large title can hand over to the
/// compact one in the bar. Cheaper than a `GeometryReader` per row: one preference,
/// written by a single zero-height probe at the top of the content.
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollOffsetProbe: View {
    /// Which named coordinate space to measure against. Screens that host their own
    /// `ScrollView` name it themselves; `RefreshableScroll` names its own "scroll".
    var space: String = "scroll"

    var body: some View {
        Color.clear
            .frame(height: 0)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named(space)).minY)
                }
            )
    }
}

/// The large title that scrolls with the content, with the scope line under it.
/// The compact title in the `TopBar` fades in as this one leaves.
struct LargeTitle: View {
    let title: String
    var subtitle: String?
    var onTapSubtitle: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Typography.title)
                .tracking(-0.5)
                .foregroundStyle(Theme.Colors.foreground)

            if let subtitle, !subtitle.isEmpty {
                Button {
                    onTapSubtitle?()
                } label: {
                    HStack(spacing: 3) {
                        Text(subtitle)
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(1)
                        if onTapSubtitle != nil {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.Colors.mutedForeground)
                        }
                    }
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onTapSubtitle == nil)
                .accessibilityHint(onTapSubtitle == nil ? "" : "Changes which mailbox is shown")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

/// Pull to refresh that matches the rest of the chrome rather than the system's tinted
/// spinner. Wraps `refreshable`, which already handles the gesture and the async wait.
struct RefreshableScroll<Content: View>: View {
    let onRefresh: () async -> Void
    @Binding var offset: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            ScrollOffsetProbe()
            content()
        }
        .coordinateSpace(name: "scroll")
        .onPreferenceChange(ScrollOffsetKey.self) { offset = $0 }
        .refreshable { await onRefresh() }
        .scrollDismissesKeyboard(.interactively)
    }
}
