import AppKit
import SwiftUI

// MARK: - Shared look

/// Colors and surfaces shared by the menu bar panel and its detail panel.
enum MenuBarStyle {
    static let link = Color(red: 0.56, green: 0.80, blue: 1.0)
    static let selection = Color(red: 0.47, green: 0.52, blue: 1.0)
    static let panelWidth: CGFloat = 360
    static let corner: CGFloat = 18
}

/// Deep indigo glass, the same family as Smart Care.
struct MenuBarSurface: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MenuBarStyle.corner, style: .continuous)
        ZStack {
            VisualEffectBackdrop()
            LinearGradient(
                colors: [
                    Color(red: 0.25, green: 0.12, blue: 0.58).opacity(0.92),
                    Color(red: 0.16, green: 0.07, blue: 0.42).opacity(0.94),
                    Color(red: 0.09, green: 0.04, blue: 0.24).opacity(0.97)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 0.55, green: 0.35, blue: 1.0).opacity(0.28), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 340
            )
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8
            )
        )
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The blue text actions ("Free Up", "Test Speed").
struct MenuBarLink: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var isBusy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                }
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize()
            .foregroundStyle(MenuBarStyle.link.opacity(hovering ? 1 : 0.92))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(MenuBarStyle.link.opacity(hovering ? 0.14 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Navigation into the main window

/// Hands a destination to the main window, buffering it when the window has
/// to be created first.
enum MenuBarNavigation {
    static let notification = Notification.Name("MacTidy.MenuBarNavigate")
    static var pending: (section: AppSection, startScan: Bool)?

    @MainActor
    static func open(_ section: AppSection? = nil, startScan: Bool = false) {
        if let section { pending = (section, startScan) }
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.shared.showMainWindow()
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

// MARK: - Panel

/// The natural height of the panel's content, so the window can follow it.
struct MenuBarPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The menu bar panel, laid out like Control Center: a short header, one
/// compact row per metric (icon, name, a thin meter, the value), and a
/// row's detail unfolding under it when clicked. Rows are plain symbols and
/// text, so the panel stays light while it updates.
struct MenuBarPanelView: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var state: MenuBarPanelState
    let close: () -> Void
    /// Called with the content's height whenever it changes.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    private let info = MacSystemInfo.current
    @State private var showsAllDevices = false
    static let expand = Animation.spring(response: 0.32, dampingFraction: 0.9)

    var body: some View {
        // Scrolls only when the content is taller than the screen allows.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let notice = model.notice {
                    noticeBanner(notice)
                }
                metricList
                if MenuBarPreferences.isVisible(.devices), !deviceItems.isEmpty {
                    devicesSection
                }
                footer
            }
            .padding(12)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: MenuBarPanelHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(width: MenuBarStyle.panelWidth)
        .background(MenuBarSurface())
        .environment(\.colorScheme, .dark)
        .environment(\.themeTint, MenuBarStyle.selection)
        .onPreferenceChange(MenuBarPanelHeightKey.self) { onHeightChange($0) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let image = NSImage(named: NSImage.computerName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                (Text("Mac Health:") + Text(verbatim: " ") + Text(model.verdict.label).foregroundColor(model.verdict.tint))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(verbatim: "\(info.productFamily) · \(info.chip)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 6)
            iconButton("gearshape.fill", help: "Settings") {
                close()
                MenuBarNavigation.open(.settings)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
            Text(verbatim: text)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { model.notice = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
        }
        .padding(9)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Metrics

    /// Every metric is its own card: CPU and memory with the Apps square to
    /// its right (the app list opens in a card under the pair), then the
    /// disk, battery and network. Only Apps and Battery unfold.
    private var metricList: some View {
        VStack(spacing: 8) {
            if MenuBarPreferences.isVisible(.performance) {
                HStack(spacing: 8) {
                    performanceCard
                        .frame(maxHeight: .infinity)
                        .panelCard()
                    appsSquare
                        .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                if state.detail == .apps {
                    MenuBarDetailContent(model: model, detail: .apps, close: close)
                        .padding(12)
                        .panelCard()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            if MenuBarPreferences.isVisible(.disk) {
                diskCard.panelCard()
            }
            if MenuBarPreferences.isVisible(.battery), model.battery != nil {
                VStack(spacing: 0) {
                    metricRow(.battery)
                    if state.detail == .battery { detailBlock(.battery) }
                }
                .panelCard(highlighted: state.detail == .battery)
            }
            if MenuBarPreferences.isVisible(.network) {
                networkCard.panelCard()
            }
        }
    }

    /// The startup disk as a small ring with what's used and what's left.
    private var diskCard: some View {
        let disk = model.disk
        let purgeable = disk?.purgeable ?? 0
        let used = max(0, (disk?.used ?? 0) - purgeable)
        let total = max(disk?.total ?? 0, 1)
        let usedFraction = Double(disk?.used ?? 0) / Double(total)
        return HStack(spacing: 12) {
            StorageDonut(segments: [
                StorageDonut.Segment(id: "used", value: Double(used), color: PerformancePalette.menuBar.app, label: "Used", display: fileBytes(used)),
                StorageDonut.Segment(id: "purgeable", value: Double(purgeable), color: PerformancePalette.menuBar.cached, label: "Purgeable", display: fileBytes(purgeable)),
                StorageDonut.Segment(id: "free", value: Double(disk?.available ?? 0), color: Color.white.opacity(0.1), label: "Available", display: fileBytes(disk?.available ?? 0))
            ], lineWidth: 6, center: AnyView(
                Text(verbatim: disk == nil ? "—" : "\(Int((usedFraction * 100).rounded()))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            ))
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: disk?.name ?? "Macintosh HD")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: disk.map { fileBytes($0.total) } ?? "—")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                }
                HStack(spacing: 10) {
                    legendDot(PerformancePalette.menuBar.app, "Used", fileBytes(used))
                    if purgeable > 0 {
                        legendDot(PerformancePalette.menuBar.cached, "Purgeable", fileBytes(purgeable))
                    }
                    legendDot(Color.white.opacity(0.35), "Available", disk.map { fileBytes($0.available) } ?? "—")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func legendDot(_ color: Color, _ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Text(verbatim: value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func fileBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// The heaviest apps at a glance: their icons, and a tap opens the list.
    private var appsSquare: some View {
        let isOpen = state.detail == .apps
        let icons = model.topApps.prefix(3).compactMap { model.icon(for: $0) }
        return Button {
            withAnimation(Self.expand) { state.toggle(.apps) }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if icons.isEmpty {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    ForEach(Array(icons.enumerated()), id: \.offset) { index, icon in
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .offset(x: CGFloat(index - (icons.count - 1) / 2) * 13 - (icons.count.isMultiple(of: 2) ? 6 : 0))
                            .zIndex(Double(icons.count - index))
                    }
                }
                .frame(height: 26)
                HStack(spacing: 3) {
                    Text("Apps")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 84)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isOpen ? MenuBarStyle.selection.opacity(0.45) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOpen ? MenuBarStyle.selection : Color.white.opacity(0.07), lineWidth: isOpen ? 1 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The apps using the most memory and CPU")
        .animation(.easeOut(duration: 0.15), value: isOpen)
    }

    /// The connection, its address, and download and upload, all at once.
    private var networkCard: some View {
        let measuring = model.throughput.isEmpty
        let offline = model.network.kind == .offline
        return HStack(spacing: 10) {
            rowIcon(networkSymbol, isOpen: false)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: model.network.name.isEmpty ? String(localized: "Network") : model.network.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let address = model.network.address {
                        Text(verbatim: address)
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 12) {
                    rate("arrow.down", value: offline || measuring ? "—" : formatRate(model.downRate), tint: PerformancePalette.menuBar.app)
                        .help("Download")
                    rate("arrow.up", value: offline || measuring ? "—" : formatRate(model.upRate), tint: PerformancePalette.menuBar.cached)
                        .help("Upload")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func rate(_ symbol: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(Circle().fill(tint.opacity(0.18)))
            Text(verbatim: value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowIcon(_ symbol: String, isOpen: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isOpen ? Color.white : Color.white.opacity(0.85))
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOpen ? MenuBarStyle.selection.opacity(0.75) : Color.white.opacity(0.1))
            )
    }

    // MARK: Devices

    /// Tiles per row; more devices than this fold behind "Show all".
    private static let deviceColumns = 3

    private var deviceItems: [DeviceTile.Item] {
        model.bluetooth.map(DeviceTile.Item.accessory) + model.drives.map(DeviceTile.Item.drive)
    }

    /// Accessories and external drives as squares side by side, with their
    /// battery or free space. A second row unfolds only when there are more.
    private var devicesSection: some View {
        let items = deviceItems
        let folds = items.count > Self.deviceColumns
        let shown = folds && !showsAllDevices ? Array(items.prefix(Self.deviceColumns)) : items
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Connected Devices")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(verbatim: "\(items.count)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                Spacer(minLength: 4)
                if folds {
                    Button {
                        withAnimation(Self.expand) { showsAllDevices.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showsAllDevices ? "Show fewer" : "Show all")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(showsAllDevices ? 180 : 0))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MenuBarStyle.link)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: Self.deviceColumns), spacing: 8) {
                ForEach(shown) { item in
                    DeviceTile(item: item, model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
        }
        .padding(10)
        .panelCard()
    }

    private func detailBlock(_ detail: MenuBarDetail) -> some View {
        MenuBarDetailContent(model: model, detail: detail, close: close)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 4)
            .transition(.opacity)
    }

    private struct RowInfo {
        let symbol: String
        let title: String
        let value: String
        var detail: String? = nil
        var fraction: Double? = nil
        var valueTint: Color = .white
    }

    private func info(for row: MenuBarDetail) -> RowInfo {
        switch row {
        case .battery:
            let battery = model.battery
            return RowInfo(
                symbol: batterySymbol(battery),
                title: String(localized: "Battery"),
                value: battery.map { "\($0.percent)%" } ?? "—",
                detail: battery.map(batterySubtitle),
                fraction: battery.map { Double($0.percent) / 100 },
                valueTint: (battery?.percent ?? 100) <= 20 ? Tint.red : .white
            )
        case .apps:
            return RowInfo(symbol: "square.stack.3d.up", title: "Apps", value: "")
        }
    }

    /// CPU and memory as one row: two thin meters side by side, and
    /// pressure and temperature underneath.
    private var performanceCard: some View {
        let measuring = model.cpuHistory.isEmpty
        let memory = model.memory
        let memoryFraction = memory.map { $0.total > 0 ? Double($0.used) / Double($0.total) : 0 }
        let pressure = memory?.pressure ?? .normal
        let caption = [
            String(format: String(localized: "Pressure: %@"), pressure.label),
            model.cpuTemperature.map { "\(Int($0.rounded())) °C" }
        ].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            rowIcon("gauge.with.dots.needle.50percent", isOpen: false)
            VStack(alignment: .leading, spacing: 5) {
                Text("Performance")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    miniMeter("CPU", value: measuring ? "—" : "\(Int((model.cpuLoad * 100).rounded()))%", fraction: measuring ? nil : model.cpuLoad)
                    miniMeter("RAM", value: memoryFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", fraction: memoryFraction,
                              tint: pressure == .normal ? nil : pressure.tint)
                }
                Text(verbatim: caption)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(pressure == .normal ? Color.white.opacity(0.5) : pressure.tint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func miniMeter(_ label: String, value: String, fraction: Double?, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 2)
                Text(verbatim: value)
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .white)
            }
            Capsule()
                .fill(Color.white.opacity(0.1))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(tint ?? MenuBarStyle.selection.mixedWithWhite(0.25))
                            .frame(width: max(2, geometry.size.width * min(1, max(0, fraction ?? 0))))
                            .animation(.easeInOut(duration: 0.5), value: fraction)
                    }
                }
        }
        .frame(maxWidth: .infinity)
    }

    private func metricRow(_ row: MenuBarDetail) -> some View {
        let item = info(for: row)
        let isOpen = state.detail == row
        return Button {
            withAnimation(Self.expand) { state.toggle(row) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOpen ? Color.white : Color.white.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isOpen ? MenuBarStyle.selection.opacity(0.75) : Color.white.opacity(0.1))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: item.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(verbatim: item.value)
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(item.valueTint)
                            .lineLimit(1)
                    }
                    if let fraction = item.fraction {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 3)
                            .overlay(alignment: .leading) {
                                GeometryReader { geometry in
                                    Capsule()
                                        .fill(MenuBarStyle.selection.mixedWithWhite(0.25))
                                        .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
                                }
                            }
                    }
                    if let detail = item.detail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarRowStyle())
        .help(isOpen ? "Close the details" : "Open the details")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                close()
                MenuBarNavigation.open()
            } label: {
                HStack(spacing: 7) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text("Open MacDash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(MenuBarRowStyle())
            Spacer(minLength: 0)
        }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarRowStyle())
        .help(help)
    }

    // MARK: Helpers

    private var networkSymbol: String {
        switch model.network.kind {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .other: return "network"
        case .offline: return "wifi.slash"
        }
    }

    private func batterySubtitle(_ battery: BatteryStatus) -> String {
        if battery.isCharging { return String(localized: "Charging") }
        if battery.isCharged || battery.isOnPower { return String(localized: "On power adapter") }
        if let minutes = battery.minutesRemaining {
            return String(format: String(localized: "%@ remaining"), formatDuration(minutes: minutes))
        }
        return String(localized: "On battery")
    }

    private func batterySymbol(_ battery: BatteryStatus?) -> String {
        guard let battery else { return "battery.100" }
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// One accessory or external drive: its symbol, name, and battery or free
/// space as a number and a thin bar. Drives get an eject button.
struct DeviceTile: View {
    enum Item: Identifiable {
        case accessory(BluetoothDevice)
        case drive(ExternalDrive)

        var id: String {
            switch self {
            case .accessory(let device): return "bt:" + device.id
            case .drive(let drive): return "drive:" + drive.id
            }
        }
    }

    let item: Item
    @ObservedObject var model: MenuBarModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(height: 18)
                Spacer(minLength: 2)
                trailing
            }
            Spacer(minLength: 0)
            Text(verbatim: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: subtitle)
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Capsule()
                .fill(Color.white.opacity(fraction == nil ? 0 : 0.12))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        if let fraction {
                            Capsule().fill(tint).frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
                        }
                    }
                }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.1 : 0.07))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }

    @ViewBuilder
    private var trailing: some View {
        switch item {
        case .accessory(let device):
            if let level = device.battery {
                Text(verbatim: "\(level)%")
                    .font(.system(size: 11.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(level <= 20 ? Tint.red : .white)
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        case .drive(let drive):
            if model.ejecting.contains(drive.id) {
                ProgressView().controlSize(.mini)
            } else {
                Button { model.eject(drive) } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MenuBarStyle.link)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(MenuBarStyle.link.opacity(hovering ? 0.2 : 0.1)))
                }
                .buttonStyle(.plain)
                .help("Eject")
            }
        }
    }

    private var symbol: String {
        switch item {
        case .accessory(let device): return device.symbol
        case .drive(let drive): return drive.isDiskImage ? "opticaldiscdrive" : "externaldrive.fill"
        }
    }

    private var name: String {
        switch item {
        case .accessory(let device): return device.name
        case .drive(let drive): return drive.name
        }
    }

    private var subtitle: String {
        switch item {
        case .accessory(let device): return device.kindLabel
        case .drive(let drive):
            return String(format: String(localized: "%@ free"), ByteCountFormatter.string(fromByteCount: drive.available, countStyle: .file))
        }
    }

    private var fraction: Double? {
        switch item {
        case .accessory(let device): return device.battery.map { Double($0) / 100 }
        case .drive(let drive): return drive.total > 0 ? Double(drive.total - drive.available) / Double(drive.total) : nil
        }
    }

    private var tint: Color {
        switch item {
        case .accessory(let device): return (device.battery ?? 100) <= 20 ? Tint.red : Tint.green
        case .drive: return Color.white.opacity(0.8)
        }
    }

    private var help: String {
        switch item {
        case .accessory(let device):
            return device.battery == nil
                ? String(localized: "This accessory doesn't share its battery level with macOS. Its maker's app may show it.")
                : device.name
        case .drive(let drive): return drive.url.path
        }
    }
}

extension View {
    /// The panel's card: soft glass with a hairline edge, brighter while its
    /// detail is open.
    func panelCard(highlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return background(Color.white.opacity(highlighted ? 0.085 : 0.06), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(highlighted ? 0.12 : 0.07), lineWidth: 0.5))
            .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}

/// Row highlight on hover and press, like a menu item.
struct MenuBarRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.06 : 0)))
                )
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Formatting

func formatRate(_ bytesPerSecond: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return String(format: String(localized: "%@/sec"), formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))))
}

func formatDuration(minutes: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)m"
}
