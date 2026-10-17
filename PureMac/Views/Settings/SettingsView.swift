import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    /// The dedicated macOS Settings window owns its permission sheet. The main
    /// window already presents the shared coordinator's sheet for every page.
    var standalone = false
    @ObservedObject private var permission = PermissionCoordinator.shared
    @State private var selectedTab = SettingsTab.general

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case menuBar = "Menu Bar"
        case cleaning = "Cleaning"
        case about = "About"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // The standard Settings window already carries the title; only the
            // sidebar page repeats it as a header.
            if !standalone {
                FeaturePageHeader(
                    title: Text("Settings"),
                    systemImage: "gearshape.fill",
                    tint: SectionPalette.settings.accent,
                    detail: { Text("Make MacDash work your way.") },
                    accessory: { EmptyView() }
                )
            }

            Picker("Settings", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("settings.tabs")

            Group {
                switch selectedTab {
                case .general: GeneralSettingsView(permissionPresentation: standalone ? .settingsWindow : .mainWindow)
                case .menuBar: MenuBarSettingsView()
                case .cleaning: CleaningSettingsView()
                case .about: AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .frame(maxWidth: 960)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AmbientBackdrop(palette: .settings))
        .tint(SectionPalette.settings.accent)
        .onAppear {
            showRequestedUpdates()
            #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: "DebugSettingsTab"), let tab = SettingsTab(rawValue: raw) { selectedTab = tab }
            #endif
        }
        .onChange(of: appState.showUpdateSettings) { _ in showRequestedUpdates() }
        .sheet(isPresented: Binding(
            get: { standalone && permission.isRequesting && permission.presentation == .settingsWindow },
            set: { if !$0 && standalone && permission.presentation == .settingsWindow { permission.dismiss(callRetry: false) } }
        )) { PermissionSheet() }
    }

    private func showRequestedUpdates() {
        if !standalone && appState.showUpdateSettings {
            selectedTab = .about
            appState.showUpdateSettings = false
        }
    }
}

// MARK: - Building blocks

/// The look of every Settings page, in the manner of macOS System Settings:
/// one level of grouped rows on the backdrop, text first, native controls,
/// and explanations as quiet footers.
private enum SettingsStyle {
    static let columnWidth: CGFloat = 640
    static let sectionSpacing: CGFloat = 28
    static let corner: CGFloat = 12
    static let rowFill = Color.white.opacity(0.055)
    static let rowStroke = Color.white.opacity(0.06)
    static let separator = Color.white.opacity(0.08)
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.5)
    static let tertiary = Color.white.opacity(0.35)
}

/// A scrolling column of sections, centered with room to breathe.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
                content
            }
            .frame(maxWidth: SettingsStyle.columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.never)
    }
}

/// A titled group of rows with an optional footer.
private struct SettingsSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    var footer: Text?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsStyle.primary)
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) { content }
                .background(SettingsStyle.rowFill, in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous).strokeBorder(SettingsStyle.rowStroke, lineWidth: 0.5))

            if let footer {
                footer
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, footer: Text? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

/// One line: what it is on the left, the control on the right.
private struct SettingsRow<Control: View>: View {
    let title: Text
    var detail: Text?
    /// A monochrome symbol, only where rows name distinct things.
    var symbol: String?
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, symbol: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = Text(title)
        self.detail = detail.map { Text($0) }
        self.symbol = symbol
        self.control = control()
    }

    init(verbatim title: String, detail: String? = nil, symbol: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = Text(verbatim: title)
        self.detail = detail.map { Text(verbatim: $0) }
        self.symbol = symbol
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(SettingsStyle.secondary)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsStyle.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    detail
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 40)
    }
}

/// A hairline between rows, starting where the text starts.
private struct SettingsSeparator: View {
    var indented = false

    var body: some View {
        Rectangle()
            .fill(SettingsStyle.separator)
            .frame(height: 0.5)
            .padding(.leading, indented ? 46 : 14)
    }
}

private extension View {
    func settingsSwitch() -> some View {
        labelsHidden().toggleStyle(.switch).controlSize(.small)
    }

