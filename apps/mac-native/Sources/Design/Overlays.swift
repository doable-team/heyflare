import SwiftUI
import AppKit

// Popovers, dropdown menus, tooltips, dialogs, the right-hand sheet and toasts — all drawn
// inside the window as overlays so they look like the web's (radix / sonner) ones rather
// than AppKit's.

// MARK: - Popover layer

enum PopSide { case bottom, top, right, left }
enum PopAlign { case start, end, center }

struct Pop: Identifiable {
    let id: String
    var anchor: CGRect
    var side: PopSide
    var align: PopAlign
    var offset: CGFloat
    var content: AnyView
}

@MainActor
@Observable
final class PopLayerState {
    static let shared = PopLayerState()
    var stack: [Pop] = []
    /// Anchor frames in the window's coordinate space, kept by id.
    @ObservationIgnored var frames: [String: CGRect] = [:]
    /// When a popover closes, the button that opened it reads this to drop its expanded look.
    var openIDs: Set<String> = []

    func open<Content: View>(_ id: String, side: PopSide = .bottom, align: PopAlign = .start, offset: CGFloat = 4, @ViewBuilder content: () -> Content) {
        let anchor = frames[id] ?? CGRect(x: 100, y: 100, width: 0, height: 0)
        if let i = stack.firstIndex(where: { $0.id == id }) { stack.remove(at: i) }
        stack.append(Pop(id: id, anchor: anchor, side: side, align: align, offset: offset, content: AnyView(content())))
        openIDs.insert(id)
        TooltipState.shared.hideAll()
    }

    func toggle<Content: View>(_ id: String, side: PopSide = .bottom, align: PopAlign = .start, offset: CGFloat = 4, @ViewBuilder content: () -> Content) {
        if isOpen(id) { close(id) } else { open(id, side: side, align: align, offset: offset, content: content) }
    }

    func close(_ id: String) {
        stack.removeAll { $0.id == id }
        openIDs.remove(id)
    }

    func closeTop() {
        if let last = stack.popLast() { openIDs.remove(last.id) }
    }

    func closeAll() {
        stack.removeAll()
        openIDs.removeAll()
    }

    func isOpen(_ id: String) -> Bool { openIDs.contains(id) }
}

/// Records the view's frame (window coordinates) under `id`, so a popover can be placed by it.
struct PopAnchor: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { PopLayerState.shared.frames[id] = geo.frame(in: .named("window")) }
                    .onChange(of: geo.frame(in: .named("window"))) { _, f in PopLayerState.shared.frames[id] = f }
            }
        )
    }
}

extension View {
    func popAnchor(_ id: String) -> some View { modifier(PopAnchor(id: id)) }
}

/// Drawn once at the top of the window: a click-catcher under each open popover, then the
/// popovers themselves, positioned by their anchors and kept inside the window.
struct PopLayer: View {
    @Environment(PopLayerState.self) private var pops

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if !pops.stack.isEmpty {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { pops.closeAll() }
                }
                ForEach(pops.stack) { pop in
                    PopPositioned(pop: pop, bounds: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(!pops.stack.isEmpty)
    }
}

private struct PopPositioned: View {
    let pop: Pop
    let bounds: CGSize
    @State private var size: CGSize = .zero

    var body: some View {
        pop.content
            .fixedSize()
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } })
            .offset(x: x, y: y)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var horizontal: Bool { pop.side == .bottom || pop.side == .top }

    private var x: CGFloat {
        var v: CGFloat
        if horizontal {
            switch pop.align {
            case .start: v = pop.anchor.minX
            case .end: v = pop.anchor.maxX - size.width
            case .center: v = pop.anchor.midX - size.width / 2
            }
        } else {
            // `side="right"` / `"left"`: beside the trigger.
            v = pop.side == .right ? pop.anchor.maxX + pop.offset : pop.anchor.minX - size.width - pop.offset
            if v + size.width > bounds.width - 8 { v = pop.anchor.minX - size.width - pop.offset }
        }
        return max(8, min(v, bounds.width - size.width - 8))
    }

    private var y: CGFloat {
        var v: CGFloat
        if horizontal {
            switch pop.side {
            case .bottom: v = pop.anchor.maxY + pop.offset
            default: v = pop.anchor.minY - size.height - pop.offset
            }
            if v + size.height > bounds.height - 8 { v = pop.anchor.minY - size.height - pop.offset }
        } else {
            switch pop.align {
            case .start: v = pop.anchor.minY
            case .end: v = pop.anchor.maxY - size.height
            case .center: v = pop.anchor.midY - size.height / 2
            }
            if v + size.height > bounds.height - 8 { v = bounds.height - size.height - 8 }
        }
        return max(8, v)
    }
}

