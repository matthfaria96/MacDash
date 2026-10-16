import Charts
import SwiftUI

struct StorageDonut: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
        let label: LocalizedStringKey
        let display: String
        /// When this one slice stands for several areas, each one's own share,
        /// listed in the hover tooltip.
        var details: [Detail] = []

        struct Detail: Identifiable {
            let id: String
            let value: Double
            let label: LocalizedStringKey
            let display: String
        }
    }

    let segments: [Segment]
    var lineWidth: CGFloat = 16
    var gap: Double = 0.008
    var highlightedID: String? = nil
    /// Content drawn in the ring's center. It lives inside the chart so the
    /// hover tooltip always stacks above it.
    var center: AnyView? = nil

    @State private var reveal: Double = 0
    /// Segment under the pointer and where the pointer is, for the tooltip.
    @State private var hoveredIndex: Int?
    @State private var hoverPoint: CGPoint = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Double {
        max(segments.reduce(0) { $0 + $1.value }, 0.0001)
    }

    /// Gives every non-empty segment at least `minimum` of the ring so tiny
    /// amounts (a few MB next to many GB) still show as a sliver of color.
    /// The difference comes proportionally out of the larger segments.
    static func visibleFractions(_ raw: [Double], minimum: Double) -> [Double] {
        let nonEmpty = raw.filter { $0 > 0 }
        guard nonEmpty.count > 1, minimum * Double(nonEmpty.count) < 1 else { return raw }
        let isSmall = raw.map { $0 > 0 && $0 < minimum }
        let boosted = Double(isSmall.filter { $0 }.count) * minimum
        let largeTotal = zip(raw, isSmall).filter { !$0.1 }.reduce(0) { $0 + $1.0 }
        guard boosted > 0, largeTotal > 0 else { return raw }
        let scale = (1 - boosted) / largeTotal
        return zip(raw, isSmall).map { value, small in
            small ? minimum : value * scale
        }
    }

    private func segmentOpacity(index: Int, id: String) -> Double {
        if let hoveredIndex, segments.indices.contains(hoveredIndex) { return hoveredIndex == index ? 1 : 0.3 }
        return highlightedID == nil || highlightedID == id ? 1 : 0.22
    }

    /// Which ring segment the point is over, or nil off the ring. Angle starts
    /// at 12 o'clock and runs clockwise, like the drawn segments.
    private func segmentIndex(at point: CGPoint, in size: CGSize, ranges: [(start: Double, end: Double)]) -> Int? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = (min(size.width, size.height) - lineWidth) / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        // A little slack so thin rings are still easy to hit.
        guard abs(distance - radius) <= lineWidth / 2 + 6 else { return nil }
        var turns = atan2(dx, -dy) / (2 * .pi)
        if turns < 0 { turns += 1 }
        // Choose the segment whose range is nearest, so the thin gaps between
        // segments do not flicker the tooltip off.
        var best: (index: Int, distance: Double)?
        for (index, range) in ranges.enumerated() where segments[index].value > 0 {
            let distanceToRange = turns < range.start ? range.start - turns : (turns > range.end ? turns - range.end : 0)
            if best == nil || distanceToRange < best!.distance { best = (index, distanceToRange) }
        }
        guard let best, best.distance < 0.02 else { return nil }
        return best.index
    }

    private func percentText(_ value: Double) -> String {
        let percent = value / total * 100
        return percent < 1 && percent > 0 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    @ViewBuilder
    private func tooltip(for segment: Segment) -> some View {
        if segment.details.isEmpty {
            singleTooltip(for: segment)
        } else {
            groupTooltip(for: segment)
        }
    }

    /// Tooltip for a slice that stands for several areas: its total, then each
    /// area's own size.
    private func groupTooltip(for segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(segment.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(segment.label)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("\(percentText(segment.value)) · \(segment.display)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Divider().overlay(Color.white.opacity(0.25))
            ForEach(segment.details) { member in
                HStack(spacing: 14) {
                    Text(member.label)
                        .font(.system(size: 11))
                    Spacer(minLength: 8)
                    Text("\(percentText(member.value)) · \(member.display)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: 190)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    private func singleTooltip(for segment: Segment) -> some View {
        let text = percentText(segment.value)
        return HStack(spacing: 8) {
            Circle().fill(segment.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(segment.label)
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(text) · \(segment.display)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    var body: some View {
        let effectiveGap = segments.count <= 1 ? 0 : gap
        let fractions = Self.visibleFractions(segments.map { $0.value / total }, minimum: 0.022 + effectiveGap)
        var cursor = 0.0
        var ranges: [(start: Double, end: Double)] = []

        for fraction in fractions {
            let start = cursor
            cursor += fraction
            ranges.append((start, max(start, cursor - effectiveGap)))
        }

        return ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.065), lineWidth: lineWidth)
            center
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                Circle()
                    .trim(
                        from: ranges[index].start * reveal,
                        to: ranges[index].end * reveal
                    )
                    .stroke(
                        segment.color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
                    .opacity(segmentOpacity(index: index, id: segment.id))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: highlightedID)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hoveredIndex)
        // While a tooltip is showing, draw the whole chart above its neighbors.
        .zIndex(hoveredIndex == nil ? 0 : 1000)
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hoverPoint = point
                            hoveredIndex = segmentIndex(at: point, in: geometry.size, ranges: ranges)
                        case .ended:
                            hoveredIndex = nil
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let index = hoveredIndex, segments.indices.contains(index) {
                            tooltip(for: segments[index])
                                .fixedSize()
                                .position(
                                    x: min(max(hoverPoint.x, 60), max(geometry.size.width - 60, 60)),
                                    y: max(hoverPoint.y - 34, 14)
                                )
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
            }
        }
        .onAppear {
            if reduceMotion {
                reveal = 1
            } else {
                withAnimation(.easeOut(duration: 0.7)) {
                    reveal = 1
                }
            }
        }
    }
}

struct SuccessMedal: View {
    var tint: Color = Tint.green
    var size: CGFloat = 120
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.11))
            Circle()
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .scaleEffect(visible ? 1 : 0.92)
        .opacity(visible ? 1 : 0)
        .onAppear {
            if reduceMotion {
                visible = true
            } else {
                withAnimation(MotionTokens.gentle) {
                    visible = true
                }
            }
        }
    }
}

struct StaggeredReveal: ViewModifier {
    let index: Int
    var baseDelay = 0.035
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 6)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.easeOut(duration: 0.28).delay(Double(index) * baseDelay)) {
                        shown = true
                    }
                }
            }
    }
}

extension View {
    func staggered(_ index: Int, baseDelay: Double = 0.035) -> some View {
        modifier(StaggeredReveal(index: index, baseDelay: baseDelay))
    }
}

struct CountUpBytes: View {
    let bytes: Int64
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .modifier(ByteRollEffect(value: shown))
            .onAppear { animate(to: bytes) }
            .onChange(of: bytes) { animate(to: $0) }
    }

    private func animate(to target: Int64) {
        if reduceMotion {
            shown = Double(target)
        } else {
            withAnimation(.easeOut(duration: 0.55)) {
                shown = Double(target)
            }
        }
    }
}

private struct ByteRollEffect: AnimatableModifier {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View {
        Text(ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file))
            .monospacedDigit()
    }
}

struct ScanningGauge: View {
    let progress: Double
    var tint: Color = Tint.accent
    var label: LocalizedStringKey = "SCANNING"

    @State private var rotation = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double {
        max(0, min(1, progress))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.035, clamped))
                .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90 + rotation))
            VStack(spacing: 2) {
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }
}
