import SwiftUI

// shadcn/ui's primitives (src/web/components/ui/*), drawn natively at the same sizes.

// MARK: - Button

enum WVariant { case `default`, outline, ghost, secondary, link }
enum WSize {
    case `default`, sm, xs, lg, icon, iconSm, iconXs

    var height: CGFloat {
        switch self {
        case .default, .icon: return 32
        case .sm, .iconSm: return 28
        case .xs, .iconXs: return 24
        case .lg: return 36
        }
    }
    var paddingX: CGFloat {
        switch self {
        case .default, .lg: return 10
        case .sm: return 10
        case .xs: return 8
        case .icon, .iconSm, .iconXs: return 0
        }
    }
    var gap: CGFloat {
        switch self {
        case .default, .lg: return 6
        default: return 4
        }
    }
    var fontSize: CGFloat {
        switch self {
        case .default, .lg, .icon: return 14
        case .sm, .iconSm: return 12.8
        case .xs, .iconXs: return 12
        }
    }
    var iconSize: CGFloat {
        switch self {
        case .default, .lg, .icon, .iconSm: return 16
        case .sm: return 14
        case .xs, .iconXs: return 12
        }
    }
    var radius: CGFloat {
        switch self {
        case .default, .lg, .icon: return W.radiusLg
        default: return W.radiusMd
        }
    }
    var isIcon: Bool {
        switch self { case .icon, .iconSm, .iconXs: return true; default: return false }
    }
}

/// `buttonVariants`: the label supplies its own icon + text; this gives it the frame,
/// the wash and the hover.
struct WButtonStyle: ButtonStyle {
    var variant: WVariant = .default
    var size: WSize = .default
    /// `text-muted-foreground` on a ghost button, which turns to foreground on hover.
    var muted = false
    /// `bg-muted` while a popover it owns is open (`aria-expanded`).
    var expanded = false

    func makeBody(configuration: Configuration) -> some View {
        WButtonBody(configuration: configuration, variant: variant, size: size, muted: muted, expanded: expanded)
    }
}

private struct WButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: WVariant
    let size: WSize
    let muted: Bool
    let expanded: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.wButtonSquare) private var square

    /// Inside a `ButtonGroup` the plate is square and the group rounds the row's ends.
    private var radius: CGFloat { square ? 0 : size.radius }

    var body: some View {
        configuration.label
            .font(W.font(size.fontSize, 500))
            .foregroundStyle(foreground)
            .padding(.horizontal, size.paddingX)
            .frame(height: size.height)
            .frame(minWidth: size.isIcon ? size.height : nil)
            .background(background)
            .overlay {
                if variant == .outline {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(W.border, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(enabled ? 1 : 0.5)
            .offset(y: configuration.isPressed && variant != .link ? 1 : 0)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private var foreground: Color {
        switch variant {
        case .default: return W.primaryForeground
        case .link: return W.primary
        default: return muted && !hovering && !expanded ? W.mutedForeground : W.foreground
        }
    }

    private var background: Color {
        switch variant {
        case .default: return hovering ? W.primary.opacity(0.8) : W.primary
        case .outline, .ghost: return hovering || expanded ? W.muted : .clear
        case .secondary: return W.secondary
        case .link: return .clear
        }
    }
}

extension ButtonStyle where Self == WButtonStyle {
    static func web(_ variant: WVariant = .default, _ size: WSize = .default, muted: Bool = false, expanded: Bool = false) -> WButtonStyle {
        WButtonStyle(variant: variant, size: size, muted: muted, expanded: expanded)
    }
}

/// `<Button variant size><Icon/> Label</Button>`
struct WButton: View {
    var label: String?
    var icon: String?
    var trailingIcon: String?
    var variant: WVariant = .default
    var size: WSize = .default
    var muted = false
    var expanded = false
    var fullWidth = false
    var kbd: String?
    var help: String?
    var action: () -> Void

    init(_ label: String? = nil, icon: String? = nil, trailingIcon: String? = nil, variant: WVariant = .default, size: WSize = .default, muted: Bool = false, expanded: Bool = false, fullWidth: Bool = false, kbd: String? = nil, help: String? = nil, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.trailingIcon = trailingIcon; self.variant = variant; self.size = size
        self.muted = muted; self.expanded = expanded; self.fullWidth = fullWidth; self.kbd = kbd; self.help = help; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: size.gap) {
                if let icon { Icon(icon, size: size.iconSize) }
                if let label { Text(label) }
                if let kbd { Kbd(kbd) }
                if let trailingIcon { Icon(trailingIcon, size: size.iconSize) }
            }
            // `w-full`: the plate has to grow, not just the space around it.
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.web(variant, size, muted: muted, expanded: expanded))
        .help(help ?? label ?? "")
    }
}

/// `ButtonGroup`: buttons that share edges. The web squares the inner corners and drops the
/// inner border (`rounded-l-none`, `border-l-0`); here the children draw square and the group
/// clips the outer radius, with a 1pt overlap so neighbouring borders land on one line.
struct ButtonGroup<Content: View>: View {
    var radius: CGFloat = W.radiusLg
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: -1) { content() }
            .environment(\.wButtonSquare, true)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct WButtonSquareKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Set by `ButtonGroup`: the plate keeps its size but gives up its own corners.
    var wButtonSquare: Bool {
        get { self[WButtonSquareKey.self] }
        set { self[WButtonSquareKey.self] = newValue }
    }
}

