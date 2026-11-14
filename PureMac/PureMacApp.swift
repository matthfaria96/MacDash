import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owns the optional menu-bar status item. Nil until the monitor is enabled.
    private var menuBarController: MenuBarController?

    override init() {
        super.init()
        Self.migrateFromMacFresh()
        Self.migrateFromMacTidy()
        MenuBarPreferences.registerDefaults()
        // The menu bar panel is on unless the user turns it off in Settings.
        UserDefaults.standard.register(defaults: ["settings.general.menuBarMonitor": true])
    }

    /// MacDash was called MacFresh (`com.macfresh.app`). On the first launch
    /// under the new name, its settings come along; `MacFresh.`-prefixed keys
    /// are carried over under the `MacDash.` prefix.
    private static func migrateFromMacFresh() {
        let defaults = UserDefaults.standard
        let marker = "MacDash.migratedFromMacFresh"
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)
        guard let old = UserDefaults(suiteName: "com.macfresh.app")?.persistentDomain(forName: "com.macfresh.app") else { return }
        for (oldKey, value) in old {
            let key = oldKey.hasPrefix("MacFresh.") ? "MacDash." + oldKey.dropFirst("MacFresh.".count) : oldKey
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }

    /// Before MacFresh it was Mac Tidy (`com.mactidy.app`). Runs after the
    /// MacFresh migration, which carries its marker over, so settings that
    /// were already migrated once are not imported again.
    private static func migrateFromMacTidy() {
        let defaults = UserDefaults.standard
        let marker = "MacDash.migratedFromMacTidy"
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)
        guard let old = UserDefaults(suiteName: "com.mactidy.app")?.persistentDomain(forName: "com.mactidy.app") else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // System Settings sends this after Full Disk Access is turned on
        // ("Quit & Reopen"), and the Dock sends it too.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication)
        )
    }

    /// macdash://analyze?path=… from the Finder menu. The window's onOpenURL
    /// may get the same link; the second call finds nothing left to do.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where AssistantStore.handle(url) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Quits even with a sheet open, and remembers to come back to the same
    /// place when the quit is the reopen that grants access.
    @objc func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        if PermissionCoordinator.shared.wantsResume {
            UserDefaults.standard.set(true, forKey: PermissionCoordinator.resumeKey)
        }
        PermissionCoordinator.quitClosingSheets()
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
        // MACDASH_DEMO=1 (site screenshots): no menu bar item, Full Disk Access touch or updater.
        if DemoMode.isActive { return }

        // Install the menu-bar monitor if the user has it enabled. Never under
        // XCTest — the status-item machinery would stall the test-host run loop.
        if NSClassFromString("XCTestCase") == nil {
            syncMenuBarMonitor()
            NotificationCenter.default.addObserver(
                self, selector: #selector(syncMenuBarMonitor),
                name: .pureMacMenuBarMonitorChanged, object: nil
            )
        }
        // Touch TCC-protected paths so macOS registers MacDash in the
        // Full Disk Access pane on first launch (fixes issue #75).
        FullDiskAccessManager.shared.triggerRegistration()
        // Register the Finder Services provider so "Uninstall with MacDash"
        // appears when an .app bundle is right-clicked (issue #109).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // In-app updates (Sparkle): daily check and the Check for Updates… item.
        if NSClassFromString("XCTestCase") == nil {
            AppUpdater.shared.start()
        }
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
    /// hands it to AppState through a notification. Brings MacDash forward so
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
    static let pureMacMenuBarMonitorChanged = Notification.Name("MacDash.MenuBarMonitorChanged")
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
            // A macdash:// link from Finder goes to the open window instead of
            // opening a second one.
            .handlesExternalEvents(preferring: ["macdash"], allowing: ["*"])
            .onOpenURL { _ = AssistantStore.handle($0) }
            // Record the openWindow action so the menu-bar popover can reopen
            // this window after it's been closed (the popover lives outside the
            // scene graph and can't use openWindow itself).
            .background(WindowOpenerCapture())
        }
        .handlesExternalEvents(matching: ["macdash"])
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
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