/// `DropdownMenuContent` / `PopoverContent` chrome: rounded-lg, popover colour, ring, shadow, p-1.
struct PopCard<Content: View>: View {
    var width: CGFloat? = nil
    var padding: CGFloat = 4
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(width: width)
            .background(W.popover)
            .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.popoverRing, lineWidth: 1))
            .rounded(W.radiusLg)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// `DropdownMenuItem`: 28pt, px-1.5, gap-1.5, text-sm, hover bg-accent. A radio item
/// (`checked != nil`) reserves `pr-8` and draws its check at `right-2`, as the web does.
struct MenuItem: View {
    let label: String
    var icon: String?
    /// `<span class="w-4 text-center text-[10px]">`: the account switcher's letter glyph, an
    /// inline neighbour of the label rather than an icon — was drawn as an `.overlay` sitting
    /// on top of the email text, which is why the two used to run into each other.
    var glyph: String?
    var shortcut: String?
    var checked: Bool? = nil
    var disabled = false
    /// A menu closes every popover when a row is picked. A select that lives *inside* another
    /// popover (the time list under "Pick a date…") must only close itself, or the parent and
    /// the choice go with it.
    var closesAll = true
    var trailing: AnyView? = nil
    var action: () -> Void
    @State private var hovering = false
    @Environment(PopLayerState.self) private var pops

    init(_ label: String, icon: String? = nil, glyph: String? = nil, shortcut: String? = nil, checked: Bool? = nil, disabled: Bool = false, closesAll: Bool = true, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.glyph = glyph; self.shortcut = shortcut; self.checked = checked; self.disabled = disabled; self.closesAll = closesAll; self.action = action
    }

    var body: some View {
        Button {
            guard !disabled else { return }
            if closesAll { pops.closeAll() }
            action()
        } label: {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 16).foregroundStyle(hovering ? W.foreground : W.mutedForeground) }
                if let glyph { Text(glyph).font(W.font(10)).foregroundStyle(W.mutedForeground).frame(width: 16, alignment: .center) }
                Text(label).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                Spacer(minLength: 12)
                // `DropdownMenuShortcut`: text-xs tracking-widest.
                if let shortcut { Text(shortcut).font(W.xs).tracking(1.2).foregroundStyle(W.mutedForeground) }
            }
            .padding(.leading, 6)
            .padding(.trailing, checked != nil ? 32 : 6)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if let checked {
                    Icon("check", size: 16).opacity(checked ? 1 : 0).padding(.trailing, 8)
                }
            }
            .background(hovering && !disabled ? W.accent : Color.clear)
            .rounded(W.radiusMd)
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// `DropdownMenuLabel`: px-1.5 py-1 text-xs font-medium text-muted-foreground.
struct MenuLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuSeparator: View {
    var body: some View { Rectangle().fill(W.border).frame(height: 1).padding(.vertical, 4).padding(.horizontal, -4) }
}

// MARK: - Tooltips (radix)

/// The web's `TooltipProvider delayDuration={300}`: a dark bubble that appears after 300 ms
/// of hovering, at once when another tooltip closed within the last 300 ms
/// (`skipDelayDuration`), and goes on click or when the pointer leaves.
@MainActor
@Observable
final class TooltipState {
    static let shared = TooltipState()
    struct Tip: Identifiable {
        let id: String
        let anchor: CGRect
        let text: String
        let kbd: String?
        let side: PopSide
    }
    var current: Tip?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var lastClosed = Date.distantPast
    @ObservationIgnored var frames: [String: CGRect] = [:]

