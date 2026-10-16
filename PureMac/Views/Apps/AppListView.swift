import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: InstalledApp.ID?
    @AppStorage("apps.sortKey") private var sortKey: AppSortKey = .name
    @AppStorage("apps.sortAscending") private var sortAscending = true

    private enum AppSortKey: String, CaseIterable, Identifiable {
        case name, lastUsed, size

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .name: return "Name"
            case .lastUsed: return "Last used"
            case .size: return "Size"
            }
        }

        var icon: String {
            switch self {
            case .name: return "textformat"
            case .lastUsed: return "clock"
            case .size: return "internaldrive"
            }
        }

        /// A–Z for names; most recent and biggest first for the others.
        var defaultAscending: Bool { self == .name }
    }

    private var filteredApps: [InstalledApp] {
        let base: [InstalledApp]
        let searchText = appState.appSearchText
        if searchText.isEmpty {
            base = appState.installedApps
        } else {
            let query = searchText.lowercased()
            base = appState.installedApps.filter {
                $0.appName.lowercased().contains(query) ||
                $0.bundleIdentifier.lowercased().contains(query)
            }
        }
        return base.sorted { left, right in
            switch sortKey {
            case .name:
                let order = left.appName.localizedStandardCompare(right.appName)
                return sortAscending ? order == .orderedAscending : order == .orderedDescending
            case .lastUsed:
                let l = left.lastUsed ?? .distantPast, r = right.lastUsed ?? .distantPast
                return sortAscending ? l < r : l > r
            case .size:
                return sortAscending ? left.size < right.size : left.size > right.size
            }
        }
    }

    var body: some View {
        // Fixed-width list so selecting or closing an app never shifts the layout.
        HStack(spacing: 16) {
            appTable
                .background(GlassPanelBackground())
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(width: 330)

            fileDetail
                .background(GlassPanelBackground())
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
        .padding(.bottom, 20)

    }

    private var installedAppsTitle: String {
        String(format: String(localized: "Installed Apps (%lld)"), Int64(appState.installedApps.count))
    }

    // MARK: - App Table (left side)

    private var appTable: some View {
        VStack(spacing: 0) {
            InlineSearchField(prompt: "Search apps", text: $appState.appSearchText)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
            appTableContent
                .frame(maxHeight: .infinity)
        }
    }

    private var appTableContent: some View {
        Group {
            if appState.isLoadingApps {
                VStack(spacing: 12) {
                    ProgressView(LocalizedStringKey("Loading installed apps..."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.installedApps.isEmpty {
                EmptyStateView(
                    "No Apps Found",
                    systemImage: "square.grid.2x2",
                    description: "Could not find any installed applications.",
                    action: { appState.loadInstalledApps() },
                    actionLabel: "Retry"
                )
            } else {
                VStack(spacing: 0) {
                    listHeader
                    List(filteredApps, selection: $selection) { app in
                        AppListRow(app: app, showsLastUsed: sortKey == .lastUsed)
                            .tag(app.id)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
                .onChange(of: selection) { newValue in
                    guard let id = newValue,
                          let app = appState.installedApps.first(where: { $0.id == id })
                    else { return }
                    // Skip when the selection was just synced from an external
                    // (Finder Services) hand-off that already scanned this app,
                    // so we don't fire a redundant second scan.
                    guard appState.selectedApp?.id != app.id else { return }
                    appState.selectedApp = app
                    appState.scanForAppFiles(app)
                }
                .onChange(of: appState.selectedApp) { app in
                    // Reflect an externally-driven selection (Finder Services)
                    // in the table highlight.
                    if selection != app?.id { selection = app?.id }
                }
                .onAppear {
                    // Sync the highlight when this view mounts already pointed
                    // at an externally-selected app.
                    if selection != appState.selectedApp?.id {
                        selection = appState.selectedApp?.id
                    }
                }
            }
        }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("Apps")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("\(filteredApps.count)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            Spacer()
            sortMenu
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.75)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.75)
        }
    }

    /// Order picker plus a direction flip, sized to sit inside the header row.
    private var sortMenu: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(AppSortKey.allCases) { key in
                    Button {
                        guard key != sortKey else { return }
                        sortKey = key
                        sortAscending = key.defaultAscending
                    } label: {
                        if key == sortKey {
                            Label(key.title, systemImage: "checkmark")
                        } else {
                            Text(key.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: sortKey.icon)
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(sortKey.title)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .opacity(0.6)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Sort"))

            Button {
                sortAscending.toggle()
            } label: {
                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text(sortAscending ? "Ascending" : "Descending"))
        }
    }

    // MARK: - File Detail (right side)

    @ViewBuilder
    private var fileDetail: some View {
        if let app = appState.selectedApp {
            AppFilesView(app: app)
        } else {
            EmptyStateView(
                "Select an App",
                systemImage: "cursorarrow.click.2",
                description: "Select an app from the list to see all its related files across your system.",
                tint: SectionPalette.apps.accent
            )
        }
    }
}

private struct AppListRow: View {
    let app: InstalledApp
    var showsLastUsed = false

    private var trailingText: String {
        guard showsLastUsed else { return app.formattedSize }
        guard let lastUsed = app.lastUsed else { return String(localized: "Never") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastUsed, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            HoverScaleIcon(icon: app.icon)
            Text(app.appName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(trailingText)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .help(app.bundleIdentifier)
    }
}

/// App icon that scales up slightly on hover inside a Table cell.
private struct HoverScaleIcon: View {
    let icon: NSImage

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: 22, height: 22)
            .scaleEffect(hovering && !reduceMotion ? 1.12 : 1)
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}
