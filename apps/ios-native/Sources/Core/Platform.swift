import SwiftUI
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// The handful of facts about the host that the shared code needs and the two
/// frameworks spell differently. Everything platform-specific in Core and Design goes
/// through here, so a screen never has to know which framework is underneath.
enum Platform {
    /// Points per pixel on the main display, for hairlines and for the size a bitmap is
    /// decoded at.
    static var scale: CGFloat {
        #if canImport(UIKit)
        return UIScreen.main.scale
        #else
        return NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }

    /// A grayscale colour that follows the system appearance, expressed once for both
    /// frameworks. `light`/`dark` are white levels; `alpha` lets a colour be a wash.
    static func dynamic(light: (white: CGFloat, alpha: CGFloat), dark: (white: CGFloat, alpha: CGFloat)) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: dark.white, alpha: dark.alpha)
                : UIColor(white: light.white, alpha: light.alpha)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: dark.white, alpha: dark.alpha)
                : NSColor(white: light.white, alpha: light.alpha)
        })
        #endif
    }

    /// Puts text on the system pasteboard.
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension Image {
    init(platformImage image: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: image)
        #else
        self.init(nsImage: image)
        #endif
    }
}