    func hover(_ id: String, text: String, kbd: String?, side: PopSide) {
        pending?.cancel()
        let tip = Tip(id: id, anchor: frames[id] ?? .zero, text: text, kbd: kbd, side: side)
        if Date().timeIntervalSince(lastClosed) < 0.3 || current != nil {
            current = tip
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.current = Tip(id: id, anchor: self.frames[id] ?? tip.anchor, text: text, kbd: kbd, side: side)
        }
    }

    func leave(_ id: String) {
        pending?.cancel()
        pending = nil
        if current?.id == id { current = nil; lastClosed = Date() }
    }

    func hideAll() {
        pending?.cancel()
        pending = nil
        if current != nil { current = nil; lastClosed = Date() }
    }
}

struct WebTooltip: ViewModifier {
    let text: String?
    let kbd: String?
    let side: PopSide
    let enabled: Bool
    @State private var id = UUID().uuidString

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { TooltipState.shared.frames[id] = geo.frame(in: .named("window")) }
                        .onChange(of: geo.frame(in: .named("window"))) { _, f in TooltipState.shared.frames[id] = f }
                }
            )
            .onHover { over in
                guard let text, enabled, !text.isEmpty else { TooltipState.shared.leave(id); return }
                if over { TooltipState.shared.hover(id, text: text, kbd: kbd, side: side) } else { TooltipState.shared.leave(id) }
            }
            // radix closes the tooltip on pointer-down of its trigger.
            .simultaneousGesture(TapGesture().onEnded { TooltipState.shared.hideAll() })
            .onChange(of: enabled) { _, on in if !on { TooltipState.shared.leave(id) } }
            .onDisappear { TooltipState.shared.leave(id) }
    }
}

extension View {
    /// `<Tooltip><TooltipTrigger/><TooltipContent side>text <Kbd/></TooltipContent></Tooltip>`.
    func webTooltip(_ text: String?, kbd: String? = nil, side: PopSide = .top, enabled: Bool = true) -> some View {
        modifier(WebTooltip(text: text, kbd: kbd, side: side, enabled: enabled))
    }
}

/// `TooltipContent`: `bg-foreground text-background text-xs px-3 py-1.5 rounded-md gap-1.5`,
/// with a 10pt rotated-square arrow toward the trigger. Drawn once at the top of the window.
struct TooltipLayer: View {
    @Environment(TooltipState.self) private var tips

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let tip = tips.current {
                    TooltipBubble(tip: tip, bounds: geo.size)
                        .id(tip.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: tips.current?.id)
    }
}

private struct TooltipBubble: View {
    let tip: TooltipState.Tip
    let bounds: CGSize
    @State private var size: CGSize = .zero
    /// radix offsets the content by the arrow's height (`size-2.5` = 10).
    private let arrow: CGFloat = 10

