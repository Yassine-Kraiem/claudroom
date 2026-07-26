import AppKit
import ClaudroomCore

/// The app mark, drawn live in the menu bar.
///
/// The mark is already a capacity ring — bright arc is what is left, dim arc is
/// what has been spent — so rather than pasting a static icon next to the number,
/// the ring is driven by the same session figure the number reports. The glyph and
/// the text say the same thing in two ways.
///
/// Deliberately not a template image. Template glyphs are tinted to the menu bar's
/// foreground colour, which would flatten the used and remaining arcs into one
/// shade and destroy the only thing the mark communicates. Terracotta reads on
/// both light and dark menu bars.
public enum MenuBarGlyph {

    /// Points. Menu bar content is laid out against an 18pt bar; 16 leaves the
    /// mark optically level with the text beside it.
    static let size: CGFloat = 16

    private static func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: a)
    }

    private static let accentA = srgb(217, 119, 87)   // terracotta
    private static let accentB = srgb(193, 95, 60)    // deeper clay
    private static let warn    = srgb(193, 95, 60)
    /// Fixed mid-grey rather than `labelColor`. A dynamic colour resolves against
    /// whatever appearance is current when the image is *drawn*, and an NSImage
    /// handed to the menu bar is cached — so it can keep a light-mode track after
    /// the system flips to dark. Mid-grey reads on both bars and never goes stale.
    private static let neutral = srgb(142, 142, 147)

    /// How the ring is drawn, beyond the gauge reading.
    ///
    /// Stale and signed-out both render an empty ring and both print an em dash,
    /// so without a distinguishing treatment they are the same picture for two
    /// different problems — one clears itself, the other needs `claude` login.
    enum Mode: Equatable {
        case gauge
        case dashed   // stale: a broken ring reads as intermittent
        case slashed  // signed out: nothing to measure at all
    }

    /// What the ring should show for a given label.
    ///
    /// `remaining` is nil when there is no session to report, which draws the
    /// track alone — an empty ring, matching the em dash in the text. Reporting a
    /// full ring there would claim a fresh window that is not running.
    static func state(for label: MenuBarLabel) -> (remaining: Double?, warning: Bool, mode: Mode) {
        switch label {
        case .notSignedIn:
            return (nil, false, .slashed)
        case .stale:
            return (nil, false, .dashed)
        case .noSession:
            return (nil, false, .gauge)
        case .sessionActive(let remaining, _):
            return (remaining, false, .gauge)
        case .weekClosingUnderused(let sessionRemaining, _, _):
            return (sessionRemaining, true, .gauge)
        }
    }

    public static func image(for label: MenuBarLabel) -> NSImage {
        let s = state(for: label)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, rect: rect,
                 remaining: s.remaining, warning: s.warning, mode: s.mode)
            return true
        }
        // Colour is load-bearing here, so opt out of menu bar tinting.
        image.isTemplate = false
        return image
    }

    private static func draw(in ctx: CGContext,
                             rect: NSRect,
                             remaining: Double?,
                             warning: Bool,
                             mode: Mode) {
        let dimmed = mode != .gauge
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Proportionally fatter than the app icon: without the squircle around it
        // the ring has the whole canvas, and a hairline would disappear at 16pt.
        let radius = side * 0.33
        let lineWidth = side * 0.15
        ctx.setLineCap(.round)
        ctx.setAllowsAntialiasing(true)

        let start = CGFloat.pi / 2                     // 12 o'clock
        let clamped = min(max(remaining ?? 0, 0), 1)
        let usedFraction = remaining == nil ? 1 : 1 - clamped
        let usedSweep = CGFloat(usedFraction) * 2 * .pi

        // Used capacity: dim and thinner, so the bright remainder dominates. Drawn
        // against the menu bar's own foreground colour so it holds up in both
        // appearances, where a fixed taupe would vanish on one of them.
        let trackAlpha: CGFloat = dimmed ? 0.5 : 0.75
        ctx.setLineWidth(lineWidth * 0.72)
        ctx.setStrokeColor(neutral.copy(alpha: trackAlpha) ?? neutral)
        if mode == .dashed {
            // Short dashes, sized off the circumference so they land evenly.
            let dash = CGFloat(2 * .pi * radius) / 12
            ctx.setLineDash(phase: 0, lengths: [dash * 0.55, dash * 0.45])
        }
        ctx.addArc(center: center, radius: radius,
                   startAngle: start, endAngle: start - usedSweep,
                   clockwise: true)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // The remainder. Skipped entirely when there is no session running.
        if let remaining, remaining > 0.001, !dimmed {
            let gap = CGFloat.pi * 0.045
            ctx.setLineWidth(lineWidth)
            ctx.saveGState()
            ctx.addArc(center: center, radius: radius,
                       startAngle: start - usedSweep - gap,
                       endAngle: start + gap,
                       clockwise: true)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                colors: [warning ? warn : accentA, accentB] as CFArray,
                locations: [0, 1]) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: rect.minX, y: rect.maxY),
                                       end: CGPoint(x: rect.maxX, y: rect.minY),
                                       options: [])
            }
            ctx.restoreGState()
        }

        // Ceiling tick at 12 o'clock: the limit the headroom is measured against.
        // Same device as the app icon, so the two read as one mark.
        let tickH = side * 0.09
        let tickW = side * 0.05
        ctx.setFillColor(neutral.copy(alpha: dimmed ? 0.55 : 1) ?? neutral)
        let tick = CGRect(x: center.x - tickW / 2,
                          y: center.y + radius + lineWidth * 0.55,
                          width: tickW, height: tickH)
        ctx.addPath(CGPath(roundedRect: tick, cornerWidth: tickW / 2,
                           cornerHeight: tickW / 2, transform: nil))
        ctx.fillPath()

        // A closing under-used cycle is the one thing worth interrupting for. It
        // gets a filled centre rather than a separate warning symbol, so the mark
        // stays the mark instead of being swapped out for a triangle.
        if warning {
            ctx.setFillColor(warn)
            let dot = side * 0.17
            ctx.fillEllipse(in: CGRect(x: center.x - dot / 2, y: center.y - dot / 2,
                                       width: dot, height: dot))
        }

        // Signed out: a slash through the mark. Nothing to measure, as opposed to
        // a window that is merely not running.
        if mode == .slashed {
            ctx.setLineCap(.round)
            ctx.setLineWidth(lineWidth * 0.72)
            ctx.setStrokeColor(neutral.copy(alpha: 0.85) ?? neutral)
            let reach = radius + lineWidth * 0.15
            ctx.move(to: CGPoint(x: center.x - reach * 0.72, y: center.y - reach * 0.72))
            ctx.addLine(to: CGPoint(x: center.x + reach * 0.72, y: center.y + reach * 0.72))
            ctx.strokePath()
        }
    }
}
