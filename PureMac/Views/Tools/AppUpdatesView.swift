import SwiftUI

enum AppUpdateIdentityMatcher {
    static func baseToken(_ token: String) -> String {
        let cask = token.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? token
        return cask.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? cask
    }

    static func normalizedKey(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    static func matchingIndex(for token: String, appNames: [String]) -> Int? {
        let key = normalizedKey(baseToken(token))
        guard !key.isEmpty else { return nil }
        let matches = appNames.indices.filter { normalizedKey(appNames[$0]) == key }
        return matches.count == 1 ? matches[0] : nil
    }

    static func fallbackDisplayName(for token: String) -> String {
        let words = baseToken(token)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? token : words.joined(separator: " ")
    }

    static func shouldShowTokenDetail(_ token: String) -> Bool {
        token.contains("@") || token.contains("/")
    }
}

@MainActor
struct AppUpdatesView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var updater: ApplicationUpdater
    @ObservedObject var sparkle: SparkleUpdateChecker
    @State private var showingUpgradeConfirmation = false
    @State private var confirmationSelection: [ManagedAppUpdate] = []

    init(updater: ApplicationUpdater, sparkle: SparkleUpdateChecker) {
        _updater = StateObject(wrappedValue: updater)
        self.sparkle = sparkle
    }

    private var isChecking: Bool { sparkle.isChecking || updater.isChecking }
    private var hasChecked: Bool { sparkle.hasChecked || updater.hasChecked || updater.errorMessage != nil }

    /// One search covers apps with their own updater and Homebrew casks.
    private func startCheck() {
        sparkle.start()
        if updater.isHomebrewAvailable { updater.startCheck() }
    }

    private func cancelCheck() {
        sparkle.cancel()
        updater.cancelCheck()
    }

    private func reset() {
        sparkle.reset()
        updater.reset()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusRow

                if let status = updater.statusMessage {
                    statusCard(status)
                }

                content
                unmanagedAppsCard
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .alert("Upgrade selected apps?", isPresented: $showingUpgradeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(upgradeConfirmationLabel(count: confirmationSelection.count)) {
                let selection = confirmationSelection
                updater.startUpgrade(selection)
            }
        } message: {
            Text(upgradeConfirmationMessage)
        }
        .onAppear {
            updater.refreshAvailability()
        }
        .task {
            // Opening the tab starts the search; later visits keep the last result.
            if !hasChecked && !isChecking {
                updater.refreshAvailability()
                startCheck()
            }
        }
    }