    var body: some View {
        HStack(spacing: 6) {
            Text(tip.text).font(W.xs).foregroundStyle(W.background).lineLimit(1)
            if let kbd = tip.kbd { TooltipKbd(kbd) }
        }
        .padding(.leading, 12)
        .padding(.trailing, tip.kbd != nil ? 6 : 12)
        .padding(.vertical, 6)
        .frame(height: 28)
        .background(W.foreground)
        .rounded(W.radiusMd)
        .overlay(alignment: arrowAlignment) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(W.foreground)
                .frame(width: arrow, height: arrow)
                .rotationEffect(.degrees(45))
                .offset(arrowOffset)
        }
        .fixedSize()
        .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } })
        .offset(x: x, y: y)
    }

    private var arrowAlignment: Alignment {
        switch tip.side {
        case .top: return .bottom
        case .bottom: return .top
        case .right: return .leading
        case .left: return .trailing
        }
    }

    /// `translate-y-[calc(-50%_-_2px)]`: the square's centre sits 2pt inside the bubble's edge.
    private var arrowOffset: CGSize {
        switch tip.side {
        case .top: return CGSize(width: 0, height: arrow / 2 - 2)
        case .bottom: return CGSize(width: 0, height: -(arrow / 2 - 2))
        case .right: return CGSize(width: -(arrow / 2 - 2), height: 0)
        case .left: return CGSize(width: arrow / 2 - 2, height: 0)
        }
    }

    private var x: CGFloat {
        var v: CGFloat
        switch tip.side {
        case .top, .bottom: v = tip.anchor.midX - size.width / 2
        case .right: v = tip.anchor.maxX + arrow
        case .left: v = tip.anchor.minX - size.width - arrow
        }
        return max(4, min(v, bounds.width - size.width - 4))
    }

    private var y: CGFloat {
        var v: CGFloat
        switch tip.side {
        case .top: v = tip.anchor.minY - size.height - arrow
        case .bottom: v = tip.anchor.maxY + arrow
        case .right, .left: v = tip.anchor.midY - size.height / 2
        }
        return max(4, min(v, bounds.height - size.height - 4))
    }
}

/// `Kbd` inside a tooltip: `bg-background/20 text-background` (`/10` in the dark theme).
private struct TooltipKbd: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(W.font(12, 500))
            .foregroundStyle(W.background)
            .padding(.horizontal, 4)
            .frame(height: 20)
            .frame(minWidth: 20)
            .background(W.background.opacity(scheme == .dark ? 0.1 : 0.2))
            .rounded(W.radiusSm)
    }
}

// MARK: - Dialogs

@MainActor
@Observable
final class DialogState {
    static let shared = DialogState()
    struct Entry: Identifiable { let id: String; let width: CGFloat; let dismissible: Bool; let content: AnyView }
    var stack: [Entry] = []

    func present<Content: View>(_ id: String, width: CGFloat = 384, dismissible: Bool = true, @ViewBuilder content: () -> Content) {
        stack.removeAll { $0.id == id }
        stack.append(Entry(id: id, width: width, dismissible: dismissible, content: AnyView(content())))
        TooltipState.shared.hideAll()
    }
    func dismiss(_ id: String) { stack.removeAll { $0.id == id } }
    /// Escape: the top dialog goes, unless it was presented as one that must be finished.
    func dismissTop() { if stack.last?.dismissible ?? false { _ = stack.popLast() } }
    /// The dialog's own close button: the web's `DialogClose` always closes.
    func closeTop() { _ = stack.popLast() }
    var isOpen: Bool { !stack.isEmpty }
}

/// A dialog's content can ask for a width other than the one it was presented with
/// (`AlertDialogContent size="sm"` is `max-w-xs`, 320, whoever presents it).
struct DialogWidthKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// `DialogContent`: centred, rounded-xl, popover colour, ring, over a `bg-black/10` overlay.
struct DialogLayer: View {
    @Environment(DialogState.self) private var dialogs
    @State private var widths: [String: CGFloat] = [:]

    var body: some View {
        ZStack {
            ForEach(dialogs.stack) { entry in
                W.overlay
                    .ignoresSafeArea()
                    .onTapGesture { if entry.dismissible { dialogs.dismiss(entry.id) } }
                entry.content
                    .onPreferenceChange(DialogWidthKey.self) { widths[entry.id] = $0 }
                    .frame(width: widths[entry.id] ?? entry.width)
                    .background(W.popover)
                    .overlay(RoundedRectangle(cornerRadius: W.radiusXl, style: .continuous).strokeBorder(W.popoverRing, lineWidth: 1))
                    .rounded(W.radiusXl)
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeOut(duration: 0.1), value: dialogs.stack.count)
    }
}

/// `Confirm` (`AlertDialogContent size="sm"`): a centred title and description, then two
/// equal-width buttons on a `bg-muted/50 border-t` strip. 320 wide.
struct AlertDialogView: View {
    let title: String
    var description: String?
    var cancel = "Cancel"
    let action: String
    var actionVariant: WVariant = .default
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(title).font(W.font(16, 500)).webLine(16, 24, weight: 500).foregroundStyle(W.foreground).multilineTextAlignment(.center)
                if let description {
                    Text(description).font(W.sm).webLine(14).foregroundStyle(W.mutedForeground).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            HStack(spacing: 8) {
                WButton(cancel, variant: .outline, fullWidth: true, action: onCancel)
                WButton(action, variant: actionVariant, fullWidth: true, action: onConfirm)
            }
            .padding(16)
            .background(W.muted50)
            .edgeLine(.top)
        }
        .preference(key: DialogWidthKey.self, value: 320)
    }
}

