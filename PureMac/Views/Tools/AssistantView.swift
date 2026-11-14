import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Diagnosis: one screen that says how the Mac is doing, where the space
/// went and what to do first. It works from fixed rules on this Mac alone.
/// Nothing moves before the files are checked again and confirmed, and every
/// analysis leaves a report.
///
/// Read top to bottom it answers three questions, in this order: how is the
/// Mac (the ring), where did the space go (one bar), what should I do (the
/// recommendations, most urgent first). Explanations stay folded away.
struct AssistantView: View {
    var onNavigate: (AppSection) -> Void = { _ in }

    @ObservedObject private var store = AssistantStore.shared
    @ObservedObject private var permission = PermissionCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsHandled = false
    @State private var detailsReport: AssistantReport?
    @State private var isDropTargeted = false

    static let symbol = "stethoscope"
    /// Both ways in share one width, so they read as a pair.
    private static let entryWidth: CGFloat = 250
    private var accent: Color { SectionPalette.assistant.accent }

    var body: some View {
        ScrollViewReader { proxy in
            content
                .onAppear {
                    store.loadHistory()
                    if store.analyzeWhenShown {
                        store.analyzeWhenShown = false
                        store.analyze()
                    }
                    #if DEBUG
                    applyDebugLaunchState(proxy)
                    #endif
                }
        }
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: store.phase)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: store.message)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(accent.opacity(0.08)))
                    .overlay(Label("Drop a folder to analyze it", systemImage: "folder.badge.questionmark").font(.headline))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .sheet(item: $store.plan) { _ in
            AssistantPlanSheet(store: store, accent: accent)
        }
        .sheet(item: $detailsReport) { report in
            AssistantDetailsSheet(report: report) { detailsReport = nil }
        }
    }

    #if DEBUG
    /// Debug builds only: `-DebugAssistant recommendations|review|details`
    /// opens that state once results are in, so screenshots don't need clicks.
    private func applyDebugLaunchState(_ proxy: ScrollViewProxy) {
        guard let state = UserDefaults.standard.string(forKey: "DebugAssistant") else { return }
        Task { @MainActor in
            for _ in 0..<60 where store.phase != .results { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard store.phase == .results else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            switch state {
            case "recommendations": proxy.scrollTo("recommendations", anchor: .top)
            case "review":
                if let finding = store.live?.findings.first(where: { $0.action == .trash }) { store.review(finding.id) }
            case "details": detailsReport = store.live
            default: break
            }
        }
    }
    #endif

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                topBar
                if let message = store.message {
                    messageBanner(message)
                }
                switch store.phase {
                case .idle: idle
                case .analyzing: AssistantAnalyzingPanel(store: store)
                case .results:
                    if let report = store.live { results(report) } else { idle }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Top bar

    /// The name and three promises, without a paragraph; actions on the right.
    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Assistant")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    promise("cpu", "No AI")
                    promise("wifi.slash", "Offline")
                    promise("trash", "Trash only")
                }
            }
            Spacer(minLength: 8)
            if store.phase == .results {
                // Back to the first screen, where the Mac or a folder can be
                // chosen again; the report stays in History.
                Button {
                    withAnimation(reduceMotion ? nil : MotionTokens.gentle) { store.startOver() }
                } label: {
                    Label("Start over", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(store.isMoving)
                .keyboardShortcut(.cancelAction)
                .help("Back to the start. This report stays in History.")
                Button {
                    store.analyzeAgain()
                } label: {
                    Label("Analyze Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(store.isMoving)
            }
        }
    }

    /// Picks a folder to analyze on its own.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        panel.prompt = String(localized: "Analyze")
        panel.message = String(localized: "Choose a folder to see what is inside it and what is worth cleaning.")
        if panel.runModal() == .OK, let url = panel.url { store.analyze(folder: url.path) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard store.phase != .analyzing, !store.isMoving,
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in AssistantStore.shared.analyze(folder: url.path) }
        }
        return true
    }

    private func promise(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.6))
    }

    private func messageBanner(_ message: AssistantStore.Message) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            NoticeBanner(text: message.text, isError: message.isError) { store.message = nil }
            if message.offersTrash {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
                } label: {
                    Label("Open Trash", systemImage: "trash")
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Before an analysis

    private var needsAccess: Bool { !permission.hasFullDiskAccess && !DemoMode.isActive }

    @ViewBuilder
    private var idle: some View {
        // One calm block: the emblem, one sentence, then the two ways in,
        // stacked, with room around everything.
        AuroraPanel(padding: 0) {
            VStack(spacing: 0) {
                AuroraOrb(size: 136) {
                    Image(systemName: Self.symbol)
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 34)

                VStack(spacing: 10) {
                    Text("Find what is using space and what is worth cleaning.")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Usually under a minute. Nothing is changed.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: 560)
                .padding(.bottom, 36)

                VStack(spacing: 12) {
                    Button {
                        store.analyze()
                    } label: {
                        Label("Analyze This Mac", systemImage: "play.fill")
                            .frame(width: Self.entryWidth)
                    }
                    .buttonStyle(GlassProminentButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)

                    Button(action: chooseFolder) {
                        // The glass style pads 6 pt less on each side than the
                        // prominent one, so the label is wider by that much.
                        Label("Analyze a Folder…", systemImage: "folder")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: Self.entryWidth + 12)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.large)
                }

                Label("Drop a folder to analyze it", systemImage: "arrow.down.to.line")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 16)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity, minHeight: 500)
        }
        if needsAccess {
            AssistantAccessCard(onGranted: { store.analyze() })
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ report: AssistantReport) -> some View {
        AssistantHealthHero(report: report) { detailsReport = report }

        if report.limitedAccess {
            if needsAccess {
                AssistantAccessCard(onGranted: { store.analyze() })
            } else if !DemoMode.isActive {
                accessNowOn
            }
        }

        if report.usage.contains(where: { $0.bytes > 0 }) {
            AssistantUsageBar(report: report)
        }

        let open = report.findings.filter { $0.status.isOpen && $0.action != .advice }
        VStack(alignment: .leading, spacing: 16) {
            Text("Recommendations").font(.system(size: 18, weight: .semibold, design: .rounded))
            if open.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Tint.green)
                    Text(report.scope == nil ? "Your Mac is in good shape." : "Nothing to clean in this folder.").foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(16)
                .background(GlassPanelBackground(cornerRadius: 14))
            } else {
                ForEach(AssistantPriority.allCases, id: \.self) { priority in
                    let group = open.filter { AssistantPriority(severity: $0.severity) == priority }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            priorityHeader(priority, count: group.count)
                            ForEach(group) { finding in
                                AssistantFindingCard(finding: finding, accent: accent, actions: actions(for: finding))
                            }
                        }
                    }
                }
            }
        }
        .id("recommendations")

        let handled = report.findings.filter { !$0.status.isOpen }
        if !handled.isEmpty {
            disclosure("Handled", count: handled.count, isOpen: $showsHandled) {
                ForEach(handled) { finding in
                    AssistantFindingCard(finding: finding, accent: accent, actions: actions(for: finding))
                }
            }
        }
    }

    private var accessNowOn: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tint.green)
            Text("Full Disk Access is on. Analyze again to include every folder.")
                .font(.system(size: 12.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Analyze Again") { store.analyze() }
                .buttonStyle(GlassProminentButtonStyle())
        }
        .padding(14)
        .background(GlassPanelBackground(cornerRadius: 14))
    }

    private func priorityHeader(_ priority: AssistantPriority, count: Int) -> some View {
        HStack(spacing: 8) {
            Circle().fill(priority.tint(accent: accent)).frame(width: 8, height: 8)
            Text(priority.title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.7))
            Text(count.formatted())
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.leading, 2)
    }

    private func actions(for finding: AssistantFinding) -> AssistantFindingCard.Actions {
        AssistantFindingCard.Actions(
            isChecking: store.checkingID == finding.id,
            isBusy: store.isMoving || store.checkingID != nil,
            review: { store.review(finding.id) },
            openTool: { if let section = store.handOver(finding.id) { onNavigate(section) } },
            ignore: { withAnimation(reduceMotion ? nil : MotionTokens.gentle) { store.ignore(finding.id) } },
            restore: { withAnimation(reduceMotion ? nil : MotionTokens.gentle) { store.restore(finding.id) } }
        )
    }

    private func disclosure<Content: View>(
        _ title: LocalizedStringKey, count: Int, isOpen: Binding<Bool>, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : MotionTokens.snappy) { isOpen.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen.wrappedValue {
                content().transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Priorities

/// The three groups recommendations are shown in.
enum AssistantPriority: CaseIterable {
    case now
    case worth
    case know

    init(severity: AssistantSeverity) {
        switch severity {
        case .critical, .attention: self = .now
        case .suggestion: self = .worth
        case .info: self = .know
        }
    }

    var title: String {
        switch self {
        case .now: return String(localized: "Do now")
        case .worth: return String(localized: "Worth doing")
        case .know: return String(localized: "Good to know")
        }
    }

    func tint(accent: Color) -> Color {
        switch self {
        case .now: return Tint.orange
        case .worth: return accent
        case .know: return Color.white.opacity(0.5)
        }
    }
}

enum AssistantFormat {
    /// The path with the home folder written as "~".
    static func path(_ path: String) -> String {
        let home = DemoMode.isActive ? "/Users/alex" : NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func tint(_ severity: AssistantSeverity, accent: Color) -> Color {
        switch severity {
        case .critical: return Tint.red
        case .attention: return Tint.orange
        case .suggestion: return accent
        case .info: return Color.white.opacity(0.55)
        }
    }
}

// MARK: - Aurora pieces

/// The panel that carries Diagnosis' identity: glass with an aurora edge.
struct AuroraPanel<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial).opacity(0.5)
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.black.opacity(0.22))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(RadialGradient(colors: [SectionPalette.auroraColors[0].opacity(0.16), .clear],
                                         center: .topLeading, startRadius: 0, endRadius: 420))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(RadialGradient(colors: [SectionPalette.auroraColors[2].opacity(0.16), .clear],
                                         center: .bottomTrailing, startRadius: 0, endRadius: 420))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: SectionPalette.auroraColors.map { $0.opacity(0.55) },
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}

