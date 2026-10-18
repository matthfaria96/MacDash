import SwiftUI

/// Colors shared by the performance cards and the open apps table, so a
/// metric keeps its color wherever it appears.
struct PerformancePalette {
    let app: Color
    let wired: Color
    let compressed: Color
    let cached: Color
    let free = Color.white.opacity(0.1)
    let cpu: Color
    let cpuSystem: Color
    let memory: Color
    let swap: Color

    /// One family from the screen's color: the color itself, a deeper
    /// neighbor, a pale tint and a soft lighter neighbor, so charts read as
    /// part of the screen instead of a rainbow.
    init(_ theme: Color) {
        app = theme
        wired = theme.adjusted(hue: -0.045, saturation: 0.95, brightness: 0.82)
        compressed = theme.mixedWithWhite(0.5)
        cached = theme.adjusted(hue: 0.06, saturation: 0.5, brightness: 1.0)
        cpu = theme
        cpuSystem = theme.mixedWithWhite(0.55)
        memory = theme.mixedWithWhite(0.25)
        swap = theme.mixedWithWhite(0.7)
    }

    static let processes = PerformancePalette(SectionPalette.processes.accent)
    static let menuBar = PerformancePalette(Color(red: 0.62, green: 0.6, blue: 1.0))
}

/// The Mac's vitals as four compact tiles: a ring, the value and the last
/// three minutes as a hand-drawn sparkline (no Charts, so it stays light).
/// Tapping a tile unfolds its details underneath; tapping again folds them.
struct PerformanceOverview: View {
    @ObservedObject var model: PerformanceModel
    @State private var selected: Vital?
    @State private var hoveredSegment: String?
    @Namespace private var selection

    private let palette = PerformancePalette.processes
    /// Below this the four tiles can't show their values whole side by side.
    private static let fourAcrossWidth: CGFloat = 820
    @State private var rowWidth: CGFloat = 1000
    private let info = MacSystemInfo.current

