import Darwin
import SwiftUI

struct SmartCareView: View {
    @ObservedObject private var activity = AppActivity.shared
    @EnvironmentObject var appState: AppState
    var onNavigate: (AppSection) -> Void = { _ in }

    @State private var showConfirmation = false
    @State private var pendingCleanItems: [CleanableItem] = []
    @State private var pendingOrphans: Set<URL> = []
    @State private var pendingUnusedApps: Set<String> = []
    /// Space freed by leftovers and apps, which go to the Trash outside `cleanAll`.
    @State private var trashedSpace: Int64 = 0
    @State private var removalMessage: String?
    @State private var showsAreas = false
    @Namespace private var depthSelection
    @State private var reviewingCategory: ReviewTarget? = DemoMode.initialReview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
        if reviewingCategory != nil, careState == .completed {
            // Full-window review: categories on the left, contents on the right.
            CleanupReviewScreen(
                reviewing: $reviewingCategory,
                categories: appState.shownCategories,
                includesOrphans: appState.resultsIncludeOrphans,
                includesUnusedApps: appState.resultsIncludeUnusedApps,
                accent: SectionPalette.smartCare.accent
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // In the review the floating button gives way to a bar.
                CleanupActionBar(
                    selectedCount: appState.selectedScanCount,
                    selectedSize: appState.selectedScanSize,
                    deep: SectionPalette.smartCare.deep,
                    isDisabled: isRemoving
                ) {
                    prepareCleanupConfirmation()
                }
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
        } else {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Color.clear.frame(height: 0).id("dashboardTop")
                if careState == .idle || usesImmersiveLayout {
                    stateContent
                } else {
                    pageHeader
                    stateContent
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .padding(.bottom, 120)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        #if DEBUG
        .onChange(of: careState) { state in
            // Debug builds: `-DebugReview userCache` opens that review after a scan.
            if state == .completed, let raw = UserDefaults.standard.string(forKey: "DebugReview"),
               let category = CleaningCategory.allCases.first(where: { "\($0)" == raw }) {
                reviewingCategory = .category(category)
            }
        }
        #endif
        .onChange(of: reviewingCategory) { _ in
            scroller.scrollTo("dashboardTop", anchor: .top)
        }
        }
        }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: reviewingCategory)
        .onChange(of: careState) { state in
            if state != .completed { reviewingCategory = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let floatingAction {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, SectionPalette.smartCare.deep.opacity(0.55), SectionPalette.smartCare.deep.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                    .allowsHitTesting(false)
                    floatingAction
                        .padding(.bottom, 4)
                }
                .transition(.scale(scale: 0.86).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            cleanConfirmationTitle,
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean selected items", role: .destructive) { performCleanup() }
            Button("Cancel", role: .cancel) {
                pendingCleanItems = []
                pendingOrphans = []
                pendingUnusedApps = []
            }
        } message: {
            Text(cleanConfirmationMessage)
        }
        .alert("Some files could not be removed", isPresented: Binding(
            get: { removalMessage != nil },
            set: { if !$0 { removalMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(removalMessage ?? "")
        }
        .sheet(isPresented: $showsAreas) {
            ScanAreasSheet()
        }
        #if DEBUG
        // Debug builds: `-DebugScanAreas YES` opens "Choose areas…".
        .onAppear { if UserDefaults.standard.bool(forKey: "DebugScanAreas") { showsAreas = true } }
        #endif
    }

    /// The scan reads as running until the leftover and unused-app searches
    /// of a Complete scan are done too.
    private var careState: ScanState {
        if appState.isSmartScanRunning, !appState.scanState.isActive {
            return .scanning(progress: appState.scanProgress, currentCategory: appState.currentScanCategory)
        }
        return appState.scanState
    }

    private var isRemoving: Bool {
        appState.scanState.isActive || appState.isRemovingOrphans || appState.isRemovingUnusedApps
    }

    private var usesImmersiveLayout: Bool {
        switch careState {
        case .scanning, .completed: return true
        default: return false
        }
    }

    private var floatingAction: AnyView? {
        switch careState {
        case .idle:
            return AnyView(floatingScanButton)
        case .scanning:
            return AnyView(
                StopScanButton(progress: appState.scanProgress, animated: !reduceMotion) {
                    appState.stopSmartScan()
                }
            )
        case .completed where appState.selectedScanSize > 0 && reviewingCategory == nil && !isRemoving:
            return AnyView(
                PulsingScanButton(
                    title: "Clean",
                    subtitle: ByteCountFormatter.string(fromByteCount: appState.selectedScanSize, countStyle: .file),
                    accent: SectionPalette.smartCare.accent,
                    deep: SectionPalette.smartCare.primary,
                    animated: !reduceMotion
                ) {
                    prepareCleanupConfirmation()
                }
                .accessibilityLabel(cleanSelectedLabel)
            )
        default:
            return nil
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            if careState != .idle {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Smart Care")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.45)
                        .accessibilityAddTraits(.isHeader)
                    Text(headerSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 7) {
                if careState != .idle {
                    let status = headerStatus
                    StatusChip(label: status.label, systemImage: status.icon, tint: status.tint)
                }
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(lastCareText(relativeTo: timeline.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch careState {
        case .idle:
            idleContent
                .transition(stateTransition)
        case .scanning:
            scanningContent
                .transition(stateTransition)
        case .completed:
            resultsContent
                .transition(stateTransition)
        case .cleaning:
            cleaningContent
                .transition(stateTransition)
        case .cleaned:
            cleanedContent
                .transition(stateTransition)
        }
    }

    private var stateTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5))
    }

    private var headerSubtitle: String {
        switch careState {
        case .idle:
            return String(localized: "A clear view of reclaimable storage and the tools that manage it.")
        case .scanning:
            return String(localized: "Checking your Mac. Nothing is removed during a scan.")
        case .completed:
            return appState.scanWasCancelled
                ? String(localized: "The scan stopped. Available results are ready to review.")
                : String(localized: "Review the results and choose exactly what to remove.")
        case .cleaning:
            return String(localized: "Removing the items you selected.")
        case .cleaned:
            return String(localized: "Cleanup finished and disk information is refreshing.")
        }
    }

    private var headerStatus: (label: String, icon: String, tint: Color) {
        switch careState {
        case .idle:
            return appState.hasFullDiskAccess
                ? (String(localized: "Ready"), "checkmark.circle.fill", Tint.green)
                : (String(localized: "Limited access"), "lock.fill", Tint.orange)
        case .scanning:
            return (String(localized: "Scanning"), "magnifyingglass", Tint.accent)
        case .completed:
            if appState.scanWasCancelled {
                return (String(localized: "Stopped"), "stop.circle.fill", Tint.orange)
            }
            return (String(localized: "Review ready"), "checklist", Tint.accent)
        case .cleaning:
            return (String(localized: "Cleaning"), "trash.fill", Tint.orange)
        case .cleaned:
            return appState.lastCleanupHadFailures
                ? (String(localized: "Needs attention"), "exclamationmark.circle.fill", Tint.orange)
                : (String(localized: "Complete"), "checkmark.circle.fill", Tint.green)
        }
    }

    private func lastCareText(relativeTo now: Date) -> String {
        let date = appState.lastCleanedDate ?? appState.lastScanDate
        guard let date else {
            return String(localized: "No scan run yet")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: now)
        return String(format: String(localized: "Last activity: %@"), relative)
    }

    /// The welcome screen: the picture and the disk on the left, what Smart
    /// Care looks at on the right (each area with its icon and what it is),
    /// and underneath only the choice between the two modes.
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .center, spacing: 40) {
                VStack(spacing: 18) {
                    heroArtwork
                        .aspectRatio(1460.0 / 1078.0, contentMode: .fit)
                    HomeStorageLine(onNavigate: onNavigate)
                }
                .frame(minWidth: 290, idealWidth: 380, maxWidth: 460)
                scanIntroduction
                    .frame(minWidth: 340, maxWidth: 480, alignment: .leading)
                    .layoutPriority(1)
            }
            modePicker
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    /// The monitor sits still while a soft glow breathes and two faint rings
    /// swell outward behind it, all on Core Animation.
    private var heroArtwork: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            let animate = !reduceMotion
            ZStack {
                RippleRings(color: SectionPalette.smartCare.accent.opacity(0.22), diameter: size * 0.72, count: 2,
                            period: 6, growth: 0.42, lineWidth: 1.2, animate: animate)
                    .frame(width: size * 1.1, height: size * 1.1)
                LayerMotion(kind: .breathe, period: 4.8, amount: 0.2, animate: animate) {
                    heroGlow(size: size)
                }
                .frame(width: size * 1.1, height: size * 1.1)
                SmartCareMonitorArtwork()
                    .frame(width: size, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func heroGlow(size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [SectionPalette.smartCare.accent.opacity(0.42), Tint.purple.opacity(0.18), .clear],
                    center: .center,
                    startRadius: 12,
                    endRadius: size * 0.55
                )
            )
            .frame(width: size * 1.1, height: size * 1.1)
            .drawingGroup()
    }

    /// Title, one sentence, then what the chosen mode looks at: one row per
    /// area with its icon, what it is and what the last scan found there.
    private var scanIntroduction: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Smart Care")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Text("Checks where junk builds up, then lets you choose what goes.")
                    .font(.system(size: 14))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.7) : Color.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Label(lastCareText(relativeTo: timeline.date), systemImage: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 2)
            }

            Group {
                if appState.scanDepth == .essential {
                    essentialExplanations
                } else {
                    completeExplanations
                }
            }
            .transition(.opacity.combined(with: .offset(y: 6)))
            .id(appState.scanDepth)

            Label("Runs on this Mac. Nothing is removed without your approval.", systemImage: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: appState.scanDepth)
    }

    /// Short hints that fit on one line next to each area.
    private func heroHint(for category: CleaningCategory) -> LocalizedStringKey {
        switch category {
        case .systemJunk: return "Logs and temporary files"
        case .userCache: return "App and browser caches"
        case .trashBins: return "Files in your Trash"
        case .mailAttachments: return "Downloaded attachments"
        default: return LocalizedStringKey(category.description)
        }
    }

    /// What the last scan found in one area: a count for Threat Check, a size
    /// for everything else.
    private func lastFinding(for category: CleaningCategory) -> (text: String, isClear: Bool)? {
        guard let result = appState.categoryResults[category], appState.lastScanDate != nil else { return nil }
        if category.reportsCount {
            return result.itemCount > 0
                ? (String(format: String(localized: "%lld found"), Int64(result.itemCount)), false)
                : (String(localized: "All clear"), true)
        }
        return result.totalSize > 0
            ? (ByteCountFormatter.string(fromByteCount: result.totalSize, countStyle: .file), false)
            : (String(localized: "All clear"), true)
    }

    private var essentialExplanations: some View {
        let areas = CleaningCategory.smartCare
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(areas.enumerated()), id: \.element) { index, category in
                let finding = lastFinding(for: category)
                ExplanationRow(icon: category.icon, tint: category.color, title: Text(category.displayTitle),
                               detail: Text(heroHint(for: category)), value: finding?.text, dimmedValue: finding?.isClear ?? true)
                if index < areas.count - 1 { rowDivider }
            }
        }
    }