    func settingsMenu() -> some View {
        labelsHidden().pickerStyle(.menu).fixedSize()
    }

    func settingsValue() -> some View {
        font(.system(size: 13)).monospacedDigit().foregroundStyle(SettingsStyle.secondary)
    }
}

/// A path in a list, removable with the minus button.
private struct SettingsPathRow: View {
    let path: String
    var isDisabled = false
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsStyle.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsStyle.secondary)
            .disabled(isDisabled)
            .help(String(localized: "Remove from exclusions"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    var permissionPresentation: PermissionCoordinator.Presentation = .mainWindow
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var permission = PermissionCoordinator.shared
    @AppStorage("settings.general.launchAtLogin") private var launchAtLogin = false
    @AppStorage(Haptics.soundEffectsKey) private var soundEffects = true
    @AppStorage(AppLanguage.preferenceKey) private var appLanguageRaw = AppLanguage.current.rawValue
    private var languageNeedsRelaunch: Bool { appState.settingsNeedLanguageRestart }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsPage {
            PermissionsSection()

            SettingsSection("Language") {
                SettingsRow("Language") {
                    Picker("Language", selection: appLanguageBinding) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(LocalizedStringKey(language.displayName)).tag(language)
                        }
                    }
                    .settingsMenu()
                }
                if languageNeedsRelaunch {
                    SettingsSeparator()
                    SettingsRow("Restart MacDash to apply the selected language.") {
                        Button("Relaunch Now") { relaunchApp() }
                            .buttonStyle(.borderedProminent)
                    }
                    .transition(.opacity)
                }
            }

            SettingsSection("Behavior") {
                SettingsRow("Launch MacDash at login") {
                    Toggle("Launch MacDash at login", isOn: launchAtLoginBinding).settingsSwitch()
                }
                SettingsSeparator()
                SettingsRow("Play sound effects") {
                    Toggle("Play sound effects", isOn: $soundEffects).settingsSwitch()
                }
            }
        }
        .onAppear { refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccess()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: languageNeedsRelaunch)
    }

    private func refreshAccess() {
        appState.checkFullDiskAccess()
        permission.refreshStatus()
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                launchAtLogin = newValue
                toggleLaunchAtLogin(newValue)
            }
        )
    }

    private var appLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRaw) ?? .system },
            set: { newValue in
                appLanguageRaw = newValue.rawValue
                applyLanguage(newValue)
            }
        )
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger.shared.log("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)", level: .error)
            launchAtLogin = !enabled
        }
    }

    private func applyLanguage(_ language: AppLanguage) {
        AppLanguagePreferences.apply(language)
        appState.settingsNeedLanguageRestart = language != appState.languageAtLaunch
    }

    private func relaunchApp() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]

        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            Logger.shared.log("Failed to relaunch MacDash: \(error.localizedDescription)", level: .error)
        }
    }
}

// MARK: - Permissions

/// Each permission with its live status, the way Privacy & Security lists
/// them: what it is, what it's for, and either "Allowed" or the one button
/// that turns it on.
private struct PermissionsSection: View {
    @ObservedObject private var permissions = MacTidyPermissions.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Int { MacTidyPermissions.Item.allCases.count }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
            SettingsSection(
                title: "Permissions",
                footer: Text("Each status is read from macOS right now and updates as soon as you change it in System Settings.")
            ) {
                summary
            } content: {
                ForEach(Array(MacTidyPermissions.Item.allCases.enumerated()), id: \.element) { index, item in
                    if index > 0 { SettingsSeparator(indented: true) }
                    PermissionLine(item: item, status: permissions.status(item), isRequesting: permissions.requesting == item) {
                        permissions.request(item)
                    }
                }
            }