    enum Vital: String, CaseIterable, Identifiable {
        case cpu, memory, heat, activity
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Four across on a wide page, two by two on a narrow one, so the
            // values never get cut or widen the page. Decided by the room
            // available, not by the values, so the layout doesn't flip as
            // the numbers change.
            Group {
                if rowWidth >= Self.fourAcrossWidth {
                    HStack(spacing: 12) { tiles }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) { tiles }
                }
            }
            .frame(maxWidth: .infinity)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { rowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { rowWidth = $0 }
            })
            if let selected, let snapshot = model.snapshot {
                CardSurface(padding: 18, tint: tile(selected).tint) {
                    drawer(selected, snapshot: snapshot)
                }
                .id(selected)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -8)),
                    removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                ))
            }
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        ForEach(Array(Vital.allCases.enumerated()), id: \.element) { index, vital in
            if model.snapshot == nil {
                tileSkeleton
            } else {
                VitalTile(
                    tile: tile(vital),
                    isSelected: selected == vital,
                    index: index,
                    namespace: selection
                ) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        selected = selected == vital ? nil : vital
                    }
                }
            }
        }
    }

    struct TileModel {
        let title: LocalizedStringKey
        let symbol: String
        let value: String
        let caption: String
        let fraction: Double?
        let series: [Double]
        let ceiling: Double
        var floor: Double = 0
        let tint: Color
        var tick: Int? = nil
        /// Small symbol and value pairs shown in place of the caption, for a
        /// tile that sums up several sources.
        var chips: [(symbol: String, text: String)] = []
    }

    private func tile(_ vital: Vital) -> TileModel {
        let collecting = model.history.isEmpty
        switch vital {
        case .cpu:
            return TileModel(
                title: "CPU",
                symbol: "cpu",
                value: collecting ? "—" : percent(model.cpuTotal),
                caption: collecting ? String(localized: "Measuring…")
                    : String(format: String(localized: "Apps %@ · System %@"), percent(model.cpuUser), percent(model.cpuSystem)),
                fraction: collecting ? nil : model.cpuTotal,
                series: model.history.map(\.cpu),
                ceiling: 1,
                tint: palette.cpu,
                tick: model.history.last?.id
            )
        case .memory:
            let s = model.snapshot
            let fraction = s.map { $0.total > 0 ? Double($0.used) / Double($0.total) : 0 }
            let pressure = s?.pressure ?? .normal
            return TileModel(
                title: "Memory",
                symbol: "memorychip",
                value: s.map { formatMemory($0.used) } ?? "—",
                caption: String(format: String(localized: "Pressure %@ · %@"), model.pressurePercent.map { "\($0)%" } ?? "—", pressure.label),
                fraction: fraction,
                series: model.history.map(\.memoryUsedGB),
                ceiling: s.map { Double($0.total) / Double(MemoryReader.gib) } ?? 1,
                tint: pressure == .normal ? palette.memory : pressure.tint,
                tick: model.history.last?.id
            )
        case .heat:
            let heat = DieTemperature.display(model.temperature, thermalState: model.thermalState)
            let temps = model.history.compactMap(\.temperature)
            return TileModel(
                title: "Temperature",
                symbol: "thermometer.medium",
                value: heat.text,
                caption: model.fans.first.map { String(format: String(localized: "%@ · Fan %d rpm"), thermalLabel, $0.rpm) } ?? thermalLabel,
                fraction: heat.fraction,
                series: temps,
                ceiling: (temps.max() ?? 60) + 4,
                floor: (temps.min() ?? 30) - 4,
                tint: heat.tint,
                tick: model.history.last?.id
            )
        case .activity:
            let level = collecting ? nil : activityLevel(net: model.netDown + model.netUp, disk: model.diskRead + model.diskWrite, gpu: model.gpuLoad)
            return TileModel(
                title: "Activity",
                symbol: "waveform",
                value: level.map(activityLabel) ?? "—",
                caption: "",
                fraction: level,
                series: model.history.map { activityLevel(net: $0.netDown + $0.netUp, disk: $0.diskRead + $0.diskWrite, gpu: $0.gpu) },
                ceiling: 1,
                tint: palette.cached,
                tick: model.history.last?.id,
                chips: [
                    ("network", collecting ? "—" : formatRate(model.netDown + model.netUp)),
                    ("internaldrive", collecting ? "—" : formatRate(model.diskRead + model.diskWrite)),
                    ("square.stack.3d.up", model.gpuLoad.map(percent) ?? "—")
                ]
            )
        }
    }

    private var tileSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().stroke(Color.white.opacity(0.09), lineWidth: 4).frame(width: 40, height: 40).shimmer()
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(width: 50, height: 8)
                    SkeletonBlock(width: 70, height: 14)
                }
            }
            SkeletonBlock(height: 28, corner: 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.04)))
        .transition(.opacity)
    }

    // MARK: - Drawers

    @ViewBuilder
    private func drawer(_ vital: Vital, snapshot: MemorySnapshot) -> some View {
        switch vital {
        case .cpu: cpuDrawer
        case .memory: memoryDrawer(snapshot)
        case .heat: heatDrawer
        case .activity: activityDrawer
        }
    }

    /// A ring of where the processor's time goes (apps, macOS, idle) with
    /// the share in use at its center; the legend, the rest of the numbers
    /// and the last minutes sit beside it.
    private var cpuDrawer: some View {
        let restartSoon = ProcessInfo.processInfo.systemUptime > 7 * 86_400
        let idle = max(0, 1 - model.cpuTotal)
        let parts: [(id: String, label: LocalizedStringKey, value: Double, color: Color, help: LocalizedStringKey)] = [
            ("apps", "Apps", model.cpuUser, palette.cpu, "Time spent running your apps."),
            ("system", "System", model.cpuSystem, palette.cpuSystem, "Time macOS itself spends on your apps' behalf."),
            ("idle", "Idle", idle, Color.white.opacity(0.1), "Capacity nothing is using right now.")
        ]
        return VStack(alignment: .leading, spacing: 16) {
            drawerTitle("CPU", detail: info.chip, tint: palette.cpu)
            HStack(alignment: .center, spacing: 24) {
                StorageDonut(
                    segments: parts.map {
                        StorageDonut.Segment(id: $0.id, value: max($0.value, 0.0001), color: $0.color, label: $0.label, display: percent($0.value))
                    },
                    lineWidth: 14,
                    highlightedID: hoveredSegment,
                    center: AnyView(
                        VStack(spacing: 0) {
                            Text(verbatim: model.history.isEmpty ? "—" : percent(model.cpuTotal))
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .numericTransition()
                                .animation(.easeInOut(duration: 0.35), value: percent(model.cpuTotal))
                            Text("in use")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    )
                )
                .frame(width: 150, height: 150)
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: model.cpuTotal)

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 18) {
                        ForEach(parts, id: \.id) { part in
                            HStack(spacing: 8) {
                                Capsule().fill(part.id == "idle" ? Color.white.opacity(0.3) : part.color).frame(width: 3, height: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: percent(part.value))
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(.white)
                                        .numericTransition()
                                    Text(part.label)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }
                            .opacity(hoveredSegment == nil || hoveredSegment == part.id ? 1 : 0.45)
                            .contentShape(Rectangle())
                            .onHover { hoveredSegment = $0 ? part.id : (hoveredSegment == part.id ? nil : hoveredSegment) }
                            .help(part.help)
                        }
                        Spacer(minLength: 0)
                    }
                    .animation(.easeOut(duration: 0.15), value: hoveredSegment)
                    statGrid([
                        Stat(label: "GPU", value: model.gpuLoad.map(percent) ?? "—", tint: palette.cached),
                        Stat(label: "Cores", value: "\(ProcessInfo.processInfo.activeProcessorCount)", tint: Color.white.opacity(0.3)),
                        Stat(label: "Uptime", value: uptimeText, tint: restartSoon ? Tint.yellow : Color.white.opacity(0.3))
                    ])
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last 3 minutes")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                        VitalSparkline(values: model.history.map(\.cpu), secondary: model.history.map(\.cpuSystem), ceiling: 1, tint: palette.cpu, tick: model.history.last?.id)
                            .frame(height: 44)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if restartSoon {
                hint("arrow.clockwise", Text("It's been over a week now. A restart clears swap and caches and finishes pending updates."), tint: Tint.yellow)
            }
        }
    }


    private func memoryDrawer(_ s: MemorySnapshot) -> some View {
        let parts = buckets(s)
        let insights = Array(model.insights.filter { $0.tone != .good }.prefix(2))
        return VStack(alignment: .leading, spacing: 16) {
            drawerTitle("Memory", detail: String(format: String(localized: "%@ of %@ in use"), formatMemory(s.used), formatMemory(s.total)), tint: palette.memory)
            MemoryBar(parts: parts.map { ($0.id, Double($0.bytes), $0.color) }, highlighted: hoveredSegment)
                .frame(height: 12)
            HStack(spacing: 16) {
                ForEach(parts) { part in
                    HStack(spacing: 6) {
                        Circle().fill(part.id == "free" ? Color.white.opacity(0.3) : part.color).frame(width: 7, height: 7)
                        Text(part.label).foregroundStyle(.white.opacity(0.6))
                        Text(verbatim: formatMemory(part.bytes)).monospacedDigit().foregroundStyle(.white.opacity(0.9))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .opacity(hoveredSegment == nil || hoveredSegment == part.id ? 1 : 0.45)
                    .contentShape(Rectangle())
                    .onHover { hoveredSegment = $0 ? part.id : (hoveredSegment == part.id ? nil : hoveredSegment) }
                    .help(part.help)
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.15), value: hoveredSegment)
            VitalSparkline(values: model.history.map(\.memoryUsedGB), secondary: model.history.map(\.swapGB),
                      ceiling: max(Double(s.total) / Double(MemoryReader.gib), 1), tint: palette.memory, tick: model.history.last?.id)
                .frame(height: 72)
            statGrid([
                Stat(label: "Pressure", value: model.pressurePercent.map { "\($0)%" } ?? "—", tint: s.pressure.tint),
                Stat(label: "Swap", value: formatMemory(s.swapUsed), tint: s.swapUsed > 2 * MemoryReader.gib ? Tint.orange : palette.swap),
                Stat(label: "Available", value: formatMemory(s.total > s.used ? s.total - s.used : 0), tint: Color.white.opacity(0.3))
            ])
            ForEach(insights) { insight in
                hint(insight.symbol, Text(verbatim: insight.body), title: insight.title, tint: insight.tint)
            }
            if insights.isEmpty {
                hint("checkmark.seal.fill", s.pressure == .normal
                     ? Text("Your Mac is ready to take on more tasks. Pressure, not the amount used, is what makes a Mac slow.")
                     : Text("Memory is getting tight. Quitting a heavy app helps."),
                     tint: s.pressure.tint)
            }
        }
    }

    private var heatDrawer: some View {
        let heat = DieTemperature.display(model.temperature, thermalState: model.thermalState)
        let temps = model.history.compactMap(\.temperature)
        var stats = [
            Stat(label: "macOS", value: thermalLabel, tint: heat.tint),
            Stat(label: "Peak", value: temps.max().map { "\(Int($0.rounded())) °C" } ?? "—", tint: heat.tint.opacity(0.6))
        ]
        stats += model.fans.map { fan in
            Stat(label: model.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan", value: "\(fan.rpm) rpm", tint: heat.tint.opacity(0.5))
        }
        if let watts = model.powerWatts {
            stats.append(Stat(label: "Power", value: "\(Int(watts.rounded())) W", tint: heat.tint.opacity(0.4)))
        }
        return VStack(alignment: .leading, spacing: 16) {
            drawerTitle("Temperature", detail: heat.text, tint: heat.tint)
            if model.temperature == nil && !model.isCollecting {
                hint("thermometer.medium", Text("This Mac doesn't expose its temperature sensors, so macOS's thermal state is shown instead."), tint: heat.tint)
            } else {
                VitalSparkline(values: temps, ceiling: (temps.max() ?? 60) + 4, floor: (temps.min() ?? 30) - 4, tint: heat.tint, tick: model.history.last?.id)
                    .frame(height: 80)
            }
            statGrid(stats)
            hint("info.circle", (model.temperature ?? 0) < 80
                 ? Text("Within its perfect working range. Apple silicon runs comfortably up to about 90 °C under load.")
                 : Text("Running warm. Heavy apps and blocked vents add heat; above 90 °C macOS slows the processor to cool it."),
                 tint: heat.tint)
        }
    }

    /// One quiet line per source: what it is, its numbers, its last minutes.
    private var activityDrawer: some View {
        VStack(alignment: .leading, spacing: 14) {
            drawerTitle("Activity", detail: String(localized: "Network, disk and GPU"), tint: palette.cached)
            VStack(spacing: 6) {
                activityLine(model.connection.flatMap { $0.name.isEmpty ? nil : Text(verbatim: $0.name) } ?? Text("Network"),
                             symbol: "network",
                             detail: "↓ \(formatRate(model.netDown))   ↑ \(formatRate(model.netUp))",
                             badge: model.connection?.address,
                             values: model.history.map { $0.netDown + $0.netUp }, ceiling: nil)
                activityLine(Text("Disk"), symbol: "internaldrive",
                             detail: String(format: String(localized: "Read %@ · Write %@"), formatRate(model.diskRead), formatRate(model.diskWrite)),
                             values: model.history.map { $0.diskRead + $0.diskWrite }, ceiling: nil)
                activityLine(Text(verbatim: "GPU"), symbol: "square.stack.3d.up",
                             detail: model.gpuLoad.map(percent) ?? "—",
                             values: model.history.map { $0.gpu ?? 0 }, ceiling: 1)
            }
            devicesStrip
        }
        .task { await model.watchConnections() }
    }

    /// Paired accessories and external drives, in a quiet strip under the
    /// activity lines: the same facts as the menu bar panel.
    @ViewBuilder
    private var devicesStrip: some View {
        let count = model.bluetooth.count + model.drives.count
        if count > 0 || model.isReadingDevices {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Connected Devices")
                        .font(.system(size: 10.5, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.45))
                    if count > 0 {
                        Text(verbatim: "\(count)")
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    if model.isReadingDevices {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                    ForEach(model.bluetooth) { device in
                        deviceChip(symbol: device.symbol, name: device.name, subtitle: device.kindLabel,
                                   level: device.battery.map { Double($0) / 100 },
                                   value: device.battery.map { "\($0)%" },
                                   low: (device.battery ?? 100) <= 20,
                                   help: device.battery == nil
                                       ? String(localized: "This accessory doesn't share its battery level with macOS. Its maker's app may show it.")
                                       : device.name) { EmptyView() }
                    }
                    ForEach(model.drives) { drive in
                        deviceChip(symbol: drive.isDiskImage ? "opticaldiscdrive" : "externaldrive.fill", name: drive.name,
                                   subtitle: String(format: String(localized: "%@ free"), ByteCountFormatter.string(fromByteCount: drive.available, countStyle: .file)),
                                   level: drive.total > 0 ? Double(drive.total - drive.available) / Double(drive.total) : nil,
                                   value: nil, low: false, help: drive.url.path) {
                            if model.ejecting.contains(drive.id) {
                                ProgressView().controlSize(.mini)
                            } else {
                                Button { model.eject(drive) } label: {
                                    Image(systemName: "eject.fill")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.75))
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                                .help("Eject")
                            }
                        }
                    }
                }
                .animation(MotionTokens.gentle, value: model.bluetooth.map(\.id) + model.drives.map(\.id))
            }
            .padding(.top, 4)
            .transition(.opacity)
        }
    }

    private func deviceChip<Trailing: View>(symbol: String, name: String, subtitle: String, level: Double?, value: String?,
                                            low: Bool, help: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(verbatim: name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let value {
                        Text(verbatim: value)
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(low ? Tint.red : .white.opacity(0.85))
                    }
                }
                Text(verbatim: subtitle)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                if let level {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 2.5)
                        .overlay(alignment: .leading) {
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(value == nil ? Color.white.opacity(0.6) : (low ? Tint.red : Tint.green.opacity(0.8)))
                                    .frame(width: max(2, geometry.size.width * min(1, max(0, level))))
                            }
                        }
                }
            }
            trailing()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5))
        .help(help)
    }

    private func activityLine(_ title: Text, symbol: String, detail: String, badge: String? = nil, values: [Double], ceiling: Double?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.cached)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.cached.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let badge {
                        Text(verbatim: badge)
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.45))
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                }
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(width: 230, alignment: .leading)
            VitalSparkline(values: values, ceiling: ceiling ?? max(values.max() ?? 0, 1) * 1.15, tint: palette.cached,
                           showsDot: false, tick: model.history.last?.id)
                .frame(height: 28)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    /// How busy the Mac is besides CPU and memory, 0…1: the busiest of the
    /// network (10 MB/s is full), the disk (200 MB/s) and the GPU.
    private func activityLevel(net: Double, disk: Double, gpu: Double?) -> Double {
        min(1, max(net / 10_000_000, disk / 200_000_000, gpu ?? 0))
    }

    private func activityLabel(_ level: Double) -> String {
        level < 0.25 ? String(localized: "Calm") : (level < 0.6 ? String(localized: "Moderate") : String(localized: "Intense"))
    }

    // MARK: - Pieces

    private struct Bucket: Identifiable {
        let id: String
        let label: LocalizedStringKey
        let bytes: UInt64
        let color: Color
        let help: LocalizedStringKey
    }

    private func buckets(_ s: MemorySnapshot) -> [Bucket] {
        [
            Bucket(id: "app", label: "App", bytes: s.app, color: palette.app,
                   help: "Memory your apps are actively using."),
            Bucket(id: "wired", label: "Wired", bytes: s.wired, color: palette.wired,
                   help: "Memory macOS itself needs and can't move or compress."),
            Bucket(id: "compressed", label: "Compressed", bytes: s.compressed, color: palette.compressed,
                   help: "App memory squeezed to make room instead of swapping to disk."),
            Bucket(id: "cached", label: "Cached files", bytes: s.cached, color: palette.cached,
                   help: "Recently used files kept in RAM. Handed back the moment an app needs it."),
            Bucket(id: "free", label: "Free", bytes: s.free, color: palette.free,
                   help: "Memory nothing is using right now.")
        ]
    }

    private struct Stat: Identifiable {
        let label: LocalizedStringKey
        let value: String
        let tint: Color
        var id: String { "\(label)" }
    }

    private func statGrid(_ stats: [Stat]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                HStack(spacing: 8) {
                    Capsule().fill(stat.tint).frame(width: 3, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: stat.value)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .numericTransition()
                        Text(stat.label)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
            }
        }
    }

    private func drawerTitle(_ title: LocalizedStringKey, detail: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(verbatim: detail)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { selected = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Close the details")
        }
    }

    private func hint(_ symbol: String, _ body: Text, title: String? = nil, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(verbatim: title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                }
                body
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    private var uptimeText: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: ProcessInfo.processInfo.systemUptime) ?? "—"
    }

    private var thermalLabel: String {
        switch model.thermalState {
        case .nominal: return String(localized: "Normal")
        case .fair: return String(localized: "Warm")
        case .serious: return String(localized: "Running hot")
        case .critical: return String(localized: "Critical")
        @unknown default: return String(localized: "Normal")
        }
    }
}

