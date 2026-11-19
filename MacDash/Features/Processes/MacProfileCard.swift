import SwiftUI

/// The top of Processes: who this Mac is (name, model, chip, macOS, time
/// powered on), how its startup disk is filled, and its spec sheet. The live
/// vitals and the Health card follow below it.
struct MacProfileCard<Accessory: View>: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var inspection = SystemInspectionModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onNavigate: (AppSection) -> Void
    /// Shown next to "Your Mac" (the live sampling badge).
    @ViewBuilder var accessory: Accessory

    @State private var extras: MacHardwareExtras?
    @State private var displays: [MacHardwareExtras.Display] = []
    @State private var hoveredSegment: String?
    @State private var showSnapshots = false

    private let info = MacSystemInfo.current
    private let palette = SectionPalette.processes

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 20) {
                identity
                    .frame(maxWidth: .infinity, alignment: .leading)
                storage
                    .fixedSize()
            }

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.6)

            specGrid
        }
        .padding(22)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.055))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(RadialGradient(colors: [palette.accent.opacity(0.24), .clear], center: .topLeading, startRadius: 10, endRadius: 460))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(RadialGradient(colors: [palette.primary.opacity(0.16), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 420))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .onAppear {
            displays = MacHardwareExtras.displays()
            appState.loadDiskInfo()
        }
        .task { await inspection.loadIfNeeded() }
        .task { extras = await Task.detached(priority: .utility) { MacHardwareExtras.load() }.value }
        .sheet(isPresented: $showSnapshots) { LocalSnapshotsSheet() }
    }

    // MARK: Identity

    private var identity: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [palette.accent.opacity(0.38), .clear], center: .center, startRadius: 4, endRadius: 58))
                    .frame(width: 108, height: 108)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 74, height: 74)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
                Image(systemName: info.symbol)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(LinearGradient(colors: [.white, palette.accent.mixedWithWhite(0.35)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: palette.accent.opacity(0.5), radius: 10)
            }
            .frame(width: 84, height: 84)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Your Mac")
                        .font(.system(size: 10.5, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(palette.accent)
                    accessory
                }
                Text(verbatim: info.computerName)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: "\(info.modelName) · \(info.chip) · \(info.osVersion)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    HStack(spacing: 5) {
                        Image(systemName: "power")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("Uptime")
                        Text(verbatim: MacSystemInfo.uptimeText)
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: Storage

    private var storage: some View {
        HStack(alignment: .center, spacing: 16) {
            StorageDonut(
                segments: diskSegments,
                lineWidth: 11,
                highlightedID: hoveredSegment,
                center: AnyView(
                    VStack(spacing: 0) {
                        Text(verbatim: "\(usedPercent)%")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
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
            .frame(width: 98, height: 98)
            .zIndex(1)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Label(startupVolumeName, systemImage: "internaldrive.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Button {
                        onNavigate(.spaceLens)
                    } label: {
                        Image(systemName: "chart.pie.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)
                    .help("See what is taking up space on this disk")
                    .accessibilityLabel("Space Lens")
                }
                legendRow(id: "used", color: StorageColor.used, label: "Used", value: bytes(nonPurgeableUsed))
                if purgeableSpace > 0 {
                    legendRow(id: "purgeable", color: StorageColor.purgeable, label: "Purgeable", value: bytes(purgeableSpace))
                }
                legendRow(id: "free", color: StorageColor.free, label: "Available", value: appState.diskInfo.formattedFree)
                Text("\(appState.diskInfo.formattedTotal) total")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                snapshotsRow
            }
            .frame(width: 196)
        }
    }

    private func legendRow(id: String, color: Color, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 6)
            Text(verbatim: value)
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

    private var snapshotsRow: some View {
        Button {
            showSnapshots = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Text("Local snapshots")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 6)
                if inspection.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(verbatim: "\(inspection.snapshots.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Review Time Machine local snapshots")
    }

    // MARK: Specs

    private var specGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 8)], alignment: .leading, spacing: 8) {
            SpecCell(icon: "cpu.fill", title: "CPU cores", value: info.coreSummary, detail: clockText, tint: PerformancePalette.processes.cpu)
            SpecCell(icon: "memorychip.fill", title: "Memory", value: info.memory, detail: nil, tint: PerformancePalette.processes.memory)
            SpecCell(icon: "apple.logo", title: "macOS", value: info.osVersion, detail: info.osBuild, tint: palette.accent)
            ForEach(displays) { display in
                SpecCell(icon: "display", title: "Display", value: display.name, detail: display.summary, tint: PerformancePalette.processes.activity)
            }
            SpecCell(icon: "globe", title: "Language", value: extras?.language ?? "—", detail: nil, tint: palette.accent)
            if let packages = packagesText {
                SpecCell(icon: "shippingbox.fill", title: "Packages", value: packages, detail: "Homebrew", tint: palette.accent)
            }
        }
    }

    /// Top clock of the performance cores, and of the efficiency ones when known.
    private var clockText: String? {
        guard let extras, let performance = extras.performanceGHz else { return nil }
        let ghz = { (value: Double) in String(format: "%.2f", value) }
        if let efficiency = extras.efficiencyGHz {
            return "\(ghz(performance)) / \(ghz(efficiency)) GHz"
        }
        return "\(ghz(performance)) GHz"
    }

    private var packagesText: String? {
        guard let formulae = extras?.brewFormulae, let casks = extras?.brewCasks else { return nil }
        return String(format: String(localized: "%lld formulae · %lld casks"), Int64(formulae), Int64(casks))
    }

    // MARK: Disk math

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
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

    private var diskSegments: [StorageDonut.Segment] {
        var segments = [
            StorageDonut.Segment(id: "used", value: Double(nonPurgeableUsed), color: StorageColor.used, label: "Used", display: bytes(nonPurgeableUsed))
        ]
        if purgeableSpace > 0 {
            segments.append(StorageDonut.Segment(id: "purgeable", value: Double(purgeableSpace), color: StorageColor.purgeable, label: "Purgeable", display: bytes(purgeableSpace)))
        }
        segments.append(StorageDonut.Segment(id: "free", value: Double(max(0, appState.diskInfo.freeSpace)), color: StorageColor.free, label: "Available", display: appState.diskInfo.formattedFree))
        return segments
    }
}

/// Storage colors in Processes' family: used is its orange, purgeable a pale
/// tint of it, free space light gray.
enum StorageColor {
    static let used = SectionPalette.processes.accent
    static let purgeable = SectionPalette.processes.accent.mixedWithWhite(0.55)
    static let free = Color(white: 0.84)
}

/// One line of the spec sheet: an icon, a small title and the value.
private struct SpecCell: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String
    /// A quieter second line: build number, resolution, clock speed.
    let detail: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Text(verbatim: value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(value)
                Text(verbatim: detail ?? " ")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(detail == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
