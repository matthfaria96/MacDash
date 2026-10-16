import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owns the optional menu-bar status item. Nil until the monitor is enabled.
    private var menuBarController: MenuBarController?

    override init() {
        super.init()
        Self.migrateFromMacTidy()
        MenuBarPreferences.registerDefaults()
        // The menu bar panel is on unless the user turns it off in Settings.
        UserDefaults.standard.register(defaults: ["settings.general.menuBarMonitor": true])
    }

    /// MacFresh was called Mac Tidy (`com.mactidy.app`). On the first launch
    /// under the new name, its settings come along: onboarding, language,
    /// menu bar, schedules, exclusions and the rest.
    private static func migrateFromMacTidy() {
        let defaults = UserDefaults.standard
        let marker = "MacFresh.migratedFromMacTidy"
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)
        guard let old = UserDefaults(suiteName: "com.mactidy.app")?.persistentDomain(forName: "com.mactidy.app") else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "settings.general.menuBarMonitor")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "DebugIconGallery") {
            PremiumIconGallery.render(to: path)
            NSApp.terminate(nil)
            return
        }
        #endif
        NSWindow.allowsAutomaticWindowTabbing = false

        // Install the menu-bar monitor if the user has it enabled. Never under
        // XCTest — the status-item machinery would stall the test-host run loop.
        if NSClassFromString("XCTestCase") == nil {
            syncMenuBarMonitor()
            NotificationCenter.default.addObserver(
                self, selector: #selector(syncMenuBarMonitor),
                name: .pureMacMenuBarMonitorChanged, object: nil
            )
        }
        // Touch TCC-protected paths so macOS registers MacFresh in the
        // Full Disk Access pane on first launch (fixes issue #75).
        FullDiskAccessManager.shared.triggerRegistration()
        // Register the Finder Services provider so "Uninstall with MacFresh"
        // appears when an .app bundle is right-clicked (issue #109).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Create or tear down the menu-bar status item to match the current
    /// Settings toggle. Posted to whenever the toggle flips so it takes effect
    /// without a relaunch.
    @objc func syncMenuBarMonitor() {
        let enabled = UserDefaults.standard.bool(forKey: "settings.general.menuBarMonitor")
        if enabled, menuBarController == nil {
            menuBarController = MenuBarController()
            #if DEBUG
            if let detail = UserDefaults.standard.string(forKey: "DebugMenuBarPanel") {
                let controller = menuBarController
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { controller?.debugOpen(detail) }
            }
            #endif
        } else if !enabled, let controller = menuBarController {
            controller.teardown()
            menuBarController = nil
        }
    }

    /// Finder Services entry point. Declared in Info.plist as NSMessage
    /// `uninstallApp`; receives the right-clicked .app via the pasteboard and
    /// hands it to AppState through a notification. Brings MacFresh forward so
    /// the user lands on the uninstall scan.
    @objc func uninstallApp(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard let appURL = urls.first(where: { $0.pathExtension == "app" }) else {
            error?.pointee = String(localized: "Select an application (.app) to uninstall.") as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        // Buffer the path for the cold-launch case (AppState may not exist yet,
        // and NotificationCenter does not replay); AppState drains it in init.
        ExternalUninstallBuffer.pendingPath = appURL.path
        NotificationCenter.default.post(
            name: .pureMacExternalUninstall,
            object: nil,
            userInfo: ["path": appURL.path]
        )
    }
}

extension Notification.Name {
    /// Posted when the "Show system monitor in menu bar" Settings toggle flips,
    /// so AppDelegate can add/remove the status item live.
    static let pureMacMenuBarMonitorChanged = Notification.Name("MacFresh.MenuBarMonitorChanged")
}

@main
struct PureMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState(performStartupTasks: NSClassFromString("XCTestCase") == nil)
    @AppStorage("MacTidy.OnboardingComplete") private var onboardingComplete = false

    init() {
        AppAppearance.enforceDark()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if onboardingComplete {
                    MainWindow()
                        .environmentObject(appState)
                        .frame(minWidth: 1040, minHeight: 680)
                } else {
                    OnboardingView(isComplete: $onboardingComplete)
                }
            }
            .preferredColorScheme(.dark)
            // Record the openWindow action so the menu-bar popover can reopen
            // this window after it's been closed (the popover lives outside the
            // scene graph and can't use openWindow itself).
            .background(WindowOpenerCapture())
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(standalone: true)
                .environmentObject(appState)
                .environment(\.premiumIconsEnabled, false)
                .preferredColorScheme(.dark)
                .frame(minWidth: 680, idealWidth: 760, minHeight: 580, idealHeight: 700)
        }

    }
}
