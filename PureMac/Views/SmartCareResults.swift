import AppKit
import SwiftUI

// MARK: - Review targets

/// Something a results screen can open for item-by-item review.
enum ReviewTarget: Hashable {
    case category(CleaningCategory)
    case orphans
    case unusedApps
}

/// Display data for a result card or review header, shared by categories and
/// the orphaned-files group.
private struct ReviewTargetInfo {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let icon: String
    let tint: Color
    let totalSize: Int64
    let itemCount: Int
    let selectedCount: Int
    let selectedSize: Int64
    let footnote: LocalizedStringKey?
    /// Areas sharing a group are drawn as one slice in the chart.
    var group: String? = nil
}

@MainActor
private extension AppState {
    func info(for target: ReviewTarget) -> ReviewTargetInfo {
        switch target {
        case .category(let category):
            let result = categoryResults[category]
            return ReviewTargetInfo(
                title: category.displayTitle,
                detail: LocalizedStringKey(category.description),
                icon: category.icon,
                tint: category.color,
                totalSize: result?.totalSize ?? 0,
                itemCount: result?.itemCount ?? 0,
                selectedCount: selectedCountInCategory(category),
                selectedSize: selectedSizeInCategory(category),
                footnote: category.isRisky ? "Riskier: nothing is preselected" : nil,
                group: CleanupBundle.devAI.categories.contains(category) ? "developer" : nil
            )
        case .orphans:
            return ReviewTargetInfo(
                title: "Orphaned Files",
                detail: "Scan for leftover files from apps you have uninstalled.",
                icon: "folder.badge.questionmark",
                tint: CleanupBundle.orphanColor,
                totalSize: totalOrphanSize,
                itemCount: orphanedFiles.count,
                selectedCount: selectedOrphans.count,
                selectedSize: selectedOrphanSize,
                footnote: "Moved to the Trash, not deleted"
            )
        case .unusedApps:
            return ReviewTargetInfo(
                title: "Unused Apps",
                detail: "Not opened in \(UnusedAppsFinder.configuredMonths) months or more",
                icon: "app.dashed",
                tint: CleanupBundle.unusedAppsColor,
                totalSize: totalUnusedAppsSize,
                itemCount: unusedApps.count,
                selectedCount: selectedUnusedApps.count,
                selectedSize: selectedUnusedAppsSize,
                footnote: "Moved to the Trash with their support files"
            )
        }
    }

    func selectionBinding(for target: ReviewTarget) -> Binding<Bool> {
        switch target {
        case .category(let category):
            return categoryBinding(for: category)
        case .orphans:
            return Binding(
                get: { !self.selectedOrphans.isEmpty },
                set: { self.selectedOrphans = $0 ? Set(self.orphanedFiles) : [] }
            )
        case .unusedApps:
            return Binding(
                get: { !self.selectedUnusedApps.isEmpty },
                set: { self.selectedUnusedApps = $0 ? Set(self.unusedApps.map(\.id)) : [] }
            )
        }
    }

    func isFullySelected(_ target: ReviewTarget) -> Bool {
        let info = info(for: target)
        return info.itemCount > 0 && info.selectedCount == info.itemCount
    }

    func setAllSelected(_ selected: Bool, for target: ReviewTarget) {
        switch target {
        case .category(let category):
            if selected { selectAllInCategory(category) } else { deselectAllInCategory(category) }
        case .orphans:
            selectedOrphans = selected ? Set(orphanedFiles) : []
        case .unusedApps:
            selectedUnusedApps = selected ? Set(unusedApps.map(\.id)) : []
        }
    }
}

// MARK: - Scanning

