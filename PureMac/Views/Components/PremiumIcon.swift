import AppKit
import SwiftUI

// MacDash's own icon set: every glyph sits on a sculpted body with its own
// silhouette (squircle, hexagon, octagon, circle, soft blob, banner), lit from
// above, with an embossed glyph and, for some, a companion badge. Colors come
// from the screen's theme, so icons always match where they appear.

// MARK: - Shapes

enum PremiumIconShape {
    case squircle, circle, hexagon, octagon, blob, banner, shield
}

/// A polygon with rounded corners, from unit points (0...1).
private struct RoundedPolygon: Shape {
    let points: [CGPoint]
    let cornerFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let pts = points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
        let radius = min(rect.width, rect.height) * cornerFraction
        var path = Path()
        guard pts.count > 2 else { return path }
        let start = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        path.move(to: start)
        for index in 1...pts.count {
            let corner = pts[index % pts.count]
            let next = pts[(index + 1) % pts.count]
            path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        }
        path.closeSubpath()
        return path
    }
}

/// Four soft lobes, like a pillow seen from above.
private struct BlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        let inset: CGFloat = 0.06
        var path = Path()
        path.move(to: CGPoint(x: x + w * 0.5, y: y + h * inset))
        path.addCurve(to: CGPoint(x: x + w * (1 - inset), y: y + h * 0.5),
                      control1: CGPoint(x: x + w * 0.92, y: y - h * 0.04),
                      control2: CGPoint(x: x + w * 1.04, y: y + h * 0.08))
        path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * (1 - inset)),
                      control1: CGPoint(x: x + w * 1.04, y: y + h * 0.92),
                      control2: CGPoint(x: x + w * 0.92, y: y + h * 1.04))
        path.addCurve(to: CGPoint(x: x + w * inset, y: y + h * 0.5),
                      control1: CGPoint(x: x + w * 0.08, y: y + h * 1.04),
                      control2: CGPoint(x: x - w * 0.04, y: y + h * 0.92))
        path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * inset),
                      control1: CGPoint(x: x - w * 0.04, y: y + h * 0.08),
                      control2: CGPoint(x: x + w * 0.08, y: y - h * 0.04))
        path.closeSubpath()
        return path
    }
}

private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        var path = Path()
        path.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.04))
        path.addCurve(to: CGPoint(x: x + w * 0.94, y: y + h * 0.2),
                      control1: CGPoint(x: x + w * 0.66, y: y + h * 0.14),
                      control2: CGPoint(x: x + w * 0.8, y: y + h * 0.18))
        path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.97),
                      control1: CGPoint(x: x + w * 0.96, y: y + h * 0.58),
                      control2: CGPoint(x: x + w * 0.8, y: y + h * 0.84))
        path.addCurve(to: CGPoint(x: x + w * 0.06, y: y + h * 0.2),
                      control1: CGPoint(x: x + w * 0.2, y: y + h * 0.84),
                      control2: CGPoint(x: x + w * 0.04, y: y + h * 0.58))
        path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.04),
                      control1: CGPoint(x: x + w * 0.2, y: y + h * 0.18),
                      control2: CGPoint(x: x + w * 0.34, y: y + h * 0.14))
        path.closeSubpath()
        return path
    }
}

struct PremiumIconBody: Shape {
    let kind: PremiumIconShape

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .squircle:
            return RoundedRectangle(cornerRadius: rect.width * 0.27, style: .continuous).path(in: rect)
        case .circle:
            return Circle().path(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.02))
        case .hexagon:
            let points = (0..<6).map { index -> CGPoint in
                let angle = Double(index) * .pi / 3 - .pi / 2
                return CGPoint(x: 0.5 + 0.5 * cos(angle) * 0.98, y: 0.5 + 0.5 * sin(angle))
            }
            return RoundedPolygon(points: points, cornerFraction: 0.12).path(in: rect)
        case .octagon:
            let points = (0..<8).map { index -> CGPoint in
                let angle = Double(index) * .pi / 4 + .pi / 8
                return CGPoint(x: 0.5 + 0.52 * cos(angle), y: 0.5 + 0.52 * sin(angle))
            }
            return RoundedPolygon(points: points, cornerFraction: 0.1).path(in: rect)
        case .blob:
            return BlobShape().path(in: rect)
        case .banner:
            let points = [CGPoint(x: 0.5, y: 0.02), CGPoint(x: 0.98, y: 0.3), CGPoint(x: 0.98, y: 0.98),
                          CGPoint(x: 0.5, y: 0.84), CGPoint(x: 0.02, y: 0.98), CGPoint(x: 0.02, y: 0.3)]
            return RoundedPolygon(points: points, cornerFraction: 0.08).path(in: rect)
        case .shield:
            return ShieldShape().path(in: rect)
        }
    }
}