/// A round emblem with a slowly turning aurora rim.
struct AuroraOrb<Center: View>: View {
    var size: CGFloat
    @ViewBuilder var center: Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [SectionPalette.auroraColors[1].opacity(0.35), Color.black.opacity(0.4)],
                                     center: .center, startRadius: 0, endRadius: size * 0.55))
            SpinningRim(colors: SectionPalette.auroraColors + [SectionPalette.auroraColors[0]], diameter: size, lineWidth: 2.5,
                        period: 6, animate: !reduceMotion)
                .frame(width: size, height: size)
            center
        }
        .frame(width: size, height: size)
        .shadow(color: SectionPalette.auroraColors[0].opacity(0.35), radius: 22)
    }
}

// MARK: - While analyzing

struct AssistantAnalyzingPanel: View {
    @ObservedObject var store: AssistantStore

    private var steps: [AssistantStep] { AssistantStep.allCases }
    private var index: Int { steps.firstIndex(of: store.step) ?? 0 }
    private var progress: Double { (Double(index) + 0.5) / Double(steps.count) }

    var body: some View {
        AuroraPanel {
            VStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(AngularGradient(colors: SectionPalette.auroraColors + [SectionPalette.auroraColors[0]], center: .center),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.6), value: progress)
                    Image(systemName: store.step.symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white)
                        .id(store.step)
                        .transition(.scale.combined(with: .opacity))
                }
                .frame(width: 128, height: 128)