struct SmartCareScanningView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var categories: [CleaningCategory] = CleaningCategory.smartCare
    var includesOrphans = false
    var includesUnusedApps = false
    var title: LocalizedStringKey = "Scanning your Mac"
    var accent: Color = SectionPalette.smartCare.accent
    /// SF Symbol shown in the orb; nil shows the Smart Care artwork.
    var orbSymbol: String? = nil

    private var foundSoFar: Int64 {
        let categoriesTotal = categories.reduce(Int64(0)) { $0 + (appState.categoryResults[$1]?.totalSize ?? 0) }
        return categoriesTotal + (includesOrphans ? appState.totalOrphanSize : 0)
            + (includesUnusedApps ? appState.totalUnusedAppsSize : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 30) {
                ScanOrb(progress: appState.scanProgress, animated: !reduceMotion, accent: accent, symbol: orbSymbol)
                    .frame(width: 250, height: 250)

                VStack(alignment: .leading, spacing: 14) {
                    Text(title)
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)

                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(currentAreaTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(accent)
                    }

                    ScanPathLine(ticker: appState.scanTicker)

                    GlowProgressBar(progress: appState.scanProgress, tint: accent)
                        .frame(maxWidth: 440)

                    HStack(spacing: 10) {
                        ResultStatPill(value: "\(Int((appState.scanProgress * 100).rounded()))%", label: "complete", icon: "gauge.with.dots.needle.67percent", tint: accent)
                        ResultStatPill(value: ByteCountFormatter.string(fromByteCount: foundSoFar, countStyle: .file), label: "found so far", icon: "sparkle.magnifyingglass", tint: Tint.green)
                    }

                    Label("Nothing is removed during a scan. Stop at any time and keep what was found.", systemImage: "lock.shield.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 520, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 12) {
                Text("Areas being checked")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    ForEach(categories) { category in
                        ScanAreaTile(title: category.displayTitle, icon: category.icon, tint: category.color, accent: accent, status: status(for: category))
                    }
                    if includesOrphans {
                        ScanAreaTile(title: "Orphaned Files", icon: "folder.badge.questionmark", tint: CleanupBundle.orphanColor, accent: accent, status: orphanStatus)
                    }
                    if includesUnusedApps {
                        ScanAreaTile(title: "Unused Apps", icon: "app.dashed", tint: CleanupBundle.unusedAppsColor, accent: accent, status: unusedAppsStatus)
                    }
                }
            }
        }
    }

    private var currentAreaTitle: LocalizedStringKey {
        if case .scanning = appState.scanState {
            return LocalizedStringKey(appState.currentScanCategory)
        }
        return appState.isSearchingOrphans ? "Orphaned Files" : "Unused Apps"
    }

    private func status(for category: CleaningCategory) -> ScanAreaTile.Status {
        if let result = appState.categoryResults[category] {
            return category.reportsCount ? .found(result.itemCount) : .done(result.totalSize)
        }
        if appState.currentScanCategory == category.rawValue {
            return .scanning
        }
        return .pending
    }

    private var orphanStatus: ScanAreaTile.Status {
        if appState.isSearchingOrphans { return .scanning }
        if appState.hasSearchedOrphans { return .done(appState.totalOrphanSize) }
        return .pending
    }

    private var unusedAppsStatus: ScanAreaTile.Status {
        if appState.isSearchingUnusedApps { return .scanning }
        if appState.hasSearchedUnusedApps { return .done(appState.totalUnusedAppsSize) }
        return .pending
    }
}

private struct ScanOrb: View {
    @ObservedObject private var activity = AppActivity.shared
    let progress: Double
    let animated: Bool
    var accent: Color = SectionPalette.smartCare.accent
    var symbol: String? = nil

    var body: some View {
        TimelineView(.ambient(paused: !animated || !activity.isActive)) { timeline in
            let t = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(0.4), accent.opacity(0.1), .clear], center: .center, startRadius: 10, endRadius: 140))
                    .scaleEffect(1 + 0.05 * sin(t * 2))

                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 10)
                    .padding(14)

                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(
                        AngularGradient(colors: [accent.opacity(0.6), accent, .white.opacity(0.85), accent.opacity(0.6)], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(14)
                    .shadow(color: accent.opacity(0.8), radius: 10)
                    .animation(.easeInOut(duration: 0.5), value: progress)

                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(t * 140))
                    .padding(32)

                Group {
                    if let symbol {
                        GlassOrbIcon(systemImage: symbol, tint: accent, size: 104)
                    } else {
                        Image("SmartCareCore")
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .scaledToFit()
                            .padding(26)
                            .shadow(color: accent.opacity(0.4), radius: 18, y: 8)
                            .padding(30)
                            .drawingGroup()
                            .padding(-30)
                    }
                }
                .offset(y: animated ? CGFloat(sin(t * 1.6) * 4) : 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scan progress")
        .accessibilityValue("\(Int(progress * 100))%")
    }
}

private struct ScanPathLine: View {
    @ObservedObject var ticker: ScanProgressTicker

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
            Text(ticker.path.isEmpty ? String(localized: "Preparing the next area…") : (ticker.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: 440, alignment: .leading)
    }
}

private struct ScanAreaTile: View {
    enum Status: Equatable {
        case pending, scanning, done(Int64), found(Int)
    }

    let title: LocalizedStringKey
    let icon: String
    let tint: Color
    let accent: Color
    let status: Status