// MARK: - Spec

struct PremiumIconSpec {
    var shape: PremiumIconShape = .squircle
    var glyph: String
    var glyphScale: CGFloat = 0.5
    /// A recessed disc behind the glyph, like a dial.
    var disc = false
    /// A companion glyph on its own small body, at the bottom right.
    var badge: (glyph: String, shape: PremiumIconShape, tint: Color?)? = nil

    /// Shapes and companions for the symbols MacDash uses. The color always
    /// comes from where the icon is shown.
    static func make(for symbol: String) -> PremiumIconSpec {
        let base = symbol
        func has(_ parts: String...) -> Bool { parts.contains { base.hasPrefix($0) } }

        switch true {
        case has("desktopcomputer", "display", "macwindow", "laptopcomputer"):
            return PremiumIconSpec(shape: .squircle, glyph: symbol, glyphScale: 0.52, badge: ("sparkles", .circle, nil))
        case has("wand.and.stars", "sparkles", "sparkle"):
            return PremiumIconSpec(shape: .hexagon, glyph: symbol, glyphScale: 0.46)
        case has("square.grid", "app.badge", "app.dashed", "app.fill", "apps"):
            return PremiumIconSpec(shape: .blob, glyph: symbol, glyphScale: 0.44)
        case has("hand.raised", "shield", "checkmark.shield", "lock.shield"):
            return PremiumIconSpec(shape: .octagon, glyph: symbol, glyphScale: 0.46)
        case has("lock", "key"):
            return PremiumIconSpec(shape: .octagon, glyph: symbol, glyphScale: 0.44)
        case has("waveform", "cpu", "memorychip", "gauge", "speedometer"):
            return PremiumIconSpec(shape: .squircle, glyph: symbol, glyphScale: 0.48, disc: true)
        case has("chart.pie", "scope", "dot.radiowaves", "antenna"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.44, disc: true)
        case has("doc.on.doc", "doc", "square.on.square", "rectangle.on.rectangle"):
            return PremiumIconSpec(shape: .blob, glyph: symbol, glyphScale: 0.44)
        case has("photo", "camera", "film"):
            return PremiumIconSpec(shape: .blob, glyph: symbol, glyphScale: 0.44)
        case has("trash", "xmark.bin", "bin"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.42, disc: true)
        case has("internaldrive", "externaldrive", "opticaldiscdrive", "server"):
            return PremiumIconSpec(shape: .squircle, glyph: symbol, glyphScale: 0.5)
        case has("folder", "archivebox", "tray"):
            return PremiumIconSpec(shape: .squircle, glyph: symbol, glyphScale: 0.48)
        case has("wifi"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.44, badge: ("checkmark.shield.fill", .shield, nil))
        case has("envelope", "paperclip", "mail"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.42, disc: true)
        case has("power", "bolt", "battery"):
            return PremiumIconSpec(shape: .squircle, glyph: symbol, glyphScale: 0.48, disc: true)
        case has("exclamationmark", "ant", "ladybug", "xmark.octagon"):
            return PremiumIconSpec(shape: .squircle, glyph: symbol, glyphScale: 0.5)
        case has("wrench", "hammer", "screwdriver", "gearshape.2"):
            return PremiumIconSpec(shape: .banner, glyph: symbol, glyphScale: 0.42)
        case has("arrow.up", "arrow.down", "arrow.triangle", "arrow.clockwise", "icloud.and.arrow"):
            return PremiumIconSpec(shape: .hexagon, glyph: symbol, glyphScale: 0.4, disc: true)
        case has("puzzlepiece", "safari", "globe", "network"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.48)
        case has("clock", "timer", "calendar", "hourglass"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.46, disc: true, badge: ("person.fill", .circle, nil))
        case has("magnifyingglass", "eye"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.46)
        case has("person", "figure"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.46)
        case has("checkmark.seal", "checkmark.circle", "checkmark"):
            return PremiumIconSpec(shape: .hexagon, glyph: symbol, glyphScale: 0.46)
        case has("gearshape"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.5)
        case has("music", "speaker", "headphones"):
            return PremiumIconSpec(shape: .blob, glyph: symbol, glyphScale: 0.44)
        case has("terminal", "chevron.left.forwardslash", "curlybraces", "hammer.circle"):
            return PremiumIconSpec(shape: .squircle, glyph: symbol, glyphScale: 0.46)
        case has("bubble", "message", "text.bubble"):
            return PremiumIconSpec(shape: .circle, glyph: symbol, glyphScale: 0.46)
        case has("cart", "bag", "shippingbox", "cube"):
            return PremiumIconSpec(shape: .hexagon, glyph: symbol, glyphScale: 0.44)
        default:
            return PremiumIconSpec(shape: .squircle, glyph: symbol, glyphScale: 0.48)
        }
    }
}