            SettingsSection("Passwords macOS asks for") {
                SettingsRow(
                    verbatim: String(localized: "Wi-Fi passwords"),
                    detail: String(format: String(localized: "macOS asks for your Mac account's user name and password. Your user name is “%@”. Click “Always Allow” and that network won't ask again."), MacAccount.shortName)
                ) { EmptyView() }
                SettingsSeparator()
                SettingsRow(
                    verbatim: String(localized: "Free memory and forget networks"),
                    detail: String(localized: "These need an administrator's password each time. macOS doesn't let apps keep it.")
                ) { EmptyView() }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: permissions.statuses)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private var summary: some View {
        let granted = permissions.grantedCount
        return HStack(spacing: 5) {
            if granted == total {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
            }
            Text(String(format: String(localized: "%lld of %lld allowed"), Int64(granted), Int64(total)))
                .monospacedDigit()
                .foregroundStyle(SettingsStyle.secondary)
        }
        .font(.system(size: 12))
    }
}

private struct PermissionLine: View {
    let item: MacTidyPermissions.Item
    let status: MacTidyPermissions.Status
    let isRequesting: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 14))
                .foregroundStyle(SettingsStyle.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsStyle.primary)
                    if item.isRequired {
                        Text("Required")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsStyle.tertiary)
                    }
                }
                Text(item.purpose)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .granted:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.green)
                Text("Allowed").foregroundStyle(SettingsStyle.secondary)
            }
            .font(.system(size: 12))
        case .needsFullDiskAccess:
            Text("Checked after Full Disk Access")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsStyle.tertiary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 150, alignment: .trailing)
        case .notAsked, .denied:
            Button(action: action) {
                if isRequesting {
                    ProgressView().controlSize(.small)
                } else {
                    Text(buttonTitle)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRequesting)
            .help(status == .denied ? String(localized: "Opens the matching page of System Settings") : "")
        }
    }

    private var buttonTitle: String {
        switch (item, status) {
        case (.notifications, .notAsked), (.automation, .notAsked), (.bluetooth, .notAsked), (.location, .notAsked): return String(localized: "Allow")
        default: return String(localized: "Open Settings")
        }
    }
}

// MARK: - Cleaning