    var body: some View {
        HStack(spacing: 11) {
            CategoryBadge(systemName: icon, tint: tint, size: 32)
                .opacity(status == .pending ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(status == .pending ? 0.55 : 1))
                    .lineLimit(1)
                detail
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(status == .scanning ? accent.opacity(0.16) : Color.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(status == .scanning ? accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: status == .scanning ? 1 : 0.6)
        }
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    @ViewBuilder
    private var detail: some View {
        switch status {
        case .pending:
            Text("Waiting").foregroundStyle(.white.opacity(0.4))
        case .scanning:
            Text("Checking…").foregroundStyle(accent)
        case .done(let size):
            if size > 0 {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).foregroundStyle(.white.opacity(0.7))
            } else {
                Text("Nothing found").foregroundStyle(.white.opacity(0.5))
            }
        case .found(let count):
            if count > 0 {
                Text(String(format: String(localized: "%lld found"), Int64(count))).foregroundStyle(tint)
            } else {
                Text("Nothing found").foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.white.opacity(0.3))
        case .scanning:
            ProgressView().controlSize(.small)
        case .done, .found(0):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
        case .found:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(tint)
        }
    }
}

struct StopScanButton: View {
    @ObservedObject private var activity = AppActivity.shared
    let progress: Double
    let animated: Bool
    var accent: Color = SectionPalette.smartCare.accent
    let action: () -> Void

    @State private var hovering = false

    private let diameter: CGFloat = 92

    var body: some View {
        Button(action: action) {
            TimelineView(.ambient(paused: !animated || !activity.isActive)) { timeline in
                let t = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
                let breath = animated ? (sin(t * .pi * 2 / 2.2) + 1) / 2 : 0.5
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.25))
                        .frame(width: diameter, height: diameter)
                        .blur(radius: 16 + breath * 8)

                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.white.opacity(hovering ? 0.2 : 0.1)))
                        .frame(width: diameter, height: diameter)

                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 4)
                        .frame(width: diameter - 4, height: diameter - 4)
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, progress)))
                        .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter - 4, height: diameter - 4)
                        .shadow(color: accent, radius: 6)
                        .animation(.easeInOut(duration: 0.4), value: progress)

                    VStack(spacing: 3) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                }
                .scaleEffect(hovering ? 1.06 : 1)
            }
            .frame(width: diameter * 1.5, height: diameter * 1.5)
            .contentShape(Circle().inset(by: diameter * 0.25))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Stop the scan and keep the results found so far (Esc)")
        .accessibilityLabel("Stop scan")
        .onHover { isHovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { hovering = isHovering }
        }
    }
}

// MARK: - Results

