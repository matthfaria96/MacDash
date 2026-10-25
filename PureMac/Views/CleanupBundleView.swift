import SwiftUI

/// Scans, reviews and cleans every selected General Cleanup area (System and
/// Developer together) the way Smart Care does for everything.
struct GeneralCleanupRunView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Returns to the General Cleanup overview.
    var onBack: () -> Void = {}

    @State private var reviewing: ReviewTarget? = DemoMode.initialReview
    @State private var showConfirmation = false
    @State private var pendingItems: [CleanableItem] = []
    @State private var pendingOrphans: Set<URL> = []
    @State private var pendingUnusedApps: Set<String> = []
    @State private var orphanFreedSpace: Int64 = 0
    @State private var removalMessage: String?

    private enum Phase: Equatable {
        case idle, scanning, results, cleaning, cleaned
    }

    private let palette = SectionPalette.cleanup
    private let scope = ScanScope.generalCleanup
    /// Only areas the user kept selected count, even if older results exist
    /// for an area switched off later.
    private var allCategories: [CleaningCategory] { appState.enabledCleanupCategories }

    private var phase: Phase {
        if appState.isRunningGeneralCleanup { return .scanning }
        if appState.scanScope == scope {
            switch appState.scanState {
            case .completed: return .results
            case .cleaning: return .cleaning
            case .cleaned: return .cleaned
            default: break
            }
        }
        // Results stay available until they are discarded, even when another
        // screen ran the most recent scan.
        return appState.hasStoredCleanupResults ? .results : .idle
    }

    private var selectedItems: [CleanableItem] {
        allCategories
            .compactMap { appState.categoryResults[$0] }
            .flatMap(\.items)
            .filter(appState.isItemSelected)
    }

    private var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
            + (appState.cleanupIncludesOrphans ? appState.selectedOrphanSize : 0)
            + (appState.cleanupIncludesUnusedApps ? appState.selectedUnusedAppsSize : 0)
    }

    private var isBusyElsewhere: Bool {
        appState.isBusy(outside: scope)
    }

    var body: some View {
        ZStack {
        if reviewing != nil, phase == .results {
            // Full-window review: areas on the left, contents on the right.
            CleanupReviewScreen(
                reviewing: $reviewing,
                categories: allCategories,
                includesOrphans: appState.cleanupIncludesOrphans,
                includesUnusedApps: appState.cleanupIncludesUnusedApps,
                accent: palette.accent
            )
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
        } else {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 0).id("bundleTop")
                    HStack(spacing: 10) {
                        NavCapsuleButton(title: "Advanced Cleanup", systemImage: "chevron.left", action: goBack)
                            .help("Back to Advanced Cleanup")
                        Spacer(minLength: 10)
                        runControls
                    }
                    content
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 24)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onChange(of: reviewing) { _ in
                scroller.scrollTo("bundleTop", anchor: .top)
            }
            .onChange(of: phase) { _ in
                // Wait for the new phase to lay out before jumping to the top.
                DispatchQueue.main.async {
                    scroller.scrollTo("bundleTop", anchor: .top)
                }
            }
        }
        }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: reviewing)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if phase == .results {
                cleanupBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Clean selected items", role: .destructive) { performCleanup() }
            Button("Cancel", role: .cancel) {
                pendingItems = []
                pendingOrphans = []
            }
        } message: {
            Text(confirmationMessage)
        }
        .alert("Some files could not be removed", isPresented: Binding(
            get: { removalMessage != nil },
            set: { if !$0 { removalMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalMessage ?? "")
        }
        .onChange(of: phase) { newPhase in
            if newPhase != .results { reviewing = nil }
            // Start over / Done return to idle: go back to the overview.
            if newPhase == .idle { onBack() }
        }
    }

    // MARK: Header

    @ViewBuilder
    private var runControls: some View {
        if phase == .scanning {
            StopActionButton { appState.stopGeneralCleanup() }
        } else if phase == .results {
            NavCapsuleButton(title: "Scan again", systemImage: "arrow.clockwise") {
                reviewing = nil
                appState.startGeneralCleanup()
            }
            .disabled(appState.scanState.isActive || appState.isRemovingOrphans)
            .help("Scan the selected areas again")
        } else if phase == .cleaned {
            StartOverButton { startOver() }
                .disabled(appState.isRemovingOrphans)
        }
    }

    /// Leaving the run screen discards what it found, so the overview starts fresh.
    private func goBack() {
        if phase == .scanning { appState.stopGeneralCleanup() }
        startOver()
        onBack()
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            Color.clear.frame(height: 1)
        case .scanning:
            SmartCareScanningView(
                categories: appState.enabledCleanupCategories,
                includesOrphans: appState.cleanupIncludesOrphans,
                includesUnusedApps: appState.cleanupIncludesUnusedApps,
                title: "Scanning",
                accent: palette.accent,
                orbSymbol: "wand.and.stars"
            )
            .transition(.opacity)
        case .results:
            SmartCareResultsView(
                reviewing: $reviewing,
                categories: allCategories,
                includesOrphans: appState.cleanupIncludesOrphans,
                includesUnusedApps: appState.cleanupIncludesUnusedApps,
                accent: palette.accent,
                showsNavigation: false
            )
            .transition(.opacity)
        case .cleaning:
            cleaningContent
        case .cleaned:
            cleanedContent
        }
    }

    // MARK: Cleaning

    private var cleaningContent: some View {
        CardSurface(padding: 34, elevation: .standard, tint: palette.accent) {
            VStack(spacing: 22) {
                ScanningGauge(progress: appState.cleanProgress, tint: palette.accent, label: "CLEANING")
                    .frame(width: 170, height: 170)
                Text("Cleaning selected items")
                    .font(.system(size: 22, weight: .semibold))
                GlowProgressBar(progress: appState.cleanProgress, tint: palette.accent)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, minHeight: 340)
        }
    }

    private var cleanedContent: some View {
        let failed = appState.lastCleanupHadFailures
        return CardSurface(padding: 34, elevation: .standard, tint: failed ? Tint.orange : Tint.green) {
            HStack(spacing: 30) {
                SuccessMedal(tint: failed ? Tint.orange : Tint.green, size: 116)
                VStack(alignment: .leading, spacing: 8) {
                    Text(failed ? "Some items need attention" : "Cleanup complete")
                        .font(.system(size: 24, weight: .semibold))
                    CountUpBytes(bytes: appState.totalFreedSpace + orphanFreedSpace)
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                    Text("reclaimed")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Button("Done") { startOver() }
                        .buttonStyle(GlassProminentButtonStyle(large: true))
                        .tint(palette.accent)
                        .padding(.top, 6)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
        }
    }

    // MARK: Cleanup bar

    private var selectedCount: Int {
        selectedItems.count
            + (appState.cleanupIncludesOrphans ? appState.selectedOrphans.count : 0)
            + (appState.cleanupIncludesUnusedApps ? appState.selectedUnusedApps.count : 0)
    }

    private var cleanupBar: some View {
        CleanupActionBar(
            selectedCount: selectedCount,
            selectedSize: selectedSize,
            deep: palette.deep,
            isDisabled: appState.isRemovingOrphans || appState.isRemovingUnusedApps || appState.scanState.isActive
        ) {
            prepareCleanup()
        }
    }

    // MARK: Actions

    private func startOver() {
        reviewing = nil
        orphanFreedSpace = 0
        withAnimation(reduceMotion ? nil : MotionTokens.gentle) {
            appState.resetGeneralCleanup()
        }
    }

    private func prepareCleanup() {
        pendingItems = selectedItems
        pendingOrphans = appState.cleanupIncludesOrphans ? appState.selectedOrphans : []
        pendingUnusedApps = appState.cleanupIncludesUnusedApps ? appState.selectedUnusedApps : []
        showConfirmation = !pendingItems.isEmpty || !pendingOrphans.isEmpty || !pendingUnusedApps.isEmpty
    }

    private func performCleanup() {
        let items = pendingItems
        let orphans = pendingOrphans
        let unusedApps = pendingUnusedApps
        pendingItems = []
        pendingOrphans = []
        pendingUnusedApps = []
        Task {
            orphanFreedSpace = 0
            var messages: [String] = []
            if !orphans.isEmpty {
                // Sizes leave the cache once items are removed, so read them first.
                let sizes = orphans.reduce(into: [URL: Int64]()) { $0[$1] = appState.orphanSizes[$1] ?? 0 }
                if let message = await appState.removeOrphans(orphans) { messages.append(message) }
                orphanFreedSpace = orphans
                    .filter { !appState.orphanedFiles.contains($0) }
                    .reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            }
            if !unusedApps.isEmpty {
                let outcome = await appState.removeUnusedApps(unusedApps)
                orphanFreedSpace += outcome.freed
                if let message = outcome.error { messages.append(message) }
            }
            removalMessage = messages.isEmpty ? nil : messages.joined(separator: "\n\n")
            // When files are cleaned too, that cleanup counts as the task.
            UsageStats.shared.recordCleanup(.cleanup, bytes: orphanFreedSpace, countsAsTask: items.isEmpty)
            appState.claimGeneralCleanupScope()
            if !items.isEmpty {
                appState.cleanAll(itemIDs: Set(items.map(\.id)))
            } else if !orphans.isEmpty || !unusedApps.isEmpty {
                appState.totalFreedSpace = 0
                appState.scanState = .cleaned
            }
        }
    }

    private var confirmationTitle: String {
        let size = pendingItems.reduce(Int64(0)) { $0 + $1.size }
            + pendingOrphans.reduce(Int64(0)) { $0 + (appState.orphanSizes[$1] ?? 0) }
            + appState.unusedApps.filter { pendingUnusedApps.contains($0.id) }.reduce(Int64(0)) { $0 + $1.totalSize }
        return String(
            format: String(localized: "Clean %@?"),
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        )
    }

    private var confirmationMessage: String {
        var lines: [String] = []
        let everyday = pendingItems.filter { !$0.category.isRisky }
        let machines = pendingItems.filter { $0.category == .virtualMachines || ($0.category == .dockerData && !$0.isActionItem) }
        let dockerCommands = pendingItems.filter { $0.category == .dockerData && $0.isActionItem }
        if !everyday.isEmpty {
            lines.append(String(
                format: String(localized: "%lld selected items will be permanently deleted. Review the list before continuing."),
                Int64(everyday.count)
            ))
        }
        if !machines.isEmpty {
            lines.append(String(
                format: String(localized: "%lld virtual machines or Docker disks will be moved to the Trash. Quit the apps that use them first."),
                Int64(machines.count)
            ))
        }
        if !dockerCommands.isEmpty {
            lines.append(String(localized: "Docker will delete the selected images, volumes or build cache for good. Images can be downloaded again; data in volumes can't be recovered."))
        }
        if !pendingOrphans.isEmpty {
            lines.append(String(
                format: String(localized: "%lld app leftovers will be moved to the Trash."),
                Int64(pendingOrphans.count)
            ))
        }
        if !pendingUnusedApps.isEmpty {
            lines.append(String(
                format: String(localized: "%lld unused apps and their support files will be moved to the Trash."),
                Int64(pendingUnusedApps.count)
            ))
        }
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - General Cleanup hub

/// General Cleanup overview: one card with Files (and the riskier groups
/// under it) and Developer columns. The
/// user picks the areas, then a single scan covers all of them.
struct CleanupHubView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if appState.cleanupDetailOpen {
                GeneralCleanupRunView { appState.cleanupDetailOpen = false }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else {
                overview
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: appState.cleanupDetailOpen)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HubHeader(
                    title: "Advanced Cleanup",
                    subtitle: "Large files, app leftovers and developer data. You choose what to scan and what to remove.",
                    icon: "wand.and.stars",
                    tint: SectionPalette.cleanup.accent
                ) {
                    EmptyView()
                }
                GeneralCleanupCard { appState.cleanupDetailOpen = true }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The single General Cleanup card: area selection in two columns and one
/// action for all of them.
private struct GeneralCleanupCard: View {
    @EnvironmentObject var appState: AppState
    let open: () -> Void

    private let tint = SectionPalette.cleanup.accent

    private var isRunning: Bool { appState.isRunningGeneralCleanup }
    private var hasResults: Bool { appState.hasStoredCleanupResults && !isRunning }
    private var busyElsewhere: Bool { appState.isBusy(outside: .generalCleanup) }

    /// Everyday areas only: the riskier ones are never part of "Select all".
    private var everydayCategories: [CleaningCategory] { AppState.generalCleanupCategories.filter { !$0.isRisky } }
    private var totalAreas: Int { everydayCategories.count + 2 }
    private var enabledAreas: Int {
        appState.enabledCleanupCategories.filter { !$0.isRisky }.count
            + (appState.cleanupIncludesOrphans ? 1 : 0)
            + (appState.cleanupIncludesUnusedApps ? 1 : 0)
    }

    private var foundSize: Int64 {
        appState.enabledCleanupCategories.reduce(Int64(0)) { $0 + (appState.categoryResults[$1]?.totalSize ?? 0) }
            + (appState.cleanupIncludesOrphans ? appState.totalOrphanSize : 0)
            + (appState.cleanupIncludesUnusedApps ? appState.totalUnusedAppsSize : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
                .padding(.horizontal, 22)
                .padding(.vertical, 18)

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.75)

            // Two columns. The riskier groups sit under the first, shorter
            // one, in their own tinted box, so both columns end about level.
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(CleanupBundle.allCases.filter { !$0.isRisky }.enumerated()), id: \.element) { index, bundle in
                    VStack(alignment: .leading, spacing: 18) {
                        BundleColumn(bundle: bundle, isLocked: isRunning)
                        if index == 0 {
                            ForEach(CleanupBundle.allCases.filter(\.isRisky), id: \.self) { risky in
                                BundleColumn(bundle: risky, isLocked: isRunning)
                                    .padding(12)
                                    .background(risky.cardTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(risky.cardTint.opacity(0.3), lineWidth: 0.75))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(18)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.75)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                Text("Nothing is removed until you confirm.")
                Spacer()
                Button(enabledAreas == totalAreas ? "Deselect all" : "Select all") {
                    let enable = enabledAreas != totalAreas
                    for category in everydayCategories {
                        appState.setCleanupArea(category.rawValue, enabled: enable)
                    }
                    appState.setCleanupArea(AppState.orphanAreaID, enabled: enable)
                    appState.setCleanupArea(AppState.unusedAppsAreaID, enabled: enable)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(tint)
                .disabled(isRunning)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .background {
            ZStack {
                GlassPanelBackground(cornerRadius: 26)
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(RadialGradient(colors: [tint.opacity(0.2), .clear], center: .topLeading, startRadius: 10, endRadius: 520))
            }
        }
    }

    // MARK: Summary row

    private var summary: some View {
        HStack(alignment: .center, spacing: 18) {
            progressRing
            VStack(alignment: .leading, spacing: 5) {
                Text(headline)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                    .animation(nil, value: headline)
                Text(verbatim: statusLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(hasResults ? Tint.green : .white.opacity(0.6))
                    .numericTransition()
                if busyElsewhere && !isRunning {
                    Label("Another scan is running. Wait for it to finish or stop it first.", systemImage: "hourglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tint.yellow.opacity(0.9))
                }
            }
            Spacer(minLength: 12)
            actions
        }
    }

    /// Selected areas while idle, scan progress while running, a check when
    /// results are in.
    private var progressRing: some View {
        let fraction = isRunning ? appState.scanProgress
            : (hasResults ? 1 : Double(enabledAreas) / Double(max(totalAreas, 1)))
        let ringTint = hasResults ? Tint.green : tint
        return ZStack {
            Circle().fill(RadialGradient(colors: [ringTint.opacity(0.22), ringTint.opacity(0.04)], center: .center, startRadius: 2, endRadius: 40))
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.002, min(1, fraction))))
                .stroke(
                    AngularGradient(colors: [ringTint.opacity(0.45), ringTint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: ringTint.opacity(0.55), radius: 6)
            Group {
                if isRunning {
                    Text(verbatim: "\(Int((appState.scanProgress * 100).rounded()))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                } else if hasResults {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Tint.green)
                } else {
                    VStack(spacing: -2) {
                        Text(verbatim: "\(enabledAreas)")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text(verbatim: "/\(totalAreas)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .monospacedDigit()
            .foregroundStyle(.white)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
        .frame(width: 66, height: 66)
        .padding(4)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: fraction)
        .animation(.easeInOut(duration: 0.25), value: isRunning)
        .animation(.easeInOut(duration: 0.25), value: hasResults)
        .accessibilityHidden(true)
    }

    private var statusLine: String {
        if isRunning {
            return String(format: String(localized: "Scanning %lld%%"), Int64((appState.scanProgress * 100).rounded()))
        }
        if hasResults {
            return String(format: String(localized: "%@ found"), ByteCountFormatter.string(fromByteCount: foundSize, countStyle: .file))
        }
        return String(format: String(localized: "%lld of %lld areas selected"), Int64(enabledAreas), Int64(totalAreas))
    }

    private var headline: LocalizedStringKey {
        if isRunning { return "Scanning your Mac" }
        if hasResults { return "Ready to free up space" }
        return "Choose what to scan"
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if isRunning {
                Button(action: open) {
                    Label("View progress", systemImage: "arrow.right")
                }
                .buttonStyle(GlassProminentButtonStyle(large: true))
            } else if hasResults {
                Button {
                    appState.startGeneralCleanup()
                    open()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GlassButtonStyle())
                .controlSize(.large)
                .help("Scan again")
                .disabled(busyElsewhere || !appState.hasEnabledCleanupAreas)
                Button(action: open) {
                    Label(
                        String(format: String(localized: "Review %@"), ByteCountFormatter.string(fromByteCount: foundSize, countStyle: .file)),
                        systemImage: "list.bullet.rectangle"
                    )
                }
                .buttonStyle(GlassProminentButtonStyle(large: true))
            } else {
                Button {
                    appState.startGeneralCleanup()
                    open()
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 2)
                }
                .buttonStyle(GlassProminentButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(busyElsewhere || !appState.hasEnabledCleanupAreas)
            }
        }
    }
}

/// One column of the General Cleanup card: a group title with its own
/// select-all checkbox, then one row per area.
private struct BundleColumn: View {
    @EnvironmentObject var appState: AppState
    let bundle: CleanupBundle
    let isLocked: Bool

    private struct Area: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let icon: String
        let tint: Color
        let size: Int64?
        let scanning: Bool
    }

    private var areas: [Area] {
        var list = bundle.categories.map { category in
            Area(
                id: category.rawValue,
                title: category.displayTitle,
                icon: category.icon,
                tint: category.color,
                size: appState.categoryResults[category]?.totalSize,
                scanning: appState.isRunningGeneralCleanup && appState.currentScanCategory == category.rawValue
            )
        }
        if bundle.includesOrphans {
            list.append(Area(
                id: AppState.orphanAreaID,
                title: "Orphaned Files",
                icon: "folder.badge.questionmark",
                tint: CleanupBundle.orphanColor,
                size: appState.hasSearchedOrphans ? appState.totalOrphanSize : nil,
                scanning: appState.isSearchingOrphans
            ))
        }
        if bundle.includesUnusedApps {
            list.append(Area(
                id: AppState.unusedAppsAreaID,
                title: "Unused Apps",
                icon: "app.dashed",
                tint: CleanupBundle.unusedAppsColor,
                size: appState.hasSearchedUnusedApps ? appState.totalUnusedAppsSize : nil,
                scanning: appState.isSearchingUnusedApps
            ))
        }
        return list
    }

    private var allEnabled: Bool { areas.allSatisfy { appState.isCleanupAreaEnabled($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if bundle.isRisky {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(bundle.cardTint)
                                .help("Riskier: these can hold work you still need. Nothing here is preselected, and Select all leaves it out.")
                        }
                        Text(bundle.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text(bundle.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        // The riskier group's warning sits in its subtitle; let it finish.
                        .lineLimit(bundle.isRisky ? 4 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { allEnabled },
                    set: { enable in areas.forEach { appState.setCleanupArea($0.id, enabled: enable) } }
                ))
                .labelsHidden()
                .toggleStyle(AnimatedCheckboxStyle(tint: SectionPalette.cleanup.accent))
                .help("Include every area in this column")
                .disabled(isLocked)
            }

            VStack(spacing: 0) {
                ForEach(Array(areas.enumerated()), id: \.element.id) { index, area in
                    row(area)
                    if index < areas.count - 1 {
                        Divider().opacity(0.25).padding(.leading, 74)
                    }
                }
            }
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func row(_ area: Area) -> some View {
        let enabled = appState.isCleanupAreaEnabled(area.id)
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { appState.setCleanupArea(area.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(AnimatedCheckboxStyle(tint: SectionPalette.cleanup.accent))
            .disabled(isLocked)
            CategoryBadge(systemName: area.icon, tint: area.tint, size: 28)
                .opacity(enabled ? 1 : 0.45)
            Text(area.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? 0.92 : 0.45))
                .lineLimit(1)
            Spacer(minLength: 8)
            if area.scanning {
                ProgressView().controlSize(.small)
            } else if let size = area.size, enabled {
                Text(size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : String(localized: "Nothing found"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(size > 0 ? Color.white : Tint.green)
            } else {
                Text("—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isLocked else { return }
            appState.setCleanupArea(area.id, enabled: !enabled)
        }
    }
}
