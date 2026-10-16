import AppKit
import SwiftUI

// The live readout next to MacFresh's menu bar icon, and the preferences that
// shape it and the panel. The drawing follows Performance Monitor (MIT): a
// template image, so macOS tints it for light and dark menu bars, with fixed
// slot widths so numbers never make the menu bar jump. The stacked style
// (small label over the value) follows Stats (MIT).

// MARK: - Preferences

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, temperature, network, disk

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .temperature: return "Temperature"
        case .network: return "Network"
        case .disk: return "Free disk space"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "square.stack.3d.up"
        case .temperature: return "thermometer.medium"
        case .network: return "arrow.up.arrow.down"
        case .disk: return "internaldrive"
        }
    }

    /// The short label drawn over the value in the stacked style.
    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .gpu: return "GPU"
        case .temperature: return "TEMP"
        case .network: return "NET"
        case .disk: return "SSD"
        }
    }

    var defaultsKey: String { "menuBar.metric.\(rawValue)" }
    var isOnByDefault: Bool { self == .cpu || self == .memory }
}

enum MenuBarReadoutStyle: String, CaseIterable, Identifiable {
    case stacked, inline
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .stacked: return "Compact"
        case .inline: return "Text"
        }
    }
}

enum MenuBarPanelCard: String, CaseIterable, Identifiable {
    case performance, disk, battery, network, devices
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .performance: return "CPU and Memory"
        case .disk: return "Startup disk"
        case .battery: return "Battery"
        case .network: return "Network"
        case .devices: return "Connected Devices"
        }
    }

    var symbol: String {
        switch self {
        case .performance: return "gauge.with.dots.needle.50percent"
        case .disk: return "internaldrive"
        case .battery: return "battery.100"
        case .network: return "wifi"
        case .devices: return "headphones"
        }
    }

    var defaultsKey: String { "menuBar.card.\(rawValue)" }
}

enum MenuBarPreferences {
    static let styleKey = "menuBar.readoutStyle"
    static let intervalKey = "menuBar.interval"
    static let alertsKey = "menuBar.alertColors"
    static let showIconKey = "menuBar.showIcon"

    static func registerDefaults() {
        var defaults: [String: Any] = [
            styleKey: MenuBarReadoutStyle.stacked.rawValue,
            intervalKey: 2.0,
            alertsKey: true,
            showIconKey: true
        ]
        for metric in MenuBarMetric.allCases { defaults[metric.defaultsKey] = metric.isOnByDefault }
        for card in MenuBarPanelCard.allCases { defaults[card.defaultsKey] = true }
        UserDefaults.standard.register(defaults: defaults)
        migrateRetiredCards()
    }

    /// CPU and Memory became one Performance card and the recommendation
    /// card is gone: carry a turned-off CPU and Memory pair over, then drop
    /// the old keys.
    private static func migrateRetiredCards() {
        let store = UserDefaults.standard
        let cpu = store.object(forKey: "menuBar.card.cpu") as? Bool
        let memory = store.object(forKey: "menuBar.card.memory") as? Bool
        if cpu != nil || memory != nil, store.object(forKey: MenuBarPanelCard.performance.defaultsKey) == nil {
            store.set((cpu ?? true) || (memory ?? true), forKey: MenuBarPanelCard.performance.defaultsKey)
        }
        ["menuBar.card.cpu", "menuBar.card.memory", "menuBar.card.recommendation"].forEach(store.removeObject)
    }

    static var metrics: [MenuBarMetric] {
        MenuBarMetric.allCases.filter { UserDefaults.standard.bool(forKey: $0.defaultsKey) }
    }

    static var style: MenuBarReadoutStyle {
        MenuBarReadoutStyle(rawValue: UserDefaults.standard.string(forKey: styleKey) ?? "") ?? .stacked
    }

    static var interval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: intervalKey)
        return value > 0 ? value : 2
    }

    static var alertColors: Bool { UserDefaults.standard.bool(forKey: alertsKey) }

    static var showIcon: Bool { UserDefaults.standard.bool(forKey: showIconKey) }

    static func isVisible(_ card: MenuBarPanelCard) -> Bool {
        UserDefaults.standard.bool(forKey: card.defaultsKey)
    }
}

// MARK: - Values

struct MenuBarReadoutValues: Equatable {
    var cpu: Double?
    var memory: Double?
    var gpu: Double?
    var temperature: Double?
    var down: Double?
    var up: Double?
    var diskFree: Int64?

    /// What the settings preview shows before the first real reading.
    static let preview = MenuBarReadoutValues(cpu: 0.18, memory: 0.62, gpu: 0.07, temperature: 52, down: 1_200_000, up: 84_000, diskFree: 56_000_000_000)
}

