import SwiftUI

/// "Choose areas…": what a Complete scan adds to the essential areas. The
/// choice is saved (`cleanup.disabledAreas`) and the riskier group starts off.
struct ScanAreasSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let palette = SectionPalette.smartCare
    private var isLocked: Bool { appState.isSmartScanRunning }

    /// Everyday areas only: the riskier ones are never part of "Select all".
    private var everydayCategories: [CleaningCategory] { AppState.generalCleanupCategories.filter { !$0.isRisky } }
    private var totalAreas: Int { everydayCategories.count + 2 }
    private var enabledAreas: Int {
        appState.enabledCleanupCategories.filter { !$0.isRisky }.count
            + (appState.cleanupIncludesOrphans ? 1 : 0)
            + (appState.cleanupIncludesUnusedApps ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                PremiumIcon(systemName: ScanDepth.complete.icon, tint: palette.accent, size: 34, style: .glass)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Complete scan areas")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .tracking(-0.3)
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    Text("Large files, app leftovers and developer data. You choose what to scan and what to remove.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.75)

            // Two columns. The riskier group sits under the first, shorter
            // one, in its own tinted box, so both columns end about level.
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(CleanupBundle.allCases.filter { !$0.isRisky }.enumerated()), id: \.element) { index, bundle in
                    VStack(alignment: .leading, spacing: 18) {
                        BundleColumn(bundle: bundle, isLocked: isLocked)
                        if index == 0 {
                            ForEach(CleanupBundle.allCases.filter(\.isRisky), id: \.self) { risky in
                                BundleColumn(bundle: risky, isLocked: isLocked)
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
                .foregroundStyle(palette.accent)
                .disabled(isLocked)
                Button("Done") { dismiss() }
                    .buttonStyle(GlassProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 760)
        .background {
            ZStack {
                LinearGradient(colors: [palette.secondary, palette.deep], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [palette.accent.opacity(0.22), .clear], center: .topLeading, startRadius: 10, endRadius: 520)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
    }
}

/// One group of Complete scan areas: a title with its own select-all
/// checkbox, then one row per area.
struct BundleColumn: View {
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
                scanning: appState.isSmartScanRunning && appState.currentScanCategory == category.rawValue
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
                .toggleStyle(AnimatedCheckboxStyle(tint: SectionPalette.smartCare.accent))
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
            .toggleStyle(AnimatedCheckboxStyle(tint: SectionPalette.smartCare.accent))
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
