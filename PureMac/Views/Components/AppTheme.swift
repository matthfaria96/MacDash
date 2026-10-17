import AppKit
import SwiftUI

@MainActor
enum AppAppearance {
    static func enforceDark() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }
}

enum Tint {
    static let accent = Color(red: 0.76, green: 0.24, blue: 0.98)
    static let teal = Color(red: 0.35, green: 0.79, blue: 0.91)
    static let blue = Color(red: 0.43, green: 0.62, blue: 1.00)
    static let green = Color(red: 0.35, green: 0.86, blue: 0.67)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.39)
    static let purple = Color(red: 0.82, green: 0.42, blue: 1.00)
    static let pink = Color(red: 1.00, green: 0.40, blue: 0.82)
    static let cyan = Color(red: 0.42, green: 0.80, blue: 1.00)
    static let red = Color(red: 1.00, green: 0.38, blue: 0.49)
    static let yellow = Color(red: 1.00, green: 0.79, blue: 0.39)
}

struct SectionPalette {
    let primary: Color
    let secondary: Color
    let deep: Color
    let accent: Color
    /// Where the light and the dark pools sit in the backdrop.
    var layout: BackdropLayout = .centerGlow

    static let smartCare = SectionPalette(
        primary: Color(red: 0.52, green: 0.12, blue: 0.74),
        secondary: Color(red: 0.33, green: 0.07, blue: 0.58),
        deep: Color(red: 0.1, green: 0.04, blue: 0.32),
        accent: Color(red: 0.96, green: 0.24, blue: 0.83),
        layout: .centerGlow
    )
    static let cleanup = SectionPalette(
        primary: Color(red: 0.3, green: 0.55, blue: 0.08),
        secondary: Color(red: 0.1, green: 0.4, blue: 0.1),
        deep: Color(red: 0.02, green: 0.2, blue: 0.07),
        accent: Color(red: 0.45, green: 0.95, blue: 0.45),
        layout: .topGlow
    )

    // Each destination has its own identity color.
    static let protection = SectionPalette(
        primary: Color(red: 0.78, green: 0.16, blue: 0.58),
        secondary: Color(red: 0.55, green: 0.06, blue: 0.4),
        deep: Color(red: 0.26, green: 0.02, blue: 0.18),
        accent: Color(red: 1.0, green: 0.5, blue: 0.85),
        layout: .leftGlow
    )
    static let apps = SectionPalette(
        primary: Color(red: 0.07, green: 0.3, blue: 0.72),
        secondary: Color(red: 0.18, green: 0.16, blue: 0.62),
        deep: Color(red: 0.06, green: 0.05, blue: 0.28),
        accent: Color(red: 0.45, green: 0.7, blue: 1.0),
        layout: .centerGlow
    )
    static let duplicates = SectionPalette(
        primary: Color(red: 0.05, green: 0.52, blue: 0.48),
        secondary: Color(red: 0.03, green: 0.36, blue: 0.36),
        deep: Color(red: 0.01, green: 0.15, blue: 0.16),
        accent: Color(red: 0.35, green: 0.95, blue: 0.82),
        layout: .topGlow
    )
    static let photos = SectionPalette(
        primary: Color(red: 0.66, green: 0.46, blue: 0.06),
        secondary: Color(red: 0.48, green: 0.3, blue: 0.04),
        deep: Color(red: 0.2, green: 0.11, blue: 0.02),
        accent: Color(red: 1.0, green: 0.82, blue: 0.35),
        layout: .cornerGlow
    )
    /// Ruby red: the one hue no other section uses.
    static let spaceLens = SectionPalette(
        primary: Color(red: 0.74, green: 0.12, blue: 0.22),
        secondary: Color(red: 0.52, green: 0.06, blue: 0.14),
        deep: Color(red: 0.22, green: 0.02, blue: 0.06),
        accent: Color(red: 1.0, green: 0.42, blue: 0.47),
        layout: .leftGlow
    )
    /// Burnt orange, apart from the amber of Similar Photos.
    static let processes = SectionPalette(
        primary: Color(red: 0.84, green: 0.34, blue: 0.08),
        secondary: Color(red: 0.6, green: 0.2, blue: 0.05),
        deep: Color(red: 0.24, green: 0.08, blue: 0.02),
        accent: Color(red: 1.0, green: 0.55, blue: 0.3),
        layout: .cornerGlow
    )
    static let settings = SectionPalette(
        primary: Color(red: 0.3, green: 0.3, blue: 0.4),
        secondary: Color(red: 0.18, green: 0.18, blue: 0.26),
        deep: Color(red: 0.06, green: 0.06, blue: 0.1),
        accent: Color(red: 0.78, green: 0.78, blue: 0.92),
        layout: .centerGlow
    )