// MARK: - Kbd

struct Kbd: View {
    let text: String
    var onDark = false
    init(_ text: String, onDark: Bool = false) { self.text = text; self.onDark = onDark }

    var body: some View {
        Text(text)
            .font(W.font(12, 500))
            .foregroundStyle(onDark ? W.primaryForeground : W.mutedForeground)
            .padding(.horizontal, 4)
            .frame(height: 20)
            .frame(minWidth: 20)
            .background(onDark ? W.primaryForeground.opacity(0.2) : W.muted)
            .rounded(W.radiusSm)
    }
}

// MARK: - Badge

enum WBadgeVariant { case `default`, secondary, outline }

struct WBadge: View {
    var text: String
    var icon: String?
    var variant: WBadgeVariant = .secondary
    var muted = false
    var small = false
    var dot: Color?

    init(_ text: String, icon: String? = nil, variant: WBadgeVariant = .secondary, muted: Bool = false, small: Bool = false, dot: Color? = nil) {
        self.text = text; self.icon = icon; self.variant = variant; self.muted = muted; self.small = small; self.dot = dot
    }

    var body: some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            if let icon { Icon(icon, size: 12) }
            Text(text).lineLimit(1)
        }
        .font(W.font(small ? 10 : 12, muted ? 400 : 500))
        .foregroundStyle(variant == .default ? W.primaryForeground : (muted ? W.mutedForeground : W.foreground))
        .padding(.horizontal, small ? 4 : 8)
        .frame(height: small ? 16 : 20)
        .background(variant == .default ? W.primary : variant == .secondary ? W.secondary : Color.clear)
        .overlay {
            if variant == .outline { Capsule().strokeBorder(W.border, lineWidth: 1) }
        }
        .clipShape(Capsule())
    }
}

// MARK: - Input

/// shadcn `Input`: h-8 rounded-md bg-input px-2.5 text-sm; focus turns the wash into the
/// page colour with a ring border.
struct WTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var mono = false
    var height: CGFloat = 32
    var fontSize: CGFloat = 14
    var onSubmit: (() -> Void)?
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? W.mono(fontSize) : W.font(fontSize))
        .foregroundStyle(W.foreground)
        .focused($focused)
        .onSubmit { onSubmit?() }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(focused ? W.background : W.input)
        .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(focused ? W.ring : Color.clear, lineWidth: 1))
        .rounded(W.radiusMd)
        .onAppear { if autofocus { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } } }
    }
}

/// shadcn `Textarea`.
struct WTextArea: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 64
    var fontSize: CGFloat = 14
    var mono = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(mono ? W.mono(fontSize) : W.font(fontSize)).foregroundStyle(W.mutedForeground).padding(.horizontal, 10).padding(.vertical, 6)
            }
            TextEditor(text: $text)
                .font(mono ? W.mono(fontSize) : W.font(fontSize))
                .foregroundStyle(W.foreground)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        }
        .frame(minHeight: minHeight)
        .background(focused ? W.background : W.input)
        .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(focused ? W.ring : Color.clear, lineWidth: 1))
        .rounded(W.radiusMd)
    }
}

/// shadcn `Label` + a field.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    // `text-sm leading-none font-medium`: a 14pt box, not Geist's natural 18.2.
    var body: some View { Text(text).font(W.font(14, 500)).webLine(14, 14, weight: 500).foregroundStyle(W.foreground) }
}

