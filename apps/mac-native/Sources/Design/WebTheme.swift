import SwiftUI
import AppKit

// The web build's design tokens (src/web/index.css), verbatim. Everything on the Mac is
// drawn from these so the two clients are one design rather than two approximations.

enum W {
    // MARK: Colours

    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    private static func hex(_ h: String) -> NSColor {
        var s = h; if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    private static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    // Notion-like light palette / dark palette, strictly grayscale.
    static let background = dyn(hex("#ffffff"), hex("#191919"))
    static let foreground = dyn(hex("#37352f"), hex("#d4d4d4"))
    static let card = dyn(hex("#ffffff"), hex("#1f1f1f"))
    static let popover = dyn(hex("#ffffff"), hex("#252525"))
    static let primary = foreground
    static let primaryForeground = background
    static let secondary = dyn(rgba(55, 53, 47, 0.06), rgba(255, 255, 255, 0.055))
    static let muted = secondary
    static let mutedForeground = dyn(rgba(55, 53, 47, 0.65), rgba(255, 255, 255, 0.55))
    static let tertiary = dyn(rgba(55, 53, 47, 0.45), rgba(255, 255, 255, 0.38))
    static let accent = dyn(rgba(55, 53, 47, 0.08), rgba(255, 255, 255, 0.08))
    static let border = dyn(rgba(55, 53, 47, 0.09), rgba(255, 255, 255, 0.094))
    static let input = secondary
    static let ring = dyn(rgba(55, 53, 47, 0.3), rgba(255, 255, 255, 0.3))
    static let sidebar = dyn(hex("#f7f7f5"), hex("#202020"))
    static let sidebarAccent = accent
    /// `bg-black/10`, the dialog and sheet overlay (`DialogOverlay` in ui/dialog.tsx).
    static let overlay = Color.black.opacity(0.10)
    /// `ring-foreground/10`, the popover edge.
    static let popoverRing = dyn(rgba(55, 53, 47, 0.10), rgba(212, 212, 212, 0.10))
    /// `text-foreground/80` and `/90`.
    static let foreground80 = dyn(rgba(55, 53, 47, 0.80), rgba(212, 212, 212, 0.80))
    static let foreground90 = dyn(rgba(55, 53, 47, 0.90), rgba(212, 212, 212, 0.90))
    /// `bg-muted/40`, the card wash.
    static let muted40 = dyn(rgba(55, 53, 47, 0.024), rgba(255, 255, 255, 0.022))
    static let muted50 = dyn(rgba(55, 53, 47, 0.03), rgba(255, 255, 255, 0.0275))
    static let muted60 = dyn(rgba(55, 53, 47, 0.036), rgba(255, 255, 255, 0.033))
    /// Skeleton blocks.
    static let skeleton = accent

    /// The resolved NSColors, for AppKit-hosted views (the message web view's CSS).
    static func css(dark: Bool) -> (fg: String, bg: String, muted: String, border: String) {
        dark ? ("#d4d4d4", "#191919", "rgba(255,255,255,.55)", "rgba(255,255,255,.094)")
             : ("#37352f", "#ffffff", "rgba(55,53,47,.65)", "rgba(55,53,47,.09)")
    }

    // MARK: Radii (`--radius: .375rem`)

    static let radiusSm: CGFloat = 2    // rounded-sm
    static let radiusMd: CGFloat = 4    // rounded-md
    static let radiusLg: CGFloat = 6    // rounded-lg
    static let radiusXl: CGFloat = 10   // rounded-xl
    static let radius2xl: CGFloat = 16  // rounded-2xl

    // MARK: Type (Geist)

    static func font(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { Geist.font(size: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { Geist.font(size: size, weight: weight, mono: true) }
    /// `text-xs`, `text-sm`, `text-[13px]`, `text-base`.
    static let xs = font(12)
    static let sm = font(14)
    static let s13 = font(13)
    static let base = font(16)
}

/// Geist and Geist Mono, registered from the bundle at launch and instantiated with the
/// weight axis set, since the files are variable fonts.
enum Geist {
    private static var cache: [String: NSFont] = [:]
    private static let lock = NSLock()
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        for name in ["Geist[wght]", "GeistMono[wght]"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    static func nsFont(size: CGFloat, weight: CGFloat, mono: Bool = false) -> NSFont {
        register()
        let key = "\(mono ? "m" : "s")\(size)-\(weight)"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let family = mono ? "Geist Mono" : "Geist"
        let wght = NSNumber(value: 0x77676874) // 'wght'
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .variation: [wght: weight],
        ])
        let font = NSFont(descriptor: descriptor, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: NSFont.Weight(rawValue: (weight - 400) / 300))
        cache[key] = font
        return font
    }

    static func font(size: CGFloat, weight: CGFloat, mono: Bool = false) -> Font {
        Font(nsFont(size: size, weight: weight, mono: mono))
    }
}

// MARK: - Small modifiers the web's utility classes map onto

extension View {
    /// `tracking-[-0.02em]` etc., given in em.
    func trackingEm(_ em: CGFloat, size: CGFloat) -> some View { tracking(em * size) }

    /// A 1pt inset border in the given colour, `border border-border`.
    func border1(_ color: Color = W.border, radius: CGFloat = W.radiusMd) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: 1))
    }

    func rounded(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// `divide-y` / `border-b`: a hairline on one edge.
    func edgeLine(_ edge: Edge, _ color: Color = W.border) -> some View {
        overlay(alignment: edge == .top ? .top : edge == .bottom ? .bottom : edge == .leading ? .leading : .trailing) {
            if edge == .top || edge == .bottom {
                Rectangle().fill(color).frame(height: 1)
            } else {
                Rectangle().fill(color).frame(width: 1)
            }
        }
    }

    /// `truncate`.
    func truncate() -> some View { lineLimit(1).truncationMode(.tail) }
}

/// The web's `tnum` utility.
extension Text {
    func tnum() -> Text { monospacedDigit() }
}
