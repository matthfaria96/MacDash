import Darwin
import SwiftUI

struct DashboardView: View {
    @ObservedObject private var activity = AppActivity.shared
    @EnvironmentObject var appState: AppState
    var onNavigate: (AppSection) -> Void = { _ in }

    @State private var showConfirmation = false
    @State private var pendingCleanItems: [CleanableItem] = []
    @State private var reviewingCategory: ReviewTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
        if reviewingCategory != nil, careState == .completed {
            // Full-window review: categories on the left, contents on the right.
            CleanupReviewScreen(
                reviewing: $reviewingCategory,
                categories: CleaningCategory.smartCare,
                accent: SectionPalette.smartCare.accent
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // In the review the floating button gives way to the same bar
                // Advanced Cleanup uses.
                CleanupActionBar(
                    selectedCount: appState.smartCareResults.flatMap(\.items).filter(appState.isItemSelected).count,
                    selectedSize: appState.smartCareSelectedSize,
                    deep: SectionPalette.smartCare.deep,
                    isDisabled: appState.scanState.isActive
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
                if careState == .idle {
                    stateContent
                        .overlay(alignment: .topTrailing) { pageHeader }
                } else if usesImmersiveLayout {
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
            Button("Clean selected items", role: .destructive) {
                appState.cleanAll(itemIDs: Set(pendingCleanItems.map(\.id)))
                pendingCleanItems = []
            }
            Button("Cancel", role: .cancel) {
                pendingCleanItems = []
            }
        } message: {
            Text(cleanConfirmationMessage)
        }
    }

    /// Smart Care only reflects its own scans; another screen's run reads as idle.
    private var careState: ScanState { appState.scanState(in: .smartCare) }

    private var usesImmersiveLayout: Bool {
        switch careState {
        case .scanning, .completed: return true
        default: return false
        }
    }

    private var floatingAction: AnyView? {
        switch careState {
        case .idle:
            guard !appState.isBusy(outside: .smartCare), !appState.isSearchingOrphans else { return nil }
            return AnyView(floatingScanButton)
        case .scanning:
            return AnyView(
                StopScanButton(progress: appState.scanProgress, animated: !reduceMotion) {
                    appState.cancelScan()
                }
            )
        case .completed where appState.smartCareSelectedSize > 0 && reviewingCategory == nil:
            return AnyView(
                PulsingScanButton(
                    title: "Clean",
                    subtitle: ByteCountFormatter.string(fromByteCount: appState.smartCareSelectedSize, countStyle: .file),
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

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 19) {
            scanHero
            MacHealthPanel(onNavigate: onNavigate)
        }
    }

    private var scanHero: some View {
        HStack(alignment: .center, spacing: 26) {
            // The picture takes whatever the text column leaves, about two thirds.
            heroArtwork
                .aspectRatio(1460.0 / 1078.0, contentMode: .fit)
                .frame(minWidth: 340, maxWidth: 440)
                .layoutPriority(1)
            scanIntroduction
                .frame(minWidth: 250, idealWidth: 340, maxWidth: 420, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
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

    /// Title, one sentence and the areas checked, set like a macOS settings
    /// pane: system type, monochrome symbols, hairline rows, no extra chrome.
    private var scanIntroduction: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Smart Care")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                    .accessibilityAddTraits(.isHeader)

                Text("Checks where junk builds up and looks for known threats, then lets you choose what goes.")
                    .font(.system(size: 14))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.7) : Color.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            checkedAreas

            Text("Runs on this Mac. Nothing is removed without your approval.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Short hints that fit on one line next to each area.
    private func heroHint(for category: CleaningCategory) -> LocalizedStringKey {
        switch category {
        case .systemJunk: return "Logs and temporary files"
        case .userCache: return "App and browser caches"
        case .trashBins: return "Files in your Trash"
        case .mailAttachments: return "Downloaded attachments"
        case .threats: return "Known adware only, not an antivirus"
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

    /// The places Smart Care checks, each with what the last scan found. The
    /// one-line explanations live in tooltips so the list reads at a glance.
    private var checkedAreas: some View {
        let areas = CleaningCategory.smartCare
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(areas.enumerated()), id: \.element) { index, category in
                HStack(spacing: 12) {
                    PremiumIcon(systemName: category.icon, tint: category.color, size: 24, style: .glass)
                    Text(category.displayTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let finding = lastFinding(for: category) {
                        Text(finding.text)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(finding.isClear ? .white.opacity(0.45) : .white.opacity(0.85))
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .help(Text(heroHint(for: category)))
                if index < areas.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).padding(.leading, 34)
                }
            }
            if let date = appState.lastScanDate {
                HStack(spacing: 4) {
                    Text("Last scan")
                    Text(date, style: .relative)
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 8)
            }
        }
    }

    private var floatingScanButton: some View {
        PulsingScanButton(
            title: "Scan",
            accent: SectionPalette.smartCare.accent,
            deep: SectionPalette.smartCare.primary,
            animated: !reduceMotion
        ) {
            appState.startSmartScan()
        }
        .accessibilityLabel("Scan this Mac")
    }

    private var scanningContent: some View {
        SmartCareScanningView()
    }

    private var resultsContent: some View {
        SmartCareResultsView(
            reviewing: $reviewingCategory,
            onBackToStart: {
                withAnimation(reduceMotion ? nil : MotionTokens.gentle) {
                    appState.resetSmartCareToStart()
                }
            },
            onScanAgain: { appState.startSmartScan() }
        )
    }

    private var cleaningContent: some View {
        CardSurface(padding: 34, elevation: .standard, tint: Tint.accent) {
            VStack(spacing: 22) {
                ScanningGauge(progress: appState.cleanProgress, tint: Tint.accent, label: "CLEANING")
                    .frame(width: 170, height: 170)
                VStack(spacing: 6) {
                    Text("Cleaning selected items")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Keep MacFresh open until this pass finishes.")
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
                    if appState.totalFreedSpace > 0 {
                        CountUpBytes(bytes: appState.totalFreedSpace)
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
                    Button("Done") {
                        appState.resetSmartCareToStart()
                    }
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
        return String(
            format: String(localized: "Permanently delete %@?"),
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        )
    }

    private var cleanConfirmationMessage: String {
        String(
            format: String(localized: "%lld selected items will be permanently deleted. Review the list before continuing."),
            Int64(pendingCleanItems.count)
        )
    }

    private func prepareCleanupConfirmation() {
        pendingCleanItems = appState.smartCareResults
            .flatMap(\.items)
            .filter(appState.isItemSelected)
        showConfirmation = !pendingCleanItems.isEmpty
    }

    private var cleanSelectedLabel: String {
        String(
            format: String(localized: "Clean %@"),
            ByteCountFormatter.string(fromByteCount: appState.smartCareSelectedSize, countStyle: .file)
        )
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