// MARK: - Avatar

/// Notion-style avatar: 4px-rounded square, the photo when there is one, else initials.
struct WAvatar: View {
    let email: String
    var name: String = ""
    var src: String? = nil
    var size: CGFloat = 24
    var strong = false
    var selected = false
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            if selected {
                Icon("check", size: (size * 0.55).rounded(), strokeWidth: 2.5)
            } else if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Text(Fmt.initials(name, email))
                    .font(W.font(max(9, (size * 0.42).rounded()), 500))
            }
        }
        .foregroundStyle(strong || selected ? W.primaryForeground : W.foreground80)
        .frame(width: size, height: size)
        .background(strong || selected ? W.foreground : W.muted)
        .rounded(4)
        .task(id: src ?? "") {
            guard let src, !src.isEmpty, let url = URL(string: src) else { image = nil; return }
            image = await ImageCache.shared.image(for: url, maxPixel: size * 3)
        }
    }
}

extension WAvatar {
    init(_ address: Address, size: CGFloat = 24, strong: Bool = false, selected: Bool = false) {
        self.init(email: address.email, name: address.name, src: address.avatarURL, size: size, strong: strong, selected: selected)
    }
}

/// Overlapping avatars with a page-coloured ring, `AvatarStack`.
struct WAvatarStack: View {
    let people: [Address]
    var size: CGFloat = 20
    var max: Int = 3
    var plus = true

    var body: some View {
        let shown = Array(people.prefix(max))
        let rest = people.count - shown.count
        HStack(spacing: -6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                WAvatar(p, size: size)
                    .padding(2)
                    .background(W.background)
                    .rounded(6)
                    .zIndex(Double(i))
            }
            if plus && rest > 0 {
                Text("+\(rest)")
                    .font(W.font(Swift.max(9, (size * 0.4).rounded())))
                    .monospacedDigit()
                    .foregroundStyle(W.mutedForeground)
                    .frame(width: size, height: size)
                    .background(W.muted)
                    .rounded(4)
                    .padding(2)
                    .background(W.background)
                    .rounded(6)
            }
        }
    }
}

/// The tiny monochrome account mark (unified inbox).
struct AccountGlyph: View {
    let glyph: String?
    var body: some View {
        if let glyph, !glyph.isEmpty {
            Text(glyph).font(W.font(9)).foregroundStyle(W.mutedForeground)
        }
    }
}

// MARK: - Page chrome

/// `PageHeader`: 28px bold title, muted subtitle, actions at the end.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var titleIcon: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    if let titleIcon { Icon(titleIcon, size: 20).foregroundStyle(W.mutedForeground) }
                    Text(title)
                        .font(W.font(28, 700))
                        .tracking(-0.56)
                        .foregroundStyle(W.foreground)
                        .webLine(28, weight: 700)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(W.sm).webLine(14).foregroundStyle(W.mutedForeground).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) { actions() }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 24)
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, titleIcon: String? = nil) {
        self.init(title: title, subtitle: subtitle, titleIcon: titleIcon, actions: { EmptyView() })
    }
}

/// `SectionTitle`: 32pt row, 12px medium muted, count in tertiary.
struct SectionTitle<Actions: View>: View {
    let title: String
    var count: Int? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
            if let count, count > 0 {
                Text("\(count)").font(W.xs).monospacedDigit().foregroundStyle(W.tertiary)
            }
            Spacer(minLength: 0)
            actions()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .padding(.bottom, 2)
    }
}

extension SectionTitle where Actions == EmptyView {
    init(_ title: String, count: Int? = nil) { self.init(title: title, count: count, actions: { EmptyView() }) }
}

/// `EmptyState`: icon, a line, a muted line, an optional ghost action.
struct EmptyStateView<Action: View>: View {
    var icon: String? = nil
    let title: String
    var body_: String? = nil
    var compact = false
    @ViewBuilder var action: () -> Action

    init(icon: String? = nil, title: String, body: String? = nil, compact: Bool = false, @ViewBuilder action: @escaping () -> Action) {
        self.icon = icon; self.title = title; self.body_ = body; self.compact = compact; self.action = action
    }