struct CleaningSettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("settings.cleaning.skipHiddenFiles") private var skipHiddenFiles = true
    @AppStorage("settings.cleaning.largeFileThreshold") private var largeFileThresholdMB: Int = 100
    @AppStorage("settings.cleaning.oldFileMonths") private var oldFileMonths: Int = 12
    @AppStorage(UnusedAppsFinder.monthsKey) private var unusedAppsMonths = 6
    @State private var excludedFolders: [String] = []

    private static let excludedFoldersKey = "settings.cleaning.largeFileExcludedFolders"
    static let sizeOptionsMB = [100, 500, 1024, 2048, 5120, 10240]
    static let ageOptionsMonths = [3, 6, 12, 24, 48]

    /// Older saved values snap to the closest listed option.
    private var sizeBinding: Binding<Int> {
        Binding(
            get: { Self.sizeOptionsMB.min { abs($0 - largeFileThresholdMB) < abs($1 - largeFileThresholdMB) } ?? 100 },
            set: { largeFileThresholdMB = $0 }
        )
    }

    private var ageBinding: Binding<Int> {
        Binding(
            get: { Self.ageOptionsMonths.min { abs($0 - oldFileMonths) < abs($1 - oldFileMonths) } ?? 12 },
            set: { oldFileMonths = $0 }
        )
    }

    private static func sizeLabel(_ megabytes: Int) -> String {
        megabytes >= 1024 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    private func monthsLabel(_ months: Int) -> String {
        String(format: String(localized: "%lld months"), Int64(months))
    }

    var body: some View {
        SettingsPage {
            AutomaticScanSection(scheduler: appState.scheduler)

            SettingsSection(
                "Large & Old Files",
                footer: Text("Used by Advanced Cleanup › Large Files. Looks in Downloads, Documents and Desktop for files bigger than the chosen size, or unchanged for the chosen time and over 10 MB. Nothing is preselected.")
            ) {
                SettingsRow("Bigger than") {
                    Picker("Bigger than", selection: sizeBinding) {
                        ForEach(Self.sizeOptionsMB, id: \.self) { Text(Self.sizeLabel($0)).tag($0) }
                    }
                    .settingsMenu()
                }
                SettingsSeparator()
                SettingsRow("Or not changed for") {
                    Picker("Or not changed for", selection: ageBinding) {
                        ForEach(Self.ageOptionsMonths, id: \.self) { Text(monthsLabel($0)).tag($0) }
                    }
                    .settingsMenu()
                }
                SettingsSeparator()
                SettingsRow("Skip hidden files during scan") {
                    Toggle("Skip hidden files during scan", isOn: $skipHiddenFiles).settingsSwitch()
                }
                SettingsSeparator()
                SettingsRow("Folders to skip") {
                    Button("Add Folder…") { addExcludedFolder() }
                        .buttonStyle(.bordered)
                }
                ForEach(excludedFolders, id: \.self) { folder in
                    SettingsSeparator()
                    SettingsPathRow(path: folder) { removeExcludedFolder(folder) }
                }
            }

            SettingsSection(
                "Unused Apps",
                footer: Text("Used by Advanced Cleanup › Unused Apps. Uses the last-opened date macOS records. Apple apps, apps open now and apps with no recorded date are never listed.")
            ) {
                SettingsRow("Not opened for") {
                    Picker("Not opened for", selection: $unusedAppsMonths) {
                        ForEach(UnusedAppsFinder.monthOptions, id: \.self) { Text(monthsLabel($0)).tag($0) }
                    }
                    .settingsMenu()
                }
            }

            SettingsSection(
                "Never Remove",
                footer: Text("Excluded paths stay out of every manual and scheduled cleanup; right-click a cleanup result to add one. Ignored orphans won't appear in future orphan scans.")
            ) {
                SettingsRow("Excluded paths") {
                    Text("\(appState.excludedCleanupPaths.count)").settingsValue()
                }
                ForEach(appState.excludedCleanupPaths, id: \.self) { path in
                    SettingsSeparator()
                    SettingsPathRow(path: path, isDisabled: appState.scanState.isActive) {
                        appState.removeCleanupExclusion(path)
                    }
                }
                SettingsSeparator()
                SettingsRow(verbatim: String(format: String(localized: "Ignored orphans: %lld"), Int64(appState.ignoredOrphanCount))) {
                    Button("Forget Ignored") { appState.clearIgnoredOrphans() }
                        .buttonStyle(.bordered)
                        .disabled(appState.ignoredOrphanCount == 0)
                }
            }
        }
        .onAppear {
            excludedFolders = UserDefaults.standard.stringArray(forKey: Self.excludedFoldersKey) ?? []
        }
    }

    private func persistExcludedFolders() {
        UserDefaults.standard.set(excludedFolders, forKey: Self.excludedFoldersKey)
    }

    private func addExcludedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Folder…")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !excludedFolders.contains(url.path) {
            excludedFolders.append(url.path)
        }
        persistExcludedFolders()
    }

    private func removeExcludedFolder(_ folder: String) {
        excludedFolders.removeAll { $0 == folder }
        persistExcludedFolders()
    }
}

// MARK: - Automatic scanning

/// Scheduled scanning, at the top of the Cleaning tab.
private struct AutomaticScanSection: View {
    @ObservedObject var scheduler: SchedulerService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showInfo = false