    /// Slim status row: Stop while checking, otherwise when it last ran.
    @ViewBuilder
    private var statusRow: some View {
        if isChecking {
            HStack {
                Spacer()
                StopActionButton { cancelCheck() }
            }
        } else if hasChecked, let date = sparkle.lastCheckedAt ?? updater.lastCheckedAt {
            HStack(spacing: 6) {
                Spacer()
                Text("Last checked")
                    .foregroundStyle(.white.opacity(0.5))
                Text(date, style: .relative)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isChecking {
            // Results show up as they arrive; the bar says how far along it is.
            checkingProgress
            sparkleSection
            homebrewSection
        } else if !hasChecked {
            CardSurface(padding: 28, elevation: .standard) {
                VStack(spacing: 14) {
                    GlassOrbIcon(systemImage: "arrow.triangle.2.circlepath", tint: SectionPalette.apps.accent, size: 69)
                    Text("Check your apps for updates")
                        .font(.title3.weight(.semibold))
                    Text("MacFresh reads the update feed of every app that has its own updater, and asks Homebrew about the apps it manages.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                    Button("Check for Updates") {
                        startCheck()
                    }
                    .buttonStyle(GlassProminentButtonStyle(large: true))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        } else {
            sparkleSection
            homebrewSection
        }
    }

    // MARK: Apps with their own updater

    private var checkingProgress: some View {
        let total = max(sparkle.appsTotal, 1)
        let fraction = sparkle.appsTotal == 0 ? 0 : Double(sparkle.appsChecked) / Double(total)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if sparkle.isChecking, sparkle.appsTotal > 0 {
                    Text(String(format: String(localized: "%lld of %lld apps"), Int64(sparkle.appsChecked), Int64(sparkle.appsTotal)))
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            GlowProgressBar(progress: sparkle.isChecking ? fraction : 1, tint: SectionPalette.apps.accent)
                .frame(height: 6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(GlassPanelBackground(cornerRadius: 16))
    }

    @ViewBuilder
    private var sparkleSection: some View {
        if sparkle.isChecking && sparkle.updates.isEmpty {
            EmptyView()
        } else if sparkle.hasChecked || sparkle.isChecking {
            if sparkle.updates.isEmpty {
                quietRow(
                    icon: "checkmark.circle.fill",
                    tint: Tint.green,
                    text: String(format: String(localized: "Apps with their own updater are up to date (%lld checked)."), Int64(sparkle.appsChecked))
                )
            } else {
                CardSurface(padding: 0, elevation: .standard) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sparkle.updates.count == 1 ? String(localized: "1 update available") : String(localized: "\(sparkle.updates.count) updates available"))
                                    .font(.headline)
                                Text("Apps with their own updater")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            sparkleBatchControls
                        }
                        .padding(16)
                        UpdatesTable(checker: sparkle)
                    }
                }
            }
        }
    }

    /// Update all (one after another), or progress and Cancel while it runs.
    @ViewBuilder
    private var sparkleBatchControls: some View {
        if sparkle.isBatchRunning {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(String(format: String(localized: "%lld of %lld"), Int64(sparkle.batchDone), Int64(sparkle.batchTotal)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                Button("Cancel") { sparkle.cancelInstalls() }
                    .buttonStyle(GlassButtonStyle())
            }
        } else if !sparkle.installable.isEmpty {
            Button {
                sparkle.updateAll()
            } label: {
                UpdateAllLabel(count: sparkle.installable.count)
            }
            .buttonStyle(UpdateAllButtonStyle())
            .disabled(sparkle.isInstalling)
            .help("Downloads and installs every update here, one after another. The old versions go to the Trash.")
        }
    }

    // MARK: Homebrew

    @ViewBuilder
    private var homebrewSection: some View {
        if updater.isChecking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Asking Homebrew for newer versions…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(GlassPanelBackground(cornerRadius: 16))
        } else if !updater.isHomebrewAvailable {
            quietRow(icon: "shippingbox", tint: .secondary, text: String(localized: "Homebrew is not installed, so cask apps were not checked."))
        } else if let error = updater.errorMessage {
            CardSurface(padding: 22, elevation: .standard, tint: Tint.red) {
                HStack(alignment: .top, spacing: 14) {
                    CategoryBadge(systemName: "exclamationmark.triangle.fill", tint: Tint.red, size: 36)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Couldn't check Homebrew")
                            .font(.headline)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
            }
        } else if updater.hasChecked && updater.updates.isEmpty {
            quietRow(icon: "checkmark.circle.fill", tint: Tint.green, text: String(localized: "Homebrew apps are up to date."))
        } else if !updater.updates.isEmpty {
            updatesCard
        }
    }


    private func quietRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(GlassPanelBackground(cornerRadius: 16))
    }

    private var updatesCard: some View {
        CardSurface(padding: 0, elevation: .standard) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateCountTitle)
                            .font(.headline)
                        Text("Homebrew apps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if updater.isUpgrading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Homebrew is updating…")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                            Button("Cancel") { updater.cancelUpgrade() }
                                .buttonStyle(GlassButtonStyle())
                        }
                    } else if updater.updates.contains(where: { !$0.isPinned }) {
                        Button {
                            confirmationSelection = updater.updates.filter { !$0.isPinned }
                            showingUpgradeConfirmation = true
                        } label: {
                            UpdateAllLabel(count: updater.updates.filter { !$0.isPinned }.count)
                        }
                        .buttonStyle(UpdateAllButtonStyle())
                        .disabled(updater.isBusy)
                    }
                }
                .padding(16)

                LazyVStack(spacing: 0) {
                    ForEach(Array(updater.updates.enumerated()), id: \.element.id) { index, update in
                        BrewUpdateRow(
                            update: update,
                            displayName: displayName(for: update.token),
                            icon: installedApp(for: update.token)?.icon ?? updater.caskPresentations[update.token]?.icon,
                            presentation: updater.caskPresentations[update.token],
                            isUpgrading: updater.upgradingTokens.contains(update.token),
                            isDisabled: updater.isBusy || update.isPinned,
                            isStriped: index.isMultiple(of: 2)
                        ) {
                            confirmationSelection = [update]
                            showingUpgradeConfirmation = true
                        }
                    }
                }
            }
        }
    }


    private func installedApp(for token: String) -> InstalledApp? {
        let names = appState.installedApps.map(\.appName)
        guard let index = AppUpdateIdentityMatcher.matchingIndex(for: token, appNames: names) else { return nil }
        return appState.installedApps[index]
    }

    private func displayName(for token: String) -> String {
        installedApp(for: token)?.appName
            ?? updater.caskPresentations[token]?.displayName
            ?? AppUpdateIdentityMatcher.fallbackDisplayName(for: token)
    }

    private func updateDetail(_ update: ManagedAppUpdate) -> String {
        let installed = String(localized: "Installed \(update.installedVersion)")
        guard AppUpdateIdentityMatcher.shouldShowTokenDetail(update.token) else { return installed }
        return String(localized: "\(update.token)  ·  \(installed)")
    }

    /// App Store apps update in the App Store itself, so this points there
    /// in the App Store's own look.
    private var unmanagedAppsCard: some View {
        HStack(spacing: 16) {
            Image(nsImage: IconCache.icon(forFile: "/System/Applications/App Store.app"))
                .resizable()
                .frame(width: 58, height: 58)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("App Store")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Apps you got from the App Store are updated there. The Updates page opens in the App Store app.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                updater.openAppStoreUpdates()
            } label: {
                HStack(spacing: 6) {
                    Text("Open App Store")
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(red: 0.0, green: 0.48, blue: 1.0)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6))
                .shadow(color: Color(red: 0.0, green: 0.48, blue: 1.0).opacity(0.45), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.05, green: 0.45, blue: 1.0).opacity(0.35), Color(red: 0.25, green: 0.2, blue: 0.9).opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(GlassEdge.gradient, lineWidth: 0.8))
    }

    private func stateCard(title: LocalizedStringKey, message: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        CardSurface(padding: 28, elevation: .standard, tint: tint) {
            VStack(spacing: 12) {
                GlassOrbIcon(systemImage: systemImage, tint: tint, size: 69)
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func statusCard(_ status: String) -> some View {
        CardSurface(padding: 14, elevation: .flat, tint: Tint.green) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Tint.green)
                Text(status)
                    .font(.callout.weight(.medium))
                Spacer()
            }
        }
    }

    private var updateCountTitle: String {
        updater.updates.count == 1 ? String(localized: "1 update available") : String(localized: "\(updater.updates.count) updates available")
    }

    private var selectedCountTitle: String {
        updater.selectedCount == 1 ? String(localized: "1 app selected") : String(localized: "\(updater.selectedCount) apps selected")
    }

    private func upgradeConfirmationLabel(count: Int) -> String {
        count == 1 ? String(localized: "Upgrade 1 App") : String(localized: "Upgrade \(count) Apps")
    }

    private var upgradeConfirmationMessage: String {
        let versions = confirmationSelection.map {
            String(localized: "\(displayName(for: $0.token)) \($0.installedVersion) to \($0.currentVersion)")
        }
        let selectionSummary: String
        if versions.count <= 5 {
            selectionSummary = versions.joined(separator: ", ")
        } else {
            selectionSummary = versions.prefix(5).joined(separator: ", ") + String(localized: ", and \(versions.count - 5) more")
        }
        return String(localized: "Homebrew will upgrade \(selectionSummary). It may quit running apps and remove superseded cask versions as part of its normal upgrade process.")
    }
}