struct SmartCareResultsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var reviewing: ReviewTarget?
    var categories: [CleaningCategory] = CleaningCategory.smartCare
    var includesOrphans = false
    var includesUnusedApps = false
    var accent: Color = SectionPalette.smartCare.accent
    /// Smart Care shows its own Start over / Scan again bar; module screens
    /// use the page header and the toolbar instead.
    var showsNavigation = true
    var onBackToStart: () -> Void = {}
    var onScanAgain: () -> Void = {}

    private var results: [CategoryResult] {
        appState.allResults
            .filter { categories.contains($0.category) }
            .sorted { $0.totalSize > $1.totalSize }
    }

    private var targets: [ReviewTarget] {
        appState.reviewTargets(categories: categories, includesOrphans: includesOrphans, includesUnusedApps: includesUnusedApps)
    }

    /// Areas that were scanned and came back empty. They get an informational
    /// card instead of silently disappearing.
    private var emptyTargets: [ReviewTarget] {
        var list: [ReviewTarget] = CleaningCategory.scannable
            .filter { categories.contains($0) && appState.categoryResults[$0] != nil }
            .filter { (appState.categoryResults[$0]?.totalSize ?? 0) == 0 }
            .map { ReviewTarget.category($0) }
        if includesOrphans && appState.hasSearchedOrphans && appState.orphanedFiles.isEmpty { list.append(.orphans) }
        if includesUnusedApps && appState.hasSearchedUnusedApps && appState.unusedApps.isEmpty { list.append(.unusedApps) }
        return list
    }

    private var nothingFoundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing found")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("These areas were checked and have nothing to clean.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(emptyTargets, id: \.self) { target in
                    let info = appState.info(for: target)
                    HStack(spacing: 12) {
                        CategoryBadge(systemName: info.icon, tint: info.tint.opacity(0.55), size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                            Text("Nothing found")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Tint.green.opacity(0.8))
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.6))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Chart slices: every ungrouped area on its own, and all areas of a group
    /// (the developer ones) merged into a single slice with a detailed tooltip.
    private var chartSegments: [StorageDonut.Segment] {
        func bytes(_ size: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        var segments: [StorageDonut.Segment] = []
        var grouped: [(target: ReviewTarget, info: ReviewTargetInfo)] = []
        for target in targets {
            let info = appState.info(for: target)
            if info.group != nil {
                grouped.append((target, info))
            } else {
                segments.append(StorageDonut.Segment(
                    id: "\(target)",
                    value: Double(info.totalSize),
                    color: info.tint,
                    label: info.title,
                    display: bytes(info.totalSize)
                ))
            }
        }
        if !grouped.isEmpty {
            let total = grouped.reduce(Int64(0)) { $0 + $1.info.totalSize }
            segments.append(StorageDonut.Segment(
                id: "developer",
                value: Double(total),
                color: CleanupBundle.developerColor,
                label: "Developer",
                display: bytes(total),
                details: grouped
                    .sorted { $0.info.totalSize > $1.info.totalSize }
                    .map { StorageDonut.Segment.Detail(id: "\($0.target)", value: Double($0.info.totalSize), label: $0.info.title, display: bytes($0.info.totalSize)) }
            ))
        }
        return segments
    }

    private var totalFound: Int64 { targets.reduce(0) { $0 + appState.info(for: $1).totalSize } }
    private var totalSelected: Int64 { targets.reduce(0) { $0 + appState.info(for: $1).selectedSize } }
    private var totalItems: Int { targets.reduce(0) { $0 + appState.info(for: $1).itemCount } }

    /// The review itself is a full-window split view that the hosting screen
    /// shows in place of this summary (see `CleanupReviewScreen`).
    var body: some View {
        summary
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 24) {
            if showsNavigation {
                HStack(spacing: 10) {
                    NavCapsuleButton(title: "Start over", systemImage: "chevron.left", action: onBackToStart)
                        .help("Discard these results and return to Smart Care")
                    Spacer()
                    NavCapsuleButton(title: "Scan again", systemImage: "arrow.clockwise", action: onScanAgain)
                }
            }

            summaryHero

            if targets.isEmpty {
                emptyState
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cleanup plan")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Click a category to see and choose each item.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    let allSelected = targets.allSatisfy(appState.isFullySelected)
                    Button(allSelected ? "Deselect all" : "Select all") {
                        for target in targets {
                            appState.setAllSelected(!allSelected, for: target)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(accent)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(targets, id: \.self) { target in
                        ResultCategoryCard(target: target, accent: accent) {
                            open(target)
                        }
                    }
                }
            }

            if !emptyTargets.isEmpty {
                nothingFoundSection
            }
        }
    }

    private func open(_ target: ReviewTarget) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88)) {
            reviewing = target
        }
    }

    private var summaryHero: some View {
        HStack(alignment: .center, spacing: 30) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [accent.opacity(0.3), .clear], center: .center, startRadius: 10, endRadius: 120))
                    .frame(width: 240, height: 240)
                StorageDonut(
                    segments: chartSegments,
                    lineWidth: 16,
                    center: AnyView(
                        VStack(spacing: 2) {
                            CountUpBytes(bytes: totalFound)
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("found")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .textCase(.uppercase)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .allowsHitTesting(false)
                    )
                )
                .frame(width: 180, height: 180)
            }
            .frame(width: 220, height: 220)
            .zIndex(1)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: appState.scanWasCancelled ? "stop.circle.fill" : "checkmark.seal.fill")
                    Text(appState.scanWasCancelled ? "Scan stopped" : "Scan complete")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(appState.scanWasCancelled ? Tint.orange : Tint.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background((appState.scanWasCancelled ? Tint.orange : Tint.green).opacity(0.15), in: Capsule())

                Text(targets.isEmpty ? "Your Mac is already tidy" : "Ready to free up space")
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)

                Text(summaryText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    ResultStatPill(value: ByteCountFormatter.string(fromByteCount: totalSelected, countStyle: .file), label: "selected", icon: "checkmark.circle.fill", tint: accent)
                    ResultStatPill(value: "\(targets.count)", label: "categories", icon: "square.grid.2x2.fill", tint: Tint.cyan)
                    ResultStatPill(value: "\(totalItems)", label: "items", icon: "doc.on.doc.fill", tint: Tint.orange)
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private var summaryText: String {
        if targets.isEmpty {
            return appState.scanWasCancelled
                ? String(localized: "No reclaimable items were found before the scan stopped.")
                : String(localized: "No reclaimable items were found in the areas checked.")
        }
        let size = ByteCountFormatter.string(fromByteCount: totalFound, countStyle: .file)
        if appState.scanWasCancelled {
            return String(format: String(localized: "%@ found before the scan stopped. Results may be incomplete."), size)
        }
        return String(format: String(localized: "%@ found across %lld categories."), size, Int64(targets.count))
            + " " + String(localized: "Nothing is removed until you confirm.")
    }

    private var emptyState: some View {
        HStack(spacing: 18) {
            SuccessMedal(tint: Tint.green, size: 72)
            VStack(alignment: .leading, spacing: 5) {
                Text("Nothing to clean")
                    .font(.system(size: 18, weight: .semibold))
                Text("MacDash did not find removable items in the selected scan areas.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ResultCategoryCard: View {
    @EnvironmentObject var appState: AppState
    let target: ReviewTarget
    let accent: Color
    let open: () -> Void

    @State private var hovering = false

    private var info: ReviewTargetInfo { appState.info(for: target) }

    var body: some View {
        Button(action: open) { card }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                Toggle("", isOn: appState.selectionBinding(for: target))
                    .labelsHidden()
                    .toggleStyle(AnimatedCheckboxStyle(tint: accent))
                    .scaleEffect(1.25)
                    .padding(18)
                    .help("Include this category in the cleanup")
                    .accessibilityLabel(Text(info.title))
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .onHover { isHovering in
                withAnimation(.easeOut(duration: 0.18)) { hovering = isHovering }
            }
    }

    /// Threat Check counts what it found; every other area shows its size.
    private func headline(_ info: ReviewTargetInfo) -> String {
        if case .category(let category) = target, category.reportsCount {
            return String(format: String(localized: "%lld found"), Int64(info.itemCount))
        }
        return ByteCountFormatter.string(fromByteCount: info.totalSize, countStyle: .file)
    }

    private var card: some View {
        let info = info
        let tint = info.tint
        return VStack(alignment: .leading, spacing: 12) {
            CategoryBadge(systemName: info.icon, tint: tint, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(info.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(info.footnote ?? info.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Text(headline(info))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geometry in
                    let fraction = info.totalSize > 0 ? CGFloat(Double(info.selectedSize) / Double(info.totalSize)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(fraction > 0 ? 6 : 0, geometry.size.width * fraction))
                    }
                }
                .frame(height: 6)
                .animation(.easeInOut(duration: 0.3), value: info.selectedSize)

                HStack {
                    Text("\(info.selectedCount) of \(info.itemCount) selected")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    HStack(spacing: 3) {
                        Text("Review")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? .white : accent)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.1 : 0.06))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(hovering ? 0.22 : 0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(hovering ? tint.opacity(0.6) : Color.white.opacity(0.09), lineWidth: hovering ? 1 : 0.6)
        }
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.12), radius: hovering ? 16 : 8, y: hovering ? 8 : 3)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Cleanup bar

/// The bar under a cleanup review: how much is selected and the Clean button.
/// Smart Care and Advanced Cleanup share it so both reviews end the same way.
struct CleanupActionBar: View {
    let selectedCount: Int
    let selectedSize: Int64
    let deep: Color
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            Text("\(selectedCount) items selected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1, height: 18)
            Text(ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button(action: action) {
                Label("Clean", systemImage: "trash")
            }
            .buttonStyle(GlassProminentButtonStyle(large: true))
            .disabled(isDisabled || selectedSize == 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background {
            Rectangle().fill(.ultraThinMaterial).opacity(0.7)
            Rectangle().fill(deep.opacity(0.25))
        }
        .overlay(alignment: .top) {
            Rectangle().fill(GlassEdge.gradient).frame(height: 0.8)
        }
    }
}

// MARK: - Review (split view)

extension AppState {
    /// What a results screen can review: large files first, then orphaned
    /// files, then unused apps, then every other area by size.
    func reviewTargets(categories: [CleaningCategory], includesOrphans: Bool, includesUnusedApps: Bool) -> [ReviewTarget] {
        var list = allResults
            .filter { categories.contains($0.category) }
            .sorted { $0.totalSize > $1.totalSize }
            .map { ReviewTarget.category($0.category) }
        if includesOrphans && !orphanedFiles.isEmpty { list.append(.orphans) }
        if includesUnusedApps && !unusedApps.isEmpty { list.append(.unusedApps) }
        func rank(_ target: ReviewTarget) -> Int {
            switch target {
            case .category(.largeFiles): return 0
            case .orphans: return 1
            case .unusedApps: return 2
            default: return 3
            }
        }
        return list.enumerated()
            .sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }
            .map(\.element)
    }
}

/// Full-window review: every area on the left, the chosen area's contents on
/// the right, each side scrolling on its own.
struct CleanupReviewScreen: View {
    @EnvironmentObject var appState: AppState
    @Binding var reviewing: ReviewTarget?
    let categories: [CleaningCategory]
    var includesOrphans = false
    var includesUnusedApps = false
    let accent: Color
    /// Room kept free under the panels for a floating action (Smart Care's Clean button).
    var bottomClearance: CGFloat = 16

    var body: some View {
        let targets = appState.reviewTargets(categories: categories, includesOrphans: includesOrphans, includesUnusedApps: includesUnusedApps)
        if let target = reviewing, targets.contains(target) {
            CleanupReviewSplit(target: target, targets: targets, accent: accent, bottomClearance: bottomClearance, reviewing: $reviewing)
        } else {
            Color.clear.onAppear { reviewing = targets.first }
        }
    }
}

/// Selection state of an area, a group or an item.
private enum SelectionState {
    case off, mixed, on

    init(selected: Int, total: Int) {
        if selected == 0 { self = .off } else if selected >= total { self = .on } else { self = .mixed }
    }
}

/// A round macOS-style check: empty ring, filled with a check, or a dash when
/// only part is selected.
private struct SelectionCircle: View {
    let state: SelectionState
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if state == .off {
                    Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5)
                } else {
                    Circle().fill(tint)
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(MotionTokens.snappy, value: state)
        .accessibilityAddTraits(state == .on ? .isSelected : [])
    }
}

private struct CleanupReviewSplit: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let target: ReviewTarget
    let targets: [ReviewTarget]
    let accent: Color
    let bottomClearance: CGFloat
    @Binding var reviewing: ReviewTarget?

    @State private var filter = CleanupReviewFilter()
    /// Groups the user flipped from their default (open when few, closed when many).
    @State private var flippedGroups: Set<String> = []

    private var info: ReviewTargetInfo { appState.info(for: target) }

    private var category: CleaningCategory? {
        if case .category(let category) = target { return category }
        return nil
    }

    private var visibleItems: [CleanableItem] {
        guard let category else { return [] }
        return filter.apply(to: appState.categoryResults[category]?.items ?? [])
    }

    private var visibleOrphans: [URL] {
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = appState.orphanedFiles.sorted { (appState.orphanSizes[$0] ?? 0) > (appState.orphanSizes[$1] ?? 0) }
        guard !query.isEmpty else { return all }
        return all.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    private var visibleUnusedApps: [UnusedAppRecord] {
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.unusedApps }
        return appState.unusedApps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.appURL.path.localizedCaseInsensitiveContains(query) }
    }

    private var isEmpty: Bool {
        switch target {
        case .category: return visibleItems.isEmpty
        case .orphans: return visibleOrphans.isEmpty
        case .unusedApps: return visibleUnusedApps.isEmpty
        }
    }

    private var totalSelected: Int64 { targets.reduce(0) { $0 + appState.info(for: $1).selectedSize } }
    private var totalFound: Int64 { targets.reduce(0) { $0 + appState.info(for: $1).totalSize } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            HStack(alignment: .top, spacing: 14) {
                sidebar
                    .frame(width: 248)
                detail
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 16 + bottomClearance)
        .onChange(of: target) { _ in
            filter = CleanupReviewFilter()
            flippedGroups = []
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            NavCapsuleButton(title: "Cleanup plan", systemImage: "chevron.left") {
                withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88)) { reviewing = nil }
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to the cleanup plan (Esc)")
            Spacer()
            Text(String(format: String(localized: "%@ selected of %@"),
                        ByteCountFormatter.string(fromByteCount: totalSelected, countStyle: .file),
                        ByteCountFormatter.string(fromByteCount: totalFound, countStyle: .file)))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
            let allSelected = targets.allSatisfy(appState.isFullySelected)
            Button(allSelected ? "Deselect all" : "Select all") {
                for target in targets { appState.setAllSelected(!allSelected, for: target) }
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(targets, id: \.self) { other in
                    ReviewTargetRow(
                        target: other,
                        isCurrent: other == target,
                        accent: accent
                    ) {
                        // No animation: the panels keep their size and only the list changes.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { reviewing = other }
                    }
                }
            }
            .padding(8)
        }
        .background(GlassPanelBackground(cornerRadius: 20))
    }

    // MARK: Detail

    /// Just the list. The sidebar already names the area and its size, and the
    /// top bar holds the only Select all.
    private var detail: some View {
        ScrollView {
            content
                .padding(14)
        }
        .id(target)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassPanelBackground(cornerRadius: 20))
    }

    @ViewBuilder
    private var content: some View {
        if isEmpty {
            EmptyStateView("No matching files", systemImage: "line.3.horizontal.decrease.circle", description: "Try another name, size, or date range.", action: { filter = CleanupReviewFilter() }, actionLabel: "Clear filters", tint: info.tint)
                .frame(minHeight: 260)
        } else {
            switch target {
            case .category:
                let rows = visibleItems
                if let groups = CleanupGrouper.groups(for: rows) {
                    LazyVStack(spacing: 8) {
                        ForEach(groups) { group in
                            ReviewGroupCard(group: group, tint: accent, isExpanded: isExpanded(group, total: groups.count)) {
                                withAnimation(reduceMotion ? nil : MotionTokens.snappy) {
                                    if flippedGroups.contains(group.id) { flippedGroups.remove(group.id) } else { flippedGroups.insert(group.id) }
                                }
                            }
                        }
                    }
                } else {
                    ReviewCard {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { item in ReviewItemRow(item: item, tint: accent) }
                        }
                    }
                }
            case .orphans:
                ReviewCard {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleOrphans, id: \.self) { url in ReviewOrphanRow(url: url, tint: accent) }
                    }
                }
            case .unusedApps:
                ReviewCard {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleUnusedApps) { app in ReviewUnusedAppRow(app: app, tint: accent) }
                    }
                }
            }
        }
    }

    /// Few groups open by default so the contents are visible; many groups
    /// start closed with their headers saying what is inside. Searching opens all.
    private func isExpanded(_ group: CleanupGroup, total: Int) -> Bool {
        if !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return (total <= 4) != flippedGroups.contains(group.id)
    }
}

