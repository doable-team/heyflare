import SwiftUI
import AppKit

// Popovers, dropdown menus, dialogs, the right-hand sheet and toasts — all drawn inside
// the window as overlays so they look like the web's (radix) ones rather than AppKit's.

// MARK: - Popover layer

enum PopSide { case bottom, top }
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

    private var x: CGFloat {
        var v: CGFloat
        switch pop.align {
        case .start: v = pop.anchor.minX
        case .end: v = pop.anchor.maxX - size.width
        case .center: v = pop.anchor.midX - size.width / 2
        }
        return max(8, min(v, bounds.width - size.width - 8))
    }

    private var y: CGFloat {
        var v: CGFloat
        switch pop.side {
        case .bottom: v = pop.anchor.maxY + pop.offset
        case .top: v = pop.anchor.minY - size.height - pop.offset
        }
        if v + size.height > bounds.height - 8 { v = pop.anchor.minY - size.height - pop.offset }
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

/// `DropdownMenuItem`: 28pt, px-1.5, gap-1.5, text-sm, hover bg-accent.
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
                if let checked {
                    Icon("check", size: 16).opacity(checked ? 1 : 0)
                }
                if let icon { Icon(icon, size: 16).foregroundStyle(hovering ? W.foreground : W.mutedForeground) }
                if let glyph { Text(glyph).font(W.font(10)).foregroundStyle(W.mutedForeground).frame(width: 16, alignment: .center) }
                Text(label).font(W.sm).foregroundStyle(W.foreground).lineLimit(1)
                Spacer(minLength: 12)
                if let shortcut { Text(shortcut).font(W.xs).foregroundStyle(W.mutedForeground) }
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && !disabled ? W.accent : Color.clear)
            .rounded(W.radiusMd)
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(W.font(12, 500)).foregroundStyle(W.mutedForeground)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuSeparator: View {
    var body: some View { Rectangle().fill(W.border).frame(height: 1).padding(.vertical, 4).padding(.horizontal, -4) }
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
    }
    func dismiss(_ id: String) { stack.removeAll { $0.id == id } }
    /// Escape: the top dialog goes, unless it was presented as one that must be finished.
    func dismissTop() { if stack.last?.dismissible ?? false { _ = stack.popLast() } }
    var isOpen: Bool { !stack.isEmpty }
}

/// `DialogContent`: centred, rounded-xl, popover colour, ring, p-4, over a 50% black overlay.
struct DialogLayer: View {
    @Environment(DialogState.self) private var dialogs

    var body: some View {
        ZStack {
            ForEach(dialogs.stack) { entry in
                W.overlay
                    .ignoresSafeArea()
                    .onTapGesture { if entry.dismissible { dialogs.dismiss(entry.id) } }
                entry.content
                    .frame(width: entry.width)
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

/// `AlertDialog`: title, description, Cancel + action.
struct AlertDialogView: View {
    let title: String
    var description: String?
    var cancel = "Cancel"
    let action: String
    var actionVariant: WVariant = .default
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(W.font(16, 500)).webLine(16, weight: 500).foregroundStyle(W.foreground)
            if let description { Text(description).font(W.sm).foregroundStyle(W.mutedForeground).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Spacer()
                WButton(cancel, variant: .outline, action: onCancel)
                WButton(action, variant: actionVariant, action: onConfirm)
            }
            .padding(.top, 8)
        }
        .padding(16)
    }
}

extension DialogState {
    func confirm(_ id: String = "confirm", title: String, description: String? = nil, cancel: String = "Cancel", action: String, onConfirm: @escaping () -> Void) {
        present(id) {
            AlertDialogView(title: title, description: description, cancel: cancel, action: action,
                            onConfirm: { self.dismiss(id); onConfirm() },
                            onCancel: { self.dismiss(id) })
        }
    }
}

/// A dialog with a title, description, form content and a footer.
struct FormDialog<Content: View, Footer: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(W.font(16, 500)).webLine(16, weight: 500).foregroundStyle(W.foreground)
            if let description { Text(description).font(W.sm).foregroundStyle(W.mutedForeground).padding(.top, 4).fixedSize(horizontal: false, vertical: true) }
            content().padding(.vertical, 20)
            HStack(spacing: 8) { Spacer(); footer() }
        }
        .padding(16)
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
    }
    func dismiss() { content = nil; onRequestClose = nil }
    func requestClose() { if let r = onRequestClose { r() } else { dismiss() } }
}

/// shadcn `Sheet side="right"`: a 600pt panel over a 50% overlay, 44pt header with the title
/// and a close button.
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
                        WButton(icon: "x", variant: .ghost, size: .iconSm, muted: true, help: "Close") { sheet.requestClose() }
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

    @discardableResult
    func show(_ title: String, description: String? = nil, kind: ToastKind = .info, duration: Double? = nil, action: (label: String, run: @MainActor () -> Void)? = nil) -> Int {
        let id = next; next += 1
        let d = duration ?? (kind == .error ? 7 : 4)
        let toast = WToast(id: id, title: title, description: description, kind: kind, action: action, duration: d)
        withAnimation(.easeOut(duration: 0.15)) { items.append(toast) }
        if items.count > 3 { dismiss(items[0].id) }
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(d))
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
        return id
    }

    func success(_ title: String, description: String? = nil) { show(title, description: description, kind: .success) }
    func error(_ title: String, description: String? = nil) { show(title, description: description, kind: .error) }

    func dismiss(_ id: Int) {
        timers[id]?.cancel()
        timers[id] = nil
        withAnimation(.easeOut(duration: 0.15)) { items.removeAll { $0.id == id } }
    }
}

/// Bottom-right stack, 356 wide, popover colour with a border, 16pt padding.
struct ToastLayer: View {
    @Environment(Toasts.self) private var toasts

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer()
            ForEach(toasts.items) { t in
                HStack(alignment: .top, spacing: 12) {
                    switch t.kind {
                    case .success: Icon("circleCheck", size: 16).padding(.top, 1)
                    case .error: Icon("octagonX", size: 16).padding(.top, 1)
                    case .info: EmptyView()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(W.font(13, 500)).foregroundStyle(W.foreground)
                        if let d = t.description { Text(d).font(W.xs).foregroundStyle(W.mutedForeground) }
                    }
                    Spacer(minLength: 0)
                    if let a = t.action {
                        WButton(a.label, variant: .default, size: .xs) { toasts.dismiss(t.id); a.run() }
                    }
                }
                .padding(16)
                .frame(width: 356, alignment: .leading)
                .background(W.popover)
                .overlay(RoundedRectangle(cornerRadius: W.radiusLg, style: .continuous).strokeBorder(W.border, lineWidth: 1))
                .rounded(W.radiusLg)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(!toasts.items.isEmpty)
    }
}
