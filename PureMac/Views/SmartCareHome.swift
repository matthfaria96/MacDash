import Darwin
import SwiftUI

// MARK: - Your Mac panel

/// Single "Your Mac" panel for the Smart Care home: identity, live CPU and
/// memory load, storage breakdown and a compact spec sheet.
struct MacHealthPanel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var monitor = SystemMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onNavigate: (AppSection) -> Void

    @State private var monitorOwner = UUID()
    @State private var hoveredSegment: String?
    @State private var extras: MacHardwareExtras?
    @State private var displays: [MacHardwareExtras.Display] = []
    @State private var temperature: Double?
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @State private var showSnapshots = false
    @ObservedObject private var inspection = SystemInspectionModel.shared

    private let info = MacSystemInfo.current

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            HStack(alignment: .top, spacing: 16) {
                storageBlock
                    .frame(maxWidth: .infinity)
                liveBlock
                    .frame(maxWidth: .infinity)
            }


            specGrid
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.055))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [SectionPalette.smartCare.accent.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .center))
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.6))
        .onAppear {
            monitor.start(owner: monitorOwner, interval: 2)
            displays = MacHardwareExtras.displays()
            appState.loadDiskInfo()
        }
        .onDisappear {
            monitor.stop(owner: monitorOwner)
        }
        .task { await inspection.loadIfNeeded() }
        .task {
            extras = await Task.detached(priority: .utility) { MacHardwareExtras.load() }.value
        }
        .task {
            // Temperature only needs a slow poll, and stops when the panel does.
            while !Task.isCancelled {
                temperature = await Task.detached(priority: .utility) { DieTemperature.read() }.value
                thermalState = ProcessInfo.processInfo.thermalState
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        .sheet(isPresented: $showSnapshots) { LocalSnapshotsSheet() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            CategoryBadge(systemName: info.symbol, tint: SectionPalette.smartCare.accent, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.computerName)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(info.productFamily) · \(info.chip) · \(info.osVersion)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
        }
    }

    // MARK: Storage

    private var storageBlock: some View {
        PanelTile {
            VStack(alignment: .leading, spacing: 12) {
                // Mirrors the live tile: what it is on the left, where to go
                // for detail on the right.
                HStack(spacing: 8) {
                    Label(startupVolumeName, systemImage: "internaldrive.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        onNavigate(.spaceLens)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chart.pie.fill")
                            Text("Space Lens")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)
                    .help("See what is taking up space on this disk")
                }

                HStack(alignment: .center, spacing: 16) {
                    StorageDonut(
                        segments: diskSegments,
                        lineWidth: 11,
                        highlightedID: hoveredSegment,
                        center: AnyView(
                            VStack(spacing: 0) {
                                Text("\(usedPercent)%")
                                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                Text("used")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .textCase(.uppercase)
                                    .tracking(0.6)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .allowsHitTesting(false)
                        )
                    )
                    .frame(width: 96, height: 96)
                    .zIndex(1)

                    VStack(alignment: .leading, spacing: 7) {
                        legendRow(id: "used", color: HDColor.used, label: "Used", value: bytes(nonPurgeableUsed))
                        if purgeableSpace > 0 {
                            legendRow(id: "purgeable", color: HDColor.purgeable, label: "Purgeable", value: bytes(purgeableSpace))
                        }
                        legendRow(id: "free", color: HDColor.free, label: "Available", value: appState.diskInfo.formattedFree)
                        Text("\(appState.diskInfo.formattedTotal) total")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.45))
                        snapshotsRow
                    }
                }
            }
        }
    }

    private func legendRow(id: String, color: Color, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .opacity(hoveredSegment == nil || hoveredSegment == id ? 1 : 0.4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                hoveredSegment = hovering ? id : nil
            }
        }
    }

    // MARK: Live load

    private var snapshotsRow: some View {
        Button {
            showSnapshots = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SectionPalette.smartCare.accent)
                Text("Local snapshots")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 6)
                if inspection.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("\(inspection.snapshots.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Review Time Machine local snapshots")
    }

    private var liveBlock: some View {
        PanelTile {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Tint.green)
                            .frame(width: 6, height: 6)
                            .shadow(color: Tint.green, radius: 3)
                        Text("Live")
                            .font(.system(size: 10, weight: .bold))
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(Tint.green)
                    }
                    Spacer()
                    Button {
                        onNavigate(.processes)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform.path.ecg.rectangle.fill")
                            Text("Processes")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)
                    .help("See which apps are using your Mac right now")
                }
                LoadMeter(
                    title: "CPU",
                    icon: "cpu.fill",
                    fraction: monitor.cpuUsage,
                    value: "\(Int((monitor.cpuUsage * 100).rounded()))%",
                    tint: SectionPalette.smartCare.accent
                )
                LoadMeter(
                    title: "Memory",
                    icon: "memorychip.fill",
                    fraction: monitor.memoryFraction,
                    value: "\(bytes(monitor.memoryUsed, style: .memory)) / \(info.memory)",
                    tint: SectionPalette.smartCare.accent.adjusted(hue: -0.08, saturation: 0.75, brightness: 1.0)
                )
                LoadMeter(
                    title: "Temperature",
                    icon: "thermometer.medium",
                    fraction: temperatureFraction,
                    value: temperatureText,
                    tint: temperatureTint
                )
            }
        }
    }

    private var temperatureFraction: Double {
        if let temperature { return max(0.04, min(1, (temperature - 20) / 80)) }
        switch thermalState {
        case .nominal: return 0.25
        case .fair: return 0.55
        default: return 0.9
        }
    }

    private var temperatureText: String {
        if let temperature { return "\(Int(temperature.rounded())) °C" }
        switch thermalState {
        case .nominal: return String(localized: "Normal")
        case .fair: return String(localized: "Warm")
        default: return String(localized: "Running hot")
        }
    }

    private var temperatureTint: Color {
        // A pale tint while normal; it only turns orange or red when the Mac runs hot.
        let calm = SectionPalette.smartCare.accent.mixedWithWhite(0.55)
        if let temperature { return temperature < 80 ? calm : (temperature < 92 ? Tint.orange : Tint.red) }
        return thermalState == .nominal ? calm : (thermalState == .fair ? Tint.orange : Tint.red)
    }

    // MARK: Specs

    private var specGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            SpecCell(icon: "cpu.fill", title: "Chip", value: info.chip)
            SpecCell(icon: "circle.hexagongrid.fill", title: "CPU cores", value: coreText)
            SpecCell(icon: "memorychip.fill", title: "Memory", value: info.memory)
            SpecCell(icon: "apple.logo", title: "macOS", value: info.osVersionWithBuild)
            SpecCell(icon: "globe", title: "Language", value: extras?.language ?? "—")
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                SpecCell(icon: "clock.fill", title: "Uptime", value: MacSystemInfo.uptimeText)
            }
            if let packages = packagesText {
                SpecCell(icon: "shippingbox.fill", title: "Packages", value: packages)
            }
            ForEach(displays) { display in
                SpecCell(icon: "display", title: "Display", value: "\(display.name) · \(display.summary)")
            }
        }
    }

    private var coreText: String {
        guard let extras, let performance = extras.performanceGHz else { return info.coreSummary }
        let ghz = { (value: Double) in String(format: "%.2f", value) }
        if let efficiency = extras.efficiencyGHz {
            return "\(info.coreSummary) · \(ghz(performance)) / \(ghz(efficiency)) GHz"
        }
        return "\(info.coreSummary) · \(ghz(performance)) GHz"
    }

    private var packagesText: String? {
        guard let formulae = extras?.brewFormulae, let casks = extras?.brewCasks else { return nil }
        return String(format: String(localized: "%lld formulae · %lld casks"), Int64(formulae), Int64(casks))
    }

    // MARK: Disk math

    private func bytes(_ value: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: style)
    }

    private var startupVolumeName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? String(localized: "Macintosh HD")
    }

    private var purgeableSpace: Int64 {
        min(max(0, appState.diskInfo.purgeableSpace), max(0, appState.diskInfo.usedSpace))
    }

    private var nonPurgeableUsed: Int64 {
        max(0, appState.diskInfo.usedSpace - purgeableSpace)
    }

    private var usedPercent: Int {
        guard appState.diskInfo.totalSpace > 0 else { return 0 }
        let used = appState.diskInfo.totalSpace - appState.diskInfo.freeSpace
        return Int((Double(max(0, used)) / Double(appState.diskInfo.totalSpace) * 100).rounded())
    }

    private var availablePercent: Int {
        guard appState.diskInfo.totalSpace > 0 else { return 100 }
        return Int((Double(max(0, appState.diskInfo.freeSpace)) / Double(appState.diskInfo.totalSpace) * 100).rounded())
    }

    private var diskSegments: [StorageDonut.Segment] {
        var segments = [
            StorageDonut.Segment(id: "used", value: Double(nonPurgeableUsed), color: HDColor.used, label: "Used", display: bytes(nonPurgeableUsed))
        ]
        if purgeableSpace > 0 {
            segments.append(StorageDonut.Segment(id: "purgeable", value: Double(purgeableSpace), color: HDColor.purgeable, label: "Purgeable", display: bytes(purgeableSpace)))
        }
        segments.append(StorageDonut.Segment(id: "free", value: Double(max(0, appState.diskInfo.freeSpace)), color: HDColor.free, label: "Available", display: appState.diskInfo.formattedFree))
        return segments
    }
}