/// One area in the review sidebar.
private struct ReviewTargetRow: View {
    @EnvironmentObject var appState: AppState
    let target: ReviewTarget
    let isCurrent: Bool
    let accent: Color
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let info = appState.info(for: target)
        let state = SelectionState(selected: info.selectedCount, total: info.itemCount)
        HStack(spacing: 10) {
            SelectionCircle(state: state, tint: accent) {
                appState.setAllSelected(state != .on, for: target)
            }
            .accessibilityLabel(Text(info.title))
            CategoryBadge(systemName: info.icon, tint: info.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(String(format: String(localized: "%@ · %lld of %lld"),
                            ByteCountFormatter.string(fromByteCount: info.totalSize, countStyle: .file),
                            Int64(info.selectedCount), Int64(info.itemCount)))
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isCurrent ? 0.15 : (hovering ? 0.07 : 0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isCurrent ? info.tint.opacity(0.55) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(MotionTokens.snappy, value: hovering)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A rounded tray holding rows.
private struct ReviewCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(6)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
    }
}

/// Row chrome shared by every reviewable item: generous height, hover
/// highlight, and a click anywhere on the row toggles it.
private struct ReviewRowShell<Content: View>: View {
    let toggle: () -> Void
    /// Receives whether the pointer is over the row, for hover-only controls.
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) { content(hovering) }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 46)
            .background(Color.white.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(perform: toggle)
            .onHover { hovering = $0 }
    }
}