extension DialogState {
    func confirm(_ id: String = "confirm", title: String, description: String? = nil, cancel: String = "Cancel", action: String, onConfirm: @escaping () -> Void) {
        present(id, width: 320) {
            AlertDialogView(title: title, description: description, cancel: cancel, action: action,
                            onConfirm: { self.dismiss(id); onConfirm() },
                            onCancel: { self.dismiss(id) })
        }
    }
}

/// `Modal`: a title (leading-none), description, form content, a close button at the top
/// right and the `DialogFooter` strip (`-mx-4 -mb-4 border-t bg-muted/50 p-4`).
struct FormDialog<Content: View, Footer: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(W.font(16, 500)).webLine(16, 16, weight: 500).foregroundStyle(W.foreground)
                if let description { Text(description).font(W.sm).webLine(14).foregroundStyle(W.mutedForeground).padding(.top, 8).fixedSize(horizontal: false, vertical: true) }
                content().padding(.top, 16)
            }
            .padding(16)
            HStack(spacing: 8) { Spacer(); footer() }
                .padding(16)
                .background(W.muted50)
                .edgeLine(.top)
        }
        .overlay(alignment: .topTrailing) {
            WButton(icon: "x", variant: .ghost, size: .iconSm) { DialogState.shared.closeTop() }.padding(8)
        }
    }
}

// MARK: - Sheet (right)

@MainActor
@Observable
final class SheetState {
    static let shared = SheetState()
    var content: AnyView?
    var title = ""
    var width: CGFloat = 600
    var onRequestClose: (() -> Void)?
    var isOpen: Bool { content != nil }

    func present<Content: View>(title: String, width: CGFloat = 600, onRequestClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.width = width
        self.onRequestClose = onRequestClose
        self.content = AnyView(content())
        TooltipState.shared.hideAll()
    }
    func dismiss() { content = nil; onRequestClose = nil }
    func requestClose() { if let r = onRequestClose { r() } else { dismiss() } }
}

/// shadcn `Sheet side="right"`: a 600pt panel over a `bg-black/10` overlay, 44pt header with
/// the title and a close button.
struct SheetLayer: View {
    @Environment(SheetState.self) private var sheet

    var body: some View {
        ZStack(alignment: .trailing) {
            if let content = sheet.content {
                W.overlay.ignoresSafeArea().onTapGesture { sheet.requestClose() }.transition(.opacity)
                VStack(spacing: 0) {
                    HStack {
                        Text(sheet.title).font(W.font(13, 500)).foregroundStyle(W.foreground)
                        Spacer()
                        WButton(icon: "x", variant: .ghost, size: .iconSm, muted: true) { sheet.requestClose() }
                    }
                    .padding(.leading, 16).padding(.trailing, 12)
                    .frame(height: 44)
                    .edgeLine(.bottom)
                    content
                }
                .frame(width: sheet.width)
                .frame(maxHeight: .infinity)
                .background(W.background)
                .edgeLine(.leading)
                .shadow(color: .black.opacity(0.2), radius: 24)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.2), value: sheet.isOpen)
    }
}

// MARK: - Toasts (sonner)

enum ToastKind { case info, success, error }

struct WToast: Identifiable, Equatable {
    let id: Int
    var title: String
    var description: String?
    var kind: ToastKind
    var action: (label: String, run: @MainActor () -> Void)?
    var duration: Double

