import AppKit
import SwiftUI

// MARK: - Shared inspection

/// One inspection of startup items and local snapshots, shared by the
/// Applications screen (startup tab) and Smart Care (snapshots).
@MainActor
final class SystemInspectionModel: ObservableObject {
    static let shared = SystemInspectionModel()

    enum State {
        case idle
        case loading
        case loaded(PerformanceInspection)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var deletingSnapshotID: String?

    enum LoginItemsState: Equatable {
        case idle, loading, loaded, denied
        case failed(String)
    }

    @Published private(set) var loginItems: [LaunchItemControl.LoginItem] = []
    @Published private(set) var loginItemsState: LoginItemsState = .idle
    /// Login items switched off here; kept so they can be switched back on.
    @Published private(set) var removedLoginItems: [LaunchItemControl.LoginItem] = SystemInspectionModel.loadRemovedLoginItems()
    /// launchd's enabled/disabled overrides for the user's own agents.
    @Published private(set) var agentOverrides: [String: Bool] = [:]
    /// Rows with a change in progress.
    @Published private(set) var busyIDs: Set<String> = []

    private static let removedLoginItemsKey = "startup.removedLoginItems"

    private let inspector = PerformanceInspector()

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var inspection: PerformanceInspection? {
        if case .loaded(let inspection) = state { return inspection }
        return nil
    }

    var startupItems: [PerformanceStartupItem] { inspection?.startupItems ?? [] }
    var snapshots: [PerformanceSnapshot] { inspection?.snapshots ?? [] }
    var issues: [PerformanceInspectionIssue] { inspection?.issues ?? [] }

