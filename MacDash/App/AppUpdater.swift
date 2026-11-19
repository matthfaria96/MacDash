import AppKit
import Combine
import Sparkle
import SwiftUI

/// In-app updates for MacDash itself through Sparkle, as in the other witchmymac apps (Sirena, Wineup).
/// The feed (SUFeedURL), the EdDSA public key (SUPublicEDKey) and the daily automatic check live in
/// Info.plist; versions are signed with the witchmymac EdDSA key and the app with the witchmymac
/// certificate, so macOS keeps MacDash's permissions (Full Disk Access, App Management) across updates.
///
/// Not to be confused with `SparkleUpdateChecker`/`SparkleInstaller`, which update other apps.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// False while a check or an install is already under way.
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    private init() {}

    /// Starts Sparkle's scheduler (daily check, from Info.plist). Call once at launch.
    /// Test copies with another bundle id don't check, unless MACDASH_UPDATES is set.
    func start() {
        guard controller == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.macdash.app" || env["MACDASH_UPDATES"] != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            DispatchQueue.main.async { self?.canCheckForUpdates = canCheck }
        }
        controller.startUpdater()
    }

    /// "Check for Updates…": always shows a result, even "You're up to date".
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// The app menu item and the button in Settings › About: disabled while a check is already under way.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