// MARK: - Icon

/// Settings keeps plain system symbols; everywhere else uses MacDash's icons.
private struct PremiumIconsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

/// The color of the screen an icon sits on. Icons follow it, so a screen
/// reads in one color family instead of a fruit salad.
private struct ThemeTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var premiumIconsEnabled: Bool {
        get { self[PremiumIconsEnabledKey.self] }
        set { self[PremiumIconsEnabledKey.self] = newValue }
    }

    var themeTint: Color? {
        get { self[ThemeTintKey.self] }
        set { self[ThemeTintKey.self] = newValue }
    }
}

/// `.color` leans toward the screen's color; `.glass` is nearly white, for
/// places that should stay calm.
enum PremiumIconStyle {
    case color, glass
}

/// MacDash's own icon: the symbol itself, with thickness, a light face that
/// blends white with the screen's color, and a soft glow. No plate or border
/// around it. Status colors (green, orange, red, yellow) keep their meaning
/// and are used as given; any other color follows the screen.
struct PremiumIcon: View {
    let spec: PremiumIconSpec
    let tint: Color
    var size: CGFloat = 40
    /// Lifts the icon a little, for hover and selection.
    var isRaised = false
    var style: PremiumIconStyle = .color
    @Environment(\.themeTint) private var themeTint

    init(systemName: String, tint: Color, size: CGFloat = 40, isRaised: Bool = false, style: PremiumIconStyle = .color) {
        self.spec = PremiumIconSpec.make(for: systemName)
        self.tint = tint
        self.size = size
        self.isRaised = isRaised
        self.style = style
    }

    init(spec: PremiumIconSpec, tint: Color, size: CGFloat = 40, isRaised: Bool = false, style: PremiumIconStyle = .color) {
        self.spec = spec
        self.tint = tint
        self.size = size
        self.isRaised = isRaised
        self.style = style
    }

    static let statusTints: [Color] = [Tint.green, Tint.orange, Tint.red, Tint.yellow]

    var body: some View {
        let isStatus = Self.statusTints.contains(tint)
        let color = isStatus ? tint : (themeTint ?? tint)
        let whiteness: Double = isStatus ? 0.12 : (style == .glass ? 0.62 : 0.32)
        ThemedGlyph(symbol: spec.glyph, size: size, color: color, whiteness: whiteness)
            .frame(width: size, height: size)
            .scaleEffect(isRaised ? 1.08 : 1)
            .offset(y: isRaised ? -size * 0.04 : 0)
            .animation(MotionTokens.snappy, value: isRaised)
            .accessibilityHidden(true)
    }
}

/// A symbol with depth: a few darker layers stacked under the face give it
/// thickness, the face runs from white into the tinted color, a sheen sits
/// on top and a soft glow lifts it off the background.
struct ThemedGlyph: View {
    let symbol: String
    let size: CGFloat
    let color: Color
    /// How much white is mixed into the face, 0...1.
    var whiteness: Double = 0.32