                VStack(spacing: 6) {
                    Text(store.step.title)
                        .font(.system(size: 16, weight: .semibold))
                    Text(AssistantFormat.path(store.stepDetail))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 460, minHeight: 15)
                }

                HStack(spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { offset, step in
                        Image(systemName: offset < index ? "checkmark" : step.symbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(offset <= index ? Color.black.opacity(0.75) : Color.white.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(offset <= index ? AnyShapeStyle(SectionPalette.assistant.accent) : AnyShapeStyle(Color.white.opacity(0.08))))
                            .help(step.title)
                    }
                }
                StopActionButton { store.cancel() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - How the Mac is doing

/// The ring shows how full the disk is; its center, how much can come back.
/// Beside it: a one-word state, one sentence and three numbers.
struct AssistantHealthHero: View {
    let report: AssistantReport
    var showDetails: () -> Void

    private enum Health {
        case critical, attention, healthy
    }

    private var health: Health {
        let open = report.findings.filter { $0.status.isOpen }
        if open.contains(where: { $0.severity == .critical }) { return .critical }
        if open.contains(where: { $0.severity == .attention }) { return .attention }
        return .healthy
    }

    private var tint: Color {
        switch health {
        case .critical: return Tint.red
        case .attention: return Tint.orange
        case .healthy: return Tint.green
        }
    }

    private var healthTitle: String {
        switch health {
        case .critical: return String(localized: "Critical")
        case .attention: return String(localized: "Attention")
        case .healthy: return String(localized: "Healthy")
        }
    }

    /// For the Mac, how full the disk is; for a folder, its share of what is used.
    /// For the Mac, what the selected suggestions recover. For a folder the
    /// person asked about, everything in it that could go, selected or not.
    private var recoverable: Int64 {
        guard report.scope != nil else { return report.reclaimable }
        return report.findings.filter { $0.status.isOpen && $0.action == .trash }.reduce(0) { $0 + $1.total }
    }

    private var used: Double {
        if let size = report.scopeSize {
            return report.diskUsed > 0 ? min(1, Double(size) / Double(report.diskUsed)) : 0
        }
        return report.diskTotal > 0 ? Double(report.diskUsed) / Double(report.diskTotal) : 0
    }

    /// The disk warning and forecast are said here, not repeated as cards.
    /// The amount that can come back is in the ring, so the words don't repeat it.
    private var lines: (main: String, second: String) {
        if let scope = report.scope {
            let name = (scope as NSString).lastPathComponent
            let size = AssistantRules.format(report.scopeSize ?? 0)
            return (name + " · " + size, report.headline)
        }
        let disk = report.findings.first { $0.id == "disk.low" }
        let forecast = report.findings.first { $0.id == "disk.forecast" }
        let free = String(format: String(localized: "%@ free of %@"), AssistantRules.format(report.diskFree), AssistantRules.format(report.diskTotal))
        let main: String
        if let disk {
            main = disk.title
        } else if health == .healthy {
            main = String(localized: "Your Mac is in good shape.")
        } else {
            main = String(localized: "A few things are worth a look.")
        }
        return (main, forecast?.title ?? free)
    }

    var body: some View {
        AuroraPanel(padding: 24) {
            HStack(alignment: .center, spacing: 26) {
                ring
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        Text(healthTitle)
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tint.opacity(0.15)))

                    VStack(alignment: .leading, spacing: 4) {
                        if let scope = report.scope {
                            Label(AssistantFormat.path(scope), systemImage: "folder.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(lines.main)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(lines.second)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        stat(AssistantRules.format(report.movedBytes), "Moved to Trash", "trash")
                        // The same count as the list below; disk notes are said above.
                        stat(report.findings.filter { $0.status.isOpen && $0.action != .advice }.count.formatted(), "Pending", "list.bullet")
                    }

                    Button(action: showDetails) {
                        HStack(spacing: 4) {
                            Text(String(format: String(localized: "Last analysis: %@"), report.date.formatted(date: .abbreviated, time: .shortened)))
                            Text(verbatim: "·")
                            Text("Details")
                                .underline()
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 12)
            Circle()
                .trim(from: 0, to: used)
                .stroke(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.5), radius: 8)
            VStack(spacing: 2) {
                Text(AssistantRules.format(recoverable))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("Can be recovered")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 20)
        }
        .frame(width: 150, height: 150)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: LocalizedStringKey, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            Label(label, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 92, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Where the space went

/// One bar split by what fills the disk, with a legend. Each legend entry
/// opens the largest things inside it.
struct AssistantUsageBar: View {
    let report: AssistantReport
    @State private var opened: String?

    private static let colors: [String: Color] = [
        "documents": Color(red: 0.4, green: 1.0, blue: 0.7),
        "apps": Color(red: 0.45, green: 0.7, blue: 1.0),
        "appdata": Color(red: 0.95, green: 0.45, blue: 0.8),
        "developer": Color(red: 1.0, green: 0.62, blue: 0.3),
        "caches": Color(red: 0.72, green: 0.5, blue: 1.0),
        "downloads": Color(red: 0.35, green: 0.85, blue: 1.0),
        "desktop": Color(red: 0.3, green: 0.9, blue: 0.85),
        "movies": Color(red: 1.0, green: 0.82, blue: 0.35),
        "music": Color(red: 1.0, green: 0.45, blue: 0.55),
        "pictures": Color(red: 0.95, green: 0.95, blue: 0.5),
        "trash": Color(red: 1.0, green: 0.38, blue: 0.4),
        "other": Color.white.opacity(0.45),
        "system": Color.white.opacity(0.22),
    ]

    /// A folder's contents have no fixed kinds, so they take colors in turn.
    private static let cycle: [Color] = [
        Color(red: 0.4, green: 1.0, blue: 0.7), Color(red: 0.45, green: 0.7, blue: 1.0), Color(red: 0.72, green: 0.5, blue: 1.0),
        Color(red: 1.0, green: 0.62, blue: 0.3), Color(red: 0.95, green: 0.45, blue: 0.8), Color(red: 0.35, green: 0.85, blue: 1.0),
        Color(red: 1.0, green: 0.82, blue: 0.35), Color(red: 0.3, green: 0.9, blue: 0.85), Color(red: 1.0, green: 0.45, blue: 0.55),
    ]

    private func color(_ id: String) -> Color {
        if let fixed = Self.colors[id] { return fixed }
        if let index = slices.firstIndex(where: { $0.id == id }) { return Self.cycle[index % Self.cycle.count] }
        return Color.white.opacity(0.4)
    }

    private var slices: [AssistantUsage] { report.usage.filter { $0.bytes > 0 } }
    private var total: Int64 { max(slices.reduce(0) { $0 + $1.bytes }, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(report.scope == nil ? "What is using the disk" : "What is inside").font(.system(size: 18, weight: .semibold, design: .rounded))
            VStack(alignment: .leading, spacing: 16) {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        ForEach(slices) { slice in
                            Rectangle()
                                .fill(color(slice.id))
                                .frame(width: max(2, (geometry.size.width - CGFloat(slices.count) * 2) * CGFloat(slice.bytes) / CGFloat(total)))
                                .opacity(opened == nil || opened == slice.id ? 1 : 0.35)
                                .help(slice.title + " · " + AssistantRules.format(slice.bytes))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 14)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(slices) { slice in legend(slice) }
                }
            }
            .padding(18)
            .background(GlassPanelBackground(cornerRadius: 18))
        }
    }

    private func legend(_ slice: AssistantUsage) -> some View {
        Button {
            guard !slice.items.isEmpty else { return }
            opened = slice.id
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color(slice.id))
                    .frame(width: 10, height: 10)
                Text(slice.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(AssistantRules.format(slice.bytes))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                if !slice.items.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(opened == slice.id ? 0.12 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { opened == slice.id }, set: { if !$0 { opened = nil } }), arrowEdge: .bottom) {
            contents(slice)
        }
    }

    private func contents(_ slice: AssistantUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(slice.title).font(.system(size: 13, weight: .semibold))
            ForEach(slice.items) { item in
                HStack(spacing: 10) {
                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    Text(AssistantRules.format(item.bytes))
                        .font(.system(size: 12, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    if let path = item.path, !DemoMode.isActive {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Full Disk Access, without leaving the screen

/// Asks for Full Disk Access in place. After System Settings opens it waits
/// for the switch; if macOS wants MacDash reopened, "Quit & Reopen" (or the
/// button here) brings it back to this screen, which then analyzes on its own.
struct AssistantAccessCard: View {
    var onGranted: () -> Void

    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var waiting = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: waiting ? "hourglass" : "lock.shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SectionPalette.assistant.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(SectionPalette.assistant.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 8) {
                Text("Full Disk Access")
                    .font(.system(size: 14, weight: .semibold))
                if waiting {
                    step(1, "Turn on MacDash in the list")
                    step(2, "Choose Quit & Reopen. MacDash comes back here.")
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for access…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                    HStack(spacing: 14) {
                        Button("Reopen MacDash") { permission.relaunch() }
                            .buttonStyle(GlassButtonStyle())
                            .help("Access applies after MacDash reopens. It comes back to this screen.")
                        Button("MacDash not in the list?") { FullDiskAccessManager.shared.revealAppInFinder() }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                } else {
                    Text("Needed to look inside Documents, Desktop and Downloads.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !waiting {
                Button("Open Settings") {
                    FullDiskAccessManager.shared.triggerRegistration()
                    FullDiskAccessManager.shared.openFullDiskAccessSettings()
                    waiting = true
                }
                .buttonStyle(GlassProminentButtonStyle())
            }
        }
        .padding(16)
        .background(GlassPanelBackground(cornerRadius: 16))
        .task(id: waiting) {
            guard waiting else { return }
            permission.waitingElsewhere = true
            defer { permission.waitingElsewhere = false }
            // Some Macs apply the switch at once; then there's no need to reopen.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let granted = await Task.detached(priority: .utility) { FullDiskAccessManager.shared.hasFullDiskAccess }.value
                if granted {
                    permission.refreshStatus()
                    Haptics.success()
                    onGranted()
                    return
                }
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.black.opacity(0.75))
                .frame(width: 17, height: 17)
                .background(Circle().fill(SectionPalette.assistant.accent))
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - What was analyzed

struct AssistantProbesCard: View {
    let report: AssistantReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.probes) { probe in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: probe.complete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(probe.complete ? Tint.green : Tint.orange)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(probe.title).font(.system(size: 12.5, weight: .medium))
                        Text(probe.complete ? probe.detail : probe.detail + " · " + String(localized: "partly out of reach without full access"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
            Text(String(format: String(localized: "Time: %lld s · MacDash %@"), Int64(report.duration.rounded()), report.appVersion))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
    }
}

/// What the analysis covered, and the reminder that it is a snapshot.
struct AssistantDetailsSheet: View {
    let report: AssistantReport
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What was analyzed").font(.system(size: 16, weight: .semibold))
            AssistantProbesCard(report: report)
            Text(String(format: String(localized: "This shows the Mac as it was at %@. Files change, so every action checks them again first."),
                        report.date.formatted(date: .omitted, time: .shortened)))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(GlassProminentButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