/// Icon for a path: the real Finder icon for folders and apps, a clear kind
/// icon for everything else.
private struct FinderIcon: View {
    let path: String
    var size: CGFloat = 26

    var body: some View {
        FileIcon(path: path, size: size)
    }
}

/// One app's (or one kind of file's) items under a header that says what they
/// are, how many there are and how much space they take.
private struct ReviewGroupCard: View {
    @EnvironmentObject var appState: AppState
    let group: CleanupGroup
    let tint: Color
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    @State private var hovering = false

    private var selectedCount: Int { group.items.filter(appState.isItemSelected).count }

    var body: some View {
        let state = SelectionState(selected: selectedCount, total: group.items.count)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SelectionCircle(state: state, tint: tint) {
                    appState.setSelection(state != .on, for: group.items)
                }
                .accessibilityLabel(Text(group.title))

                groupIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(group.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                if state == .mixed {
                    Text("\(selectedCount) of \(group.items.count) selected")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(ByteCountFormatter.string(fromByteCount: group.totalSize, countStyle: .file))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.1 : 0)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)
            .onHover { hovering = $0 }

            if isExpanded {
                Divider().opacity(0.3).padding(.horizontal, 12)
                LazyVStack(spacing: 2) {
                    ForEach(group.items) { item in
                        ReviewItemRow(item: item, tint: tint)
                    }
                }
                .padding(.leading, 30)
                .padding([.trailing, .vertical], 6)
            }
        }
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.6))
    }

    @ViewBuilder
    private var groupIcon: some View {
        if let path = group.appPath ?? group.items.first(where: { !$0.isActionItem })?.path {
            FinderIcon(path: path, size: 32)
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 32, height: 32)
        }
    }
}