    var body: some View {
        let font = Font.system(size: size * 0.74, weight: .semibold, design: .rounded)
        let face = color.mixedWithWhite(whiteness)
        let depth = color.adjusted(hue: 0, saturation: 1.05, brightness: 0.5)
        let step = max(0.35, size * 0.016)
        ZStack {
            ForEach(1..<4) { layer in
                Image(systemName: symbol)
                    .font(font)
                    .foregroundStyle(depth.opacity(0.75 - Double(layer) * 0.12))
                    .offset(y: step * CGFloat(layer))
            }
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(LinearGradient(colors: [Color.white, face], startPoint: .top, endPoint: .bottom))
            // A sheen across the upper half.
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(Color.white.opacity(0.55))
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))
        }
        .symbolRenderingMode(.monochrome)
        .shadow(color: color.opacity(0.35), radius: size * 0.14)
        .shadow(color: .black.opacity(0.22), radius: size * 0.03, y: size * 0.03)
    }
}

// MARK: - Showcase

/// The icon with a soft halo, for empty states and heroes. It floats and its
/// halo breathes, driven by Core Animation so the motion runs in the render
/// server and costs the app nothing; it pops in when it first appears.
/// Motion stops with Reduce Motion.
struct PremiumHeroIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themeTint) private var themeTint
    @State private var appeared = false

    var body: some View {
        let glow = PremiumIcon.statusTints.contains(tint) ? tint : (themeTint ?? tint)
        ZStack {
            LayerMotion(kind: .breathe, period: 3.6, amount: 0.35, animate: !reduceMotion) {
                Circle()
                    .fill(RadialGradient(colors: [glow.opacity(0.42), glow.opacity(0.12), .clear], center: .center, startRadius: 2, endRadius: size * 0.95))
                    .frame(width: size * 1.8, height: size * 1.8)
            }
            .frame(width: size * 1.8, height: size * 1.8)
            LayerMotion(kind: .float, period: 4.2, amount: size * 0.05, animate: !reduceMotion) {
                PremiumIcon(systemName: systemName, tint: tint, size: size)
                    .environment(\.themeTint, themeTint)
                    .padding(size * 0.2)
            }
            .frame(width: size * 1.4, height: size * 1.4)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { appeared = true }
        }
        .accessibilityHidden(true)
    }
}

/// Hosts SwiftUI content in a layer that Core Animation moves on its own, so
/// endless ambient motion runs in the render server instead of redrawing the
/// view every frame.
struct LayerMotion<Content: View>: NSViewRepresentable {
    enum Kind {
        /// Up and down by `amount` points.
        case float
        /// Opacity down to `1 - amount` and back.
        case breathe
    }

    let kind: Kind
    let period: Double
    var amount: CGFloat = 0
    var animate = true
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> CenteredHostView<Content> {
        let view = CenteredHostView(rootView: content)
        view.motion = animation
        view.applyMotion(animate)
        return view
    }

    func updateNSView(_ view: CenteredHostView<Content>, context: Context) {
        view.host.rootView = content
        view.applyMotion(animate)
    }

    private var animation: CAAnimation {
        let result: CAAnimation
        switch kind {
        case .float:
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = -amount
            move.toValue = amount
            move.duration = period / 2
            move.autoreverses = true
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            result = move
        case .breathe:
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 1 - amount
            fade.duration = period / 2
            fade.autoreverses = true
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            result = fade
        }
        result.repeatCount = .infinity
        result.isRemovedOnCompletion = false
        return result
    }
}

/// A view whose hosted content's layer is anchored at its center, so Core
/// Animation scales and turns it in place.
final class CenteredHostView<Content: View>: NSView {
    let host: NSHostingView<Content>
    var motion: CAAnimation?
    private let key = "mactidy.motion"
    private var running = false

    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        // The SwiftUI frame around this view sets its size; the hosted
        // content must not feed sizes back, or layout would loop.
        host.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        host.wantsLayer = true
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Purely decorative: clicks and hovers go to the SwiftUI around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        recenter()
    }

    /// Keeps the hosted layer anchored at its center. AppKit may put the
    /// geometry back after a layout, so this re-applies it, but only when it
    /// differs; touching the layer every pass would schedule another layout.
    private func recenter() {
        if host.frame != bounds { host.frame = bounds }
        guard let layer = host.layer else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let anchor = CGPoint(x: 0.5, y: 0.5)
        if layer.anchorPoint != anchor { layer.anchorPoint = anchor }
        if layer.position != center { layer.position = center }
    }

    func applyMotion(_ animate: Bool) {
        guard let layer = host.layer else { return }
        #if DEBUG
        let animate = animate && !UserDefaults.standard.bool(forKey: "DebugNoMotion")
        #endif
        if animate, !running, let motion {
            layer.add(motion, forKey: key)
            running = true
        } else if !animate, running {
            layer.removeAnimation(forKey: key)
            running = false
        }
    }

    // Layers lose their animations when the view leaves the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recenter()
        guard window != nil, running, let layer = host.layer, layer.animation(forKey: key) == nil, let motion else { return }
        layer.add(motion, forKey: key)
    }
}