    static func == (a: WToast, b: WToast) -> Bool { a.id == b.id }
}

@MainActor
@Observable
final class Toasts {
    static let shared = Toasts()
    private(set) var items: [WToast] = []
    private var next = 1
    private var timers: [Int: Task<Void, Never>] = [:]
    /// Sonner pauses every timer while the pointer is over the toaster, and resumes with the
    /// time that was left.
    private var deadlines: [Int: Date] = [:]
    private var remaining: [Int: Double] = [:]
    private var paused = false

    @discardableResult
    func show(_ title: String, description: String? = nil, kind: ToastKind = .info, duration: Double? = nil, action: (label: String, run: @MainActor () -> Void)? = nil) -> Int {
        let id = next; next += 1
        let d = duration ?? (kind == .error ? 7 : 4)
        let toast = WToast(id: id, title: title, description: description, kind: kind, action: action, duration: d)
        withAnimation(.easeOut(duration: 0.4)) { items.append(toast) }
        if items.count > 3 { dismiss(items[0].id) }
        if paused { remaining[id] = d } else { schedule(id, after: d) }
        return id
    }

    private func schedule(_ id: Int, after seconds: Double) {
        deadlines[id] = Date().addingTimeInterval(seconds)
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    func pause() {
        guard !paused else { return }
        paused = true
        for (id, deadline) in deadlines {
            timers[id]?.cancel()
            remaining[id] = max(0.5, deadline.timeIntervalSinceNow)
        }
        deadlines.removeAll()
    }

    func resume() {
        guard paused else { return }
        paused = false
        for (id, left) in remaining { schedule(id, after: left) }
        remaining.removeAll()
    }

    func success(_ title: String, description: String? = nil) { show(title, description: description, kind: .success) }
    func error(_ title: String, description: String? = nil) { show(title, description: description, kind: .error) }

    func dismiss(_ id: Int) {
        timers[id]?.cancel()
        timers[id] = nil
        deadlines[id] = nil
        remaining[id] = nil
        withAnimation(.easeOut(duration: 0.4)) { items.removeAll { $0.id == id } }
    }
}

/// `Toaster position="bottom-center"`: 356 wide, 24 from the bottom, 14 apart, popover
/// colour with a border, `rounded-md`, 16 padding, sonner's icons.
struct ToastLayer: View {
    @Environment(Toasts.self) private var toasts

    var body: some View {
        VStack(spacing: 14) {
            ForEach(toasts.items) { t in
                HStack(spacing: 6) {
                    if t.kind != .info {
                        SonnerIcon(kind: t.kind)
                            .padding(.leading, -3).padding(.trailing, 4)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(W.font(14, 500)).webLine(14, 21, weight: 500).foregroundStyle(W.foreground)
                        if let d = t.description { Text(d).font(W.sm).webLine(14, 19.6).foregroundStyle(W.mutedForeground) }
                    }
                    Spacer(minLength: 0)
                    if let a = t.action {
                        WButton(a.label, variant: .default, size: .xs) { toasts.dismiss(t.id); a.run() }
                    }
                }
                .padding(16)
                .frame(width: 356, alignment: .leading)
                .background(W.popover)
                .overlay(RoundedRectangle(cornerRadius: W.radiusMd, style: .continuous).strokeBorder(W.border, lineWidth: 1))
                .rounded(W.radiusMd)
                .shadow(color: .black.opacity(0.1), radius: 6, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onHover { over in if over { toasts.pause() } else { toasts.resume() } }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(!toasts.items.isEmpty)
    }
}

/// Sonner's default icons: heroicons' solid `check-circle` / `x-circle`, 20pt, in the text
/// colour with the mark cut out.
private struct SonnerIcon: View {
    let kind: ToastKind
    var body: some View {
        ZStack {
            Circle().fill(W.foreground).frame(width: 20, height: 20)
            Icon(kind == .error ? "x" : "check", size: 12, strokeWidth: 2.5).foregroundStyle(W.background)
        }
        .frame(width: 16, height: 16)
    }
}
