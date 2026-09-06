import SwiftUI

// Shared with the Mac app. Views stay in Features/; everything here is platform-neutral.

/// Short-lived confirmations: "Set aside", "Moved to The Feed", with an Undo where the
/// action has an inverse. Sits above the tab bar so it never covers it.
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var undo: (@MainActor () async -> Void)?

        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, undo: (@MainActor () async -> Void)? = nil) {
        dismissTask?.cancel()
        withAnimation(Theme.Motion.navigation) { current = Toast(message: message, undo: undo) }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func error(_ message: String) {
        Haptics.warning()
        show(message)
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(Theme.Motion.quick) { current = nil }
    }
}

struct ToastView: View {
    let toast: ToastCenter.Toast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.background)
                .lineLimit(2)
            if toast.undo != nil {
                Button("Undo", action: onUndo)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.background)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Theme.Colors.foreground)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
        .padding(.horizontal, Theme.Metrics.hPadding)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
