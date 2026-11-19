import Foundation

/// The only place that knows MacDash's former names (MacFresh, before it
/// Mac Tidy). Copies of those apps left settings behind; on launch they are
/// carried over once, and the old identifiers are kept here so MacDash still
/// recognizes its own files. Nothing else in the code should spell them.
enum LegacyMigration {
    /// Bundle-identifier prefixes MacDash shipped under before. Its own launch
    /// items and support files under them are never flagged or offered for removal.
    static let formerBundlePrefixes = ["com.macfresh", "com.mactidy"]

    /// Runs once per launch, before any setting is read.
    static func run() {
        importMacFreshSettings()
        importMacTidySettings()
        renameKeys()
    }

    /// MacDash was called MacFresh (`com.macfresh.app`). On the first launch
    /// under the new name, its settings come along; `MacFresh.`-prefixed keys
    /// are carried over under the `MacDash.` prefix.
    private static func importMacFreshSettings() {
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
    /// MacFresh import, which carries its marker over, so settings that were
    /// already migrated once are not imported again.
    private static func importMacTidySettings() {
        let defaults = UserDefaults.standard
        let marker = "MacDash.migratedFromMacTidy"
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)
        guard let old = UserDefaults(suiteName: "com.mactidy.app")?.persistentDomain(forName: "com.mactidy.app") else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Keys that kept the old name after the move to MacDash (1.5 and earlier).
    /// Without this, onboarding would show again and the menu bar item would
    /// lose its place.
    static let renamedKeys: [(old: String, new: String)] = [
        ("MacTidy.OnboardingComplete", "MacDash.OnboardingComplete"),
        ("MacTidy.lastScanDate", "MacDash.lastScanDate"),
        ("MacTidy.lastCleanDate", "MacDash.lastCleanDate"),
        ("MacTidy.SidebarCompact", "MacDash.SidebarCompact"),
        ("mactidy.motion", "MacDash.motion"),
        ("NSStatusItem Preferred Position MacTidySystemMonitor", "NSStatusItem Preferred Position MacDashSystemMonitor"),
        ("NSStatusItem Visible MacTidySystemMonitor", "NSStatusItem Visible MacDashSystemMonitor"),
    ]

    static func renameKeys(in defaults: UserDefaults = .standard) {
        for (old, new) in renamedKeys {
            guard let value = defaults.object(forKey: old) else { continue }
            if defaults.object(forKey: new) == nil {
                defaults.set(value, forKey: new)
            }
            defaults.removeObject(forKey: old)
        }
    }
}