// MARK: - Updates table

/// Apps with an update, as a sortable table: click a column title to sort,
/// click again to flip the order.
private struct UpdatesTable: View {
    enum Column { case name, size, updated }

    @ObservedObject var checker: SparkleUpdateChecker

    @State private var column: Column = .name
    @State private var ascending = true

    private var sorted: [SparkleAppUpdate] {
        let ordered = checker.updates.sorted { lhs, rhs in
            switch column {
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size: return lhs.size < rhs.size
            case .updated: return (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
            }
        }
        return ascending ? ordered : ordered.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                header("App", .name).frame(maxWidth: .infinity, alignment: .leading)
                Text("Version").frame(width: 140, alignment: .leading)
                header("Size", .size).frame(width: 74, alignment: .trailing)
                header("Updated", .updated).frame(width: 84, alignment: .trailing)
                Color.clear.frame(width: 34, height: 1)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.04))

            LazyVStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, update in
                    UpdateTableRow(
                        update: update,
                        state: checker.installStates[update.id],
                        isBusy: checker.isInstalling,
                        isStriped: index.isMultiple(of: 2)
                    ) {
                        checker.update(update)
                    }
                }
            }
        }
    }

    private func header(_ title: LocalizedStringKey, _ target: Column) -> some View {
        let isCurrent = column == target
        return Button {
            if isCurrent { ascending.toggle() } else { column = target; ascending = target == .name }
        } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1).minimumScaleFactor(0.75)
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(isCurrent ? 1 : 0)
            }
            .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help("Sort by this column")
    }
}