    static func forSection(_ section: AppSection?) -> SectionPalette {
        switch section ?? .smartCare {
        case .smartCare: return .smartCare
        case .protection: return .protection
        case .apps: return .apps
        case .duplicates: return .duplicates
        case .spaceLens: return .spaceLens
        case .processes: return .processes
        case .similarPhotos: return .photos
        case .cleanup: return .cleanup
        case .settings: return .settings
        }
    }


    var background: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: primary, location: 0),
                .init(color: secondary, location: 0.44),
                .init(color: deep, location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var sidebar: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: primary.opacity(0.88), location: 0),
                .init(color: secondary.opacity(0.78), location: 0.58),
                .init(color: deep.opacity(0.96), location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum MotionTokens {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let gentle = Animation.spring(response: 0.46, dampingFraction: 0.88)
    static let press = Animation.easeOut(duration: 0.1)
}

enum TintGradient {
    static let accent = LinearGradient(
        colors: [Tint.accent, Tint.accent.opacity(0.86)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let smartCare = LinearGradient(
        colors: [
            Color(red: 0.47, green: 0.11, blue: 0.66),
            Color(red: 0.10, green: 0.035, blue: 0.29)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let destructive = LinearGradient(
        colors: [Tint.red, Tint.red.opacity(0.86)],
        startPoint: .top,
        endPoint: .bottom
    )

    static func of(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.82)], startPoint: .top, endPoint: .bottom)
    }
}

struct IconTile: View {
    let systemName: String
    var tint: Color = Tint.accent
    var size: CGFloat = 26
    var corner: CGFloat = 7
    var glow = false
    var vivid = false

    var body: some View {
        ZStack {
            Image(systemName: systemName)
                .font(.system(size: size * 0.72, weight: .medium, design: .rounded))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.black.opacity(0.56))
                .offset(y: size * 0.055)
            Image(systemName: systemName)
                .font(.system(size: size * 0.72, weight: .medium, design: .rounded))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.white, Color(red: 0.91, green: 0.94, blue: 1), Color(red: 0.65, green: 0.70, blue: 0.79)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .white.opacity(glow || vivid ? 0.48 : 0.28), radius: glow || vivid ? 3 : 1.2, y: -0.6)
            Image(systemName: systemName)
                .font(.system(size: size * 0.72, weight: .medium, design: .rounded))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.white.opacity(0.26))
                .offset(y: -size * 0.025)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(glow || vivid ? playfulTilt : playfulTilt * 0.45))
        .scaleEffect(glow ? 1.08 : 1)
        .shadow(color: Color.white.opacity(glow ? 0.30 : 0.11), radius: glow ? 3.5 : 1.3, y: 1.2)
        .animation(MotionTokens.snappy, value: glow)
    }

    private var playfulTilt: Double {
        switch systemName {
        case "bolt", "bolt.fill", "sparkles", "sparkle": -7
        case "hand.raised.fill", "hand.raised", "shield.checkered": 5
        case "folder", "folder.fill", "internaldrive", "externaldrive.fill": -4
        case "app.dashed", "hammer.fill", "app.fill": 4
        default: -3
        }
    }
}

/// The composition of a section's backdrop, after the CleanMyMac screens:
/// one or two pools of light, and dark pools that give the color depth.
enum BackdropLayout {
    /// Light down the middle of the top; dark top left and bottom right (purple).
    case centerGlow
    /// Light across the top; a large dark pool bottom right, darker left (green).
    case topGlow
    /// Dark top left, light top right, dark bottom left (orange).
    case cornerGlow
    /// Light on the left, wine-dark right side, darkest top right (magenta).
    case leftGlow

    struct Spot {
        let center: UnitPoint
        let radius: CGFloat
        let strength: Double
    }