// MARK: - Sampler

/// Reads only the metrics shown in the menu bar, on the chosen interval, with
/// timer tolerance so macOS can coalesce wake-ups. Temperature is read at most
/// every five seconds and free space every minute; nothing runs while the
/// displays sleep or when no metric is shown.
@MainActor
final class MenuBarReadoutSampler {
    var onUpdate: ((MenuBarReadoutValues) -> Void)?
    private(set) var values = MenuBarReadoutValues()

    private var metrics: Set<MenuBarMetric> = []
    private var interval: TimeInterval = 2
    private var timer: Timer?
    private var cpuReader = CPULoadReader()
    private let gpuReader = GPUUsageReader()
    private var previousNetwork: (inBytes: UInt64, outBytes: UInt64, at: UInt64)?
    private var networkInterface: String?
    private var lastInterfaceLookup: Date?
    private var lastTemperature: Date?
    private var lastDisk: Date?
    private var displaysAsleep = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaysAsleep = true; self?.reschedule() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaysAsleep = false; self?.reschedule() }
        })
    }

    func configure(metrics: [MenuBarMetric], interval: TimeInterval) {
        let set = Set(metrics)
        guard set != self.metrics || interval != self.interval || timer == nil else { return }
        self.metrics = set
        self.interval = interval
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard !metrics.isEmpty, !displaysAsleep else { return }
        tick()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        var next = values
        if metrics.contains(.cpu), let load = cpuReader.read() {
            next.cpu = min(1, load.user + load.system)
        }
        if metrics.contains(.memory), let memory = MemoryReader.snapshot(), memory.total > 0 {
            next.memory = Double(memory.used) / Double(memory.total)
        }
        if metrics.contains(.gpu) {
            next.gpu = gpuReader.read()
        }
        if metrics.contains(.network) {
            readNetwork(into: &next)
        }
        if metrics.contains(.disk), lastDisk.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            lastDisk = Date()
            next.diskFree = StartupDiskReader.read()?.available
        }
        if metrics.contains(.temperature), lastTemperature.map({ Date().timeIntervalSince($0) >= max(5, interval) }) ?? true {
            lastTemperature = Date()
            Task { [weak self] in
                let celsius = await Task.detached(priority: .utility) { DieTemperature.read() }.value
                guard let self else { return }
                self.values.temperature = celsius
                self.onUpdate?(self.values)
            }
        }
        if next != values {
            values = next
            onUpdate?(values)
        }
    }

    private func readNetwork(into values: inout MenuBarReadoutValues) {
        if lastInterfaceLookup.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
            lastInterfaceLookup = Date()
            networkInterface = NetworkReader.primaryInterface()
        }
        guard let interface = networkInterface, let counters = NetworkReader.byteCounters()[interface] else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let previous = previousNetwork, now > previous.at, counters.0 >= previous.inBytes, counters.1 >= previous.outBytes {
            let seconds = Double(now - previous.at) / 1_000_000_000
            values.down = Double(counters.0 - previous.inBytes) / seconds
            values.up = Double(counters.1 - previous.outBytes) / seconds
        }
        previousNetwork = (counters.0, counters.1, now)
    }
}

// MARK: - Drawing