/// One file or folder that can be cleaned.
private struct ReviewItemRow: View {
    @EnvironmentObject var appState: AppState
    let item: CleanableItem
    let tint: Color

    var body: some View {
        ReviewRowShell(toggle: { appState.toggleItem(item) }) { hovering in
            SelectionCircle(state: appState.isItemSelected(item) ? .on : .off, tint: tint) {
                appState.toggleItem(item)
            }
            .accessibilityLabel("Select \(item.name)")

            if item.isActionItem {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24, height: 24)
            } else {
                FinderIcon(path: item.path, size: 24)
            }

            Text(item.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.isActionItem ? item.name : item.path)

            Spacer(minLength: 10)

            if !item.isActionItem {
                Button { reveal() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)
                    .opacity(hovering ? 1 : 0)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal \(item.name) in Finder")
            }
            Text(item.formattedSize)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 78, alignment: .trailing)
        }
        .contextMenu {
            if !item.isActionItem {
                Button("Reveal in Finder") { reveal() }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                }
                Divider()
                Button("Always exclude from cleanup") { appState.excludeFromCleanup(item) }
                    .disabled(appState.scanState.isActive)
            }
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }
}

/// One leftover file from an uninstalled app.
private struct ReviewOrphanRow: View {
    @EnvironmentObject var appState: AppState
    let url: URL
    let tint: Color