    var lights: [Spot] {
        switch self {
        case .centerGlow:
            return [Spot(center: UnitPoint(x: 0.6, y: 0.02), radius: 0.62, strength: 0.85),
                    Spot(center: UnitPoint(x: 0.45, y: 0.55), radius: 0.4, strength: 0.25)]
        case .topGlow:
            return [Spot(center: UnitPoint(x: 0.5, y: -0.08), radius: 0.7, strength: 0.9),
                    Spot(center: UnitPoint(x: 0.3, y: 0.45), radius: 0.4, strength: 0.25)]
        case .cornerGlow:
            return [Spot(center: UnitPoint(x: 0.85, y: 0.0), radius: 0.62, strength: 0.9),
                    Spot(center: UnitPoint(x: 0.8, y: 0.85), radius: 0.45, strength: 0.4)]
        case .leftGlow:
            return [Spot(center: UnitPoint(x: 0.12, y: 0.35), radius: 0.6, strength: 0.85),
                    Spot(center: UnitPoint(x: 0.35, y: 1.0), radius: 0.45, strength: 0.35)]
        }
    }

    var pools: [Spot] {
        switch self {
        case .centerGlow:
            return [Spot(center: UnitPoint(x: 0.0, y: 0.0), radius: 0.5, strength: 0.95),
                    Spot(center: UnitPoint(x: 1.0, y: 1.0), radius: 0.62, strength: 0.95),
                    Spot(center: UnitPoint(x: 0.05, y: 0.95), radius: 0.35, strength: 0.5)]
        case .topGlow:
            return [Spot(center: UnitPoint(x: 1.0, y: 1.0), radius: 0.75, strength: 1.0),
                    Spot(center: UnitPoint(x: 0.0, y: 0.7), radius: 0.45, strength: 0.65),
                    Spot(center: UnitPoint(x: 1.0, y: 0.0), radius: 0.35, strength: 0.45)]
        case .cornerGlow:
            return [Spot(center: UnitPoint(x: 0.0, y: 0.0), radius: 0.55, strength: 1.0),
                    Spot(center: UnitPoint(x: 0.0, y: 1.0), radius: 0.55, strength: 0.85)]
        case .leftGlow:
            return [Spot(center: UnitPoint(x: 1.0, y: 0.0), radius: 0.65, strength: 1.0),
                    Spot(center: UnitPoint(x: 1.0, y: 0.75), radius: 0.5, strength: 0.7),
                    Spot(center: UnitPoint(x: 0.0, y: 0.0), radius: 0.3, strength: 0.4)]
        }
    }

    /// Which way the secondary light leans on the color wheel.
    var neighborShift: Double {
        switch self {
        case .centerGlow: return 0.04
        case .topGlow: return -0.05
        case .cornerGlow: return -0.03
        case .leftGlow: return 0.03
        }
    }
}

/// The section's backdrop: a vivid color field with depth, like a mesh
/// gradient. Bright blooms (one drifting toward a neighboring hue), dark
/// pools in the corners and a fine grain.
struct AmbientBackdrop: View {
    var palette: SectionPalette = .smartCare
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                // Drawn once: a still field keeps scrolling and transitions
                // smooth; the life comes from the content moving over it.
                GeometryReader { geometry in
                    field(size: geometry.size, time: 0)
                }
                .overlay(GrainOverlay().opacity(0.07).blendMode(.overlay))
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .ignoresSafeArea()
    }

    private func field(size: CGSize, time: TimeInterval) -> some View {
        let span = max(size.width, size.height)
        // Slow, out-of-phase drifts so the field never repeats visibly.
        func drift(_ period: Double, _ phase: Double, _ amount: CGFloat) -> CGFloat {
            CGFloat(sin(time * .pi * 2 / period + phase)) * amount
        }
        func moved(_ point: UnitPoint, _ seed: Double) -> UnitPoint {
            UnitPoint(x: point.x + drift(37 + seed * 4, seed, 0.035), y: point.y + drift(31 + seed * 3, seed * 1.7, 0.03))
        }
        // Rich, not blown out: the light is the section color, a touch
        // brighter; the dark pools are nearly black in the same hue.
        let light = palette.primary.adjusted(hue: 0, saturation: 1.02, brightness: 1.12)
        let neighbor = palette.primary.adjusted(hue: palette.layout.neighborShift, saturation: 1.0, brightness: 1.05)
        let night = palette.deep.adjusted(hue: 0, saturation: 1.05, brightness: 0.55)
        let layout = palette.layout
        return ZStack {
            palette.secondary.adjusted(hue: 0, saturation: 1, brightness: 0.82)
            ForEach(Array(layout.lights.enumerated()), id: \.offset) { index, spot in
                bloom(index == 0 ? light : neighbor, at: moved(spot.center, Double(index)), radius: span * spot.radius, opacity: spot.strength)
            }
            ForEach(Array(layout.pools.enumerated()), id: \.offset) { index, spot in
                bloom(night, at: moved(spot.center, Double(index) + 5), radius: span * spot.radius, opacity: spot.strength)
            }
        }
        .frame(width: size.width, height: size.height)
        .drawingGroup()
    }

    private func bloom(_ color: Color, at center: UnitPoint, radius: CGFloat, opacity: Double) -> some View {
        RadialGradient(
            stops: [
                .init(color: color.opacity(opacity), location: 0),
                .init(color: color.opacity(opacity * 0.55), location: 0.35),
                .init(color: color.opacity(0), location: 1)
            ],
            center: center,
            startRadius: 0,
            endRadius: radius
        )
    }
}

