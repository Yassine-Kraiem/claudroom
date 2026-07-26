import SwiftUI

/// Claudroom's visual tokens.
///
/// The palette is the Claude ecosystem's — warm clay on paper — because the app
/// lives inside that world. The type is deliberately *not* the editorial serif that
/// usually accompanies those colours: this is an instrument, so every number is
/// monospaced and every label is a wide-tracked micro-cap, the way a gauge is
/// labelled rather than the way an article is set.
public enum Palette {
    public static let paper       = Color(red: 0.945, green: 0.929, blue: 0.902)
    public static let paperDeep   = Color(red: 0.898, green: 0.878, blue: 0.843)
    public static let ink         = Color(red: 0.129, green: 0.122, blue: 0.110)
    public static let inkSoft     = Color(red: 0.129, green: 0.122, blue: 0.110).opacity(0.55)
    public static let inkFaint    = Color(red: 0.129, green: 0.122, blue: 0.110).opacity(0.30)

    /// The accent. Used for capacity *consumed*, never for chrome — so the eye
    /// reads clay as "spent" everywhere in the app without being told.
    public static let clay        = Color(red: 0.851, green: 0.467, blue: 0.341)
    public static let clayDeep    = Color(red: 0.722, green: 0.337, blue: 0.227)
    public static let clayWash    = Color(red: 0.851, green: 0.467, blue: 0.341).opacity(0.14)

    /// Capacity still available. Quiet on purpose: headroom is the absence of
    /// spend, and drawing it loudly would invert the app's point.
    public static let rest        = Color(red: 0.780, green: 0.757, blue: 0.706)

    /// Model series. Clay leads; the rest step away in hue without shouting.
    public static let series: [Color] = [
        Color(red: 0.851, green: 0.467, blue: 0.341),   // clay
        Color(red: 0.427, green: 0.478, blue: 0.502),   // slate
        Color(red: 0.639, green: 0.545, blue: 0.404),   // ochre
        Color(red: 0.396, green: 0.412, blue: 0.353),   // olive
        Color(red: 0.596, green: 0.427, blue: 0.427),   // rose-brown
        Color(red: 0.510, green: 0.549, blue: 0.576),   // pale slate
    ]
}

public enum TypeScale {
    /// Numbers are always monospaced, always tight. They are readings.
    public static func reading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    /// Structural micro-label. Wide tracking is the device that holds the page
    /// together, in place of decorative numbering.
    public static let eyebrow = Font.system(size: 9.5, weight: .semibold, design: .monospaced)
    public static let title = Font.system(size: 13, weight: .semibold)
    public static let body = Font.system(size: 11.5)
    public static let caption = Font.system(size: 10)
}

/// A wide-tracked micro-cap label. The only structural ornament in the design.
public struct Eyebrow: View {
    let text: String
    let tint: Color

    public init(_ text: String, tint: Color = Palette.inkSoft) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text.uppercased())
            .font(TypeScale.eyebrow)
            .tracking(1.4)
            .foregroundStyle(tint)
    }
}

/// Offscreen rendering cannot rasterise Liquid Glass — it is composited live by the
/// window server, so `ImageRenderer` produces empty panels. Set this to false when
/// rendering to an image; the material fallback captures correctly and is what
/// pre-macOS-26 users see anyway.
public struct AllowsLiquidGlassKey: EnvironmentKey {
    public static let defaultValue = true
}

public extension EnvironmentValues {
    var allowsLiquidGlass: Bool {
        get { self[AllowsLiquidGlassKey.self] }
        set { self[AllowsLiquidGlassKey.self] = newValue }
    }
}

/// Liquid Glass where the OS provides it, a material otherwise.
///
/// Glass is only worth using when something sits behind it — here that is the
/// ambient capacity field, so the panels refract the user's own activity rather
/// than a decorative blur.
public struct GlassPanel: ViewModifier {
    @Environment(\.allowsLiquidGlass) private var allowsLiquidGlass
    var cornerRadius: CGFloat = 18

    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *), allowsLiquidGlass {
            content
                .padding(18)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.white.opacity(0.75), lineWidth: 0.75)
                )
                .shadow(color: Palette.ink.opacity(0.05), radius: 12, y: 4)
        }
    }
}

public extension View {
    func glassPanel(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

/// The backdrop: soft blooms positioned by real activity, so the glass has the
/// user's own data behind it. Kept low-contrast — it is atmosphere, not a chart.
public struct CapacityField: View {
    /// Normalised 0…1 intensities, one per day, oldest first.
    let intensities: [Double]

    public init(intensities: [Double]) {
        self.intensities = intensities
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.paper
                ForEach(Array(intensities.enumerated()), id: \.offset) { index, value in
                    let t = intensities.count > 1
                        ? Double(index) / Double(intensities.count - 1) : 0.5
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Palette.clay.opacity(0.32 * value), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: geo.size.width * 0.18)
                        )
                        .frame(width: geo.size.width * 0.36)
                        .position(
                            x: geo.size.width * (0.06 + 0.88 * t),
                            y: geo.size.height * (0.16 + 0.5 * (1 - value)))
                }
            }
            .blur(radius: 46)
            .ignoresSafeArea()
        }
    }
}
