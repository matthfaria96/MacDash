import AppKit
import SwiftUI

/// Which detail panel is open. It opens only from a card's "Details" link,
/// never on hover, and the same link closes it again.
@MainActor
final class MenuBarPanelState: ObservableObject {
    @Published private(set) var detail: MenuBarDetail?

    func toggle(_ tile: MenuBarDetail) {
        detail = detail == tile ? nil : tile
    }

    func show(_ tile: MenuBarDetail) {
        detail = tile
    }

    func reset() {
        detail = nil
    }
}

/// A card's detail, shown expanded inside the panel under the card's row.
struct MenuBarDetailContent: View {
    @ObservedObject var model: MenuBarModel
    let detail: MenuBarDetail
    let close: () -> Void

    var body: some View {
        switch detail {
        case .apps: AppsDetail(model: model, close: close)
        case .battery: BatteryDetail(model: model)
        }
    }
}

// MARK: - Pieces

/// The row above already names the detail, so only an optional action
/// (like opening Space Lens) is shown here.
private struct DetailTitle: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        if let trailing {
            HStack {
                Spacer()
                trailing
            }
        }
    }
}

/// A two-part card: title row with a value, then an explanation with
/// "Learn More" that expands the full story in place.
/// A compact fact: icon and title, the value, and one line of context. The
/// longer explanation lives in the tooltip instead of expanding the panel.
private struct InfoCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    var valueTint: Color = .white
    let summary: String
    let more: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            Text(verbatim: value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Color.white.opacity(0.06)))
        .help(more)
    }
}

private struct CardPair<Left: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            left
            right
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The heaviest open apps with their CPU share and memory, and a Quit link
/// on hover.
private struct AppsDetail: View {
    @ObservedObject var model: MenuBarModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.topApps.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 50)
            }
            ForEach(model.topApps.prefix(5)) { group in
                AppLine(model: model, group: group)
                    .transition(.opacity)
            }
            HStack {
                Spacer()
                MenuBarLink(title: "All processes", systemImage: "chevron.right") {
                    close()
                    MenuBarNavigation.open(.processes)
                }
            }
            .padding(.top, 4)
        }
        .animation(.easeInOut(duration: 0.25), value: model.topApps.map(\.id))
    }

    private struct AppLine: View {
        @ObservedObject var model: MenuBarModel
        let group: MemoryAppGroup
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                Group {
                    if let icon = model.icon(for: group) {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "app.dashed").resizable().scaledToFit().padding(3).foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(width: 20, height: 20)
                Text(verbatim: group.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering && group.isQuittable {
                    MenuBarLink(title: "Quit") { model.quit(group) }
                        .help("Asks the app to quit, so it can offer to save your work.")
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Text(verbatim: group.cpuFraction.map { percentText($0, digits: 0) } ?? "—")
                        .foregroundStyle((group.cpuFraction ?? 0) > 0.25 ? Tint.yellow : .white.opacity(0.6))
                        .frame(width: 40, alignment: .trailing)
                    Text(verbatim: formatMemory(group.bytes))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
            .frame(height: 24)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }
}

private func percentText(_ fraction: Double, digits: Int = 0) -> String {
    fraction.formatted(.percent.precision(.fractionLength(digits)))
}

// MARK: - Battery

private struct BatteryDetail: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        let battery = model.battery
        VStack(alignment: .leading, spacing: 16) {
            DetailTitle(title: String(localized: "Battery"))
            HStack(alignment: .center, spacing: 22) {
                SegmentedRing(fraction: Double(battery?.percent ?? 0) / 100, tint: ringTint(battery))
                    .frame(width: 128, height: 128)
                    .overlay {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(verbatim: "\(battery?.percent ?? 0)")
                                .font(.system(size: 46, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(verbatim: "%").font(.system(size: 18, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                    }
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: stateTitle(battery))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                        if let detail = stateDetail(battery) {
                            Text(verbatim: detail)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let cycles = battery?.cycleCount {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(cycles) / \(battery?.designCycles ?? 1000)")
                                .font(.system(size: 17, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                            Text("charge cycles")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            CardPair {
                InfoCard(
                    symbol: "heart.fill",
                    title: "Health",
                    value: battery?.healthPercent.map { "\($0)%" } ?? "—",
                    valueTint: (battery?.healthPercent ?? 100) < 80 ? Tint.orange : .white,
                    summary: healthSummary(battery?.healthPercent),
                    more: String(localized: "Health compares the most your battery can hold today with what it held when new. Below 80 percent, Apple recommends a service.")
                )
            } right: {
                InfoCard(
                    symbol: "thermometer.medium",
                    title: "Temperature",
                    value: battery?.temperature.map { "\(Int($0.rounded()))°C" } ?? "—",
                    valueTint: (battery?.temperature ?? 0) > 40 ? Tint.orange : .white,
                    summary: (battery?.temperature ?? 0) <= 40
                        ? String(localized: "Battery temperature is within its perfect working range.")
                        : String(localized: "The battery is warm. Heat wears batteries faster."),
                    more: String(localized: "Batteries last longest between 16 and 22 °C. Avoid leaving your Mac charging in hot places.")
                )
            }
        }
    }

    private func ringTint(_ battery: BatteryStatus?) -> Color {
        guard let battery else { return Color(red: 0.45, green: 0.93, blue: 0.75) }
        if battery.percent <= 10 { return Tint.red }
        if battery.percent <= 20 { return Tint.orange }
        return Color(red: 0.45, green: 0.93, blue: 0.75)
    }

    private func stateTitle(_ battery: BatteryStatus?) -> String {
        guard let battery else { return "—" }
        if battery.isCharging { return String(localized: "Charging") }
        if battery.isCharged || battery.isOnPower { return String(localized: "Charged") }
        return String(localized: "Discharging")
    }

    private func stateDetail(_ battery: BatteryStatus?) -> String? {
        guard let battery, let minutes = battery.minutesRemaining else { return nil }
        return battery.isCharging
            ? String(format: String(localized: "About %@ until full"), formatDuration(minutes: minutes))
            : String(format: String(localized: "About %@ until empty"), formatDuration(minutes: minutes))
    }

    private func healthSummary(_ health: Int?) -> String {
        guard let health else { return String(localized: "This Mac doesn't report battery health.") }
        if health >= 95 { return String(localized: "Your battery is in great condition.") }
        if health >= 80 { return String(localized: "Your battery is in good condition, but already lost some capacity.") }
        return String(localized: "Your battery holds much less than when new. Consider a service.")
    }
}

/// The ticked ring from the reference's battery view.
private struct SegmentedRing: View {
    let fraction: Double
    let tint: Color
    private let count = 48

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let lit = Int((fraction * Double(count)).rounded())
            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(index < lit ? tint : Color.white.opacity(0.1))
                        .frame(width: size * 0.045, height: size * 0.13)
                        .offset(y: -size / 2 + size * 0.065)
                        .rotationEffect(.degrees(Double(index) / Double(count) * 360))
                        .shadow(color: index < lit ? tint.opacity(0.5) : .clear, radius: 3)
                }
            }
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.5), value: lit)
        }
    }
}
