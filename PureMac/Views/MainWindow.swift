import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedSection: AppSection? = .smartCare
    @AppStorage("MacTidy.SidebarCompact") private var sidebarIsCompact = false
    @FocusState private var focusedSection: AppSection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var assistantOpen = false

    var body: some View {
        NavigationSplitView {
            sidebarColumn
                .navigationSplitViewColumnWidth(
                    min: sidebarIsCompact ? 104 : 292,
                    ideal: sidebarIsCompact ? 104 : 296,
                    max: sidebarIsCompact ? 104 : 320
                )
        } detail: {
            detailContainer
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(reduceMotion ? nil : MotionTokens.gentle) {
                        sidebarIsCompact.toggle()
                    }
                } label: {
                    Label(
                        sidebarIsCompact ? "Expand sidebar" : "Collapse sidebar",
                        systemImage: sidebarIsCompact ? "sidebar.right" : "sidebar.left"
                    )
                    .labelStyle(.iconOnly)
                }
                .help(Text(sidebarIsCompact ? "Expand sidebar" : "Collapse sidebar"))
                .accessibilityLabel(Text(sidebarIsCompact ? "Expand sidebar" : "Collapse sidebar"))
            }
            // The Assistant sits in the same corner on every screen.
            ToolbarItem(placement: .primaryAction) {
                AssistantToolbarButton(isOpen: $assistantOpen, tint: selectedPalette.accent)
            }
            // The current section's name sits centered in a see-through title bar.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) { sectionTitle }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { sectionTitle }
            }
        }
        .overlay(alignment: .topTrailing) {
            if assistantOpen {
                ZStack(alignment: .topTrailing) {
                    // A click anywhere else closes it.
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { closeAssistant() }
                    AssistantPanel(tint: selectedPalette.accent, navigate: { selectSection($0) }) { closeAssistant() }
                        .padding(.top, 6)
                        .padding(.trailing, 14)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.08, anchor: .topTrailing).combined(with: .opacity)
                        )
                }
            }
        }
        .navigationTitle("MacDash")
        .modifier(HiddenWindowTitle())
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 1040, minHeight: 680)
        .tint(selectedPalette.accent)
        .background(AmbientBackdrop(palette: selectedPalette))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.38), value: selectedSection)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.checkFullDiskAccess()
            permission.refreshStatus()
        }
        .onChange(of: appState.pendingExternalApp) { app in
            guard app != nil else { return }
            appState.applicationsTab = .uninstall
            selectSection(.apps)
            appState.pendingExternalApp = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuBarNavigation.notification)) { _ in
            applyMenuBarNavigation()
        }
        .onChange(of: appState.showUpdateSettings) { showUpdates in
            if showUpdates { selectSection(.settings) }
        }
        .onAppear {
            if appState.showUpdateSettings {
                selectSection(.settings)
            } else if appState.pendingExternalApp != nil {
                appState.applicationsTab = .uninstall
                selectSection(.apps)
                appState.pendingExternalApp = nil
            } else if let selectedSection {
                focusedSection = selectedSection
            }
            #if DEBUG
            applyDebugLaunchSelection()
            #endif
            applyMenuBarNavigation()
            // Scheduled antivirus scans; findings only wait for review.
            if !DemoMode.isActive { AntivirusStore.shared.startScheduler() }
        }
        .onChange(of: appState.cleanErrorIsFDAFixable) { isFDAFixable in
            guard isFDAFixable else { return }
            let pending = appState.pendingPermissionRetryItems
            appState.cleanError = nil
            appState.cleanErrorIsFDAFixable = false
            appState.requestFullDiskAccessAndRetry(
                items: pending,
                context: .cleanup(failedCount: pending.count)
            )
        }
        .alert("Couldn't clean everything", isPresented: Binding(
            get: { appState.cleanError != nil && !appState.cleanErrorIsFDAFixable },
            set: { if !$0 { appState.cleanError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.cleanError = nil }
        } message: {
            Text(appState.cleanError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { permission.isRequesting && permission.presentation == .mainWindow },
            set: { if !$0 && permission.presentation == .mainWindow { permission.dismiss(callRetry: false) } }
        )) {
            PermissionSheet()
        }
    }

    /// Sidebar layout: Smart Care followed by the tools, one continuous list.
    /// Each destination has its own color.
    private static let mainSections: [AppSection] = [
        .cleanup, .apps, .protection, .antivirus, .processes, .spaceLens, .duplicates, .similarPhotos
    ]

    private var sidebar: some View {
        List {
            navRow(.smartCare)
            ForEach(Self.mainSections, id: \.self) { navRow($0) }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 48)
        .scrollContentBackground(.hidden)
        .background(sidebarBackground)
        .onMoveCommand(perform: moveSelection)
        // A little more room between the window buttons and the first item.
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 8) }
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
    }

    @ViewBuilder
    private var sidebarColumn: some View {
        if #available(macOS 14.0, *) {
            sidebar.toolbar(removing: .sidebarToggle)
        } else {
            sidebar
        }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 1, leading: sidebarIsCompact ? 5 : 8, bottom: 1, trailing: sidebarIsCompact ? 5 : 8)
    }

    private var sectionTitle: some View {
        Text(selectedSection.map { SidebarItem($0).title } ?? "MacDash")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 240)
    }

    private func navRow(_ section: AppSection) -> some View {
        let item = SidebarItem(section)
        return Button {
            selectSection(section)
        } label: {
            SidebarNavRow(
                label: item.title,
                icon: item.icon,
                tint: SectionPalette.forSection(section).accent,
                badge: badge(for: section),
                isSelected: selectedSection == section,
                isCompact: sidebarIsCompact
            )
        }
        .buttonStyle(.plain)
        .focused($focusedSection, equals: section)
        .accessibilityLabel(Text(item.title))
        .help(Text(item.title))
        .accessibilityIdentifier(accessibilityIdentifier(for: section))
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var visibleSections: [AppSection] {
        [.smartCare] + Self.mainSections + [.settings]
    }

    private func closeAssistant() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.9)) {
            assistantOpen = false
        }
    }

    /// A destination picked in the menu bar panel, possibly before this
    /// window existed.
    private func applyMenuBarNavigation() {
        guard let pending = MenuBarNavigation.pending else { return }
        MenuBarNavigation.pending = nil
        selectSection(pending.section)
        if pending.startScan, appState.scanState(in: .smartCare) == .idle {
            appState.startSmartScan()
        }
    }

    private func selectSection(_ section: AppSection) {
        selectedSection = section
        focusedSection = section
    }

    private func accessibilityIdentifier(for section: AppSection) -> String {
        switch section {
        case .smartCare: return "sidebar.smartCare"
        case .apps: return "sidebar.uninstaller"
        case .duplicates: return "sidebar.duplicates"
        case .spaceLens: return "sidebar.spaceLens"
        case .processes: return "sidebar.processes"
        case .similarPhotos: return "sidebar.similarPhotos"
        case .protection: return "sidebar.protection"
        case .antivirus: return "sidebar.antivirus"
        case .settings: return "sidebar.settings"
        case .cleanup: return "sidebar.cleanup"
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let sections = visibleSections
        guard !sections.isEmpty else { return }
        let current = focusedSection ?? selectedSection
        let currentIndex = current.flatMap(sections.firstIndex(of:))
        let targetIndex: Int

        switch direction {
        case .up:
            targetIndex = max(0, (currentIndex ?? sections.count) - 1)
        case .down:
            targetIndex = min(sections.count - 1, (currentIndex ?? -1) + 1)
        default:
            return
        }

        selectSection(sections[targetIndex])
    }

    private func badge(for section: AppSection) -> String? {
        switch section {
        case .smartCare:
            guard appState.scanScope == .smartCare, appState.totalJunkSize > 0 else { return nil }
            return ByteCountFormatter.string(fromByteCount: appState.totalJunkSize, countStyle: .file)
        case .apps:
            guard !appState.installedApps.isEmpty else { return nil }
            return String(format: String(localized: "%lld apps"), Int64(appState.installedApps.count))
        case .cleanup:
            let size = appState.enabledCleanupCategories.reduce(Int64(0)) { $0 + (appState.categoryResults[$1]?.totalSize ?? 0) }
                + (appState.cleanupIncludesOrphans ? appState.totalOrphanSize : 0)
                + (appState.cleanupIncludesUnusedApps ? appState.totalUnusedAppsSize : 0)
            guard size > 0 else { return nil }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        default:
            return nil
        }
    }

    /// The section's backdrop runs under the sidebar, so it only adds a
    /// faint shade and a hairline edge.
    private var sidebarBackground: some View {
        Rectangle()
            .fill(Color.black.opacity(0.06))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 0.75)
            }
            .ignoresSafeArea()
    }

    private var sidebarFooter: some View {
        Button {
            selectSection(.settings)
        } label: {
            SidebarNavRow(
                label: "Settings",
                icon: "gearshape.fill",
                tint: SectionPalette.settings.accent,
                badge: nil,
                isSelected: selectedSection == .settings,
                isCompact: sidebarIsCompact
            )
        }
        .buttonStyle(.plain)
        .focused($focusedSection, equals: .settings)
        .accessibilityIdentifier("sidebar.settings")
        .accessibilityAddTraits(selectedSection == .settings ? .isSelected : [])
        .padding(.horizontal, sidebarIsCompact ? 5 : 12)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var detailContainer: some View {
        VStack(spacing: 0) {
            if selectedSection != .settings && !appState.hasFullDiskAccess && !appState.fdaBannerDismissed {
                accessBanner
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            detailView
                .id(selectedSection)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 18)).combined(with: .scale(scale: 0.985, anchor: .top)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))
                ))
        }
        .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.86), value: selectedSection)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: appState.fdaBannerDismissed)
        .animation(reduceMotion ? nil : MotionTokens.gentle, value: appState.hasFullDiskAccess)
        // The detail column takes exactly the room the window leaves it. Its
        // ideal width is ignored: text reports its full untruncated length as
        // ideal, so a page that just received data (long process names, live
        // numbers) would otherwise widen past the window and push the sidebar
        // off its left edge.
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.themeTint, selectedPalette.accent)
        // Content scrolling under the see-through title bar fades into the
        // backdrop instead of colliding with the section name.
        .overlay(alignment: .top) {
            AmbientBackdrop(palette: selectedPalette)
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 64)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea()
                )
                .allowsHitTesting(false)
        }
        .background(AmbientBackdrop(palette: selectedPalette))
    }

    #if DEBUG
    /// Debug builds only: `-DebugSection protection -DebugTab wifi` opens a
    /// screen directly, so screenshots don't need clicks.
    private func applyDebugLaunchSelection() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "DebugAssistant") { assistantOpen = true }
        let sections: [String: AppSection] = [
            "smartCare": .smartCare, "apps": .apps, "cleanup": .cleanup, "protection": .protection, "antivirus": .antivirus,
            "duplicates": .duplicates, "similarPhotos": .similarPhotos, "spaceLens": .spaceLens, "processes": .processes, "settings": .settings,
        ]
        guard let name = defaults.string(forKey: "DebugSection"), let section = sections[name] else { return }
        if let tab = defaults.string(forKey: "DebugTab") {
            if let value = ProtectionTab(rawValue: tab) { appState.protectionTab = value }
            if let value = ApplicationsTab(rawValue: tab) { appState.applicationsTab = value }
            if let value = SpaceLensTab(rawValue: tab) { SpaceLensModel.shared.tab = value }
        }
        selectSection(section)
        if section == .smartCare, defaults.bool(forKey: "DebugScan") { appState.startSmartScan() }
        // `-DebugAntivirusScan deep` starts that Antivirus scan on launch.
        if let mode = defaults.string(forKey: "DebugAntivirusScan").flatMap(AntivirusScanMode.init(rawValue:)) {
            AntivirusStore.shared.start(mode)
        }
        if section == .spaceLens, let root = defaults.string(forKey: "DebugSpaceLensRoot") {
            SpaceLensModel.shared.location = root == "/" ? .startupDisk : .custom(URL(fileURLWithPath: root))
            SpaceLensModel.shared.start()
            // `-DebugSpaceLensOpen Users` opens that folder, then goes back,
            // so the rings' motion can be recorded.
            if let name = defaults.string(forKey: "DebugSpaceLensOpen") {
                Task { @MainActor in
                    let model = SpaceLensModel.shared
                    while model.phase != .results { try? await Task.sleep(nanoseconds: 200_000_000) }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if let node = model.root?.children.first(where: { $0.name == name }) { model.open(node) }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    model.goUp()
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .smartCare:
            DashboardView { selectSection($0) }
        case .cleanup:
            CleanupHubView()
        case .apps:
            ApplicationsHubView()
        case .spaceLens:
            SpaceLensView()
        case .processes:
            ProcessesView()
        case .duplicates:
            DuplicateFinderView()
        case .similarPhotos:
            SimilarPhotosView()
        case .protection:
            ProtectionHubView()
        case .antivirus:
            AntivirusView()
        case .settings:
            // Settings keeps plain system symbols, like System Settings.
            SettingsView()
                .environment(\.premiumIconsEnabled, false)
        case nil:
            EmptyStateView(
                "MacDash",
                systemImage: "sparkles",
                description: "Select a tool from the sidebar."
            )
        }
    }

    private var selectedPalette: SectionPalette {
        SectionPalette.forSection(selectedSection)
    }

    private var accessBanner: some View {
        HStack(spacing: 12) {
            PremiumIcon(systemName: "lock.shield.fill", tint: Tint.orange, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off")
                    .font(.system(size: 13, weight: .semibold))
                Text("Protected caches and app containers will be skipped.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set up") {
                permission.requestAccess(context: .general) {
                    appState.checkFullDiskAccess()
                }
            }
            .buttonStyle(GlassProminentButtonStyle())
            .controlSize(.regular)
            .tint(Tint.accent)
            Button {
                appState.fdaBannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tint.orange.opacity(0.075))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Tint.orange.opacity(0.18), lineWidth: 0.5)
        }
    }
}