/// A round glass button holding one symbol, like the toolbar buttons of macOS.

/// The action column: update icon, progress ring, or a warning with the reason.
private struct UpdateActionButton: View {
    let state: SparkleUpdateChecker.InstallState?
    let isMacAppStore: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        switch state {
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 30, height: 30)
                .help("Waiting to update")
        case .downloading(let fraction):
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(SectionPalette.apps.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: fraction)
            }
            .frame(width: 22, height: 22)
            .frame(width: 30, height: 30)
            .help("Updating…")
        case .failed(let message):
            Button(action: action) {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .buttonStyle(GlassIconButtonStyle(tint: Tint.orange))
            .help(message)
        case nil:
            Button(action: action) {
                Image(systemName: isMacAppStore ? "bag" : "arrow.down")
            }
            .buttonStyle(GlassIconButtonStyle(tint: SectionPalette.apps.accent))
            .disabled(isBusy && !isMacAppStore)
            .help(isMacAppStore ? "Open the App Store" : "Download and install this update")
            .accessibilityLabel(isMacAppStore ? "Open App Store" : "Update")
        }
    }
}

private struct UpdateTableRow: View {
    let update: SparkleAppUpdate
    let state: SparkleUpdateChecker.InstallState?
    let isBusy: Bool
    let isStriped: Bool
    let perform: () -> Void
    @State private var showInfo = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: IconCache.icon(forFile: update.appURL.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(update.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Button { showInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                .help("About this app")
                .accessibilityLabel("About \(update.name)")
                .popover(isPresented: $showInfo, arrowEdge: .trailing) { AppUpdateInfoView(update: update) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Text(update.installedVersion)
                    .foregroundStyle(.white.opacity(0.5))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
                Text(update.availableVersion)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tint.green)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .lineLimit(1)
            .frame(width: 140, alignment: .leading)
            Text(update.size > 0 ? ByteCountFormatter.string(fromByteCount: update.size, countStyle: .file) : "—")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 74, alignment: .trailing)
            Text(update.updatedAt.map { $0.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits)) } ?? "—")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 84, alignment: .trailing)
            UpdateActionButton(state: state, isMacAppStore: update.isMacAppStore, isBusy: isBusy, action: perform)
                .frame(width: 34)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.white.opacity(hovering ? 0.07 : (isStriped ? 0.025 : 0)))
        .onHover { hovering = $0 }
    }
}

/// A Homebrew app with an update, in the same style as the table above.
private struct BrewUpdateRow: View {
    let update: ManagedAppUpdate
    let displayName: String
    let icon: NSImage?
    let presentation: InstalledCaskPresentation?
    let isUpgrading: Bool
    let isDisabled: Bool
    let isStriped: Bool
    let perform: () -> Void
    @State private var showInfo = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        // Formulae and casks without an app bundle have no icon of their own.
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(red: 0.98, green: 0.71, blue: 0.25))
                            .frame(width: 28, height: 28)
                            .background(Color(red: 0.98, green: 0.71, blue: 0.25).opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if update.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Tint.orange)
                        .help("Pinned in Homebrew; it won't be upgraded")
                }
                Button { showInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                .help("About this app")
                .accessibilityLabel("About \(displayName)")
                .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                    BrewInfoView(update: update, displayName: displayName, icon: icon, presentation: presentation)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Text(update.installedVersion)
                    .foregroundStyle(.white.opacity(0.5))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
                Text(update.currentVersion)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tint.green)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .lineLimit(1)
            .frame(width: 140 + 74 + 84 + 24, alignment: .leading)

            Group {
                if isUpgrading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: perform) { Image(systemName: "arrow.down") }
                        .buttonStyle(GlassIconButtonStyle(tint: SectionPalette.apps.accent))
                        .disabled(isDisabled)
                        .help("Update with Homebrew")
                        .accessibilityLabel("Update")
                }
            }
            .frame(width: 34)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.white.opacity(hovering ? 0.07 : (isStriped ? 0.025 : 0)))
        .onHover { hovering = $0 }
    }
}