/// A header icon pops in with a little turn when its screen opens, and
/// wiggles when the pointer passes over it.
private struct IconEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var wiggle = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || reduceMotion ? 1 : 0.55)
            .rotationEffect(.degrees(shown || reduceMotion ? (wiggle ? -6 : 0) : -18))
            .opacity(shown || reduceMotion ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.58).delay(0.05)) { shown = true }
            }
            .onHover { hovering in
                guard !reduceMotion, hovering else { return }
                withAnimation(.spring(response: 0.18, dampingFraction: 0.35)) { wiggle = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { wiggle = false }
                }
            }
    }
}

extension View {
    func iconEntrance() -> some View { modifier(IconEntrance()) }
}

#if DEBUG
/// Debug builds only: `-DebugIconGallery /path.png` renders every icon shape
/// in each theme color to a PNG, for design review.
enum PremiumIconGallery {
    static let symbols = [
        "desktopcomputer", "wand.and.stars", "square.grid.2x2.fill", "hand.raised.fill", "waveform.path.ecg.rectangle.fill",
        "chart.pie.fill", "doc.on.doc.fill", "photo.stack.fill", "trash.fill", "internaldrive.fill", "wifi",
        "envelope.fill", "power", "exclamationmark.triangle.fill", "wrench.and.screwdriver.fill", "arrow.up",
        "puzzlepiece.extension.fill", "clock.fill", "lock.open.fill", "folder.fill", "battery.75", "magnifyingglass"
    ]

    @MainActor
    static func render(to path: String) {
        let tints: [Color] = [SectionPalette.smartCare.accent, SectionPalette.cleanup.accent, SectionPalette.apps.accent,
                              SectionPalette.protection.accent, SectionPalette.processes.accent, SectionPalette.spaceLens.accent,
                              SectionPalette.duplicates.accent, SectionPalette.photos.accent]
        let view = VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(tints.enumerated()), id: \.offset) { _, tint in
                HStack(spacing: 18) {
                    ForEach(symbols, id: \.self) { symbol in
                        PremiumIcon(systemName: symbol, tint: tint, size: 64)
                    }
                }
            }
            HStack(spacing: 22) {
                ForEach(["/x/a.dmg", "/x/a.zip", "/x/a.pdf", "/x/a.png", "/x/a.mov", "/x/a.mp3", "/x/a.txt", "/x/a.json", "/x/a.log", "/x/a.db", "/x/a.pkg", "/x/a.xyz", "/Applications", "/System/Applications/Notes.app"], id: \.self) { path in
                    FileIcon(path: path, size: 26)
                }
            }
            .padding(14)
            .background(Color(red: 0.3, green: 0.12, blue: 0.45), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 24) {
                ForEach([16, 22, 28, 40, 54, 96], id: \.self) { size in
                    PremiumIcon(systemName: "wifi", tint: SectionPalette.protection.accent, size: CGFloat(size))
                }
            }
        }
        .padding(30)
        .background(Color(red: 0.12, green: 0.06, blue: 0.24))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif

// MARK: - Files

/// A calm icon for a file in a list: folders and apps keep their real Finder
/// icon; anything else is a frosted page with a symbol for its kind (disk
/// image, archive, PDF, picture…), so it never looks like a blank, broken
/// document.
struct FileIcon: View {
    let path: String
    var size: CGFloat = 26

    var body: some View {
        let kind = FileKind.of(path)
        Group {
            if kind == .folder || kind == .application {
                Image(nsImage: IconCache.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
            } else {
                FilePage(kind: kind, size: size)
            }
        }
        .frame(width: size, height: size)
        .help(kind.label)
        .accessibilityHidden(true)
    }
}

enum FileKind: Equatable {
    case folder, application, diskImage, archive, pdf, image, video, audio, text, code, log, data, installer, other

