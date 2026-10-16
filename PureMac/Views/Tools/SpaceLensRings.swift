import SwiftUI

/// Rings view of Space Lens: the current folder in the middle, its items in
/// the first ring and their contents in the rings beyond. Each slice's angle
/// is its share of the folder above it.
///
/// Every slice keeps the same identity at every level, so moving between
/// folders is one continuous motion: the opened slice widens into the center
/// while its contents spread around the circle, and going back reverses it.
struct SpaceLensRings: View {
    @ObservedObject var model: SpaceLensModel
    let folder: SpaceNode

    @State private var hoveredKey: String?
    @StateObject private var morph = SunburstMorph()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVolumeRoot: Bool { model.path.count == 1 && model.volumeFree != nil }

    var body: some View {
        VStack(spacing: 10) {
            CardSurface(padding: 8, elevation: .standard) {
                GeometryReader { proxy in
                    let geometry = Sunburst.Geometry(size: proxy.size)
                    let slices = morph.update(
                        folder: folder,
                        geometry: geometry,
                        free: isVolumeRoot ? model.volumeFree ?? 0 : 0,
                        animated: !reduceMotion
                    )
                    let hovered = slices.first { $0.key == hoveredKey }
                    ZStack {
                        TimelineView(.animation(minimumInterval: nil, paused: !morph.isMoving)) { timeline in
                            SunburstCanvas(
                                frames: morph.frames(at: timeline.date),
                                geometry: geometry,
                                highlighted: highlightedKey(hovered: hovered, in: slices),
                                picked: Set(model.picks.keys)
                            )
                        }
                        centerLabel(hovered: hovered, geometry: geometry)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let slice = Sunburst.hit(point, in: slices, geometry: geometry)
                            // Only redraw when the pointer moves onto another slice.
                            guard slice?.key != hoveredKey else { return }
                            hoveredKey = slice?.key
                            model.hovered = slice?.node
                        case .ended:
                            hoveredKey = nil
                            model.hovered = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        tap(at: value.location, slices: slices, geometry: geometry)
                    })
                }
                .overlay {
                    if folder.children.isEmpty {
                        Text(folder.isUnreadable ? "No access" : "Empty")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            SpaceInfoBar(model: model, folder: folder)
            legend
        }
        .onChange(of: ObjectIdentifier(folder)) { _ in
            // The slice under the pointer belonged to the previous level.
            hoveredKey = nil
        }
    }

    /// The slice under the pointer, or the one matching the list row under it.
    private func highlightedKey(hovered: Sunburst.Slice?, in slices: [Sunburst.Slice]) -> String? {
        if let hovered { return hovered.key }
        guard let node = model.hovered else { return nil }
        return slices.first { $0.node === node }?.key
    }

    private func tap(at point: CGPoint, slices: [Sunburst.Slice], geometry: Sunburst.Geometry) {
        guard !morph.isMoving else { return }
        if geometry.isInCenter(point) {
            model.goUp()
            return
        }
        guard let slice = Sunburst.hit(point, in: slices, geometry: geometry), let node = slice.node else { return }
        if node.canOpen {
            model.open(trail: slice.trail)
        } else if slice.trail.count == 1 {
            if model.canPick(node) { model.togglePick(node) }
        } else {
            // A file further out: open the folder that holds it.
            model.open(trail: Array(slice.trail.dropLast()))
            model.hovered = node
        }
    }

    private func centerLabel(hovered: Sunburst.Slice?, geometry: Sunburst.Geometry) -> some View {
        let size = hovered?.size ?? folder.size
        let title = hovered?.title ?? folder.name
        return VStack(spacing: 2) {
            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                .font(.system(size: geometry.centerRadius > 70 ? 22 : 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 2)
                .opacity(hovered == nil && model.path.count > 1 ? 1 : 0)
        }
        .frame(width: geometry.centerRadius * 1.6)
        .position(geometry.center)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: hovered?.key)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            swatch(Sunburst.Paint.forItem(angle: 0.15, depth: 1, isFile: false).color, "Folders")
            swatch(Sunburst.Paint.forItem(angle: 0.15, depth: 1, isFile: true).color, "Files")
            swatch(Sunburst.Paint.group.color, "Smaller items")
            if folder.children.contains(where: { $0.kind == .hidden }) {
                swatch(SpaceCategory.system.color, "System & hidden data")
            }
            if isVolumeRoot {
                swatch(Sunburst.Paint.free.color, "Free space")
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .help("Click a ring to open it, the center to go back")
    }

    private func swatch(_ color: Color, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 9, height: 9)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

// MARK: - Motion

/// Keeps the current layout and, after a change, where each slice came from,
/// so frames in between can be drawn. Hovering never lays the rings out again.
private final class SunburstMorph: ObservableObject {
    private struct Key: Equatable {
        let folder: ObjectIdentifier
        let size: Int64
        let count: Int
        let free: Int64
        let width: CGFloat
        let height: CGFloat
    }

    static let duration: TimeInterval = 0.55

    private var key: Key?
    private var target: [Sunburst.Slice] = []
    private var targetFrames: [Sunburst.Frame] = []
    private var origin: [String: Sunburst.Frame] = [:]
    private var startedAt = Date.distantPast

    var isMoving: Bool { Date().timeIntervalSince(startedAt) < Self.duration }

    /// Lays the rings out when something changed and starts the motion
    /// from what is on screen right now.
    func update(folder: SpaceNode, geometry: Sunburst.Geometry, free: Int64, animated: Bool) -> [Sunburst.Slice] {
        let key = Key(folder: ObjectIdentifier(folder), size: folder.size, count: folder.children.count, free: free,
                      width: geometry.center.x, height: geometry.center.y)
        guard key != self.key else { return target }
        let onlyResized = self.key.map { $0.folder == key.folder && $0.size == key.size && $0.count == key.count && $0.free == key.free } ?? false
        let now = Date()
        let onScreen = frames(at: now)
        self.key = key

        target = Sunburst.layout(folder: folder, geometry: geometry, free: free)
        // The center folder is drawn as a full ring at depth 0 so it can grow
        // out of, or shrink into, the middle.
        let center = Sunburst.Frame(key: Sunburst.key(for: folder), start: 0, end: 2 * .pi, depth: 0, paint: .center, alpha: 0)
        targetFrames = [center] + target.map(Sunburst.Frame.init)

        guard animated, !onlyResized else {
            origin = [:]
            startedAt = .distantPast
            return target
        }
        // Whatever is on screen is where each slice starts from. The old
        // center is in there as a depth-0 ring, so going back up it grows
        // out of the middle into its slice.
        origin = Dictionary(onScreen.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        startedAt = now
        // Wake the view once the motion is over so its timeline can pause.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.05) { [weak self] in
            self?.objectWillChange.send()
        }
        return target
    }

    /// The frames to draw at `date`: every target slice on its way from where
    /// it was, plus the slices that are leaving, fading out.
    func frames(at date: Date) -> [Sunburst.Frame] {
        let raw = min(1, max(0, date.timeIntervalSince(startedAt) / Self.duration))
        guard raw < 1, !origin.isEmpty || startedAt != .distantPast else { return targetFrames }
        let t = 1 - pow(1 - raw, 3)
        var result: [Sunburst.Frame] = []
        var arriving = Set<String>()
        for frame in targetFrames {
            arriving.insert(frame.key)
            if let from = origin[frame.key] {
                result.append(from.interpolated(to: frame, t: t))
            } else {
                // New slices fade in from the inner edge of their ring, outer
                // rings a moment after inner ones.
                let delay = min(0.5, max(0, frame.depth - 1) * 0.12)
                let local = min(1, max(0, (raw - delay) / (1 - delay)))
                let eased = 1 - pow(1 - local, 3)
                var incoming = frame
                incoming.alpha = frame.alpha * eased
                incoming.reach = eased
                result.append(incoming)
            }
        }
        // Leaving slices fade where they are; they are drawn first, beneath.
        let leaving = origin.values
            .filter { !arriving.contains($0.key) }
            .map { frame -> Sunburst.Frame in
                var frame = frame
                frame.alpha *= 1 - t
                return frame
            }
        return leaving.sorted { $0.depth < $1.depth } + result.sorted { $0.depth < $1.depth }
    }
}

// MARK: - Layout

enum Sunburst {
    struct Geometry {
        let center: CGPoint
        let centerRadius: CGFloat
        let ringWidth: CGFloat
        let rings: Int

        init(size: CGSize) {
            let radius = max(40, min(size.width, size.height) / 2 - 10)
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            rings = radius > 280 ? 5 : 4
            centerRadius = radius * 0.24
            ringWidth = (radius - centerRadius) / CGFloat(rings)
        }

        /// Radii for a ring; fractional depths sit between rings, and depths
        /// below 1 shrink toward the center disc.
        func radii(depth: Double) -> (inner: CGFloat, outer: CGFloat) {
            let d = CGFloat(max(0, depth))
            if d >= 1 {
                return (centerRadius + (d - 1) * ringWidth + 1.5, centerRadius + d * ringWidth)
            }
            return ((centerRadius + 1.5) * d, centerRadius + ringWidth * d)
        }

        /// Distance from the center and angle clockwise from 12 o'clock.
        func polar(_ point: CGPoint) -> (radius: CGFloat, angle: Double) {
            let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
            var angle = atan2(dx, -dy)
            if angle < 0 { angle += 2 * .pi }
            return (CGFloat(hypot(dx, dy)), angle)
        }

        func isInCenter(_ point: CGPoint) -> Bool { polar(point).radius < centerRadius }
    }

    /// A color as hue, saturation, brightness and opacity, so it can be
    /// blended smoothly while a slice moves.
    struct Paint {
        var hue: Double
        var saturation: Double
        var brightness: Double
        var opacity: Double

        var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness, opacity: opacity) }

        static let group = Paint(hue: 0, saturation: 0, brightness: 1, opacity: 0.2)
        static let free = Paint(hue: 0, saturation: 0, brightness: 1, opacity: 0.13)
        static let system = Paint(hue: 0.63, saturation: 0.24, brightness: 0.68, opacity: 1)
        static let center = Paint(hue: 0, saturation: 0, brightness: 1, opacity: 0.12)

        /// Hue follows the position around the circle, so a folder and
        /// everything inside it share a color family; outer rings get
        /// lighter, files softer.
        static func forItem(angle: Double, depth: Int, isFile: Bool) -> Paint {
            var hue = 0.60 + angle * 0.47
            if hue > 1 { hue -= 1 }
            let saturation = (isFile ? 0.38 : 0.66) - Double(depth - 1) * 0.04
            return Paint(hue: hue, saturation: max(0.2, saturation), brightness: 0.97 - Double(depth - 1) * 0.05, opacity: 1)
        }

        func blended(to other: Paint, t: Double) -> Paint {
            // Gray paints have no meaningful hue; take the other one's.
            let fromHue = saturation < 0.01 ? other.hue : hue
            let toHue = other.saturation < 0.01 ? fromHue : other.hue
            var delta = toHue - fromHue
            if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
            var blendedHue = fromHue + delta * t
            if blendedHue < 0 { blendedHue += 1 } else if blendedHue >= 1 { blendedHue -= 1 }
            return Paint(
                hue: blendedHue,
                saturation: saturation + (other.saturation - saturation) * t,
                brightness: brightness + (other.brightness - brightness) * t,
                opacity: opacity + (other.opacity - opacity) * t
            )
        }
    }

    enum Kind {
        case item
        /// The tail of a folder's items, too thin to draw one by one.
        case group(count: Int)
        case free
    }

    struct Slice {
        let key: String
        let kind: Kind
        let node: SpaceNode?
        /// From a child of the center folder down to this item.
        let trail: [SpaceNode]
        let start: Double
        let end: Double
        let depth: Int
        let size: Int64
        let paint: Paint

        var title: String {
            switch kind {
            case .item: return node?.name ?? ""
            case .group(let count): return String(format: String(localized: "%lld smaller items"), Int64(count))
            case .free: return String(localized: "Free space")
            }
        }
    }

    /// One slice as drawn, possibly halfway between two layouts.
    struct Frame {
        let key: String
        var start: Double
        var end: Double
        var depth: Double
        var paint: Paint
        var alpha: Double
        /// How far the slice reaches across its ring (it grows outward).
        var reach: Double = 1
        var isFree = false

        init(key: String, start: Double, end: Double, depth: Double, paint: Paint, alpha: Double) {
            self.key = key
            self.start = start
            self.end = end
            self.depth = depth
            self.paint = paint
            self.alpha = alpha
        }

        init(_ slice: Slice) {
            self.init(key: slice.key, start: slice.start, end: slice.end, depth: Double(slice.depth), paint: slice.paint, alpha: 1)
            if case .free = slice.kind { isFree = true }
        }

        func interpolated(to target: Frame, t: Double) -> Frame {
            var frame = target
            frame.start = start + (target.start - start) * t
            frame.end = end + (target.end - end) * t
            frame.depth = depth + (target.depth - depth) * t
            frame.paint = paint.blended(to: target.paint, t: t)
            frame.alpha = alpha + (target.alpha - alpha) * t
            frame.reach = reach + (target.reach - reach) * t
            return frame
        }
    }

    /// The same key for a node at every level, so its slice can be followed.
    static func key(for node: SpaceNode) -> String { "n\(UInt(bitPattern: ObjectIdentifier(node).hashValue))" }

    /// Slices thinner than this many points along their ring are folded.
    private static let minimumArc: CGFloat = 4
    private static let maximumSlices = 6_000

    static func layout(folder: SpaceNode, geometry: Geometry, free: Int64) -> [Slice] {
        let total = folder.size
        guard total > 0 else { return [] }
        let whole = Double(total + max(free, 0))
        var slices: [Slice] = []

        if free > 0 {
            let start = 2 * .pi * Double(total) / whole
            slices.append(Slice(key: "free", kind: .free, node: nil, trail: [], start: start, end: 2 * .pi, depth: 1, size: free, paint: .free))
        }

        func place(_ items: [SpaceNode], in parent: SpaceNode, parentSize: Double, start: Double, span: Double, depth: Int, trail: [SpaceNode]) {
            guard depth <= geometry.rings, parentSize > 0 else { return }
            let radii = geometry.radii(depth: Double(depth))
            let minimumAngle = Double(minimumArc / max(1, (radii.inner + radii.outer) / 2))
            var angle = start
            for (index, node) in items.enumerated() where node.size > 0 {
                if slices.count >= maximumSlices { return }
                let share = span * Double(node.size) / parentSize
                if share < minimumAngle {
                    let rest = items[index...].reduce(Int64(0)) { $0 + $1.size }
                    let restAngle = span * Double(rest) / parentSize
                    if restAngle >= minimumAngle * 0.5 {
                        slices.append(Slice(
                            key: "g" + key(for: parent), kind: .group(count: items.count - index), node: nil, trail: trail,
                            start: angle, end: angle + restAngle, depth: depth, size: rest, paint: .group
                        ))
                    }
                    return
                }
                let path = trail + [node]
                let paint: Paint
                switch node.kind {
                case .smallerFiles: paint = .group
                case .hidden: paint = .system
                default: paint = .forItem(angle: (angle + share / 2) / (2 * .pi), depth: depth, isFile: node.kind != .folder)
                }
                slices.append(Slice(key: key(for: node), kind: .item, node: node, trail: path, start: angle, end: angle + share, depth: depth, size: node.size, paint: paint))
                if node.canOpen, share > minimumAngle * 1.5 {
                    place(node.children, in: node, parentSize: Double(node.size), start: angle, span: share, depth: depth + 1, trail: path)
                }
                angle += share
            }
        }

        place(folder.children, in: folder, parentSize: whole, start: 0, span: 2 * .pi, depth: 1, trail: [])
        return slices
    }

    static func hit(_ point: CGPoint, in slices: [Slice], geometry: Geometry) -> Slice? {
        let polar = geometry.polar(point)
        guard polar.radius >= geometry.centerRadius else { return nil }
        let depth = Int((polar.radius - geometry.centerRadius) / geometry.ringWidth) + 1
        return slices.last { $0.depth == depth && polar.angle >= $0.start && polar.angle < $0.end }
    }
}

// MARK: - Drawing

private struct SunburstCanvas: View {
    let frames: [Sunburst.Frame]
    let geometry: Sunburst.Geometry
    let highlighted: String?
    let picked: Set<ObjectIdentifier>

    var body: some View {
        Canvas { context, _ in
            let center = geometry.center
            var highlight: Path?
            let pickedKeys = Set(picked.map(Sunburst.key(forID:)))

            for frame in frames {
                // Depths below 1 belong to the center: fade them as they shrink in.
                let alpha = frame.alpha * min(1, frame.depth)
                guard alpha > 0.01, frame.end - frame.start > 0.0005 else { continue }
                let radii = geometry.radii(depth: frame.depth)
                let outer = radii.inner + (radii.outer - radii.inner) * CGFloat(frame.reach)
                guard outer - radii.inner > 0.5 else { continue }
                let path = sector(center: center, inner: radii.inner, outer: outer, start: frame.start, end: frame.end)

                var layer = context
                layer.opacity = alpha
                layer.fill(path, with: .color(frame.paint.color))
                if frame.isFree {
                    // Free space reads as an outline, not as something stored.
                    layer.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                } else {
                    layer.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 0.7)
                }
                if pickedKeys.contains(frame.key) {
                    layer.stroke(path, with: .color(.white), lineWidth: 2)
                }
                if frame.key == highlighted { highlight = path }
            }

            // The center disc, on top of anything shrinking into it.
            let disc = Path(ellipseIn: CGRect(
                x: center.x - geometry.centerRadius, y: center.y - geometry.centerRadius,
                width: geometry.centerRadius * 2, height: geometry.centerRadius * 2
            ))
            context.fill(disc, with: .color(Color(white: 0.12).opacity(0.55)))
            context.stroke(disc, with: .color(.white.opacity(0.14)), lineWidth: 0.8)

            // Drawn last so no neighbor covers it.
            if let highlight {
                context.fill(highlight, with: .color(.white.opacity(0.24)))
                context.stroke(highlight, with: .color(.white.opacity(0.9)), lineWidth: 1.2)
            }
        }
    }

    /// An annular sector; angles run clockwise from 12 o'clock.
    private func sector(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double) -> Path {
        var path = Path()
        let from = Angle(radians: start - .pi / 2)
        let to = Angle(radians: end - .pi / 2)
        path.addArc(center: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
        if inner > 0.5 {
            path.addArc(center: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
        } else {
            path.addLine(to: center)
        }
        path.closeSubpath()
        return path
    }
}

private extension Sunburst {
    static func key(forID id: ObjectIdentifier) -> String { "n\(UInt(bitPattern: id.hashValue))" }
}