/// Title and symbol for each sidebar destination.
struct SidebarItem {
    let title: LocalizedStringKey
    let icon: String

    init(_ section: AppSection) {
        switch section {
        case .smartCare: (title, icon) = ("Smart Care", "desktopcomputer")
        case .protection: (title, icon) = ("Protection", "hand.raised.fill")
        case .antivirus: (title, icon) = ("Antivirus", "shield.lefthalf.filled")
        case .apps: (title, icon) = ("Applications", "square.grid.2x2.fill")
        case .duplicates: (title, icon) = ("Duplicate Finder", "doc.on.doc.fill")
        case .spaceLens: (title, icon) = ("Space Lens", "chart.pie.fill")
        case .processes: (title, icon) = ("Processes", "waveform.path.ecg.rectangle.fill")
        case .similarPhotos: (title, icon) = ("Similar Photos", "photo.stack.fill")
        case .cleanup: (title, icon) = ("Advanced Cleanup", "wand.and.stars")
        case .settings: (title, icon) = ("Settings", "gearshape.fill")
        }
    }
}

private struct SidebarNavRow: View {
    let label: LocalizedStringKey
    let icon: String
    /// The destination's identity color, shown on the icon when selected.
    let tint: Color
    let badge: String?
    let isSelected: Bool
    var isCompact = false

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            icon(size: 28)
            if !isCompact {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 14.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Color.white.opacity(isSelected ? 1 : 0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: isCompact ? .center : .leading)
        .padding(.horizontal, isCompact ? 0 : 12)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.16) : (hovering ? Color.white.opacity(0.07) : .clear))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(GlassEdge.gradient, lineWidth: 0.9)
                    }
                }
                .shadow(color: .black.opacity(isSelected ? 0.18 : 0), radius: 8, y: 3)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: isSelected)
        .onHover { hovering = $0 }
    }

    /// Silver glyph like the reference; the selected item lights up in its color.
    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        if isSelected {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: size * 0.78, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(LinearGradient(colors: [tint.mixedWithWhite(0.45), tint], startPoint: .top, endPoint: .bottom))
                    .shadow(color: tint.opacity(0.7), radius: 6)
            }
            .frame(width: size + 4, height: size + 4)
        } else {
            IconTile(systemName: icon, tint: tint, size: size, corner: 8, glow: hovering)
                .frame(width: size + 4, height: size + 4)
        }
    }
}