/// One vital: ring, value, sparkline. Rises into place on appear, lifts
/// under the pointer, and wears a glowing outline while its details show.
private struct VitalTile: View {
    let tile: PerformanceOverview.TileModel
    let isSelected: Bool
    let index: Int
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    RingGauge(fraction: tile.fraction, tint: tile.tint, symbol: tile.symbol)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tile.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(verbatim: tile.value)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .numericTransition()
                            .animation(.easeInOut(duration: 0.35), value: tile.value)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(hovering || isSelected ? 0.7 : 0.3))
                        .rotationEffect(.degrees(isSelected ? 180 : 0))
                }
                VitalSparkline(values: tile.series, ceiling: tile.ceiling, floor: tile.floor, tint: tile.tint, showsDot: false, capacity: 30, tick: tile.tick)
                    .frame(height: 28)
                if tile.chips.isEmpty {
                    Text(verbatim: tile.caption)
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    HStack(spacing: 8) {
                        ForEach(Array(tile.chips.enumerated()), id: \.offset) { _, chip in
                            HStack(spacing: 3) {
                                Image(systemName: chip.symbol)
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text(verbatim: chip.text)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                ZStack {
                    shape.fill(Color.white.opacity(hovering ? 0.075 : 0.05))
                    shape.fill(LinearGradient(colors: [tile.tint.opacity(isSelected ? 0.22 : 0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if isSelected {
                        shape.strokeBorder(tile.tint.opacity(0.7), lineWidth: 1)
                            .shadow(color: tile.tint.opacity(0.5), radius: 8)
                            .matchedGeometryEffect(id: "vital.selection", in: namespace)
                    } else {
                        shape.strokeBorder(GlassEdge.gradient, lineWidth: 0.7).opacity(hovering ? 1 : 0.6)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(VitalPressStyle())
        .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
        .offset(y: appeared || reduceMotion ? 0 : 16)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onHover { hovering = $0 }
        .animation(MotionTokens.snappy, value: hovering)
        .onAppear {
            guard !appeared else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(Double(index) * 0.06)) { appeared = true }
        }
        .help(isSelected ? "Close the details" : "Show the details")
    }
}

private struct VitalPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(MotionTokens.press, value: configuration.isPressed)
    }
}

/// A ring that sweeps to its value, with the metric's symbol inside.
struct RingGauge: View {
    let fraction: Double?
    let tint: Color
    let symbol: String
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0.002, fraction ?? 0))))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.45), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.55), radius: 3)
                .opacity(fraction == nil ? 0 : 1)
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(lineWidth / 2)
        .animation(.spring(response: 0.7, dampingFraction: 0.78), value: fraction)
        .accessibilityHidden(true)
    }
}

