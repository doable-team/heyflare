import SwiftUI

/// The heyflare mark, drawn from the same geometry as `public/logo.svg` so the app, the
/// web build and the icon are one shape rather than three approximations.
///
/// The source is a 64pt viewBox: a rounded plate, a lowercase "h" stroked at 7pt with
/// round caps, and a dot. Everything below is that path scaled, so the mark stays exact
/// at any size instead of being a bitmap that softens.
struct HeyflareMark: View {
    var size: CGFloat = 20
    /// The plate. Inverts with the theme, like everything else in the app.
    var plate: Color = Theme.Colors.foreground
    var ink: Color = Theme.Colors.background

    private var scale: CGFloat { size / 64 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                .fill(plate)

            // The "h": a stem, then a shoulder that turns down into the second leg.
            Path { path in
                path.move(to: point(21, 15))
                path.addLine(to: point(21, 49))

                path.move(to: point(21, 37))
                path.addCurve(to: point(39, 37), control1: point(21, 28), control2: point(39, 28))
                path.addLine(to: point(39, 49))
            }
            .stroke(ink, style: StrokeStyle(lineWidth: 7 * scale, lineCap: .round, lineJoin: .round))

            // The dot.
            Circle()
                .fill(ink)
                .frame(width: 9 * scale, height: 9 * scale)
                .offset(x: (47 - 32) * scale, y: (17 - 32) * scale)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
}