    private static var cache: [String: FileKind] = [:]

    @MainActor
    static func of(_ path: String) -> FileKind {
        if let cached = cache[path] { return cached }
        let kind = resolve(path)
        cache[path] = kind
        return kind
    }

    private static func resolve(_ path: String) -> FileKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "app" { return .application }
        var isDirectory: ObjCBool = false
        if ext.isEmpty || !["dmg", "zip", "pkg"].contains(ext),
           FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .folder
        }
        switch ext {
        case "dmg", "iso", "sparseimage", "sparsebundle", "img": return .diskImage
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "xip": return .archive
        case "pkg", "mpkg": return .installer
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "webp", "bmp", "raw", "cr2", "nef", "dng", "psd", "svg": return .image
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return .video
        case "mp3", "m4a", "aac", "wav", "aiff", "flac", "caf": return .audio
        case "txt", "rtf", "md", "doc", "docx", "pages", "csv": return .text
        case "swift", "js", "ts", "py", "rb", "c", "h", "m", "json", "xml", "html", "css", "plist", "yml", "yaml", "sh": return .code
        case "log", "crash", "ips", "diag": return .log
        case "db", "sqlite", "sqlite3", "cache", "dat", "bin", "data": return .data
        default: return .other
        }
    }

    var symbol: String {
        switch self {
        case .diskImage: return "externaldrive.fill"
        case .archive: return "doc.zipper"
        case .installer: return "shippingbox.fill"
        case .pdf: return "doc.richtext.fill"
        case .image: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .text: return "text.alignleft"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .log: return "list.bullet"
        case .data: return "cylinder.split.1x2.fill"
        case .folder: return "folder.fill"
        case .application: return "app.fill"
        case .other: return "doc.fill"
        }
    }

    /// A hint of color so kinds can be told apart without shouting.
    var tint: Color {
        switch self {
        case .diskImage, .installer: return Color(red: 0.62, green: 0.72, blue: 1.0)
        case .archive: return Color(red: 0.95, green: 0.82, blue: 0.55)
        case .pdf: return Color(red: 1.0, green: 0.62, blue: 0.62)
        case .image: return Color(red: 0.6, green: 0.9, blue: 0.75)
        case .video: return Color(red: 0.85, green: 0.65, blue: 1.0)
        case .audio: return Color(red: 1.0, green: 0.62, blue: 0.85)
        case .code: return Color(red: 0.6, green: 0.85, blue: 1.0)
        default: return Color.white
        }
    }

    var label: String {
        switch self {
        case .folder: return String(localized: "Folder")
        case .application: return String(localized: "App")
        case .diskImage: return String(localized: "Disk image")
        case .archive: return String(localized: "Compressed file")
        case .installer: return String(localized: "Installer package")
        case .pdf: return "PDF"
        case .image: return String(localized: "Image")
        case .video: return String(localized: "Video")
        case .audio: return String(localized: "Audio")
        case .text: return String(localized: "Document")
        case .code: return String(localized: "Code")
        case .log: return String(localized: "Log")
        case .data: return String(localized: "Data")
        case .other: return String(localized: "File")
        }
    }
}

/// A page with a folded corner, in frosted glass.
private struct PageShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let inset = w * 0.12, fold = w * 0.26, radius = w * 0.1
        let left = rect.minX + inset, right = rect.maxX - inset
        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: right - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: rect.maxY), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - radius), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()
        _ = h
        return path
    }
}

private struct FilePage: View {
    let kind: FileKind
    let size: CGFloat

    var body: some View {
        let page = PageShape()
        let inset = size * 0.12, fold = size * 0.26
        ZStack {
            page.fill(LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.1)], startPoint: .top, endPoint: .bottom))
            page.stroke(LinearGradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0.18)], startPoint: .top, endPoint: .bottom), lineWidth: max(0.6, size * 0.035))
            // The folded corner.
            Path { path in
                let right = size - inset
                path.move(to: CGPoint(x: right - fold, y: 0))
                path.addLine(to: CGPoint(x: right - fold, y: fold * 0.8))
                path.addQuadCurve(to: CGPoint(x: right - fold * 0.8, y: fold), control: CGPoint(x: right - fold, y: fold))
                path.addLine(to: CGPoint(x: right, y: fold))
                path.closeSubpath()
            }
            .fill(Color.white.opacity(0.35))
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color.white, kind.tint], startPoint: .top, endPoint: .bottom))
                .offset(y: size * 0.06)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: size * 0.05, y: size * 0.03)
    }
}