/// Storage colors in Smart Care's family: used is its magenta, reclaimable
/// space a pale tint of it, free space light gray.
private enum HDColor {
    static let used = SectionPalette.smartCare.accent
    static let purgeable = SectionPalette.smartCare.accent.mixedWithWhite(0.55)
    static let free = Color(white: 0.84)
}

private struct PanelTile<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(hovering ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
            .onHover { hovering = $0 }
    }
}

private struct LoadMeter: View {
    let title: LocalizedStringKey
    let icon: String
    let fraction: Double
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(value)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geometry.size.width * CGFloat(max(0, min(1, fraction)))))
                }
            }
            .frame(height: 7)
            // A soft glow drawn once around the track instead of a shadow
            // recomputed on every animation frame.
            .background(Capsule().fill(tint.opacity(0.12)).blur(radius: 4))
            .animation(.easeOut(duration: 0.35), value: fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(value)
    }
}

private struct SpecCell: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SectionPalette.smartCare.accent)
                .frame(width: 24, height: 24)
                .background(SectionPalette.smartCare.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - System info

struct MacSystemInfo {
    let computerName: String
    let hardwareModel: String
    let productFamily: String
    let symbol: String
    let chip: String
    let memory: String
    let coreSummary: String
    let osVersion: String
    let osVersionWithBuild: String

    static let current = MacSystemInfo()

    private init() {
        computerName = Host.current().localizedName ?? String(localized: "This Mac")
        let model = Self.sysctlString("hw.model") ?? String(localized: "Unknown")
        hardwareModel = model
        let lower = model.lowercased()
        let name = computerName.lowercased()
        if let known = ["MacBook Pro", "MacBook Air", "Mac mini", "Mac Studio", "Mac Pro", "iMac", "MacBook"].first(where: { name.contains($0.lowercased()) }) {
            productFamily = known
        } else if lower.hasPrefix("macbookpro") { productFamily = "MacBook Pro" }
        else if lower.hasPrefix("macbookair") { productFamily = "MacBook Air" }
        else if lower.hasPrefix("macbook") { productFamily = "MacBook" }
        else if lower.hasPrefix("macmini") { productFamily = "Mac mini" }
        else if lower.hasPrefix("macstudio") { productFamily = "Mac Studio" }
        else if lower.hasPrefix("macpro") { productFamily = "Mac Pro" }
        else if lower.hasPrefix("imac") { productFamily = "iMac" }
        else { productFamily = "Mac" }
        symbol = productFamily.hasPrefix("MacBook") ? "laptopcomputer" : "desktopcomputer"

        if let name = Self.sysctlString("machdep.cpu.brand_string"), !name.isEmpty {
            chip = name.replacingOccurrences(of: "  ", with: " ")
        } else {
            chip = String(localized: "Apple silicon")
        }
        memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: ProcessInfo.processInfo.physicalMemory), countStyle: .memory)

        let total = ProcessInfo.processInfo.processorCount
        if let performance = Self.sysctlInt("hw.perflevel0.physicalcpu"),
           let efficiency = Self.sysctlInt("hw.perflevel1.physicalcpu"), efficiency > 0 {
            coreSummary = "\(total) (\(performance)P + \(efficiency)E)"
        } else {
            coreSummary = "\(total)"
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let short = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        osVersionWithBuild = Self.sysctlString("kern.osversion").map { "\(short) (\($0))" } ?? short
    }

    static var uptimeText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: ProcessInfo.processInfo.systemUptime) ?? "—"
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