enum MenuBarReadoutRenderer {
    private static let height: CGFloat = 22
    private static let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)
    private static let stackedValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let stackedNetworkFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let inlineFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// The widest text each metric can show, so its slot never changes width.
    private static func widest(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .cpu, .memory, .gpu: return "100%"
        case .temperature: return "100°"
        case .disk: return "999 GB"
        case .network: return "↓999K"
        }
    }

    static func image(values: MenuBarReadoutValues, metrics: [MenuBarMetric], style: MenuBarReadoutStyle, alerts: Bool, icon: NSImage?) -> NSImage {
        let slots = metrics.map { metric in
            (metric, text(for: metric, values: values), severity(for: metric, values: values, alerts: alerts))
        }
        let anyAlert = slots.contains { $0.2 != nil }
        let spacing: CGFloat = style == .stacked ? 8 : 10
        let iconWidth: CGFloat = icon == nil ? 0 : 18
        let widths = metrics.map { slotWidth($0, style: style) }
        let total = iconWidth + (icon != nil && !metrics.isEmpty ? 6 : 0) + widths.reduce(0, +) + spacing * CGFloat(max(0, metrics.count - 1))
        let image = NSImage(size: NSSize(width: max(total, 18), height: height), flipped: false) { _ in
            // Template pixels are black; with an alert showing, the image
            // can't be a template, so normal text takes the label color,
            // resolved against the menu bar when drawn.
            let normal: NSColor = anyAlert ? .labelColor : .black
            var x: CGFloat = 0
            if let icon {
                icon.draw(in: NSRect(x: 0, y: (height - 16) / 2, width: 18, height: 16), from: .zero, operation: .sourceOver, fraction: 1)
                x += iconWidth + 6
            }
            for (index, slot) in slots.enumerated() {
                let color = slot.2 ?? normal
                let width = widths[index]
                draw(slot.0, text: slot.1, style: style, color: color, x: x, width: width)
                x += width + spacing
            }
            return true
        }
        image.isTemplate = !anyAlert
        return image
    }

    private static func slotWidth(_ metric: MenuBarMetric, style: MenuBarReadoutStyle) -> CGFloat {
        switch style {
        case .stacked:
            let valueFont = metric == .network ? stackedNetworkFont : stackedValueFont
            let value = (widest(metric) as NSString).size(withAttributes: [.font: valueFont]).width
            let label = (metric.label as NSString).size(withAttributes: [.font: labelFont]).width
            return ceil(max(value, label))
        case .inline:
            let sample = metric == .network ? "↓999K ↑999K" : "\(metric.label) \(widest(metric))"
            return ceil((sample as NSString).size(withAttributes: [.font: inlineFont]).width)
        }
    }

    private static func draw(_ metric: MenuBarMetric, text: (String, String?), style: MenuBarReadoutStyle, color: NSColor, x: CGFloat, width: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style == .stacked ? .center : .left
        switch style {
        case .stacked:
            if metric == .network {
                let attributes: [NSAttributedString.Key: Any] = [.font: stackedNetworkFont, .foregroundColor: color, .paragraphStyle: paragraph]
                (("↑" + (text.1 ?? "–")) as NSString).draw(in: NSRect(x: x, y: 10.5, width: width, height: 11), withAttributes: attributes)
                (("↓" + text.0) as NSString).draw(in: NSRect(x: x, y: 0.5, width: width, height: 11), withAttributes: attributes)
            } else {
                let label: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: color.withAlphaComponent(0.75), .paragraphStyle: paragraph]
                let value: [NSAttributedString.Key: Any] = [.font: stackedValueFont, .foregroundColor: color, .paragraphStyle: paragraph]
                (metric.label as NSString).draw(in: NSRect(x: x, y: 12.5, width: width, height: 9), withAttributes: label)
                (text.0 as NSString).draw(in: NSRect(x: x, y: -0.5, width: width, height: 14), withAttributes: value)
            }
        case .inline:
            let attributes: [NSAttributedString.Key: Any] = [.font: inlineFont, .foregroundColor: color, .paragraphStyle: paragraph]
            let line = metric == .network ? "↓\(text.0) ↑\(text.1 ?? "–")" : "\(metric.label) \(text.0)"
            (line as NSString).draw(in: NSRect(x: x, y: 3, width: width, height: 16), withAttributes: attributes)
        }
    }

    /// The value, and for the network the upload as a second value.
    private static func text(for metric: MenuBarMetric, values: MenuBarReadoutValues) -> (String, String?) {
        func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }
        switch metric {
        case .cpu: return (percent(values.cpu), nil)
        case .memory: return (percent(values.memory), nil)
        case .gpu: return (percent(values.gpu), nil)
        case .temperature: return (values.temperature.map { "\(Int($0.rounded()))°" } ?? "–", nil)
        case .disk:
            return (values.diskFree.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file).replacingOccurrences(of: ",", with: ".") } ?? "–", nil)
        case .network:
            return (values.down.map(compactRate) ?? "–", values.up.map(compactRate))
        }
    }

    /// "820K", "1.2M": short enough for the menu bar.
    private static func compactRate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1_000: return "\(Int(bytesPerSecond))B"
        case ..<1_000_000: return "\(Int(bytesPerSecond / 1_000))K"
        case ..<10_000_000: return String(format: "%.1fM", bytesPerSecond / 1_000_000)
        default: return "\(Int(bytesPerSecond / 1_000_000))M"
        }
    }

    /// Orange or red when a value runs high, if alert colors are on.
    private static func severity(for metric: MenuBarMetric, values: MenuBarReadoutValues, alerts: Bool) -> NSColor? {
        guard alerts else { return nil }
        let level: Double?
        let warn: Double, critical: Double
        switch metric {
        case .cpu: level = values.cpu; warn = 0.8; critical = 0.95
        case .memory: level = values.memory; warn = 0.85; critical = 0.95
        case .gpu: level = values.gpu; warn = 0.85; critical = 0.97
        case .temperature: level = values.temperature; warn = 85; critical = 95
        default: return nil
        }
        guard let level else { return nil }
        if level >= critical { return .systemRed }
        if level >= warn { return .systemOrange }
        return nil
    }
}