/// A fixed field of fine noise, drawn once and tiled.
private struct GrainOverlay: View {
    private static let tile: NSImage = {
        let side = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
                                   bytesPerRow: side, bitsPerPixel: 8)!
        var generator = SystemRandomNumberGenerator()
        if let data = rep.bitmapData {
            for index in 0..<(side * side) { data[index] = UInt8.random(in: 0...255, using: &generator) }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }()

    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Digits roll to their new value (macOS 14 and later).
    @ViewBuilder
    func numericTransition() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }
}

extension Color {
    /// Shifts hue and scales saturation and brightness, clamped to valid values.
    func adjusted(hue: Double, saturation: Double, brightness: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemPurple
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(
            hue: (Double(h) + hue + 1).truncatingRemainder(dividingBy: 1),
            saturation: min(1, max(0, Double(s) * saturation)),
            brightness: min(1, max(0, Double(b) * brightness)),
            opacity: Double(a)
        )
    }
}

struct CardSurface<Content: View>: View {
    var padding: CGFloat = 16
    var accent: Color? = nil
    var elevation: CardElevation = .standard
    var material: Material? = nil
    var tint: Color? = nil
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var hovering = false

    private let cornerRadius: CGFloat = 18

    var body: some View {
        surface
            // Cards rise into place when their screen opens, and brighten
            // their edge under the pointer.
            .opacity(revealed || reduceMotion ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 14)
            .scaleEffect(revealed || reduceMotion ? 1 : 0.985, anchor: .top)
            .onAppear {
                guard !revealed else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86).delay(0.04)) { revealed = true }
            }
            .onHover { hovering = $0 }
    }

    private var surface: some View {
        content
            .padding(padding)
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                ZStack {
                    if let material {
                        shape.fill(material)
                    } else if colorScheme == .dark {
                        shape.fill(.ultraThinMaterial)
                            .opacity(0.55)
                        shape.fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.10), Color.white.opacity(0.035)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    } else {
                        shape.fill(Color(nsColor: .controlBackgroundColor))
                    }
                    if let tint {
                        shape.fill(
                            LinearGradient(
                                colors: [tint.opacity(colorScheme == .dark ? 0.14 : 0.05), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? AnyShapeStyle(GlassEdge.gradient)
                            : AnyShapeStyle(Color.primary.opacity(0.075)),
                        lineWidth: 0.8
                    )
                    .opacity(hovering ? 1 : 0.8)
                    .animation(.easeOut(duration: 0.2), value: hovering)
            }
            .overlay(alignment: .top) {
                if let accent {
                    Capsule()
                        .fill(accent.opacity(0.72))
                        .frame(width: 36, height: 2)
                        .padding(.top, 1)
                }
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? max(elevation.ambient * 4, 0.12) : elevation.ambient),
                radius: max(elevation.ambientRadius, 10),
                y: max(elevation.ambientY, 4)
            )
    }
}

extension Color {
    /// Blends the color toward white without the macOS 15 `mix` API.
    func mixedWithWhite(_ amount: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let t = max(0, min(1, amount))
        return Color(
            red: Double(ns.redComponent) + (1 - Double(ns.redComponent)) * t,
            green: Double(ns.greenComponent) + (1 - Double(ns.greenComponent)) * t,
            blue: Double(ns.blueComponent) + (1 - Double(ns.blueComponent)) * t
        )
    }
}

/// Hides the window's own title so only the centered section name shows.
struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

// MARK: - Module run cycle
//
// Every module follows the same cycle: start an action, stop it while it runs
// (button or Esc), and start over from the natural first screen once results
// are showing. "Do it again" always lives in the window toolbar.

