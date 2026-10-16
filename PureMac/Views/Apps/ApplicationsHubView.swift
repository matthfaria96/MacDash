import SwiftUI

/// The three Applications tabs.
enum ApplicationsTab: String, CaseIterable, Identifiable {
    case uninstall
    case startup
    case updates

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .uninstall: return "Uninstall"
        case .startup: return "Startup Items"
        case .updates: return "Updates"
        }
    }

    var icon: String {
        switch self {
        case .uninstall: return "trash"
        case .startup: return "power"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// Applications hub: uninstall apps, control what starts with the Mac, and
/// keep Homebrew apps up to date — one screen, three tabs.
struct ApplicationsHubView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var inspection = SystemInspectionModel.shared
    /// Kept here so switching tabs never throws away an update check.
    @StateObject private var updater = ApplicationUpdater()
    @StateObject private var sparkle = SparkleUpdateChecker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let palette = SectionPalette.apps

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 14)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(appState.applicationsTab)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appState.applicationsTab)
        .task {
            if appState.installedApps.isEmpty { appState.loadInstalledApps() }
            await inspection.loadIfNeeded()
        }
    }

    private var header: some View {
        HubHeader(
            title: "Applications",
            subtitle: "Uninstall apps, control what starts with your Mac and keep everything up to date.",
            icon: "square.grid.2x2.fill",
            tint: palette.accent
        ) {
            PillTabBar(
                tabs: ApplicationsTab.allCases,
                selection: $appState.applicationsTab,
                title: { $0.title },
                icon: { $0.icon },
                badge: { count(for: $0).map(String.init) }
            )
        }
    }

    private func count(for tab: ApplicationsTab) -> Int? {
        switch tab {
        case .uninstall:
            return appState.installedApps.isEmpty ? nil : appState.installedApps.count
        case .startup:
            return inspection.inspection == nil ? nil : inspection.startupItems.count
        case .updates:
            guard updater.hasChecked || sparkle.hasChecked else { return nil }
            return updater.updates.count + sparkle.updates.count
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch appState.applicationsTab {
        case .uninstall:
            AppListView()
        case .startup:
            StartupItemsView()
        case .updates:
            AppUpdatesView(updater: updater, sparkle: sparkle)
        }
    }
}