    private var isSelected: Bool { appState.selectedOrphans.contains(url) }

    var body: some View {
        ReviewRowShell(toggle: toggle) { hovering in
            SelectionCircle(state: isSelected ? .on : .off, tint: tint, action: toggle)
                .accessibilityLabel(Text(url.lastPathComponent))
            FinderIcon(path: url.path)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
            }
            Spacer(minLength: 10)
            Text(ByteCountFormatter.string(fromByteCount: appState.orphanSizes[url] ?? 0, countStyle: .file))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 78, alignment: .trailing)
            Button { reveal() } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(GlassButtonStyle())
                .controlSize(.small)
                .opacity(hovering ? 1 : 0)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
        }
        .contextMenu {
            Button("Reveal in Finder") { reveal() }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            Divider()
            Button("Always Ignore") { appState.ignoreOrphans([url]) }
        }
    }

    private func toggle() {
        if isSelected { appState.selectedOrphans.remove(url) } else { appState.selectedOrphans.insert(url) }
    }

    private func reveal() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if fileManager.fileExists(atPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

/// One unused app: when it was last opened and how much it takes with its
/// support files.
private struct ReviewUnusedAppRow: View {
    @EnvironmentObject var appState: AppState
    let app: UnusedAppRecord
    let tint: Color

    private var isSelected: Bool { appState.selectedUnusedApps.contains(app.id) }

    var body: some View {
        ReviewRowShell(toggle: toggle) { hovering in
            SelectionCircle(state: isSelected ? .on : .off, tint: tint, action: toggle)
                .accessibilityLabel(Text(app.name))
            FinderIcon(path: app.appURL.path, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(String(format: String(localized: "Last opened %@"), app.lastUsed.formatted(date: .abbreviated, time: .omitted)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 10)
            Text(String(format: String(localized: "%lld items"), Int64(app.files.count)))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
            Text(ByteCountFormatter.string(fromByteCount: app.totalSize, countStyle: .file))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 78, alignment: .trailing)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([app.appURL])
            } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(GlassButtonStyle())
                .controlSize(.small)
                .opacity(hovering ? 1 : 0)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.appURL]) }
        }
    }

    private func toggle() {
        if isSelected { appState.selectedUnusedApps.remove(app.id) } else { appState.selectedUnusedApps.insert(app.id) }
    }
}

// MARK: - Shared pieces

struct CategoryBadge: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 40
    @Environment(\.premiumIconsEnabled) private var premiumIcons

    var body: some View {
        if premiumIcons {
            PremiumIcon(systemName: systemName, tint: tint, size: size)
        } else {
            systemBadge
        }
    }

    private var systemBadge: some View {
        IconTile(systemName: systemName, tint: tint, size: size * 0.62, corner: size * 0.2, vivid: true)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
                    )
            }
            .shadow(color: tint.opacity(0.45), radius: size * 0.18, y: size * 0.06)
    }
}

struct NavCapsuleButton: View {
    let title: LocalizedStringKey?
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                if let title {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                }
            }
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.35))
            .padding(.horizontal, title == nil ? 9 : 13)
            .padding(.vertical, 7)
            .background(Color.white.opacity(hovering && isEnabled ? 0.16 : 0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ResultStatPill: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
    }
}

struct GlowProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.65), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geometry.size.width * CGFloat(max(0, min(1, progress)))))
                    .shadow(color: tint.opacity(0.8), radius: 6)
            }
        }
        .frame(height: 8)
        .animation(.easeInOut(duration: 0.4), value: progress)
    }
}