/// Stops a running scan or check. Esc triggers it too.
struct StopActionButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .cancel, action: action) {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(GlassButtonStyle())
        .controlSize(.large)
        .keyboardShortcut(.cancelAction)
        .help("Stop now and keep everything as it is (Esc)")
    }
}

/// Discards results and returns the module to its first screen.
struct StartOverButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Start over", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(GlassButtonStyle())
        .controlSize(.large)
        .help("Discard these results and go back to the start")
    }
}

extension View {
    /// The standard toolbar "do it again" control, matching Performance.
    func moduleRefreshToolbar(
        _ help: LocalizedStringKey,
        isVisible: Bool = true,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        toolbar {
            ToolbarItem {
                if isVisible {
                    Button(action: action) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isDisabled)
                    .help(Text(help))
                }
            }
        }
    }
}

/// Glowing frosted orb for hero icons in empty and status states.
struct GlassOrbIcon: View {
    let systemImage: String
    var tint: Color = Tint.accent
    var size: CGFloat = 96
    @Environment(\.premiumIconsEnabled) private var premiumIcons

    var body: some View {
        if premiumIcons {
            PremiumHeroIcon(systemName: systemImage, tint: tint, size: size)
        } else {
            orb
        }
    }

    private var orb: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.32), .clear], center: .center, startRadius: 2, endRadius: size * 0.85))
                .frame(width: size * 1.6, height: size * 1.6)
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(0.7)
                .overlay(Circle().fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(Circle().strokeBorder(GlassEdge.gradient, lineWidth: 1))
                .frame(width: size, height: size)
                .shadow(color: tint.opacity(0.35), radius: size * 0.16, y: size * 0.06)
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .shadow(color: tint.opacity(0.8), radius: 6)
        }
        .frame(width: size * 1.25, height: size * 1.25)
        .accessibilityHidden(true)
    }
}

/// Frosted glass panel used behind lists, tables and forms.
struct GlassPanelBackground: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(.ultraThinMaterial).opacity(0.55)
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(shape.strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
    }
}