    func loadIfNeeded() async {
        if case .idle = state { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        state = .loading
        do {
            agentOverrides = await LaunchItemControl.userAgentOverrides()
            state = .loaded(try await inspector.inspect())
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Deletes one snapshot and re-reads the list. Returns an error message on failure.
    func delete(_ snapshot: PerformanceSnapshot) async -> String? {
        guard deletingSnapshotID == nil else { return nil }
        deletingSnapshotID = snapshot.id
        defer { deletingSnapshotID = nil }
        do {
            try await inspector.deleteSnapshot(snapshot)
            state = .loaded(try await inspector.inspect())
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Turning items on and off

    /// Only the user's own launch agents and login items can change without an
    /// administrator password; system-wide items stay read-only.
    func canToggle(_ item: PerformanceStartupItem) -> Bool {
        item.domain == .userAgent
    }

    func isEnabled(_ item: PerformanceStartupItem) -> Bool {
        if item.domain == .userAgent, let disabled = agentOverrides[item.label] {
            return !disabled
        }
        return !item.isDisabled
    }

    /// Returns an error message when the change fails.
    func setEnabled(_ item: PerformanceStartupItem, enabled: Bool) async -> String? {
        guard canToggle(item), !busyIDs.contains(item.id) else { return nil }
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        do {
            try await LaunchItemControl.setUserAgent(label: item.label, plistURL: item.sourceURL, enabled: enabled)
            agentOverrides = await LaunchItemControl.userAgentOverrides()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func loadLoginItems() async {
        guard loginItemsState != .loading else { return }
        loginItemsState = .loading
        do {
            let items = try await LaunchItemControl.loginItems()
            loginItems = items
            // Anything the user re-added elsewhere is no longer "removed here".
            let liveNames = Set(items.map(\.name))
            setRemovedLoginItems(removedLoginItems.filter { !liveNames.contains($0.name) })
            loginItemsState = .loaded
        } catch LaunchItemControl.ControlError.automationDenied {
            loginItemsState = .denied
        } catch {
            loginItemsState = .failed(error.localizedDescription)
        }
    }

    func setLoginItem(_ item: LaunchItemControl.LoginItem, enabled: Bool) async -> String? {
        let id = "login:" + item.name
        guard !busyIDs.contains(id) else { return nil }
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            if enabled {
                try await LaunchItemControl.addLoginItem(path: item.path)
                setRemovedLoginItems(removedLoginItems.filter { $0 != item })
            } else {
                try await LaunchItemControl.removeLoginItem(named: item.name)
                if !removedLoginItems.contains(item), !item.path.isEmpty {
                    setRemovedLoginItems(removedLoginItems + [item])
                }
            }
            loginItems = (try? await LaunchItemControl.loginItems()) ?? loginItems
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func setRemovedLoginItems(_ items: [LaunchItemControl.LoginItem]) {
        removedLoginItems = items
        UserDefaults.standard.set(items.map { ["name": $0.name, "path": $0.path] }, forKey: Self.removedLoginItemsKey)
    }

    private static func loadRemovedLoginItems() -> [LaunchItemControl.LoginItem] {
        let raw = UserDefaults.standard.array(forKey: removedLoginItemsKey) as? [[String: String]] ?? []
        return raw.compactMap { entry in
            guard let name = entry["name"], let path = entry["path"] else { return nil }
            return LaunchItemControl.LoginItem(name: name, path: path)
        }
    }

    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    static func openTimeMachineSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.TimeMachine-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Startup items tab

/// Everything that starts with the Mac: login items first, then launch agents
/// and daemons grouped by who they run for. The user's own items can be
/// switched on and off here.
struct StartupItemsView: View {
    @ObservedObject private var model = SystemInspectionModel.shared
    @State private var search = ""
    /// Switched-off items always stay listed so they can be switched back on.
    private let showDisabled = true
    @State private var errorMessage: String?

    private let tint = SectionPalette.apps.accent

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredItems: [PerformanceStartupItem] {
        model.startupItems.filter { item in
            (showDisabled || model.isEnabled(item))
                && (query.isEmpty
                    || item.label.localizedCaseInsensitiveContains(query)
                    || (item.program ?? "").localizedCaseInsensitiveContains(query))
        }
    }

    /// Live login items (on) followed by the ones switched off here (off).
    private var loginRows: [(item: LaunchItemControl.LoginItem, enabled: Bool)] {
        let rows = model.loginItems.map { ($0, true) } + (showDisabled ? model.removedLoginItems.map { ($0, false) } : [])
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.0.name.localizedCaseInsensitiveContains(query) || $0.0.path.localizedCaseInsensitiveContains(query) }
    }

    private var enabledCount: Int {
        model.loginItems.count + model.startupItems.filter(model.isEnabled).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch model.state {
                case .idle, .loading:
                    loadingCard
                case .failed(let message):
                    failureCard(message)
                case .loaded:
                    if !model.issues.isEmpty { issuesCard }
                    loginSection
                    ForEach(PerformanceStartupDomain.allCases, id: \.self) { domain in
                        let items = filteredItems.filter { $0.domain == domain }
                        if !items.isEmpty {
                            domainSection(domain, items: items)
                        }
                    }
                    if filteredItems.isEmpty && loginRows.isEmpty && model.loginItemsState == .loaded {
                        emptyCard
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            await model.loadIfNeeded()
            if model.loginItemsState == .idle { await model.loadLoginItems() }
        }
        .alert("The change could not be made", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Login items

    @ViewBuilder
    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Login items", count: model.loginItems.count) {
                Button {
                    SystemInspectionModel.openLoginItemsSettings()
                } label: {
                    Label("System Settings", systemImage: "gearshape")
                }
                .buttonStyle(GlassButtonStyle())
                .controlSize(.small)
                .help("Open Login Items in System Settings")
            }
            VStack(spacing: 0) {
                // The search filters every section below, but lives in the
                // first table so it reads as part of the list.
                InlineSearchField(prompt: "Find an item", text: $search)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.75)
                switch model.loginItemsState {
                case .idle, .loading:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading login items…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                    }
                    .padding(14)
                case .denied:
                    HStack(spacing: 12) {
                        CategoryBadge(systemName: "hand.raised.fill", tint: Tint.orange, size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Allow access to System Events")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Login items are read through System Events. Allow MacDash under Automation, then try again.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.65))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Open Settings") { SystemInspectionModel.openAutomationSettings() }
                            .buttonStyle(GlassButtonStyle())
                        Button("Try Again") { Task { await model.loadLoginItems() } }
                            .buttonStyle(GlassProminentButtonStyle())
                    }
                    .padding(14)
                case .failed(let message):
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tint.orange)
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Button("Try Again") { Task { await model.loadLoginItems() } }
                            .buttonStyle(GlassButtonStyle())
                    }
                    .padding(14)
                case .loaded:
                    if loginRows.isEmpty {
                        Text("No login items.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        ForEach(Array(loginRows.enumerated()), id: \.offset) { index, row in
                            LoginItemRow(
                                item: row.item,
                                isEnabled: row.enabled,
                                isBusy: model.busyIDs.contains("login:" + row.item.name),
                                tint: tint
                            ) { enabled in
                                Task { errorMessage = await model.setLoginItem(row.item, enabled: enabled) }
                            }
                            if index < loginRows.count - 1 {
                                Divider().opacity(0.4).padding(.leading, 62)
                            }
                        }
                    }
                }
            }
            .background(GlassPanelBackground(cornerRadius: 16))
        }
    }

    // MARK: Launch agents and daemons

    private func domainSection(_ domain: PerformanceStartupDomain, items: [PerformanceStartupItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(LocalizedStringKey(domain.title), count: items.count, hint: domainHint(domain))
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    StartupItemRow(
                        item: item,
                        isEnabled: model.isEnabled(item),
                        canToggle: model.canToggle(item),
                        isBusy: model.busyIDs.contains(item.id),
                        tint: tint
                    ) { enabled in
                        Task { errorMessage = await model.setEnabled(item, enabled: enabled) }
                    }
                    if index < items.count - 1 {
                        Divider().opacity(0.4).padding(.leading, 62)
                    }
                }
            }
            .background(GlassPanelBackground(cornerRadius: 16))
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, count: Int, hint: LocalizedStringKey) -> some View {
        sectionTitle(title, count: count) {
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func sectionTitle<Trailing: View>(
        _ title: LocalizedStringKey,
        count: Int,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            Spacer()
            trailing()
        }
    }

    private func domainHint(_ domain: PerformanceStartupDomain) -> LocalizedStringKey {
        switch domain {
        case .userAgent: return "Runs for your account"
        case .systemAgent: return "Runs for every account"
        case .systemDaemon: return "Runs before anyone logs in"
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Inspecting startup items and local snapshots…")
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
        .padding(20)
        .background(GlassPanelBackground(cornerRadius: 16))
    }

    private func failureCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CategoryBadge(systemName: "exclamationmark.triangle.fill", tint: Tint.orange, size: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text("Inspection stopped")
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(GlassPanelBackground(cornerRadius: 16))
    }

    private var emptyCard: some View {
        EmptyInspectionRow(
            systemImage: "checkmark.circle.fill",
            title: "No launchd items found",
            detail: "The inspected user and third-party launch folders are empty."
        )
        .background(GlassPanelBackground(cornerRadius: 16))
    }

    private var issuesCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.issues) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title)
                            .font(.system(size: 12, weight: .medium))
                        Text(issue.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Label("Some information could not be read (\(model.issues.count))", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tint.orange)
        }
        .padding(16)
        .background(GlassPanelBackground(cornerRadius: 16))
    }
}

/// The on/off control at the end of a startup row: a switch when the item can
/// change here, or a lock for system-wide items.
private struct StartupToggle: View {
    let isEnabled: Bool
    let canToggle: Bool
    let isBusy: Bool
    let tint: Color
    let onChange: (Bool) -> Void

    var body: some View {
        if isBusy {
            ProgressView().controlSize(.small).frame(width: 40)
        } else if canToggle {
            Toggle("", isOn: Binding(get: { isEnabled }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(tint)
                .help(isEnabled ? "Switch off so it no longer starts" : "Switch on so it starts again")
        } else {
            HStack(spacing: 6) {
                StatusChip(
                    label: isEnabled ? String(localized: "Enabled") : String(localized: "Disabled"),
                    systemImage: isEnabled ? "checkmark.circle.fill" : "pause.circle.fill",
                    tint: isEnabled ? Tint.green : .secondary
                )
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .help("System-wide items can only be changed in System Settings")
            }
        }
    }
}

private struct LoginItemRow: View {
    let item: LaunchItemControl.LoginItem
    let isEnabled: Bool
    let isBusy: Bool
    let tint: Color
    let onChange: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: IconCache.icon(forFile: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .opacity(isEnabled ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.55))
                    .lineLimit(1)
                Text((item.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            StartupToggle(isEnabled: isEnabled, canToggle: !item.path.isEmpty, isBusy: isBusy, tint: tint, onChange: onChange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? Color.white.opacity(0.04) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
            if !item.path.isEmpty {
                Button("Reveal in Finder") { SystemInspectionModel.reveal(URL(fileURLWithPath: item.path)) }
            }
        }
    }
}

private struct StartupItemRow: View {
    let item: PerformanceStartupItem
    let isEnabled: Bool
    let canToggle: Bool
    let isBusy: Bool
    let tint: Color
    let onChange: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if let appBundleURL {
                Image(nsImage: IconCache.icon(forFile: appBundleURL.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .opacity(isEnabled ? 1 : 0.5)
            } else {
                CategoryBadge(systemName: item.domain == .systemDaemon ? "gearshape.2.fill" : "bolt.horizontal.fill", tint: tint, size: 34)
                    .opacity(isEnabled ? 1 : 0.5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(programName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.55))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(item.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if !item.triggers.isEmpty {
                Text(item.triggers.joined(separator: " · "))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }

            Button {
                SystemInspectionModel.reveal(item.sourceURL)
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.45))
            .help("Reveal plist in Finder")
            .accessibilityLabel("Reveal plist in Finder")

            StartupToggle(isEnabled: isEnabled, canToggle: canToggle, isBusy: isBusy, tint: tint, onChange: onChange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? Color.white.opacity(0.04) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { SystemInspectionModel.reveal(item.sourceURL) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.sourceURL.path, forType: .string)
            }
        }
    }

    private var appBundleURL: URL? {
        guard let program = item.program else { return nil }
        let components = URL(fileURLWithPath: program).pathComponents
        guard let appIndex = components.lastIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(through: appIndex))))
    }

    private var programName: String {
        if let appBundleURL {
            let bundle = Bundle(url: appBundleURL)
            if let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !displayName.isEmpty {
                return displayName
            }
            if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
            return appBundleURL.deletingPathExtension().lastPathComponent
        }
        if let program = item.program {
            return URL(fileURLWithPath: program).deletingPathExtension().lastPathComponent
        }
        return item.label.split(separator: ".").suffix(2).joined(separator: " ")
    }
}

struct EmptyInspectionRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            PremiumIcon(systemName: systemImage, tint: Tint.green, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }
}

// MARK: - Local snapshots (shown from Smart Care)

/// Reviews Time Machine local snapshots, which hold disk space until macOS
/// releases them.
struct LocalSnapshotsSheet: View {
    @ObservedObject private var model = SystemInspectionModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: PerformanceSnapshot?
    @State private var deletionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CategoryBadge(systemName: "clock.arrow.circlepath", tint: SectionPalette.smartCare.accent, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local snapshots")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Time Machine snapshots can be reviewed and removed individually")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Time Machine Settings") { SystemInspectionModel.openTimeMachineSettings() }
                    .buttonStyle(GlassButtonStyle())
            }

            VStack(spacing: 0) {
                if model.isLoading {
                    HStack { ProgressView().controlSize(.small); Spacer() }.padding(18)
                } else if model.snapshots.isEmpty {
                    EmptyInspectionRow(
                        systemImage: "clock.badge.checkmark.fill",
                        title: "No local snapshots reported",
                        detail: "Time Machine did not report any snapshots for the startup disk."
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(model.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                                SnapshotRow(
                                    snapshot: snapshot,
                                    isDeleting: model.deletingSnapshotID == snapshot.id,
                                    deletionInProgress: model.deletingSnapshotID != nil
                                ) { pendingDeletion = snapshot }
                                if index < model.snapshots.count - 1 {
                                    Divider().opacity(0.4).padding(.leading, 58)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    Label("macOS does not report reliable per-snapshot sizes in this listing.", systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .background(GlassPanelBackground(cornerRadius: 16))

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GlassProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(AmbientBackdrop(palette: .smartCare))
        .task { await model.loadIfNeeded() }
        .alert("Delete local snapshot?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete Snapshot", role: .destructive) {
                guard let snapshot = pendingDeletion else { return }
                pendingDeletion = nil
                Task { deletionError = await model.delete(snapshot) }
            }
        } message: {
            if let snapshot = pendingDeletion {
                Text("This permanently removes \(snapshot.identifier). Its size is unknown, and the action cannot be undone.")
            }
        }
        .alert("Snapshot could not be deleted", isPresented: Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? String(localized: "Unknown error"))
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: PerformanceSnapshot
    let isDeleting: Bool
    let deletionInProgress: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CategoryBadge(
                systemName: snapshot.kind == .systemUpdate ? "arrow.down.circle.fill" : "clock.arrow.circlepath",
                tint: snapshot.kind == .systemUpdate ? Tint.orange : Tint.purple,
                size: 30
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(snapshot.kind.title)
                        .font(.system(size: 13, weight: .medium))
                    if let date = snapshot.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snapshot.identifier)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if PerformanceInspector.deletionTimestamp(for: snapshot) != nil {
                Button(role: .destructive, action: onDelete) {
                    if isDeleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .controlSize(.small)
                .disabled(deletionInProgress)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
