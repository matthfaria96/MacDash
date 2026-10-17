import AppKit
import SwiftUI

/// The apps the user has open, heaviest first, each folded to one line that
/// unfolds into its details and actions. The numbers come from the page's
/// own reading, which pauses when MacDash is in the background.
struct ProcessResourcesView: View {
    @ObservedObject var model: PerformanceModel
    let isActive: Bool
    /// Extra controls shown just left of the Activity Monitor button.
    var accessory: AnyView? = nil
    @State private var sort: ProcessResourceSort = .memory
    @State private var ascending = false
    @State private var pendingForceQuit: ProcessResourceConsumer?
    @State private var quitting: Set<String> = []
    @State private var quitFailed: String?
    @State private var search = ""
    @State private var expanded: String?
    @State private var showsAll = false

    /// Apps shown before "Show all": five rows of two.
    static let foldedLimit = 10

    var body: some View {
        let sorted = ProcessResourceMath.sorted(model.openApps, by: sort, ascending: ascending, search: search)
        let folding = search.isEmpty && !showsAll && sorted.count > Self.foldedLimit
        let visibleConsumers = folding ? Array(sorted.prefix(Self.foldedLimit)) : sorted
        // Bars compare apps with each other, so a 2 GB app on a 64 GB Mac
        // still reads as the heavy one.
        let memoryScale = max(sorted.map(\.memoryBytes).max() ?? 0, ProcessInfo.processInfo.physicalMemory / 10)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Open apps")
                        .font(.system(size: 15, weight: .semibold))
                    if !model.openApps.isEmpty {
                        Text(verbatim: "\(model.openApps.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .numericTransition()
                            .animation(MotionTokens.snappy, value: model.openApps.count)
                    }
                    if !isActive {
                        Label("Paused", systemImage: "pause.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 8)
                GlassSearchField(prompt: "Search apps", text: $search, maxWidth: 220)
                    .accessibilityIdentifier("performance.processSearch")
                if let accessory { accessory }
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(GlassButtonStyle())
                .help("Open Activity Monitor")
                .accessibilityLabel("Open Activity Monitor")
            }

            if model.openApps.isEmpty && !model.hasReadProcesses {
                // Rows in the shape of what's coming, while the first reading runs.
                VStack(spacing: 10) {
                    ForEach(0..<5, id: \.self) { _ in
                        HStack(spacing: 12) {
                            SkeletonBlock(width: 26, height: 26, corner: 7)
                            VStack(alignment: .leading, spacing: 6) {
                                SkeletonBlock(width: 140, height: 11)
                                SkeletonBlock(width: 90, height: 3)
                            }
                            Spacer()
                            SkeletonBlock(width: 40, height: 10)
                            SkeletonBlock(width: 60, height: 10)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                }
                .transition(.opacity)
            } else if visibleConsumers.isEmpty {
                if isActive || !model.openApps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("No matching apps")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .transition(.opacity)
                }
            } else {
                // Two columns: the heavier half down the left, the rest down
                // the right, so a live re-sort rarely moves an app across.
                let half = (visibleConsumers.count + 1) / 2
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<2, id: \.self) { column in
                        VStack(spacing: 3) {
                            columnHeader
                            ForEach(Array(visibleConsumers.enumerated()).filter { ($0.offset < half) == (column == 0) }, id: \.element.id) { index, consumer in
                                row(consumer, index: index, memoryScale: memoryScale)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .animation(MotionTokens.gentle, value: visibleConsumers.map(\.id))

                if search.isEmpty && sorted.count > Self.foldedLimit {
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { showsAll.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(showsAll ? "Show fewer" : "Show all \(sorted.count) apps")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(showsAll ? 180 : 0))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                        .overlay(Capsule().strokeBorder(GlassEdge.gradient, lineWidth: 0.7))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }

            Text("Helpers are counted with their app. Click an app for its details and to quit it.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .animation(MotionTokens.gentle, value: isActive)
        .alert(
            pendingForceQuit.map { String(format: String(localized: "Force quit %@?"), $0.name) } ?? "",
            isPresented: Binding(get: { pendingForceQuit != nil }, set: { if !$0 { pendingForceQuit = nil } }),
            presenting: pendingForceQuit
        ) { consumer in
            Button("Cancel", role: .cancel) {}
            Button("Force Quit", role: .destructive) { forceQuit(consumer) }
        } message: { _ in
            Text("The app closes right away. Anything you haven't saved in it is lost.")
        }
        .alert("Couldn't quit the app", isPresented: Binding(get: { quitFailed != nil }, set: { if !$0 { quitFailed = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(quitFailed ?? "")
        }
        .onAppear {
            // The search field would otherwise take the window's first focus,
            // and the page would scroll back to it whenever a panel unfolds.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private func row(_ consumer: ProcessResourceConsumer, index: Int, memoryScale: UInt64) -> some View {
        ProcessResourceRow(
            consumer: consumer,
            icon: consumer.applicationPath.flatMap(model.icon(forPath:)),
            memoryScale: memoryScale,
            sort: sort,
            index: index,
            canQuit: Self.runningApp(for: consumer) != nil,
            isQuitting: quitting.contains(consumer.id),
            isExpanded: expanded == consumer.id,
            onToggle: {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    expanded = expanded == consumer.id ? nil : consumer.id
                }
            },
            onQuit: { quit(consumer) },
            onForceQuit: { pendingForceQuit = consumer }
        )
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        ))
    }

    /// Column titles over each half of the list. CPU and Memory sort the
    /// apps; the arrow shows the direction, and clicking again flips it.
    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("App")
            Spacer(minLength: 4)
            sortHeader("CPU", for: .cpu)
                .frame(width: ProcessResourceRow.cpuWidth, alignment: .trailing)
            sortHeader("Memory", for: .memory)
                .frame(width: ProcessResourceRow.memoryWidth, alignment: .trailing)
            Color.clear.frame(width: 12, height: 1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private func sortHeader(_ title: LocalizedStringKey, for column: ProcessResourceSort) -> some View {
        let isCurrent = sort == column
        return Button {
            withAnimation(MotionTokens.snappy) {
                if isCurrent { ascending.toggle() } else { sort = column; ascending = false }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: isCurrent ? (ascending ? "arrow.up" : "arrow.down") : "arrow.up.arrow.down")
                    .font(.system(size: isCurrent ? 8.5 : 7.5, weight: .bold))
                    .opacity(isCurrent ? 1 : 0.5)
            }
            .foregroundStyle(isCurrent ? SectionPalette.processes.accent : Color.white.opacity(0.45))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCurrent
              ? (ascending ? "Lightest first. Click for the heaviest first." : "Heaviest first. Click for the lightest first.")
              : "Sort by this column")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

extension ProcessResourcesView {
    /// The running app behind a row, unless it is MacDash itself or Finder,
    /// which are never offered for quitting.
    fileprivate static func runningApp(for consumer: ProcessResourceConsumer) -> NSRunningApplication? {
        guard let path = consumer.applicationPath else { return nil }
        let app = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleURL?.path == path
        }
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier, app.bundleIdentifier != "com.apple.finder" else { return nil }
        return app
    }

    /// Asks the app to quit the normal way, so it can offer to save documents.
    /// The row shows progress until the app is gone or a few seconds pass.
    fileprivate func quit(_ consumer: ProcessResourceConsumer) {
        guard let app = Self.runningApp(for: consumer), app.terminate() else { return }
        quitting.insert(consumer.id)
        Task {
            for _ in 0..<16 where !app.isTerminated {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            quitting.remove(consumer.id)
        }
    }

    fileprivate func forceQuit(_ consumer: ProcessResourceConsumer) {
        guard let app = Self.runningApp(for: consumer) else { return }
        if !app.forceTerminate() {
            quitFailed = String(format: String(localized: "macOS didn't let MacDash close %@."), consumer.name)
        }
    }
}

/// A compact glass capsule for row actions; red-tinted when destructive.
struct RowActionButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        RowActionButton(configuration: configuration, destructive: destructive)
    }

    private struct RowActionButton: View {
        let configuration: ButtonStyleConfiguration
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let tint = destructive ? Tint.red : Color.white
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(destructive ? Tint.red : Color.white.opacity(0.92))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(.ultraThinMaterial).opacity(0.6)
                    Capsule().fill(tint.opacity(hovering && isEnabled ? (destructive ? 0.3 : 0.18) : (destructive ? 0.18 : 0.1)))
                }
                .overlay(Capsule().strokeBorder(destructive ? AnyShapeStyle(Tint.red.opacity(0.55)) : AnyShapeStyle(GlassEdge.gradient), lineWidth: 0.8))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .animation(MotionTokens.snappy, value: hovering)
                .animation(MotionTokens.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A thin meter used in both columns.
struct UsageMeter: View {
    let fraction: Double
    let tint: LinearGradient

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.08))
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(tint)
                        .frame(width: fraction > 0 ? max(3, geometry.size.width * min(1, fraction)) : 0)
                }
            }
            .animation(.easeInOut(duration: 0.5), value: fraction)
            .accessibilityHidden(true)
    }
}

/// One app, folded to a line: icon, name, a meter for the sorted column and
/// both values. Clicking unfolds the details and the Quit actions.
private struct ProcessResourceRow: View {
    static let cpuWidth: CGFloat = 58
    static let memoryWidth: CGFloat = 76

    let consumer: ProcessResourceConsumer
    let icon: NSImage?
    let memoryScale: UInt64
    let sort: ProcessResourceSort
    let index: Int
    let canQuit: Bool
    let isQuitting: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    let onQuit: () -> Void
    let onForceQuit: () -> Void
    @State private var hovering = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let palette = PerformancePalette.processes

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) { folded }
                .buttonStyle(.plain)
            if isExpanded {
                details
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .background {
            shape.fill(Color.white.opacity(isExpanded ? 0.07 : (hovering ? 0.045 : 0)))
            if isExpanded {
                shape.fill(LinearGradient(colors: [palette.app.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(isExpanded ? 0.1 : 0), lineWidth: 0.7))
        .clipShape(shape)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        // Rows cascade in the first time they appear.
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(x: appeared || reduceMotion ? 0 : -10)
        .onAppear {
            guard !appeared else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(min(Double(index), 10) * 0.035)) { appeared = true }
        }
        .contextMenu {
            if canQuit {
                Button("Quit", action: onQuit)
                Button("Force Quit…", action: onForceQuit)
                Divider()
            }
            if let path = consumer.applicationPath {
                Button("Show in Finder") { showInFinder(path) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Quit")) { if canQuit { onQuit() } }
        .accessibilityAction(named: Text("Force Quit")) { if canQuit { onForceQuit() } }
    }

    private var folded: some View {
        HStack(spacing: 10) {
            appIcon
                .frame(width: 26, height: 26)
                .scaleEffect(hovering && !reduceMotion ? 1.08 : 1)
                .animation(MotionTokens.snappy, value: hovering)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: consumer.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(consumer.processCount == 1 ? "1 process" : "\(consumer.processCount) processes")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 8)
            if isQuitting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Quitting…").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .transition(.opacity)
            }
            Group {
                if consumer.cpuFraction == nil {
                    SkeletonBlock(width: 30, height: 9)
                } else {
                    Text(verbatim: cpuText)
                        .foregroundStyle((consumer.cpuFraction ?? 0) >= 0.1 ? palette.cpu : Color.white.opacity(sort == .cpu ? 0.95 : 0.6))
                }
            }
            .frame(width: Self.cpuWidth, alignment: .trailing)
            Text(verbatim: formatMemory(consumer.memoryBytes))
                .foregroundStyle(Color.white.opacity(sort == .memory ? 0.95 : 0.6))
                .frame(width: Self.memoryWidth, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(hovering || isExpanded ? 0.65 : 0.25))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(consumer.applicationPath ?? consumer.name)
    }

    private var details: some View {
        let ramShare = Double(consumer.memoryBytes) / Double(max(ProcessInfo.processInfo.physicalMemory, 1))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                detailMetric("CPU", value: cpuText, caption: consumer.cpuIsPartial ? String(localized: "Partial reading") : String(localized: "of all cores")) {
                    UsageMeter(fraction: consumer.cpuFraction ?? 0, tint: cpuGradient)
                }
                detailMetric("Memory", value: formatMemory(consumer.memoryBytes),
                             caption: String(format: String(localized: "%@ of RAM"), ramShare.formatted(.percent.precision(.fractionLength(1))))) {
                    UsageMeter(fraction: ramShare, tint: memoryGradient)
                }
            }
            if let path = consumer.applicationPath {
                Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                if let path = consumer.applicationPath {
                    Button { showInFinder(path) } label: { Image(systemName: "folder") }
                        .buttonStyle(RowActionButtonStyle())
                        .help("Show in Finder")
                        .accessibilityLabel("Show in Finder")
                }
                Spacer(minLength: 0)
                if canQuit {
                    Button("Force Quit", action: onForceQuit)
                        .buttonStyle(RowActionButtonStyle(destructive: true))
                        .fixedSize()
                        .help("The app closes right away, without saving")
                    Button("Quit", action: onQuit)
                        .buttonStyle(RowActionButtonStyle())
                        .fixedSize()
                        .disabled(isQuitting)
                        .help("Asks the app to quit, so it can offer to save your work.")
                }
            }
        }
        .padding(.leading, 46)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }

    private func detailMetric<Meter: View>(_ title: LocalizedStringKey, value: String, caption: String, @ViewBuilder meter: () -> Meter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.5))
            Text(verbatim: value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .numericTransition()
            meter()
            Text(verbatim: caption)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            CategoryBadge(systemName: "gearshape.2", tint: .secondary, size: 26)
                .accessibilityHidden(true)
        }
    }

    private var memoryFraction: Double {
        memoryScale > 0 ? Double(consumer.memoryBytes) / Double(memoryScale) : 0
    }

    private var cpuGradient: LinearGradient {
        LinearGradient(colors: [palette.cpuSystem, palette.cpu], startPoint: .leading, endPoint: .trailing)
    }

    private var memoryGradient: LinearGradient {
        LinearGradient(colors: [palette.app, palette.wired], startPoint: .leading, endPoint: .trailing)
    }

    private func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// A trailing plus marks a group whose CPU is the sum of its measured members only.
    private var cpuText: String {
        guard let cpu = consumer.cpuFraction else { return "—" }
        let value = cpu.formatted(.percent.precision(.fractionLength(1)))
        return consumer.cpuIsPartial ? value + "+" : value
    }
}