/// Light catching the top-left edge of a glass panel.
enum GlassEdge {
    static let gradient = LinearGradient(
        colors: [Color.white.opacity(0.30), Color.white.opacity(0.08), Color.white.opacity(0.04), Color.white.opacity(0.14)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Primary call to action: a bright white pill with dark text, as in the
/// reference design. Destructive buttons keep red text.
struct GlassProminentButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        GlassProminentButton(configuration: configuration, large: large)
    }

    private struct GlassProminentButton: View {
        let configuration: ButtonStyleConfiguration
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        private var isLarge: Bool { large || controlSize == .large }

        var body: some View {
            let destructive = configuration.role == .destructive
            configuration.label
                .font(.system(size: isLarge ? 14 : 12.5, weight: .semibold))
                .foregroundStyle(destructive ? Color(red: 0.85, green: 0.15, blue: 0.25) : Color.black.opacity(0.82))
                .padding(.horizontal, isLarge ? 22 : 15)
                .padding(.vertical, isLarge ? 11 : 7)
                .background {
                    Capsule().fill(Color.white.opacity(hovering && isEnabled ? 1 : 0.92))
                }
                .shadow(color: .black.opacity(hovering && isEnabled ? 0.28 : 0.18), radius: hovering ? 12 : 7, y: 3)
                .scaleEffect(configuration.isPressed ? 0.96 : hovering && isEnabled ? 1.03 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .animation(MotionTokens.snappy, value: hovering)
                .animation(MotionTokens.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Secondary action: frosted glass capsule.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassButton(configuration: configuration)
    }

    private struct GlassButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        var body: some View {
            let large = controlSize == .large
            configuration.label
                .font(.system(size: large ? 13 : 12, weight: .semibold))
                .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(Tint.red) : AnyShapeStyle(Color.white.opacity(0.92)))
                .padding(.horizontal, large ? 16 : 12)
                .padding(.vertical, large ? 8 : 5)
                .background {
                    Capsule().fill(.ultraThinMaterial).opacity(0.6)
                    Capsule().fill(Color.white.opacity(hovering && isEnabled ? 0.16 : 0.08))
                }
                .overlay(Capsule().strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .animation(MotionTokens.snappy, value: hovering)
                .animation(MotionTokens.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Glass tab strip used in place of the system segmented control.
struct GlassSegmentedPicker<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> LocalizedStringKey
    var icon: ((Value) -> String)? = nil
    var tint: Color = Tint.accent

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    withAnimation(MotionTokens.snappy) { selection = option }
                } label: {
                    HStack(spacing: 6) {
                        if let icon {
                            Image(systemName: icon(option))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(label(option))
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.62))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule()
                                .fill(LinearGradient(colors: [tint.opacity(0.75), tint.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.7))
                                .shadow(color: tint.opacity(0.45), radius: 8, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background {
            Capsule().fill(.ultraThinMaterial).opacity(0.6)
            Capsule().fill(Color.white.opacity(0.06))
        }
        .overlay(Capsule().strokeBorder(GlassEdge.gradient, lineWidth: 0.7))
    }
}

/// White-pill tab bar shared by the Applications and General Cleanup hubs.
struct PillTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> LocalizedStringKey
    let icon: (Tab) -> String
    var badge: (Tab) -> String? = { _ in nil }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon(tab))
                            .font(.system(size: 11, weight: .semibold))
                        Text(title(tab))
                            .font(.system(size: 12.5, weight: .semibold))
                        if let badge = badge(tab) {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(selected ? Color.black.opacity(0.12) : Color.white.opacity(0.12)))
                        }
                    }
                    .foregroundStyle(selected ? Color.black.opacity(0.82) : Color.white.opacity(0.8))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        if selected {
                            Capsule().fill(Color.white.opacity(0.92))
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background {
            Capsule().fill(.ultraThinMaterial).opacity(0.6)
            Capsule().fill(Color.white.opacity(0.06))
        }
        .overlay(Capsule().strokeBorder(GlassEdge.gradient, lineWidth: 0.7))
        .fixedSize()
    }
}

/// Header shared by the tabbed hubs: identity on the left, tabs on the right.
struct HubHeader<Tabs: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    let tint: Color
    @ViewBuilder var tabs: Tabs

    var body: some View {
        // Tabs move under the title when both don't fit on one line, so a
        // wide tab bar never squeezes the sidebar.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                titleBlock
                    .frame(minWidth: 310, idealWidth: 360, alignment: .leading)
                Spacer(minLength: 12)
                tabs
            }
            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                tabs
            }
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 16) {
            CategoryBadge(systemName: icon, tint: tint, size: 54)
                .iconEntrance()
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
        }
    }
}

enum CardElevation {
    case flat, standard, raised

    var ambient: Double {
        switch self {
        case .flat: return 0
        case .standard: return 0.035
        case .raised: return 0.07
        }
    }

    var ambientRadius: CGFloat {
        switch self {
        case .flat: return 0
        case .standard: return 6
        case .raised: return 16
        }
    }

    var ambientY: CGFloat {
        switch self {
        case .flat: return 0
        case .standard: return 2
        case .raised: return 7
        }
    }
}

struct StatusChip: View {
    let label: String
    var systemImage: String? = nil
    var tint: Color = Tint.accent

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.6))
    }
}

enum LiquidGlassShape {
    case capsule
    case circle
    case roundedRectangle(CGFloat)
}

/// Uses Liquid Glass for functional controls on macOS 26 and newer. Earlier
/// macOS versions retain their existing material and contrast treatments.
struct AdaptiveLiquidGlass: ViewModifier {
    let tint: Color
    var shape: LiquidGlassShape = .roundedRectangle(12)
    var interactive = false
    var isEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled, #available(macOS 26.0, *) {
            switch shape {
            case .capsule:
                content.glassEffect(.regular.tint(tint).interactive(interactive), in: Capsule())
            case .circle:
                content.glassEffect(.regular.tint(tint).interactive(interactive), in: Circle())
            case .roundedRectangle(let radius):
                content.glassEffect(
                    .regular.tint(tint).interactive(interactive),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
            }
        } else {
            content
        }
    }
}

/// Shared title treatment for tool screens: the same icon scale, heading rhythm,
/// readable description width, and action alignment across every module.
struct FeaturePageHeader<Detail: View, Accessory: View>: View {
    let title: Text
    let systemImage: String
    let tint: Color
    let detail: Detail
    let accessory: Accessory

