import SwiftUI

/// A small SVG path-data parser: enough for lucide's icons (M L H V C S Q T A Z, absolute and
/// relative), with arcs converted to cubic Béziers. Parsed paths are cached by string.
enum SVGPath {
    private static var cache: [String: Path] = [:]
    private static let lock = NSLock()

    static func path(_ d: String) -> Path {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[d] { return cached }
        let parsed = parse(d)
        cache[d] = parsed
        return parsed
    }

    private static func parse(_ d: String) -> Path {
        var path = Path()
        let chars = Array(d.utf8)
        var i = 0
        var command: UInt8 = 0
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint? = nil
        var lastCommand: UInt8 = 0

        func skipSeparators() {
            while i < chars.count, chars[i] == 32 || chars[i] == 44 || chars[i] == 10 || chars[i] == 9 || chars[i] == 13 { i += 1 }
        }
        func number() -> CGFloat? {
            skipSeparators()
            let startIndex = i
            if i < chars.count, chars[i] == 45 || chars[i] == 43 { i += 1 }
            var seenDot = false
            var seenDigit = false
            while i < chars.count {
                let c = chars[i]
                if c >= 48 && c <= 57 { seenDigit = true; i += 1 }
                else if c == 46, !seenDot { seenDot = true; i += 1 }
                else if (c == 101 || c == 69), seenDigit { // exponent
                    i += 1
                    if i < chars.count, chars[i] == 45 || chars[i] == 43 { i += 1 }
                    while i < chars.count, chars[i] >= 48 && chars[i] <= 57 { i += 1 }
                    break
                } else { break }
            }
            guard seenDigit, let value = Double(String(decoding: chars[startIndex..<i], as: UTF8.self)) else { i = startIndex; return nil }
            return CGFloat(value)
        }
        func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == 48 || chars[i] == 49 else { return nil }
            let value = chars[i] == 49
            i += 1
            return value
        }
        func isCommand(_ c: UInt8) -> Bool {
            switch c {
            case 77, 109, 76, 108, 72, 104, 86, 118, 67, 99, 83, 115, 81, 113, 84, 116, 65, 97, 90, 122: return true
            default: return false
            }
        }

        while i < chars.count {
            skipSeparators()
            guard i < chars.count else { break }
            if isCommand(chars[i]) {
                command = chars[i]
                i += 1
            } else if command == 77 { command = 76 } else if command == 109 { command = 108 }
            // A command without a new letter repeats (M turns into L, per the spec).
            let relative = command >= 97
            switch command {
            case 77, 109: // M
                guard let x = number(), let y = number() else { i = chars.count; break }
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: current)
                start = current
                lastControl = nil
            case 76, 108: // L
                guard let x = number(), let y = number() else { i = chars.count; break }
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: current)
                lastControl = nil
            case 72, 104: // H
                guard let x = number() else { i = chars.count; break }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case 86, 118: // V
                guard let y = number() else { i = chars.count; break }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case 67, 99: // C
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() else { i = chars.count; break }
                let base = relative ? current : .zero
                let c1 = CGPoint(x: base.x + x1, y: base.y + y1)
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                let end = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case 83, 115: // S
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { i = chars.count; break }
                let base = relative ? current : .zero
                let c1: CGPoint
                if let lc = lastControl, lastCommand == 67 || lastCommand == 99 || lastCommand == 83 || lastCommand == 115 {
                    c1 = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                } else { c1 = current }
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                let end = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case 81, 113: // Q
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { i = chars.count; break }
                let base = relative ? current : .zero
                let c = CGPoint(x: base.x + x1, y: base.y + y1)
                let end = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
            case 84, 116: // T
                guard let x = number(), let y = number() else { i = chars.count; break }
                let base = relative ? current : .zero
                let c: CGPoint
                if let lc = lastControl, lastCommand == 81 || lastCommand == 113 || lastCommand == 84 || lastCommand == 116 {
                    c = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                } else { c = current }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
            case 65, 97: // A
                guard let rx = number(), let ry = number(), let rot = number(), let large = flag(), let sweep = flag(), let x = number(), let y = number() else { i = chars.count; break }
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                arc(&path, from: current, to: end, rx: rx, ry: ry, rotation: rot, largeArc: large, sweep: sweep)
                current = end
                lastControl = nil
            case 90, 122: // Z
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                i = chars.count
            }
            lastCommand = command
        }
        return path
    }

    /// SVG arc → cubic Béziers (endpoint parameterisation to centre, then ≤90° segments).
    private static func arc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        var t = theta1
        for _ in 0..<segments {
            let t2 = t + step
            let alpha = sin(step) * (sqrt(4 + 3 * tan(step / 2) * tan(step / 2)) - 1) / 3
            func point(_ a: CGFloat) -> CGPoint {
                let x = rx * cos(a), y = ry * sin(a)
                return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
            }
            func derivative(_ a: CGFloat) -> CGPoint {
                let x = -rx * sin(a), y = ry * cos(a)
                return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
            }
            let s = point(t), e = point(t2)
            let d1 = derivative(t), d2 = derivative(t2)
            let c1 = CGPoint(x: s.x + alpha * d1.x, y: s.y + alpha * d1.y)
            let c2 = CGPoint(x: e.x - alpha * d2.x, y: e.y - alpha * d2.y)
            path.addCurve(to: e, control1: c1, control2: c2)
            t = t2
        }
    }
}

/// A lucide icon as a shape: the 24-box path scaled to the frame.
struct LucideShape: Shape {
    let name: String

    func path(in rect: CGRect) -> Path {
        guard let d = LucideData.paths[name] else { return Path() }
        let scale = min(rect.width, rect.height) / 24
        return SVGPath.path(d).applying(CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// `<Inbox size={16} />` — the icon inherits the foreground style, like an SVG with
/// `stroke="currentColor"`.
struct Icon: View {
    let name: String
    var size: CGFloat = 16
    var strokeWidth: CGFloat = 2

    init(_ name: String, size: CGFloat = 16, strokeWidth: CGFloat = 2) {
        self.name = name
        self.size = size
        self.strokeWidth = strokeWidth
    }

    var body: some View {
        LucideShape(name: name)
            .stroke(style: StrokeStyle(lineWidth: strokeWidth * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