    var body: some View {
        if compact {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(W.foreground80)
                if let body_ { Text(body_) }
                action().padding(.leading, 4)
            }
            .font(W.s13)
            .foregroundStyle(W.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 8) {
                if let icon { Icon(icon, size: 20).foregroundStyle(W.mutedForeground).padding(.bottom, 8) }
                Text(title).font(W.font(14, 500)).foregroundStyle(W.foreground)
                if let body_ { Text(body_).font(W.s13).foregroundStyle(W.mutedForeground).multilineTextAlignment(.center) }
                action().padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 64)
        }
    }
}

extension EmptyStateView where Action == EmptyView {
    init(icon: String? = nil, title: String, body: String? = nil, compact: Bool = false) {
        self.init(icon: icon, title: title, body: body, compact: compact, action: { EmptyView() })
    }
}

struct ErrorStateView: View {
    let message: String
    var title = "Something went sideways."
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(W.font(14, 500)).foregroundStyle(W.foreground)
            Text(message).font(W.mono(12)).foregroundStyle(W.mutedForeground).multilineTextAlignment(.center)
            if let retry { WButton("Try again", variant: .outline, size: .sm, action: retry).padding(.top, 8) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// `Skeleton` blocks in a row, pulsing.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = W.radiusMd
    @State private var on = false
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(W.skeleton)
            .frame(width: width, height: height)
            .opacity(on ? 0.5 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { on = true } }
    }
}

struct SkeletonRows: View {
    var rows = 6
    var compact = false
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { _ in
                GeometryReader { geo in
                    HStack(spacing: 12) {
                        if !compact { SkeletonBlock(width: 20, height: 20, radius: 4) }
                        SkeletonBlock(width: geo.size.width * 0.22)
                        SkeletonBlock(width: geo.size.width * 0.38)
                        Spacer()
                        SkeletonBlock(width: 40)
                    }
                    .frame(height: geo.size.height)
                }
                .frame(height: compact ? 40 : 44)
                .padding(.horizontal, 8)
            }
        }
    }
}

// MARK: - Toggle group, switch, checkbox

struct ToggleOption: Identifiable, Hashable {
    let id: String
    let label: String
    var icon: String? = nil
    var help: String? = nil
}

/// `ToggleGroup type="single"`; `outline` joins the items with a shared 1pt border.
struct WToggleGroup: View {
    let options: [ToggleOption]
    @Binding var value: String
    var outline = false
    var fontSize: CGFloat = 12.8
    var height: CGFloat = 28

    var body: some View {
        HStack(spacing: outline ? 0 : 4) {
            ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                let on = value == o.id
                Button {
                    value = o.id
                } label: {
                    HStack(spacing: 4) {
                        if let icon = o.icon { Icon(icon, size: 14) }
                        Text(o.label)
                    }
                    .font(W.font(fontSize, 500))
                    .foregroundStyle(on ? W.foreground : W.mutedForeground)
                    .padding(.horizontal, 10)
                    .frame(height: height)
                    .background(on ? (outline ? W.background : W.accent) : Color.clear)
                    .overlay {
                        if outline && on { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(o.help ?? o.label)
                .zIndex(on ? 1 : 0)
                .padding(.leading, outline && i > 0 ? -1 : 0)
            }
        }
        .padding(outline ? 0 : 0)
        .background {
            if outline { RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1) }
        }
    }
}

/// shadcn `Switch`: 32×18, thumb 16.
struct WSwitch: View {
    @Binding var on: Bool
    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { on.toggle() }
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? W.primary : W.input).frame(width: 32, height: 18)
                Circle().fill(on ? W.primaryForeground : W.foreground).frame(width: 14, height: 14).padding(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// shadcn `Checkbox`: 16×16, rounded 3, primary when checked.
struct WCheckbox: View {
    let checked: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(checked ? W.primary : W.input)
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(checked ? W.primary : W.border, lineWidth: 1)
                if checked { Icon("check", size: 12, strokeWidth: 2.5).foregroundStyle(W.primaryForeground) }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WSeparator: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(W.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// `animate-spin` for Loader2.
struct Spinner: View {
    var size: CGFloat = 16
    @State private var spinning = false
    var body: some View {
        Icon("loader2", size: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spinning = true } }
    }
}

/// A hover wash for a whole row (`hover:bg-muted`).
struct HoverRow<Content: View>: View {
    var radius: CGFloat = W.radiusMd
    var wash: Color = W.muted
    var active = false
    var activeWash: Color = W.accent
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .background(active ? activeWash : (hovering ? wash : Color.clear))
            .rounded(radius)
            .onHover { hovering = $0 }
    }
}