    init(
        title: Text,
        systemImage: String,
        tint: Color,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.detail = detail()
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            identity
                .layoutPriority(1)
            Spacer(minLength: 4)
            accessory
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 4)
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 16) {
            CategoryBadge(systemName: systemImage, tint: tint, size: 54)
                .iconEntrance()
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                title
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                detail
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A minimum width keeps layout probes from measuring the text one
            // character per line, which inflated the header outside scroll views.
            .frame(minWidth: 240, maxWidth: 480, alignment: .leading)
        }
    }
}

struct PressableScale: ViewModifier {
    @State private var hovering = false
    @State private var pressing = false
    var hoverScale: CGFloat = 1.006
    var lift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : pressing ? 0.985 : hovering ? hoverScale : 1)
            .shadow(color: .black.opacity(lift && hovering ? 0.06 : 0), radius: 10, y: 4)
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
            .animation(reduceMotion ? nil : MotionTokens.press, value: pressing)
            .onHover { hovering = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressing = true }
                    .onEnded { _ in pressing = false }
            )
    }
}

extension View {
    func pressable(hoverScale: CGFloat = 1.006, lift: Bool = false) -> some View {
        modifier(PressableScale(hoverScale: hoverScale, lift: lift))
    }
}

struct GlowProminentButtonStyle: ButtonStyle {
    var tint: Color = Tint.accent
    var gradient: LinearGradient = TintGradient.accent
    var breathes = false
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 20 : 16)
            .padding(.vertical, large ? 10 : 8)
            .background(Capsule().fill(gradient))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .modifier(AdaptiveLiquidGlass(tint: tint, shape: .capsule, interactive: true))
            .opacity(configuration.isPressed ? 0.84 : 1)
    }
}

struct AnimatedCheckboxStyle: ToggleStyle {
    var tint: Color = Tint.accent

    func makeBody(configuration: Configuration) -> some View {
        CheckboxBody(configuration: configuration, tint: tint)
    }

    private struct CheckboxBody: View {
        let configuration: ToggleStyleConfiguration
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let isOn = configuration.isOn
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(isOn ? AnyShapeStyle(LinearGradient(colors: [tint, tint.opacity(0.78)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(hovering ? 0.12 : 0.06)))
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .strokeBorder(isOn ? Color.white.opacity(0.35) : Color.white.opacity(hovering ? 0.5 : 0.3), lineWidth: 1)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(isOn ? 1 : 0.3)
                        .opacity(isOn ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .shadow(color: isOn ? tint.opacity(0.45) : .clear, radius: 4, y: 1)
                configuration.label
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.6), value: isOn)
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
                    .toggleStyle(.checkbox)
            }
        }
    }
}

/// Finder icons, looked up once per path. Lists redraw often (hover, live
/// updates), and asking the workspace for the same icon each time adds up.
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2_000
        return cache
    }()

    @MainActor
    static func icon(forFile path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// Whether MacDash is the frontmost app. Endless ambient animations pause
/// while it isn't, so they cost nothing while you work in other apps.
@MainActor
final class AppActivity: ObservableObject {
    static let shared = AppActivity()
    @Published private(set) var isActive = NSApplication.shared.isActive
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in AppActivity.shared.isActive = true }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in AppActivity.shared.isActive = false }
            },
        ]
    }
}

extension TimelineSchedule where Self == AnimationTimelineSchedule {
    /// Smooth enough for slow pulses and glows at half the redraws of the
    /// display's full rate.
    static func ambient(paused: Bool) -> AnimationTimelineSchedule {
        .animation(minimumInterval: 1.0 / 30, paused: paused)
    }
}

/// The app's one search field: a glass capsule that brightens while you type.
struct GlassSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var maxWidth: CGFloat = 340
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(focused ? 0.85 : 0.5))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityLabel("Clear search")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Capsule().fill(.ultraThinMaterial).opacity(0.6)
            Capsule().fill(Color.white.opacity(focused ? 0.12 : 0.07))
        }
        .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(Color.white.opacity(0.45)) : AnyShapeStyle(GlassEdge.gradient), lineWidth: focused ? 1 : 0.7))
        .shadow(color: .white.opacity(focused ? 0.08 : 0), radius: 8)
        .frame(maxWidth: maxWidth)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: focused)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: text.isEmpty)
    }
}

/// Search row built into the top of a glass panel, so a list and its search
/// read as one table instead of two floating pieces.
struct InlineSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(focused ? 0.85 : 0.45))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityLabel("Clear search")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(focused ? 0.1 : 0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(focused ? 0.3 : 0.07), lineWidth: 0.7)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: focused)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: text.isEmpty)
    }
}