/// The share of each memory bucket as one rounded bar; widths ease to new
/// values and a hovered bucket stands out.
private struct MemoryBar: View {
    let parts: [(id: String, value: Double, color: Color)]
    let highlighted: String?

    var body: some View {
        GeometryReader { geometry in
            let total = max(parts.map(\.value).reduce(0, +), 1)
            let gaps = CGFloat(max(parts.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(parts, id: \.id) { part in
                    Capsule()
                        .fill(part.color)
                        .frame(width: max(0, (geometry.size.width - gaps) * CGFloat(part.value / total)))
                        .opacity(highlighted == nil || highlighted == part.id ? 1 : 0.35)
                }
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: parts.map(\.value))
        .animation(.easeOut(duration: 0.15), value: highlighted)
        .accessibilityHidden(true)
    }
}

/// A soft area with a line on top, drawn with plain paths. The window is
/// always full: before there's data it's a flat baseline (0), and each new
/// reading slides in from the right edge, pushing the oldest out on the left.
struct VitalSparkline: View {
    let values: [Double]
    var secondary: [Double]? = nil
    let ceiling: Double
    var floor: Double = 0
    let tint: Color
    var showsDot = true
    var capacity = PerformanceModel.historyLength
    /// Changes once per reading; each change starts one step of the slide.
    var tick: Int? = nil
    @State private var shift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let step = geometry.size.width / CGFloat(max(capacity - 1, 1))
            ZStack {
                SparkShape(values: values, ceiling: ceiling, floor: floor, capacity: capacity, closed: true, shift: shift)
                    .fill(LinearGradient(colors: [tint.opacity(0.4), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                SparkShape(values: values, ceiling: ceiling, floor: floor, capacity: capacity, closed: false, shift: shift)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if let secondary {
                    SparkShape(values: secondary, ceiling: ceiling, floor: floor, capacity: capacity, closed: false, shift: shift)
                        .stroke(tint.mixedWithWhite(0.55), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [3, 3]))
                }
                if showsDot {
                    let span = max(ceiling - floor, .ulpOfOne)
                    let last = values.last ?? floor
                    let y = geometry.size.height * (1 - CGFloat(min(1, max(0, (last - floor) / span))))
                    LayerMotion(kind: .breathe, period: 1.6, amount: 0.6) {
                        Circle().fill(tint).frame(width: 6, height: 6).shadow(color: tint, radius: 4)
                    }
                    .frame(width: 10, height: 10)
                    .position(x: geometry.size.width + shift * step, y: y)
                }
            }
        }
        .clipped()
        // The slide redraws every frame; rendering it as one bitmap on the
        // GPU keeps that cheap.
        .drawingGroup()
        .onChange(of: tick) { _ in
            guard !reduceMotion else { return }
            // Start one step to the right, then glide into place until the
            // next reading arrives.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { shift = 1 }
            withAnimation(.linear(duration: 1.9)) { shift = 0 }
        }
        .accessibilityHidden(true)
    }
}

private struct SparkShape: Shape {
    let values: [Double]
    let ceiling: Double
    let floor: Double
    let capacity: Int
    let closed: Bool
    /// How far, in steps, the newest point still sits past the right edge.
    var shift: CGFloat

    var animatableData: CGFloat {
        get { shift }
        set { shift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let span = max(ceiling - floor, .ulpOfOne)
        let step = rect.width / CGFloat(max(capacity - 1, 1))
        // One point more than fits, so the one sliding out on the left still
        // draws; missing history is the baseline.
        let count = capacity + 1
        let recent = Array(values.suffix(count))
        let padded = Array(repeating: floor, count: count - recent.count) + recent
        let points = padded.enumerated().map { index, value -> CGPoint in
            let offset = CGFloat(count - 1 - index) - shift
            let level = CGFloat(min(1, max(0, (value - floor) / span)))
            return CGPoint(x: rect.maxX - offset * step, y: rect.maxY - level * (rect.height - 2) - 1)
        }
        path.move(to: points[0])
        // Midpoint quadratic curves: smooth, and never overshoot the data.
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
            if index == points.count - 1 { path.addLine(to: point) }
        }
        if closed {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// macOS services and menu bar apps that are heavy right now. Shown only when
/// something in the background stands out, above the user's own apps.
struct BackgroundActivityCard: View {
    @ObservedObject var model: PerformanceModel

    var body: some View {
        let total = model.snapshot?.total ?? ProcessInfo.processInfo.physicalMemory
        CardSurface(padding: 18, tint: Tint.orange) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(spacing: 9) {
                        PremiumIcon(systemName: "gearshape.2.fill", tint: Tint.orange, size: 24, style: .glass)
                        Text("Heavy in the background")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text("macOS services and menu bar apps")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                VStack(spacing: 2) {
                    ForEach(model.background) { group in
                        BackgroundActivityRow(
                            group: group,
                            icon: model.icon(for: group),
                            memoryHeavy: Double(group.bytes) >= PerformanceModel.memoryBar(total: total),
                            cpuHeavy: (group.cpuFraction ?? 0) >= PerformanceModel.cpuBar,
                            onQuit: { model.quit(group) }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(MotionTokens.gentle, value: model.background.map(\.id))
            }
        }
    }
}

private struct BackgroundActivityRow: View {
    let group: MemoryAppGroup
    let icon: NSImage?
    let memoryHeavy: Bool
    let cpuHeavy: Bool
    let onQuit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                symbol
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: group.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .help(group.appPath ?? (group.id.hasPrefix("/") ? group.id : group.name))
            Spacer(minLength: 8)
            Text(verbatim: cpuText)
                .monospacedDigit()
                .foregroundStyle(cpuHeavy ? Tint.orange : .white.opacity(0.7))
                .frame(width: 88, alignment: .trailing)
            Text(verbatim: formatMemory(group.bytes))
                .monospacedDigit()
                .foregroundStyle(memoryHeavy ? Tint.orange : .white.opacity(0.7))
                .frame(width: 118, alignment: .trailing)
            ZStack(alignment: .trailing) {
                if group.isQuittable && hovering {
                    Button("Quit", action: onQuit)
                        .buttonStyle(RowActionButtonStyle())
                        .fixedSize()
                        .help("Asks the app to quit, so it can offer to save your work.")
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .frame(width: 112, alignment: .trailing)
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var symbol: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            PremiumIcon(systemName: group.family?.symbol ?? "gearshape.2.fill", tint: Tint.orange, size: 28, style: .glass)
        }
    }

    private var subtitle: String {
        if let family = group.family { return family.detail }
        if let app = group.appPath {
            return app.hasPrefix("/System/") ? String(localized: "Part of macOS") : String(localized: "Menu bar or background app")
        }
        if group.id.hasPrefix("/System/") || group.id.hasPrefix("/usr/") || group.id.hasPrefix("/Library/Apple/") {
            return String(localized: "macOS service")
        }
        return String(localized: "Background process")
    }

    private var cpuText: String {
        guard let cpu = group.cpuFraction else { return "—" }
        return cpu.formatted(.percent.precision(.fractionLength(1)))
    }
}