/// What Homebrew knows about a cask.
private struct BrewInfoView: View {
    let update: ManagedAppUpdate
    let displayName: String
    let icon: NSImage?
    let presentation: InstalledCaskPresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                } else {
                    PremiumIcon(systemName: "shippingbox.fill", tint: Color(red: 0.98, green: 0.71, blue: 0.25), size: 44)
                        .frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName).font(.headline)
                    Text(update.token)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let summary = presentation?.summary {
                Text(summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Installed").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text(update.installedVersion).font(.system(size: 11.5, weight: .medium))
                }
                GridRow {
                    Text("Available").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text(update.currentVersion).font(.system(size: 11.5, weight: .medium))
                }
                GridRow {
                    Text("Source").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text("Homebrew").font(.system(size: 11.5, weight: .medium))
                }
                if let path = presentation?.bundlePath {
                    GridRow {
                        Text("Location").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            HStack {
                if let homepage = presentation?.homepage {
                    Link(destination: homepage) {
                        Label("Website", systemImage: "safari")
                    }
                    .font(.caption)
                }
                Spacer()
                if let path = presentation?.bundlePath, FileManager.default.fileExists(atPath: path) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}

/// Everything known about an app with an update, in a popover.
private struct AppUpdateInfoView: View {
    let update: SparkleAppUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: IconCache.icon(forFile: update.appURL.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(update.name).font(.headline)
                    Text(update.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                row("Installed", update.installedVersion)
                row("Available", update.availableVersion)
                row("Size", update.size > 0 ? ByteCountFormatter.string(fromByteCount: update.size, countStyle: .file) : nil)
                row("Developer", update.developer)
                row("Category", update.category)
                row("Requires", update.minimumSystem.map { "macOS \($0)" })
                row("Installed on", update.installedAt?.formatted(date: .long, time: .omitted))
                row("Updated", update.updatedAt?.formatted(date: .long, time: .omitted))
                row("Last opened", update.lastOpenedAt?.formatted(date: .long, time: .omitted))
                row("Source", update.isMacAppStore ? String(localized: "App Store") : String(localized: "Direct download"))
                row("Update feed", update.feedHost)
            }
            HStack {
                Text((update.appURL.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([update.appURL])
                }
                .controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }
}

/// "Update all" with how many apps it covers.
private struct UpdateAllLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down")
                .font(.system(size: 10.5, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.22)))
            Text("Update all")
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.18)))
        }
    }
}

/// A tinted Liquid Glass capsule: the accent color under a clear, lit glass
/// layer, the way prominent buttons look in macOS 27.
private struct UpdateAllButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        UpdateAllButtonBody(configuration: configuration)
    }

    private struct UpdateAllButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        private let accent = SectionPalette.apps.accent
        private let deep = SectionPalette.apps.primary

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill(LinearGradient(colors: [accent, deep], startPoint: .top, endPoint: .bottom))
                    // Specular sheen across the top half.
                    Capsule().fill(LinearGradient(colors: [Color.white.opacity(hovering ? 0.38 : 0.28), .clear], startPoint: .top, endPoint: .center))
                        .padding(1)
                }
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
                .shadow(color: accent.opacity(hovering ? 0.55 : 0.35), radius: hovering ? 12 : 8, y: 3)
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering && isEnabled ? 1.02 : 1))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .animation(MotionTokens.snappy, value: hovering)
                .animation(MotionTokens.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}
