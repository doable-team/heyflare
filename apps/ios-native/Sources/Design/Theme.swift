import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The design system from DESIGN.md, expressed natively. Strictly grayscale: no colour
// carries meaning anywhere in this app. Destructive actions are named, not tinted.
//
// The web build self-hosts Geist. On the phone we use SF Pro instead: it is the system
// face, it ships with iOS at every optical size, and it costs nothing to load. The scale
// and the weights below are Geist's, so the two clients read the same.

enum Theme {

    // MARK: - Colour

    /// Semantic tokens, mapped to an asset-free grayscale ramp that flips with the system theme.
    enum Colors {
        static let background = Platform.dynamic(light: (1.0, 1), dark: (0.055, 1))
        static let foreground = Platform.dynamic(light: (0.09, 1), dark: (0.98, 1))
        static let muted = Platform.dynamic(light: (0.96, 1), dark: (0.16, 1))
        static let mutedForeground = Platform.dynamic(light: (0.45, 1), dark: (0.63, 1))
        static let border = Platform.dynamic(light: (0, 0.10), dark: (1, 0.12))
        static let card = Platform.dynamic(light: (1.0, 1), dark: (0.09, 1))
        /// The pressed / selected wash behind a row.
        static let accent = Platform.dynamic(light: (0, 0.045), dark: (1, 0.07))
        /// Bars that sit over scrolling content.
        static let chrome = Platform.dynamic(light: (1.0, 0.86), dark: (0.055, 0.86))
    }

    // MARK: - Type

    /// DESIGN.md's scale: 11 caps, 12, 13, 14 default, 16, 20/600, 24/600, 30/600.
    enum Typography {
        static let caps = Font.system(size: 11, weight: .semibold)
        static let micro = Font.system(size: 12, weight: .regular)
        static let small = Font.system(size: 13, weight: .regular)
        static let body = Font.system(size: 15, weight: .regular)
        static let bodyStrong = Font.system(size: 15, weight: .semibold)
        static let bodyMedium = Font.system(size: 15, weight: .medium)
        static let large = Font.system(size: 16, weight: .regular)
        static let section = Font.system(size: 20, weight: .semibold)
        static let title = Font.system(size: 28, weight: .bold)
        static let threadSubject = Font.system(size: 22, weight: .bold)
        static let compactTitle = Font.system(size: 17, weight: .semibold)
        static let mono = Font.system(size: 13, design: .monospaced)
    }

    // MARK: - Metrics

    enum Metrics {
        static let radius: CGFloat = 10
        static let smallRadius: CGFloat = 6
        static let rowHeight: CGFloat = 76
        static let denseRowHeight: CGFloat = 56
        static let tabBarHeight: CGFloat = 52
        static let topBarHeight: CGFloat = 44
        static let hPadding: CGFloat = 16
        static let avatar: CGFloat = 38
        static let smallAvatar: CGFloat = 28
        /// Swipe distance at which a row action commits.
        static let swipeCommit: CGFloat = 96
        static let minTouchTarget: CGFloat = 44
    }

    // MARK: - Motion

    enum Motion {
        /// Screen pushes and sheet presentations.
        static let navigation = Animation.spring(response: 0.34, dampingFraction: 0.88)
        /// Rows leaving a list after an action.
        static let rowExit = Animation.spring(response: 0.30, dampingFraction: 0.86)
        /// Anything that is just a state flip.
        static let quick = Animation.easeOut(duration: 0.14)
    }

    /// Unified-inbox account marks, in connection order. Monochrome by design.
    static let accountGlyphs = ["●", "■", "▲", "◆", "✦", "✚", "✖"]

    static func glyph(forAccountIndex index: Int) -> String {
        guard index >= 0 else { return "●" }
        return accountGlyphs[index % accountGlyphs.count]
    }
}

// MARK: - Shared view helpers

extension View {
    /// A hairline that stays one physical pixel at any scale.
    func hairline(_ edge: Edge.Set = .bottom) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            Rectangle()
                .fill(Theme.Colors.border)
                .frame(height: 1 / Platform.scale)
        }
    }

    /// Applies to every full-screen surface so the grayscale ground is explicit.
    func screenBackground() -> some View {
        background(Theme.Colors.background.ignoresSafeArea())
    }

    @ViewBuilder
    func hidden(_ condition: Bool) -> some View {
        if condition { EmptyView() } else { self }
    }
}

// MARK: - Haptics

/// Physical confirmation for the gestures that commit something: a swipe that files a
/// thread, a screener decision, a send. Kept in one place so the vocabulary stays small.
/// A Mac has no taptic engine worth speaking of; the calls stay so the shared code reads
/// the same, and only the threshold tick reaches the trackpad.
enum Haptics {
    #if canImport(UIKit)
    private static let selection = UISelectionFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .medium)
    private static let notice = UINotificationFeedbackGenerator()

    /// The moment a swipe passes its commit threshold.
    static func threshold() {
        impact.prepare()
        impact.impactOccurred(intensity: 0.7)
    }

    static func select() { selection.selectionChanged() }
    static func success() { notice.notificationOccurred(.success) }
    static func warning() { notice.notificationOccurred(.warning) }
    #else
    static func threshold() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    static func select() {}
    static func success() {}
    static func warning() {}
    #endif
}