/// Rings that swell outward from the center and fade, drawn as Core
/// Animation shapes in a layer this view owns, so they always stay centered.
struct RippleRings: NSViewRepresentable {
    let color: Color
    var diameter: CGFloat
    var count = 3
    var period: Double = 2.4
    var growth: CGFloat = 0.75
    var fillOpacity: Double = 0
    var lineWidth: CGFloat = 2
    var animate = true

    func makeNSView(context: Context) -> RippleView {
        RippleView()
    }

    func updateNSView(_ view: RippleView, context: Context) {
        view.configure(color: NSColor(color), diameter: diameter, count: count, period: period, growth: growth,
                       fillOpacity: fillOpacity, lineWidth: lineWidth, animate: animate)
    }

    final class RippleView: NSView {
        private let host = CALayer()
        private var rings: [CAShapeLayer] = []
        private var signature = ""

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = host
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rings.forEach { $0.position = center }
            CATransaction.commit()
        }

        func configure(color: NSColor, diameter: CGFloat, count: Int, period: Double, growth: CGFloat,
                       fillOpacity: Double, lineWidth: CGFloat, animate: Bool) {
            let key = "\(color)|\(diameter)|\(count)|\(period)|\(growth)|\(fillOpacity)|\(lineWidth)|\(animate)"
            guard key != signature else { return }
            signature = key
            rings.forEach { $0.removeFromSuperlayer() }
            rings = (0..<count).map { index in
                let ring = CAShapeLayer()
                ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
                ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
                ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
                ring.strokeColor = color.cgColor
                ring.fillColor = color.withAlphaComponent(fillOpacity).cgColor
                ring.lineWidth = lineWidth
                if animate {
                    let scale = CABasicAnimation(keyPath: "transform.scale")
                    scale.fromValue = 1
                    scale.toValue = 1 + growth
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 1
                    fade.toValue = 0
                    let group = CAAnimationGroup()
                    group.animations = [scale, fade]
                    group.duration = period
                    group.repeatCount = .infinity
                    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    group.timeOffset = period * Double(index) / Double(count)
                    group.isRemovedOnCompletion = false
                    ring.add(group, forKey: "ripple")
                } else {
                    ring.opacity = index == 0 ? 0.5 : 0
                }
                host.addSublayer(ring)
                return ring
            }
        }
    }
}

/// A ring whose highlight travels around it, as a conic gradient masked to
/// the ring and turned by Core Animation in a layer this view owns.
struct SpinningRim: NSViewRepresentable {
    let colors: [Color]
    var diameter: CGFloat
    var lineWidth: CGFloat = 2
    var period: Double = 4
    var animate = true

    func makeNSView(context: Context) -> RimView { RimView() }

    func updateNSView(_ view: RimView, context: Context) {
        view.configure(colors: colors.map { NSColor($0).cgColor }, diameter: diameter, lineWidth: lineWidth, period: period, animate: animate)
    }

    final class RimView: NSView {
        private let host = CALayer()
        private let gradient = CAGradientLayer()
        private let mask = CAShapeLayer()
        private var signature = ""

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = host
            wantsLayer = true
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.mask = mask
            host.addSublayer(gradient)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        func configure(colors: [CGColor], diameter: CGFloat, lineWidth: CGFloat, period: Double, animate: Bool) {
            let key = "\(colors)|\(diameter)|\(lineWidth)|\(period)|\(animate)"
            guard key != signature else { return }
            signature = key
            gradient.colors = colors
            gradient.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            gradient.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
            mask.frame = gradient.bounds
            mask.path = CGPath(ellipseIn: gradient.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            mask.lineWidth = lineWidth
            gradient.removeAnimation(forKey: "spin")
            guard animate else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -Double.pi * 2
            turn.duration = period
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            gradient.add(turn, forKey: "spin")
        }
    }
}