/// Icon-only glass circle, for compact row and toolbar actions.
struct GlassIconButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, tint: tint)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(.ultraThinMaterial).opacity(0.7)
                    Circle().fill(Color.white.opacity(hovering && isEnabled ? 0.18 : 0.08))
                }
                .overlay(Circle().strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
                .scaleEffect(configuration.isPressed ? 0.9 : hovering && isEnabled ? 1.06 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
                .animation(MotionTokens.snappy, value: hovering)
                .animation(MotionTokens.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// The one way a screen reports what just happened: a glass strip with a
/// green check or an orange warning, dismissed with its own close button.
struct NoticeBanner: View {
    let text: String
    var isError = false
    let dismiss: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isError ? Tint.orange : Tint.green)
                .scaleEffect(shown || reduceMotion ? 1 : 0.4)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                withAnimation(reduceMotion ? nil : MotionTokens.snappy) { dismiss() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(GlassPanelBackground(cornerRadius: 14))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(isError ? Tint.orange : Tint.green)
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 5)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.55).delay(0.08)) { shown = true }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Loading states

/// A soft highlight sweeping across content while it loads, so waiting
/// reads as progress. Only animates while active.
private struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.55)
                            .offset(x: phase * geometry.size.width * 1.4)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .onAppear {
                        phase = -1
                        withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) { phase = 1 }
                    }
                }
            }
    }
}

extension View {
    func shimmer(_ active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}

/// A placeholder block in the shape of what's coming.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var corner: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.white.opacity(0.09))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .shimmer()
    }
}

/// Where a chart will draw, while its first readings come in.
struct ChartCollectingPlaceholder: View {
    var body: some View {
        ZStack {
            // A faint baseline with a pulse running along it.
            Capsule()
                .fill(Color.white.opacity(0.1))
                .frame(height: 2)
                .shimmer()
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Collecting data…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.18), in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

extension View {
    /// Swaps a chart for the collecting placeholder until it has data.
    func collecting(_ isCollecting: Bool) -> some View {
        opacity(isCollecting ? 0 : 1)
            .overlay { if isCollecting { ChartCollectingPlaceholder() } }
            .animation(.easeInOut(duration: 0.35), value: isCollecting)
    }
}

/// Tells at a glance whether the numbers are live: a green dot sending out
/// a soft ripple while live, a spinner while the first readings come in, or
/// a quiet pause sign while MacDash is in the background.
struct LiveStatusBadge: View {
    let isCollecting: Bool
    let isActive: Bool
    var interval: Int = 2
    @State private var ripple = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLive: Bool { isActive && !isCollecting }

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if isLive {
                    Circle()
                        .stroke(Tint.green.opacity(0.7), lineWidth: 1.2)
                        .frame(width: 8, height: 8)
                        .scaleEffect(ripple ? 2.4 : 1)
                        .opacity(ripple ? 0 : 0.9)
                    Circle().fill(Tint.green).frame(width: 7, height: 7)
                        .shadow(color: Tint.green.opacity(0.9), radius: 3)
                } else if isActive {
                    ProgressView().controlSize(.mini).scaleEffect(0.8)
                } else {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 7.5, weight: .black))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 14, height: 14)
            Group {
                if isLive {
                    Text("Live now")
                } else if isActive {
                    Text("Collecting data…")
                } else {
                    Text("Paused")
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isLive ? Color.white : Color.white.opacity(0.65))
            if isLive {
                Text(verbatim: "\(interval)s")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Tint.green.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Tint.green.opacity(0.14)))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, isLive ? 5 : 11)
        .padding(.vertical, 5)
        .background {
            Capsule().fill(.ultraThinMaterial).opacity(0.5)
            Capsule().fill((isLive ? Tint.green : Color.white).opacity(isLive ? 0.09 : 0.06))
        }
        .overlay(Capsule().strokeBorder(isLive ? AnyShapeStyle(Tint.green.opacity(0.32)) : AnyShapeStyle(GlassEdge.gradient), lineWidth: 0.7))
        .help(isActive ? (isCollecting ? "Taking the first readings. Rates need two of them." : "Updating while this screen is open.") : "Updates pause while MacDash is in the background, so it uses nothing.")
        .animation(.easeInOut(duration: 0.25), value: isCollecting)
        .animation(.easeInOut(duration: 0.25), value: isActive)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ripple = true }
        }
    }
}