    /// Complete: everything in Essential, then the area groups, each with how
    /// many of its areas are on. Any of them opens "Choose areas…".
    private var completeExplanations: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Everything in Essential, plus:")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 8)
                Button { showsAreas = true } label: {
                    Label("Choose areas…", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11.5, weight: .semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(SectionPalette.smartCare.accent.mixedWithWhite(0.25))
            }
            .padding(.bottom, 4)
            ForEach(Array(CleanupBundle.allCases.enumerated()), id: \.element) { index, bundle in
                let ids = bundle.categories.map(\.rawValue)
                    + (bundle.includesOrphans ? [AppState.orphanAreaID] : [])
                    + (bundle.includesUnusedApps ? [AppState.unusedAppsAreaID] : [])
                let enabled = ids.filter(appState.isCleanupAreaEnabled).count
                Button { showsAreas = true } label: {
                    ExplanationRow(icon: bundle.icon, tint: bundle.cardTint, title: Text(bundle.title),
                                   detail: Text(bundle.subtitle), value: "\(enabled)/\(ids.count)",
                                   dimmedValue: enabled == 0, isOn: enabled > 0)
                }
                .buttonStyle(.plain)
                .help(Text(bundle.subtitle))
                .accessibilityValue(Text(String(format: String(localized: "%lld of %lld areas selected"), Int64(enabled), Int64(ids.count))))
                if index < CleanupBundle.allCases.count - 1 { rowDivider }
            }
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Color.white.opacity(0.09)).frame(height: 0.5).padding(.leading, 50)
    }

    /// Only the two modes, side by side under everything else.
    private var modePicker: some View {
        HStack(spacing: 14) {
            ForEach(ScanDepth.allCases) { depth in
                ScanModeCard(depth: depth, selection: $appState.scanDepth, namespace: depthSelection)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(appState.isSmartScanRunning)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scan depth")
    }

    private var floatingScanButton: some View {
        PulsingScanButton(
            title: "Scan",
            subtitle: appState.scanDepth.name,
            accent: SectionPalette.smartCare.accent,
            deep: SectionPalette.smartCare.primary,
            animated: !reduceMotion
        ) {
            appState.startSmartScan()
        }
        .accessibilityLabel("Scan this Mac")
    }

    private var scanningContent: some View {
        SmartCareScanningView(
            categories: appState.shownCategories,
            includesOrphans: appState.resultsIncludeOrphans,
            includesUnusedApps: appState.resultsIncludeUnusedApps,
            depth: appState.resultsDepth
        )
    }

    private var resultsContent: some View {
        SmartCareResultsView(
            reviewing: $reviewingCategory,
            categories: appState.shownCategories,
            includesOrphans: appState.resultsIncludeOrphans,
            includesUnusedApps: appState.resultsIncludeUnusedApps,
            depth: appState.resultsDepth,
            onBackToStart: { startOver() },
            onScanAgain: { appState.startSmartScan(depth: appState.resultsDepth) },
            onGoComplete: {
                appState.scanDepth = .complete
                appState.startSmartScan(depth: .complete)
            }
        )
        .disabled(isRemoving)
    }

    private var cleaningContent: some View {
        CardSurface(padding: 34, elevation: .standard, tint: Tint.accent) {
            VStack(spacing: 22) {
                ScanningGauge(progress: appState.cleanProgress, tint: Tint.accent, label: "CLEANING")
                    .frame(width: 170, height: 170)
                VStack(spacing: 6) {
                    Text("Cleaning selected items")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Keep MacDash open until this pass finishes.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: appState.cleanProgress)
                    .tint(Tint.accent)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, minHeight: 380)
        }
    }

    private var cleanedContent: some View {
        CardSurface(
            padding: 38,
            elevation: .standard,
            tint: appState.lastCleanupHadFailures ? Tint.orange : Tint.green
        ) {
            HStack(spacing: 34) {
                SuccessMedal(tint: appState.lastCleanupHadFailures ? Tint.orange : Tint.green, size: 126)
                VStack(alignment: .leading, spacing: 9) {
                    Text(appState.lastCleanupHadFailures ? "Some items need attention" : "Cleanup complete")
                        .font(.system(size: 25, weight: .semibold))
                    if appState.totalFreedSpace + trashedSpace > 0 {
                        CountUpBytes(bytes: appState.totalFreedSpace + trashedSpace)
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                        Text("reclaimed")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    if let cleanError = appState.cleanError {
                        Text(cleanError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Button("Done") { startOver() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Tint.accent)
                    .padding(.top, 5)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .leading)
        }
    }

    private var cleanConfirmationTitle: String {
        let size = pendingCleanItems.reduce(Int64(0)) { $0 + $1.size }
            + pendingOrphans.reduce(Int64(0)) { $0 + (appState.orphanSizes[$1] ?? 0) }
            + appState.unusedApps.filter { pendingUnusedApps.contains($0.id) }.reduce(Int64(0)) { $0 + $1.totalSize }
        return String(
            format: String(localized: "Clean %@?"),
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        )
    }

    /// One line per kind of removal: deleted for good, to the Trash, or by Docker.
    private var cleanConfirmationMessage: String {
        var lines: [String] = []
        let everyday = pendingCleanItems.filter { !$0.category.isRisky }
        let machines = pendingCleanItems.filter { $0.category == .virtualMachines || ($0.category == .dockerData && !$0.isActionItem) }
        let dockerCommands = pendingCleanItems.filter { $0.category == .dockerData && $0.isActionItem }
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

    private func prepareCleanupConfirmation() {
        pendingCleanItems = appState.selectedScanItems
        pendingOrphans = appState.resultsIncludeOrphans ? appState.selectedOrphans : []
        pendingUnusedApps = appState.resultsIncludeUnusedApps ? appState.selectedUnusedApps : []
        showConfirmation = !pendingCleanItems.isEmpty || !pendingOrphans.isEmpty || !pendingUnusedApps.isEmpty
    }

    /// Leftovers and apps go to the Trash first, then the files are cleaned.
    private func performCleanup() {
        let items = pendingCleanItems
        let orphans = pendingOrphans
        let unusedApps = pendingUnusedApps
        pendingCleanItems = []
        pendingOrphans = []
        pendingUnusedApps = []
        guard !orphans.isEmpty || !unusedApps.isEmpty else {
            trashedSpace = 0
            appState.cleanAll(itemIDs: Set(items.map(\.id)))
            return
        }
        Task {
            trashedSpace = 0
            var messages: [String] = []
            if !orphans.isEmpty {
                // Sizes leave the cache once items are removed, so read them first.
                let sizes = orphans.reduce(into: [URL: Int64]()) { $0[$1] = appState.orphanSizes[$1] ?? 0 }
                if let message = await appState.removeOrphans(orphans) { messages.append(message) }
                trashedSpace = orphans
                    .filter { !appState.orphanedFiles.contains($0) }
                    .reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            }
            if !unusedApps.isEmpty {
                let outcome = await appState.removeUnusedApps(unusedApps)
                trashedSpace += outcome.freed
                if let message = outcome.error { messages.append(message) }
            }
            removalMessage = messages.isEmpty ? nil : messages.joined(separator: "\n\n")
            // When files are cleaned too, that cleanup counts as the task.
            UsageStats.shared.recordCleanup(.cleanup, bytes: trashedSpace, countsAsTask: items.isEmpty)
            if !items.isEmpty {
                appState.cleanAll(itemIDs: Set(items.map(\.id)))
            } else {
                appState.totalFreedSpace = 0
                appState.scanState = .cleaned
            }
        }
    }

    private func startOver() {
        trashedSpace = 0
        withAnimation(reduceMotion ? nil : MotionTokens.gentle) {
            appState.resetSmartCareToStart()
        }
    }

    private var cleanSelectedLabel: String {
        String(
            format: String(localized: "Clean %@"),
            ByteCountFormatter.string(fromByteCount: appState.selectedScanSize, countStyle: .file)
        )
    }
}

/// The startup disk in one line under the hero: how full it is, with the way
/// to Space Lens and to this Mac's details in Processes. Cleaning is about
/// space, so this is all of the Mac the home screen shows.
private struct HomeStorageLine: View {
    @EnvironmentObject var appState: AppState
    var onNavigate: (AppSection) -> Void

    private let accent = SectionPalette.smartCare.accent

    private var disk: DiskInfo { appState.diskInfo }
    private var purgeable: Int64 { min(max(0, disk.purgeableSpace), max(0, disk.usedSpace)) }
    private func share(_ value: Int64) -> CGFloat {
        disk.totalSpace > 0 ? CGFloat(Double(max(0, value)) / Double(disk.totalSpace)) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 30, height: 30)
                    .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: volumeName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(String(format: String(localized: "%@ free of %@"), disk.formattedFree, disk.formattedTotal))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { geometry in
                let used = share(disk.usedSpace - purgeable)
                let pale = share(purgeable)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(LinearGradient(colors: [accent.opacity(0.75), accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * used)
                        Rectangle()
                            .fill(accent.mixedWithWhite(0.55).opacity(0.8))
                            .frame(width: geometry.size.width * pale)
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.4), value: disk.freeSpace)
            HStack(spacing: 16) {
                link("Space Lens", symbol: "chart.pie.fill", help: "See what is taking up space on this disk") { onNavigate(.spaceLens) }
                link("Your Mac", symbol: "waveform.path.ecg.rectangle.fill", help: "This Mac's details, health and what is running, in Processes") { onNavigate(.processes) }
                Spacer(minLength: 0)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
        .accessibilityElement(children: .contain)
        .onAppear { appState.loadDiskInfo() }
    }

    private func link(_ title: LocalizedStringKey, symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }

    private var volumeName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? String(localized: "Macintosh HD")
    }
}

/// One area Smart Care looks at: a glass icon, its name, a line on what it
/// is, and on the right what the last scan found there.
private struct ExplanationRow: View {
    let icon: String
    let tint: Color
    let title: Text
    let detail: Text
    let value: String?
    let dimmedValue: Bool
    var isOn = true

    var body: some View {
        HStack(spacing: 14) {
            PremiumIcon(systemName: icon, tint: tint, size: 34, style: .glass)
                .opacity(isOn ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.5))
                    .lineLimit(1)
                detail
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(isOn ? 0.58 : 0.38))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let value {
                Text(verbatim: value)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(dimmedValue ? 0.42 : 0.85))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One mode as a wide card: glass icon, name and promise, and a check when
/// chosen. The lit background glides from one card to the other.
private struct ScanModeCard: View {
    let depth: ScanDepth
    @Binding var selection: ScanDepth
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private let accent = SectionPalette.smartCare.accent
    private var isSelected: Bool { selection == depth }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) { selection = depth }
        } label: {
            HStack(spacing: 14) {
                PremiumIcon(systemName: depth.icon, tint: isSelected ? accent : Color.white.opacity(0.6), size: 42, style: .glass)
                VStack(alignment: .leading, spacing: 3) {
                    Text(depth.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(isSelected ? 1 : 0.78))
                    Text(depth.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(isSelected ? 0.72 : 0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle().strokeBorder(Color.white.opacity(isSelected ? 0 : 0.28), lineWidth: 1.3)
                    if isSelected {
                        Circle().fill(LinearGradient(colors: [accent.mixedWithWhite(0.2), accent], startPoint: .top, endPoint: .bottom))
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(Color.black.opacity(hovering && !isSelected ? 0.12 : 0.2))
                    if isSelected {
                        ZStack {
                            shape.fill(LinearGradient(colors: [accent.opacity(0.3), accent.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            shape.fill(RadialGradient(colors: [Color.white.opacity(0.1), .clear], center: .topLeading, startRadius: 0, endRadius: 220))
                            shape.strokeBorder(LinearGradient(colors: [accent.mixedWithWhite(0.3).opacity(0.9), accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.1)
                        }
                        .matchedGeometryEffect(id: "mode.selection", in: namespace)
                    } else {
                        shape.strokeBorder(Color.white.opacity(hovering ? 0.18 : 0.08), lineWidth: 0.8)
                    }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SmartCareMonitorArtwork: View {
    var body: some View {
        Image("SmartCareCore")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .shadow(color: Tint.pink.opacity(0.22), radius: 18, y: 8)
            // Rasterize once on the GPU so the float animation only moves a
            // layer; the padding keeps the soft shadow from being clipped.
            .padding(40)
            .drawingGroup()
            .padding(-40)
            .accessibilityHidden(true)
    }
}

struct PulsingScanButton: View {
    @ObservedObject private var activity = AppActivity.shared
    let title: LocalizedStringKey
    var subtitle: String? = nil
    let accent: Color
    let deep: Color
    let animated: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    private let diameter: CGFloat = 100
    private let period: Double = 2.4
    private let waveCount = 3

    var body: some View {
        Button(action: action) {
            // The waves, glow, breathing and rim run on Core Animation, so the
            // button keeps pulsing without redrawing the screen every frame.
            ZStack {
                RippleRings(color: accent.opacity(0.75), diameter: diameter, count: waveCount, period: period,
                            growth: 0.75, fillOpacity: 0.12, lineWidth: 2, animate: animated)
                    .frame(width: diameter * 1.8, height: diameter * 1.8)

                LayerMotion(kind: .breathe, period: 1.6, amount: 0.45, animate: animated) {
                    Circle()
                        .fill(accent.opacity(0.5))
                        .frame(width: diameter, height: diameter)
                        .blur(radius: 26)
                        .frame(width: diameter * 1.8, height: diameter * 1.8)
                }
                .frame(width: diameter * 1.8, height: diameter * 1.8)

                ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.55, blue: 0.93), accent, deep],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay {
                                Circle()
                                    .fill(
                                        RadialGradient(
                                            colors: [.white.opacity(0.42), .clear],
                                            center: UnitPoint(x: 0.32, y: 0.22),
                                            startRadius: 0,
                                            endRadius: diameter * 0.55
                                        )
                                    )
                            }
                            .frame(width: diameter, height: diameter)
                            .shadow(color: accent.opacity(0.7), radius: 18, y: 4)

                        SpinningRim(
                            colors: [.white.opacity(0.95), accent.opacity(0.2), .white.opacity(0.6), accent.opacity(0.2), .white.opacity(0.95)],
                            diameter: diameter,
                            lineWidth: 2,
                            period: 4,
                            animate: animated
                        )
                        .frame(width: diameter, height: diameter)

                        VStack(spacing: 1) {
                            Text(title)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            if let subtitle {
                                Text(subtitle)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .opacity(0.9)
                            }
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
                .frame(width: diameter * 1.4, height: diameter * 1.4)
            }
            .scaleEffect((hovering ? 1.06 : 1) * (pressed ? 0.94 : 1))
            .frame(width: diameter * 1.8, height: diameter * 1.8)
            .contentShape(Circle().inset(by: diameter * 0.4))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { hovering = isHovering }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { withAnimation(.easeOut(duration: 0.1)) { pressed = true } } }
                .onEnded { _ in withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { pressed = false } }
        )
    }
}