    var body: some View {
        SettingsSection(title: "Automatic Scanning", footer: nil) {
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(SettingsStyle.secondary)
            .help("How automatic scanning works")
            .accessibilityLabel("How automatic scanning works")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) { infoPopover }
        } content: {
            SettingsRow("Enable scheduled scanning") {
                Toggle("Enable scheduled scanning", isOn: Binding(
                    get: { scheduler.config.isEnabled },
                    set: { scheduler.toggleEnabled($0) }
                ))
                .settingsSwitch()
            }
            if scheduler.config.isEnabled {
                Group {
                    SettingsSeparator()
                    SettingsRow("Scan interval") {
                        Picker("Scan interval", selection: Binding(
                            get: { scheduler.config.interval },
                            set: { scheduler.updateSchedule(interval: $0) }
                        )) {
                            ForEach(ScheduleInterval.allCases) { interval in
                                Text(LocalizedStringKey(interval.rawValue)).tag(interval)
                            }
                        }
                        .settingsMenu()
                    }
                    SettingsSeparator()
                    SettingsRow("Auto-clean after scan") {
                        Toggle("Auto-clean after scan", isOn: $scheduler.config.autoClean).settingsSwitch()
                    }
                    SettingsSeparator()
                    SettingsRow("Notify on completion") {
                        Toggle("Notify on completion", isOn: $scheduler.config.notifyOnCompletion)
                            .settingsSwitch()
                            .onChange(of: scheduler.config.notifyOnCompletion) { on in
                                // Without this, macOS never shows the notification.
                                if on, MacTidyPermissions.shared.status(.notifications) != .granted {
                                    MacTidyPermissions.shared.request(.notifications)
                                }
                            }
                    }
                    SettingsSeparator()
                    SettingsRow("Last run") { Text(scheduler.config.formattedLastRun).settingsValue() }
                    SettingsSeparator()
                    SettingsRow("Next run") { Text(scheduler.config.formattedNextRun).settingsValue() }
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: scheduler.config.isEnabled)
    }

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How automatic scanning works")
                .font(.system(size: 14, weight: .semibold))
            infoLine("clock", "While MacDash is open, it checks the clock once a minute and runs a scan when the chosen interval has passed since the last run.")
            infoLine("power", "It only runs while the app is open. It does not start the app by itself, so nothing happens while MacDash is quit.")
            infoLine("magnifyingglass", "It scans the same areas as Smart Care. Orphaned files, duplicates and similar photos are never included.")
            infoLine("hourglass", "It waits if another scan, a cleanup or a confirmation is in progress, and skips a run while scan results are open on screen.")
            infoLine("trash", "With Auto-clean on, items selected by default are permanently deleted once at least 100 MB are selected. Large files and personal data are unselected by default, so they are never removed automatically. Excluded paths are always kept.")
            infoLine("bell", "With Notify on completion on, you get a notification with the amount of junk found.")
        }
        .padding(18)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func infoLine(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Menu Bar

/// What MacDash shows in the menu bar and in its panel. The readout reads
/// only the metrics turned on here; with none, nothing runs in the background.
struct MenuBarSettingsView: View {
    @AppStorage("settings.general.menuBarMonitor") private var showInMenuBar = true
    @AppStorage(MenuBarPreferences.styleKey) private var styleRaw = MenuBarReadoutStyle.stacked.rawValue
    @AppStorage(MenuBarPreferences.intervalKey) private var interval = 2.0
    @AppStorage(MenuBarPreferences.alertsKey) private var alertColors = true
    @AppStorage(MenuBarPreferences.showIconKey) private var showIcon = true
    @State private var refresh = 0

    var body: some View {
        SettingsPage {
            SettingsSection(
                "MacDash in the menu bar",
                footer: Text("Your Mac's health, storage, memory, battery, CPU, network and connected devices, one click away. MacDash keeps running in the background while this is on.")
            ) {
                SettingsRow("Show MacDash in the menu bar") {
                    Toggle("Show MacDash in the menu bar", isOn: showBinding).settingsSwitch()
                }
            }

            if showInMenuBar {
                SettingsSection(
                    "In the menu bar",
                    footer: Text("Only the metrics turned on here are read, on the interval you choose. With none on, the icon alone shows and nothing is measured in the background.")
                ) {
                    preview
                    SettingsSeparator()
                    ForEach(Array(MenuBarMetric.allCases.enumerated()), id: \.element) { index, metric in
                        if index > 0 { SettingsSeparator(indented: true) }
                        SettingsRow(metric.title, symbol: metric.symbol) {
                            Toggle("", isOn: metricBinding(metric)).settingsSwitch()
                        }
                    }
                    SettingsSeparator()
                    SettingsRow("Style", detail: "Compact stacks a small label over each value.") {
                        Picker("Style", selection: $styleRaw) {
                            ForEach(MenuBarReadoutStyle.allCases) { style in
                                Text(style.title).tag(style.rawValue)
                            }
                        }
                        .settingsMenu()
                    }
                    SettingsSeparator()
                    SettingsRow("Update every", detail: "Longer intervals use less energy.") {
                        Picker("Update every", selection: $interval) {
                            Text("1 second").tag(1.0)
                            Text("2 seconds").tag(2.0)
                            Text("3 seconds").tag(3.0)
                            Text("5 seconds").tag(5.0)
                        }
                        .settingsMenu()
                    }
                    SettingsSeparator()
                    SettingsRow("Show the MacDash icon") {
                        Toggle("Show the MacDash icon", isOn: $showIcon).settingsSwitch()
                    }
                    SettingsSeparator()
                    SettingsRow("Alert colors", detail: "Orange or red when a value runs high.") {
                        Toggle("Alert colors", isOn: $alertColors).settingsSwitch()
                    }
                }

                SettingsSection(
                    "In the panel",
                    footer: Text("Cards you turn off aren't measured. Apps and Battery show more when you click them.")
                ) {
                    ForEach(Array(MenuBarPanelCard.allCases.enumerated()), id: \.element) { index, card in
                        if index > 0 { SettingsSeparator(indented: true) }
                        SettingsRow(card.title, symbol: card.symbol) {
                            Toggle("", isOn: cardBinding(card)).settingsSwitch()
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showInMenuBar)
    }

    /// The readout as it will look, drawn by the same code as the menu bar.
    private var preview: some View {
        let _ = refresh
        let metrics = MenuBarPreferences.metrics
        let image = MenuBarReadoutRenderer.image(
            values: .preview,
            metrics: metrics,
            style: MenuBarReadoutStyle(rawValue: styleRaw) ?? .stacked,
            alerts: false,
            icon: (showIcon || metrics.isEmpty) ? NSImage(systemSymbolName: "display", accessibilityDescription: nil) : nil
        )
        return HStack {
            Spacer()
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Spacer()
        }
        .padding(.vertical, 14)
        .accessibilityLabel("Menu bar preview")
    }

    private var showBinding: Binding<Bool> {
        Binding(
            get: { showInMenuBar },
            set: { newValue in
                showInMenuBar = newValue
                // Tell AppDelegate to add or remove the status item right away.
                NotificationCenter.default.post(name: .pureMacMenuBarMonitorChanged, object: nil)
            }
        )
    }

    private func metricBinding(_ metric: MenuBarMetric) -> Binding<Bool> {
        Binding(
            get: { _ = refresh; return UserDefaults.standard.bool(forKey: metric.defaultsKey) },
            set: {
                UserDefaults.standard.set($0, forKey: metric.defaultsKey)
                refresh += 1
            }
        )
    }

    private func cardBinding(_ card: MenuBarPanelCard) -> Binding<Bool> {
        Binding(
            get: { _ = refresh; return UserDefaults.standard.bool(forKey: card.defaultsKey) },
            set: {
                UserDefaults.standard.set($0, forKey: card.defaultsKey)
                refresh += 1
            }
        )
    }
}

// MARK: - About

/// Centered and quiet, like About This Mac.
struct AboutSettingsView: View {
    @State private var showLicenses = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                        .padding(.bottom, 18)
                }
                Text("MacDash")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(SettingsStyle.primary)
                Text(String(format: String(localized: "Version %@"), AppVersion.marketing)
                     + " (" + AppVersion.build + ")")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(SettingsStyle.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)

                Text("MacDash cleans your Mac: junk and caches, large files, app leftovers, unused apps, duplicate files and similar photos. It also uninstalls apps completely and checks protection settings and permissions. Nothing is removed without your approval.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
                    .padding(.top, 26)

                Text("It is built on the code of two open-source projects: PureMac (MIT License) and Mac Sai (BSD 3-Clause License).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsStyle.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .padding(.top, 14)

                HStack(spacing: 18) {
                    Link("macdash.app", destination: URL(string: "https://macdash.app")!)
                        .font(.system(size: 12))
                    Button("Open-source licenses") { showLicenses = true }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $showLicenses) { OpenSourceLicensesView() }
    }
}
